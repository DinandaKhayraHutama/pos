/// Platform seam for opening the SQLite database.
///
/// `sqflite` talks to a native SQLite through platform channels, and neither it
/// nor `path_provider` has a web implementation — on Chrome the app used to die
/// with `MissingPluginException(... getApplicationDocumentsDirectory ...)` and
/// every DB-backed screen rendered empty. Web instead runs SQLite compiled to
/// wasm (`sqflite_common_ffi_web`) against IndexedDB, which needs a different
/// factory and takes a bare database name rather than a filesystem path.
///
/// The conditional export below picks the right implementation at compile time,
/// so nothing above this file — repositories, providers, UI — has to know which
/// platform it is running on.
library;

export 'db_platform_io.dart'
    if (dart.library.js_interop) 'db_platform_web.dart';
