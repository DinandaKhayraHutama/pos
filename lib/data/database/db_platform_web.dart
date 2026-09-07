/// Web implementation of the database seam declared in `db_platform.dart`.
///
/// Runs SQLite compiled to wasm (`web/sqlite3.wasm`), persisting to IndexedDB.
///
/// **Why the no-web-worker factory.** The default `databaseFactoryFfiWeb` runs
/// SQLite in a shared worker, which requires a `sqflite_sw.js` built by
/// `dart run sqflite_common_ffi_web:setup`. That setup fails on this toolchain —
/// it shells out to `webdev`, whose `build_runner` dies with "'dart compile'
/// does not support build hooks" on Dart 3.10. The no-worker factory needs only
/// `sqlite3.wasm`, so the failing build step drops out entirely. The cost is
/// that queries run on the main thread; with a catalog this size that is not
/// measurable, but it is the thing to revisit if the web build ever handles a
/// real dataset.
///
/// **Keeping `sqlite3.wasm` in sync.** It must match the resolved `sqlite3`
/// package version in `pubspec.lock` (3.5.0 at time of writing). After
/// upgrading, re-download the matching asset:
///
/// ```bash
/// curl -sL -o web/sqlite3.wasm \
///   https://github.com/simolus3/sqlite3.dart/releases/download/sqlite3-<version>/sqlite3.wasm
/// ```
library;

import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';

/// Points `sqflite` at the wasm/IndexedDB factory. Idempotent.
void configureDatabaseFactory() {
  databaseFactory = databaseFactoryFfiWebNoWebWorker;
}

/// On web there is no filesystem: the "path" is just the IndexedDB store name.
Future<String> resolveDatabasePath(String fileName) async => fileName;
