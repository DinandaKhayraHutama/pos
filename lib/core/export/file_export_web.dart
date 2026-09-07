/// Web implementation of the export seam declared in `file_export.dart`.
library;

import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Downloads [content] as a file.
///
/// Goes through a Blob and a synthetic anchor click rather than
/// `Printing.sharePdf`. That path renders through pdf.js and expects a PDF, so
/// handing it CSV bytes produced no download at all — verified: the click fired
/// and nothing came back. A Blob URL is what a browser actually wants, and it
/// is revoked immediately so the bytes are not pinned for the life of the tab.
Future<void> saveTextFile({
  required String filename,
  required String content,
}) async {
  // UTF-8 BOM. Without it Excel on Windows reads the file as the system code
  // page and mangles any non-ASCII product or cashier name.
  final bytes = Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode(content)]);
  final blob = web.Blob(
    [bytes.toJS].toJS,
    web.BlobPropertyBag(type: 'text/csv;charset=utf-8'),
  );
  final url = web.URL.createObjectURL(blob);
  final anchor = web.document.createElement('a') as web.HTMLAnchorElement
    ..href = url
    ..download = filename;
  web.document.body!.appendChild(anchor);
  anchor.click();
  anchor.remove();
  web.URL.revokeObjectURL(url);
}
