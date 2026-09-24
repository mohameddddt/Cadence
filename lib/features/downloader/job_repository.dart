import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../../core/db/app_database.dart';
import '../../core/models/library_models.dart';

/// Persistence for the download queue (download_jobs table).
class JobRepository {
  JobRepository(this.appDb);

  final AppDatabase appDb;
  Database get db => appDb.db;

  int get _now => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  Future<int> create({
    required String url,
    required String sourceType,
    String? title,
    String? artist,
    String? thumbnail,
    Map<String, dynamic> options = const {},
  }) async {
    final id = await db.insert('download_jobs', {
      'url': url,
      'source_type': sourceType,
      'title': title,
      'artist': artist,
      'thumbnail': thumbnail,
      'status': JobStatus.queued.name,
      'progress': 0.0,
      'created_at': _now,
      'options': jsonEncode(options),
    });
    appDb.notifyChanged();
    return id;
  }

  Future<DownloadJob?> byId(int id) async {
    final rows = await db.query('download_jobs', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : DownloadJob.fromMap(rows.first);
  }

  Future<List<DownloadJob>> all({Iterable<JobStatus>? statuses, int? limit}) async {
    final rows = await db.query(
      'download_jobs',
      where: statuses == null ? null : 'status IN (${statuses.map((_) => '?').join(',')})',
      whereArgs: statuses?.map((s) => s.name).toList(),
      orderBy: 'created_at DESC, id DESC',
      limit: limit,
    );
    return rows.map(DownloadJob.fromMap).toList();
  }

  /// Oldest queued job first.
  Future<List<DownloadJob>> queued() async {
    final rows = await db.query('download_jobs', where: 'status = ?', whereArgs: [JobStatus.queued.name], orderBy: 'id');
    return rows.map(DownloadJob.fromMap).toList();
  }

  Future<DownloadJob?> activeForUrl(String url) async {
    final rows = await db.query(
      'download_jobs',
      where: 'url = ? AND status IN (?, ?, ?)',
      whereArgs: [url, JobStatus.queued.name, JobStatus.running.name, JobStatus.postprocessing.name],
      limit: 1,
    );
    return rows.isEmpty ? null : DownloadJob.fromMap(rows.first);
  }

  Future<void> update(
    int id, {
    JobStatus? status,
    double? progress,
    String? stage,
    String? outputPath,
    int? trackId,
    String? error,
    bool clearError = false,
    String? title,
    String? artist,
    String? thumbnail,
    bool finished = false,
    bool notify = true,
  }) async {
    final v = <String, Object?>{
      if (status != null) 'status': status.name,
      if (progress != null) 'progress': progress,
      if (stage != null) 'stage': stage,
      if (outputPath != null) 'output_path': outputPath,
      if (trackId != null) 'track_id': trackId,
      if (error != null) 'error': error,
      if (clearError) 'error': null,
      if (title != null) 'title': title,
      if (artist != null) 'artist': artist,
      if (thumbnail != null) 'thumbnail': thumbnail,
      if (finished) 'finished_at': _now,
    };
    if (v.isEmpty) return;
    await db.update('download_jobs', v, where: 'id = ?', whereArgs: [id]);
    if (notify) appDb.notifyChanged();
  }

  /// Keeps the last ~24 KB of yt-dlp output for the "logs" view.
  Future<void> appendLog(int id, String text) async {
    if (text.trim().isEmpty) return;
    final rows = await db.query('download_jobs', columns: ['log'], where: 'id = ?', whereArgs: [id], limit: 1);
    var log = ((rows.isEmpty ? null : rows.first['log']) as String? ?? '') + text;
    if (log.length > 24000) log = log.substring(log.length - 24000);
    await db.update('download_jobs', {'log': log}, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> delete(int id) async {
    await db.delete('download_jobs', where: 'id = ?', whereArgs: [id]);
    appDb.notifyChanged();
  }

  Future<int> clearFinished() async {
    final n = await db.delete(
      'download_jobs',
      where: 'status IN (?, ?, ?)',
      whereArgs: [JobStatus.done.name, JobStatus.failed.name, JobStatus.cancelled.name],
    );
    appDb.notifyChanged();
    return n;
  }

  /// After a crash or app kill: jobs that were mid-flight go back to the queue.
  Future<int> resetInterrupted() async {
    final n = await db.update(
      'download_jobs',
      {'status': JobStatus.queued.name, 'stage': 'Resuming', 'progress': 0.0},
      where: 'status IN (?, ?)',
      whereArgs: [JobStatus.running.name, JobStatus.postprocessing.name],
    );
    if (n > 0) appDb.notifyChanged();
    return n;
  }

  Stream<List<DownloadJob>> watchAll() => appDb.watch(() => all());
}
