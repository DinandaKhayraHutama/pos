import 'package:flutter_test/flutter_test.dart';
import 'package:nti_pos/data/sync/wire_values.dart';

/// A sale is dated on the merchant's own clock (Fase 3), not the tablet's.
/// 15:30 UTC is 22:30 in Jakarta, 23:30 in Makassar and already 00:30 the
/// next day in Jayapura — the case a WIT merchant with a WIB-set tablet hits
/// every night.
void main() {
  final instant = DateTime.utc(2026, 9, 23, 15, 30);

  test('each Indonesian zone dates the same instant on its own clock', () {
    expect(
      businessDateFor(businessTimeFor(instant, 'Asia/Jakarta')),
      '2026-09-23',
    );
    expect(
      businessDateFor(businessTimeFor(instant, 'Asia/Makassar')),
      '2026-09-23',
    );
    expect(
      businessDateFor(businessTimeFor(instant, 'Asia/Jayapura')),
      '2026-09-24',
    );
    expect(businessTimeFor(instant, 'Asia/Jayapura').hour, 0);
  });

  test('the offset an order records is the zone\'s fixed one', () {
    expect(timezoneOffsetMinutes('Asia/Jakarta'), 420);
    expect(timezoneOffsetMinutes('Asia/Makassar'), 480);
    expect(timezoneOffsetMinutes('Asia/Jayapura'), 540);
  });

  test(
    'an unknown zone or an older server leaves the device clock in charge',
    () {
      expect(timezoneOffsetMinutes('Europe/London'), isNull);
      expect(timezoneOffsetMinutes(null), isNull);
      expect(businessTimeFor(instant, null), instant.toLocal());
    },
  );
}
