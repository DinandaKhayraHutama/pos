import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:nti_pos/data/database/app_database.dart';

/// Initializes `sqflite_common_ffi` and installs it as the global
/// [databaseFactory]. Call once per test (idempotent — re-init is a no-op).
///
/// This MUST stay in `test/` so production never pulls in the FFI runtime.
Future<void> initFfi() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
}

/// Opens an in-memory SQLite database with the JustClick POS schema at the app's
/// current version.
///
/// Each call opens a fresh in-memory database. The caller owns the returned
/// [Database] and must `close()` it in `tearDown` — failing to close leaks
/// the shared in-memory store between tests.
///
/// Set [seed] to true to run the app's `_seed` (categories, products, tables)
/// during `_onCreate`; false yields an empty schema-only DB.
Future<Database> openInMemoryAppDb({bool seed = false}) async {
  await initFfi();
  return AppDatabase.openForTest(
    path: inMemoryDatabasePath,
    seed: seed,
  );
}
