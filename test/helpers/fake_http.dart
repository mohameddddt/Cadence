import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:musicplayer/core/net/api_cache.dart';
import 'package:musicplayer/core/net/http_service.dart';
import 'package:musicplayer/core/net/rate_limiter.dart';

/// Loads test/fixtures/<name> as a string.
String fixture(String name) => File('test/fixtures/$name').readAsStringSync();

dynamic fixtureJson(String name) => jsonDecode(fixture(name));

class RecordedRequest {
  RecordedRequest(this.method, this.uri, this.headers, this.body);
  final String method;
  final Uri uri;
  final Map<String, dynamic> headers;
  final Object? body;

  String get bodyText => body is String ? body as String : (body == null ? '' : jsonEncode(body));

  @override
  String toString() => '$method $uri';
}

typedef FakeHandler = FutureOr<FakeResponse> Function(RecordedRequest req);

class FakeResponse {
  FakeResponse(this.body, {this.status = 200, Map<String, String>? headers, this.bytes})
      : headers = {'content-type': 'application/json', ...?headers};

  final String body;
  final Uint8List? bytes;
  final int status;
  final Map<String, String> headers;

  factory FakeResponse.fixture(String name, {int status = 200}) => FakeResponse(fixture(name), status: status);
  factory FakeResponse.json(Object o, {int status = 200}) => FakeResponse(jsonEncode(o), status: status);
  factory FakeResponse.notFound() => FakeResponse('{"error":"not found"}', status: 404);
}

/// Dio adapter that answers from registered routes instead of the network.
class FakeHttpAdapter implements HttpClientAdapter {
  final List<({bool Function(RecordedRequest) match, FakeHandler handler})> _routes = [];
  final List<RecordedRequest> requests = [];

  /// Route on a substring of "METHOD url".
  void on(String pattern, FakeHandler handler) {
    _routes.add((match: (r) => '${r.method} ${r.uri}'.contains(pattern), handler: handler));
  }

  void onFixture(String pattern, String fixtureName, {int status = 200}) =>
      on(pattern, (_) => FakeResponse.fixture(fixtureName, status: status));

  void onJson(String pattern, Object body, {int status = 200}) => on(pattern, (_) => FakeResponse.json(body, status: status));

  List<RecordedRequest> requestsTo(String pattern) => requests.where((r) => '${r.method} ${r.uri}'.contains(pattern)).toList();

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    Object? body = options.data;
    if (requestStream != null) {
      final bytes = await requestStream.fold<List<int>>([], (a, b) => a..addAll(b));
      body = utf8.decode(bytes);
    }
    final req = RecordedRequest(options.method, options.uri, Map.of(options.headers), body);
    requests.add(req);
    for (final route in _routes.reversed) {
      if (route.match(req)) {
        final res = await route.handler(req);
        final data = res.bytes ?? Uint8List.fromList(utf8.encode(res.body));
        return ResponseBody.fromBytes(
          data,
          res.status,
          headers: {for (final e in res.headers.entries) e.key: [e.value]},
        );
      }
    }
    return ResponseBody.fromString('no route for ${req.method} ${req.uri}', 599);
  }
}

/// A service wired to [adapter] with no waiting: rate limits and retries are instantaneous
/// (their behaviour is covered separately).
HttpService fakeHttp(FakeHttpAdapter adapter, {ApiCache? cache, String userAgent = 'MusicPlayerTests/0.1 (test)'}) {
  final dio = Dio(BaseOptions(validateStatus: (_) => true))..httpClientAdapter = adapter;
  return HttpService(
    userAgent: () => userAgent,
    dio: dio,
    limiter: HostRateLimiter(intervals: const {}, delay: (_) async {}),
    cache: cache ?? MemoryApiCache(),
    sleep: (_) async {},
  );
}
