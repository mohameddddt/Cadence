import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';

import 'api_cache.dart';
import 'rate_limiter.dart';

/// Thrown for non-2xx answers (after retries) and for transport failures.
class HttpFailure implements Exception {
  HttpFailure(this.message, {this.statusCode, this.uri});

  final String message;
  final int? statusCode;
  final Uri? uri;

  bool get isNotFound => statusCode == 404;

  @override
  String toString() => 'HttpFailure(${statusCode ?? '-'}: $message${uri == null ? '' : ' @ ${uri!.host}${uri!.path}'})';
}

/// Single entry point for every HTTP call in the app.
///
/// * sets the descriptive User-Agent MusicBrainz & co. require,
/// * paces requests per host through [HostRateLimiter],
/// * caches JSON responses in [ApiCache],
/// * retries 429/5xx/timeouts with back-off.
class HttpService {
  HttpService({
    required String Function() userAgent,
    Dio? dio,
    HostRateLimiter? limiter,
    ApiCache? cache,
    this.maxAttempts = 3,
    Future<void> Function(Duration)? sleep,
  })  : _userAgent = userAgent,
        limiter = limiter ?? HostRateLimiter(),
        cache = cache ?? MemoryApiCache(),
        dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 30),
              followRedirects: true,
              maxRedirects: 5,
              validateStatus: (_) => true, // handled below so we can retry and map errors
            )),
        _sleep = sleep ?? Future<void>.delayed;

  final Dio dio;
  final HostRateLimiter limiter;
  final ApiCache cache;
  final int maxAttempts;
  final String Function() _userAgent;
  final Future<void> Function(Duration) _sleep;

  static const Duration longTtl = Duration(days: 30); // MBIDs are stable
  static const Duration mediumTtl = Duration(days: 3);
  static const Duration shortTtl = Duration(hours: 6);

  Future<Response<T>> _send<T>(
    String method,
    String url, {
    Map<String, dynamic>? query,
    Object? data,
    Map<String, String>? headers,
    ResponseType? responseType,
    String? contentType,
    CancelToken? cancel,
    Duration? receiveTimeout,
  }) async {
    final uri = buildUri(url, query);
    final effective = uri;
    Object? lastError;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      await limiter.acquire(effective.host);
      try {
        final res = await dio.requestUri<T>(
          effective,
          data: data,
          cancelToken: cancel,
          options: Options(
            method: method,
            responseType: responseType,
            contentType: contentType,
            receiveTimeout: receiveTimeout,
            headers: {
              'User-Agent': _userAgent(),
              'Accept': 'application/json, text/plain;q=0.9, */*;q=0.5',
              ...?headers,
            },
          ),
        );
        final code = res.statusCode ?? 0;
        if (code >= 200 && code < 300) return res;
        if ((code == 429 || code == 503 || code >= 500) && attempt < maxAttempts) {
          await _sleep(_backoff(attempt, res.headers.value('retry-after')));
          continue;
        }
        throw HttpFailure(_snippet(res.data) ?? 'HTTP $code', statusCode: code, uri: effective);
      } on DioException catch (e) {
        if (e.type == DioExceptionType.cancel) rethrow;
        lastError = e;
        if (attempt < maxAttempts) {
          await _sleep(_backoff(attempt, null));
          continue;
        }
        throw HttpFailure(e.message ?? e.type.name, uri: effective);
      }
    }
    throw HttpFailure('$lastError', uri: effective);
  }

  /// Merges [query] into [url]. A list value repeats the key (`fl[]=a&fl[]=b`); null skips it.
  static Uri buildUri(String url, Map<String, dynamic>? query) {
    final base = Uri.parse(url);
    final params = <String, List<String>>{
      for (final e in base.queryParametersAll.entries) e.key: List.of(e.value),
    };
    if (query != null) {
      for (final e in query.entries) {
        final v = e.value;
        if (v == null) continue;
        params[e.key] = v is Iterable ? [for (final x in v) x.toString()] : [v.toString()];
      }
    }
    if (params.isEmpty) return base;
    return base.replace(queryParameters: params);
  }

  Duration _backoff(int attempt, String? retryAfter) {
    final ra = int.tryParse(retryAfter ?? '');
    if (ra != null) return Duration(seconds: min(ra, 30));
    return Duration(milliseconds: 500 * pow(2, attempt - 1).toInt());
  }

  String? _snippet(Object? data) {
    if (data == null) return null;
    final s = data is String ? data : jsonEncode(data);
    return s.length > 160 ? s.substring(0, 160) : s;
  }

  /// GET returning decoded JSON. Cached for [ttl] (pass null to bypass the cache).
  Future<dynamic> getJson(
    String url, {
    Map<String, dynamic>? query,
    Map<String, String>? headers,
    Duration? ttl,
    CancelToken? cancel,
  }) async {
    final uri = buildUri(url, query);
    // Auth headers must not split the cache, but Accept-Language style ones should.
    final vary = headers == null ? null : (Map<String, String>.of(headers)..remove('Authorization'));
    final key = ApiCache.keyFor('GET', uri, vary: vary);
    if (ttl != null) {
      final hit = await cache.get(key);
      if (hit != null) return jsonDecode(hit);
    }
    final res = await _send<String>('GET', url,
        query: query, headers: headers, responseType: ResponseType.plain, cancel: cancel);
    final body = res.data ?? '';
    final decoded = body.isEmpty ? null : jsonDecode(body);
    if (ttl != null) await cache.put(key, body, ttl);
    return decoded;
  }

  /// Like [getJson] but returns null on 404.
  Future<dynamic> getJsonOrNull(
    String url, {
    Map<String, dynamic>? query,
    Map<String, String>? headers,
    Duration? ttl,
    CancelToken? cancel,
  }) async {
    try {
      return await getJson(url, query: query, headers: headers, ttl: ttl, cancel: cancel);
    } on HttpFailure catch (e) {
      if (e.isNotFound) return null;
      rethrow;
    }
  }

  Future<String> getText(
    String url, {
    Map<String, dynamic>? query,
    Map<String, String>? headers,
    Duration? ttl,
    CancelToken? cancel,
  }) async {
    final uri = buildUri(url, query);
    final key = ApiCache.keyFor('GET-text', uri);
    if (ttl != null) {
      final hit = await cache.get(key);
      if (hit != null) return hit;
    }
    final res = await _send<String>('GET', url,
        query: query, headers: headers, responseType: ResponseType.plain, cancel: cancel);
    final body = res.data ?? '';
    if (ttl != null) await cache.put(key, body, ttl);
    return body;
  }

  Future<List<int>> getBytes(String url, {Map<String, String>? headers, CancelToken? cancel}) async {
    final res = await _send<List<int>>('GET', url, headers: headers, responseType: ResponseType.bytes, cancel: cancel);
    return res.data ?? const [];
  }

  /// POST a JSON body (never cached).
  Future<dynamic> postJson(
    String url, {
    Object? body,
    Map<String, String>? headers,
    Map<String, dynamic>? query,
    CancelToken? cancel,
  }) async {
    final res = await _send<String>(
      'POST',
      url,
      query: query,
      data: jsonEncode(body),
      headers: headers,
      responseType: ResponseType.plain,
      contentType: 'application/json',
      cancel: cancel,
    );
    final text = res.data ?? '';
    return text.isEmpty ? null : jsonDecode(text);
  }

  /// POST application/x-www-form-urlencoded (Last.fm, Spotify token).
  Future<dynamic> postForm(
    String url, {
    required Map<String, String> fields,
    Map<String, String>? headers,
    CancelToken? cancel,
  }) async {
    final res = await _send<String>(
      'POST',
      url,
      data: fields,
      headers: headers,
      responseType: ResponseType.plain,
      contentType: Headers.formUrlEncodedContentType,
      cancel: cancel,
    );
    final text = res.data ?? '';
    return text.isEmpty ? null : jsonDecode(text);
  }

  /// Downloads a URL to [savePath] reporting progress; no caching, no retry (callers retry jobs).
  Future<void> download(
    String url,
    String savePath, {
    Map<String, String>? headers,
    void Function(int received, int total)? onProgress,
    CancelToken? cancel,
  }) async {
    final host = Uri.parse(url).host;
    await limiter.acquire(host);
    final res = await dio.download(
      url,
      savePath,
      cancelToken: cancel,
      onReceiveProgress: onProgress,
      options: Options(
        receiveTimeout: const Duration(minutes: 5),
        headers: {'User-Agent': _userAgent(), ...?headers},
      ),
    );
    final code = res.statusCode ?? 0;
    if (code < 200 || code >= 300) throw HttpFailure('HTTP $code', statusCode: code, uri: Uri.parse(url));
  }
}
