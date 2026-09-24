import 'dart:async';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'schema.dart';

/// Owns the SQLite connection and change notifications.
///
/// Repositories call [notifyChanged] after writing; UI streams built with [watch]
/// re-run their query (debounced) whenever something changed.
class AppDatabase {
  AppDatabase._(this.db);

  final Database db;
  final StreamController<void> _changes = StreamController<void>.broadcast();

  Stream<void> get changes => _changes.stream;

  void notifyChanged() {
    if (!_changes.isClosed) _changes.add(null);
  }

  /// Opens (creating/upgrading if needed). Pass [factory] to use sqflite_common_ffi in
  /// tests and [path] to override the location (use [inMemoryDatabasePath] for tests).
  static Future<AppDatabase> open({
    String? path,
    DatabaseFactory? factory,
    List<Migration> migrationList = migrations,
    int version = schemaVersion,
    List<String> create = createStatements,
    bool withSearchIndex = true,
    bool singleInstance = true,
  }) async {
    final f = factory ?? databaseFactory;
    final dbPath = path ?? p.join(await f.getDatabasesPath(), 'musicplayer.db');
    final db = await f.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: version,
        singleInstance: singleInstance,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
        },
        onCreate: (db, v) async {
          final batch = db.batch();
          for (final s in create) {
            batch.execute(s);
          }
          await batch.commit(noResult: true);
          if (withSearchIndex) await _createSearchIndex(db);
        },
        onUpgrade: (db, from, to) => runMigrations(db, from, to, migrationList),
      ),
    );
    return AppDatabase._(db);
  }

  static Future<void> _createSearchIndex(Database db) async {
    Object? last;
    for (final stmt in searchIndexStatements) {
      try {
        await db.execute(stmt);
        last = null;
        break;
      } catch (e) {
        last = e;
      }
    }
    if (last != null) throw StateError('No full-text search module available: $last');
    for (final t in searchIndexTriggers) {
      await db.execute(t);
    }
  }

  /// Applies every migration whose range lies in [from]..[to], in order.
  static Future<void> runMigrations(Database db, int from, int to, List<Migration> list) async {
    var current = from;
    while (current < to) {
      final step = list.where((m) => m.from == current).toList()..sort((a, b) => b.to.compareTo(a.to));
      if (step.isEmpty) {
        throw StateError('No migration from schema v$current (target v$to)');
      }
      final m = step.first;
      final batch = db.batch();
      for (final s in m.statements) {
        batch.execute(s);
      }
      await batch.commit(noResult: true);
      current = m.to;
    }
  }

  /// Emits the result of [query] now and again after each database change.
  Stream<T> watch<T>(Future<T> Function() query) {
    late StreamController<T> controller;
    StreamSubscription<void>? sub;
    Timer? debounce;
    var running = false;
    var dirty = false;

    Future<void> run() async {
      if (running) {
        dirty = true;
        return;
      }
      running = true;
      try {
        do {
          dirty = false;
          final value = await query();
          if (!controller.isClosed) controller.add(value);
        } while (dirty);
      } catch (e, st) {
        if (!controller.isClosed) controller.addError(e, st);
      } finally {
        running = false;
      }
    }

    controller = StreamController<T>(
      onListen: () {
        run();
        sub = changes.listen((_) {
          debounce?.cancel();
          debounce = Timer(const Duration(milliseconds: 150), run);
        });
      },
      onCancel: () async {
        debounce?.cancel();
        await sub?.cancel();
      },
    );
    return controller.stream;
  }

  Future<void> close() async {
    await _changes.close();
    await db.close();
  }
}
