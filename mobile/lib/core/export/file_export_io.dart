/// Native implementation of the export seam declared in `file_export.dart`.
library;

import 'dart:convert';

import 'package:printing/printing.dart';

/// Hands [content] to the platform share sheet.
///
/// `sharePdf` is a misnomer in `printing`: it shares arbitrary bytes under the
/// given filename. Reusing it avoids pulling in a second plugin — and a second
/// set of platform permissions — purely to write one CSV.
Future<void> saveTextFile({
  required String filename,
  required String content,
}) async {
  await Printing.sharePdf(bytes: utf8.encode(content), filename: filename);
}
