/// Native (iOS / Android / macOS) implementation of the database seam declared
/// in `db_platform.dart`. Uses the default `sqflite` factory and stores the
/// database file in the app's documents directory.
library;

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// No-op on native: `sqflite` already installs the correct `databaseFactory`.
void configureDatabaseFactory() {}

/// Absolute path to [fileName] inside the app's documents directory.
Future<String> resolveDatabasePath(String fileName) async {
  final dir = await getApplicationDocumentsDirectory();
  return p.join(dir.path, fileName);
}
