import 'package:flutter_test/flutter_test.dart';
import 'package:nti_pos/core/utils/formatters.dart';

void main() {
  group('MoneyFormatter.format', () {
    test('formats whole rupiah with grouping and symbol', () {
      final out = MoneyFormatter.format(25000);
      expect(out, startsWith('Rp '));
      expect(out, contains('25.000'));
    });

    test('zero value', () {
      final out = MoneyFormatter.format(0);
      expect(out, 'Rp 0');
    });

    test('empty symbol omits Rp', () {
      final out = MoneyFormatter.format(25000, symbol: '');
      expect(out.contains('Rp'), isFalse);
      expect(out, contains('25.000'));
    });

    test('groups millions correctly', () {
      final out = MoneyFormatter.format(1000000);
      expect(out, contains('1.000.000'));
      expect(out, startsWith('Rp '));
    });
  });

  group('MoneyFormatter.compact', () {
    test('millions suffix with 1 decimal under 10M', () {
      final out = MoneyFormatter.compact(1200000);
      expect(out, contains('jt'));
      expect(out, contains('1.2'));
    });

    test('millions suffix with 0 decimals at >= 10M', () {
      final out = MoneyFormatter.compact(12000000);
      expect(out, contains('jt'));
      expect(out, contains('12'));
      expect(out.contains('12.'), isFalse);
    });

    test('thousands suffix with 0 decimals at >= 10K', () {
      final out = MoneyFormatter.compact(15000);
      expect(out, contains('rb'));
      expect(out, contains('15'));
    });

    test('plain value below 1K', () {
      final out = MoneyFormatter.compact(500);
      expect(out, contains('500'));
      expect(out.contains('jt'), isFalse);
      expect(out.contains('rb'), isFalse);
    });

    test('threshold boundary 1_000_000 uses jt', () {
      final out = MoneyFormatter.compact(1000000);
      expect(out, contains('jt'));
    });

    test('threshold boundary 1_000 uses rb', () {
      final out = MoneyFormatter.compact(1000);
      expect(out, contains('rb'));
    });
  });

  group('DateFormatter', () {
    final fixed = DateTime(2026, 7, 22, 14, 5);

    test('time formats as HH:mm', () {
      expect(DateFormatter.time(fixed), '14:05');
    });

    test('dateTime formats as dd MMM yyyy, HH:mm', () {
      expect(DateFormatter.dateTime(fixed), '22 Jul 2026, 14:05');
    });

    test('day formats as dd MMM yyyy', () {
      expect(DateFormatter.day(fixed), '22 Jul 2026');
    });

    test('relative returns todayLabel for today', () {
      final now = DateTime.now();
      expect(
        DateFormatter.relative(now, todayLabel: 'Today'),
        'Today',
      );
    });

    test('relative returns dd MMM for a past date', () {
      final past = DateTime(2020, 1, 15);
      final out = DateFormatter.relative(past, todayLabel: 'Today');
      expect(out, '15 Jan');
      expect(out.contains('Today'), isFalse);
    });
  });
}
