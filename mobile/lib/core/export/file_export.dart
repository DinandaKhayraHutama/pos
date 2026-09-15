/// Platform seam for saving a generated text file.
///
/// Web and native have nothing in common here: a browser downloads a Blob
/// through an anchor, while a phone or desktop hands the bytes to the OS share
/// sheet. Same conditional-export shape as `db_platform.dart`, so callers just
/// say `saveTextFile(...)` and never learn which platform they are on.
library;

export 'file_export_io.dart'
    if (dart.library.js_interop) 'file_export_web.dart';
