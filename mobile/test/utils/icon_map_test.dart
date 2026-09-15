import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nti_pos/core/utils/icon_map.dart';

void main() {
  group('iconFromKey', () {
    test('resolves a known key to a non-null IconData', () {
      final icon = iconFromKey('restaurant');
      expect(icon, isA<IconData>());
      expect(icon.codePoint, greaterThan(0));
    });

    test('unknown key falls back to Icons.restaurant_rounded', () {
      final fallback = Icons.restaurant_rounded;
      expect(iconFromKey('__unknown__'), fallback);
    });

    test('null key falls back to Icons.restaurant_rounded', () {
      final fallback = Icons.restaurant_rounded;
      expect(iconFromKey(null), fallback);
    });

    test('every key in iconKeys resolves to a non-null IconData', () {
      for (final key in iconKeys) {
        final icon = iconFromKey(key);
        expect(icon, isA<IconData>(),
            reason: 'key "$key" did not resolve to IconData');
        expect(icon.codePoint, greaterThan(0),
            reason: 'key "$key" resolved to an empty codePoint');
      }
    });
  });

  group('iconKeys', () {
    test('is non-empty', () {
      expect(iconKeys, isNotEmpty);
    });

    test('contains the restaurant key', () {
      expect(iconKeys, contains('restaurant'));
    });
  });
}
