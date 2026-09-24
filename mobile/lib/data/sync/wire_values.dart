/// Conversions between local SQLite values and the v2 push contract.
///
/// Kept in one place because the server compares a revision's payload with the
/// one it already stored, field by field. A conversion that is not
/// deterministic — or that two builders do differently — turns an exact retry
/// into a `duplicate`, and a status change into "immutable fields changed".
library;

final _uuidPattern = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);

bool isUuid(Object? value) => value is String && _uuidPattern.hasMatch(value);

/// [value] when it is a UUID, otherwise null.
///
/// The server refuses an optional reference that is not a UUID. Several local
/// screens still mint ids like `table_1726…` or `emp_1726…`, and tables are not
/// synced until Fase 6 — so a dine-in sale at a locally created table would be
/// rejected outright. The name snapshot beside each id (`table_name`,
/// `cashier_name`, `product_name`) still says what the receipt said.
String? uuidOrNull(Object? value) => isUuid(value) ? value as String : null;

/// The business day a sale belongs to, `YYYY-MM-DD` in the device's local
/// time — the day printed on the receipt the customer holds.
///
/// Chosen once, when the sale is made, and never recomputed: a push that
/// arrives the next morning must still land in yesterday's report.
String businessDateFor(DateTime local) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${local.year.toString().padLeft(4, '0')}-${two(local.month)}-'
      '${two(local.day)}';
}

const indonesiaTimezoneOffsets = <String, int>{
  'Asia/Jakarta': 420,
  'Asia/Makassar': 480,
  'Asia/Jayapura': 540,
};

/// Converts one instant to the configured Indonesian business clock. Unknown
/// zones keep the historical device-local behavior for older servers.
DateTime businessTimeFor(DateTime now, String? timezone) {
  final offset = indonesiaTimezoneOffsets[timezone];
  if (offset == null) return now.toLocal();
  return now.toUtc().add(Duration(minutes: offset));
}

int? timezoneOffsetMinutes(String? timezone) =>
    indonesiaTimezoneOffsets[timezone];

int wireInt(Object? value) => value is num ? value.toInt() : 0;

int? wireIntOrNull(Object? value) => value is num ? value.toInt() : null;

/// A percentage rate, or null when absent or not a finite number — JSON has no
/// spelling for NaN, and a rate that cannot be encoded must not abort a sale.
double? wireRate(Object? value) {
  if (value is! num) return null;
  final rate = value.toDouble();
  return rate.isFinite ? rate : null;
}
