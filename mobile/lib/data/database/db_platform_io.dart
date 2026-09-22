/// Native implementation of the database seam declared in `db_platform.dart`.
///
/// Mobile and macOS use the platform `sqflite` plugin. Windows and Linux have
/// no such plugin, so they must install the FFI factory before the first
/// database operation (including `databaseExists`).
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

bool _configured = false;

/// Installs the desktop SQLite factory exactly once.
void configureDatabaseFactory() {
  if (_configured) return;
  if (Platform.isWindows || Platform.isLinux) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  _configured = true;
}

/// Absolute path to [fileName] inside the app's documents directory.
Future<String> resolveDatabasePath(String fileName) async {
  final dir = await getApplicationDocumentsDirectory();
  return p.join(dir.path, fileName);
}
