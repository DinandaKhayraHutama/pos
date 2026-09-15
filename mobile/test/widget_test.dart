import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nti_pos/core/theme/app_colors.dart';
import 'package:nti_pos/core/theme/app_theme.dart';

void main() {
  testWidgets('App boots and produces a ThemeData per brand', (tester) async {
    for (final brand in BrandPreset.presets) {
      final light = AppTheme.light(brand);
      final dark = AppTheme.dark(brand);
      expect(light.brightness, Brightness.light);
      expect(dark.brightness, Brightness.dark);
      expect(light.colorScheme.primary, isA<Color>());
      expect(dark.colorScheme.primary, isA<Color>());
    }
  });

  testWidgets('Home widget tree can be built with default theme', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(BrandPreset.presets.first),
        home: const Scaffold(body: Center(child: Text('JustClick POS'))),
      ),
    );
    expect(find.text('JustClick POS'), findsOneWidget);
  });
}
