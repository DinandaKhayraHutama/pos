import 'package:intl/intl.dart';

/// Currency & number formatting helpers.
class MoneyFormatter {
  MoneyFormatter._();

  /// Format [value] (in whole rupiah) as e.g. "Rp 25.000".
  static String format(int value, {String symbol = 'Rp'}) {
    final f = NumberFormat.currency(
      locale: 'id_ID',
      symbol: '$symbol ',
      decimalDigits: 0,
    );
    return f.format(value);
  }

  /// Compact e.g. "Rp 1,2 jt" for dashboard cards.
  static String compact(int value, {String symbol = 'Rp'}) {
    if (value >= 1000000) {
      final m = value / 1000000;
      final s = m.toStringAsFixed(m >= 10 ? 0 : 1);
      return '$symbol $s jt';
    }
    if (value >= 1000) {
      final k = value / 1000;
      final s = k.toStringAsFixed(k >= 10 ? 0 : 1);
      return '$symbol $s rb';
    }
    return '$symbol $value';
  }
}

class DateFormatter {
  DateFormatter._();

  static String time(DateTime dt) => DateFormat.Hm().format(dt);

  static String dateTime(DateTime dt) =>
      DateFormat('dd MMM yyyy, HH:mm').format(dt);

  static String day(DateTime dt) => DateFormat('dd MMM yyyy').format(dt);

  static String relative(DateTime dt, {required String todayLabel}) {
    final now = DateTime.now();
    if (dt.day == now.day && dt.month == now.month && dt.year == now.year) {
      return todayLabel;
    }
    return DateFormat('dd MMM').format(dt);
  }
}
