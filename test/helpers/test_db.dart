import 'package:musicplayer/core/db/app_database.dart';
import 'package:musicplayer/core/library/library_repository.dart';
import 'package:sqflite/sqlite_api.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

bool _ffiReady = false;

DatabaseFactory testFactory() {
  if (!_ffiReady) {
    sqfliteFfiInit();
    _ffiReady = true;
  }
  return databaseFactoryFfi;
}

Future<AppDatabase> openTestDb() =>
    AppDatabase.open(path: inMemoryDatabasePath, factory: testFactory(), singleInstance: false);

Future<LibraryRepository> openTestRepo() async => LibraryRepository(await openTestDb());
