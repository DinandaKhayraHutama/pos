import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nti_pos/core/theme/app_colors.dart';
import 'package:nti_pos/core/theme/app_text_styles.dart';
import 'package:nti_pos/core/theme/app_theme.dart';

void main() {
  testWidgets(
    'default Text inherits PlusJakartaSans from the theme bodyMedium',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(BrandPreset.presets.first),
          home: const Material(child: Center(child: Text('x'))),
        ),
      );
      await tester.pump();

      final ctx = tester.element(find.byType(Text));
      final inherited = Theme.of(ctx).textTheme.bodyMedium?.fontFamily;
      expect(inherited, 'PlusJakartaSans');

      // Guard the ThemeData-level family arg. ThemeData has no public
      // fontFamily getter in this Flutter version, so assert against
      // primaryTextTheme: app_theme passes no explicit primaryTextTheme, so
      // its entries come from the raw Typography merged with the ThemeData
      // constructor's fontFamily. If that ctor arg is removed, this turns
      // null while textTheme.bodyMedium (set explicitly in _textTheme) still
      // passes — which is exactly the gap the review flagged.
      expect(
        Theme.of(ctx).primaryTextTheme.bodyMedium?.fontFamily,
        'PlusJakartaSans',
      );

      // The Text widget itself has no explicit style, so its resolved
      // DefaultTextStyle should also report the family.
      final rendered = tester.widget<Text>(find.byType(Text));
      final resolved = rendered.style?.fontFamily ??
          DefaultTextStyle.of(ctx).style.fontFamily;
      expect(resolved, 'PlusJakartaSans');
    },
  );

  test('moneyStyle applies PlusJakartaSans + tabular figures', () {
    final style = moneyStyle(
      BrandPreset.presets.first.light.textHigh,
      fontSize: 18,
      weight: FontWeight.w700,
    );
    expect(style.fontFamily, 'PlusJakartaSans');
    expect(style.fontFeatures, contains(FontFeature.tabularFigures()));
    expect(style.fontSize, 18);
    expect(style.fontWeight, FontWeight.w700);
  });

  test('theme bodyMedium/labelLarge/titleMedium use tabular figures', () {
    final theme = AppTheme.light(BrandPreset.presets.first);
    final tabulated = <String, TextStyle>{
      'bodyMedium': theme.textTheme.bodyMedium!,
      'labelLarge': theme.textTheme.labelLarge!,
      'titleMedium': theme.textTheme.titleMedium!,
    };
    tabulated.forEach((name, style) {
      expect(
        style.fontFeatures,
        contains(FontFeature.tabularFigures()),
        reason: '$name should use tabular figures',
      );
    });
  });

  test('display/headline/title styles get negative letterSpacing', () {
    final theme = AppTheme.light(BrandPreset.presets.first);
    final tight = <String, TextStyle>{
      'displayLarge': theme.textTheme.displayLarge!,
      'displayMedium': theme.textTheme.displayMedium!,
      'displaySmall': theme.textTheme.displaySmall!,
      'headlineLarge': theme.textTheme.headlineLarge!,
      'headlineMedium': theme.textTheme.headlineMedium!,
      'headlineSmall': theme.textTheme.headlineSmall!,
      'titleLarge': theme.textTheme.titleLarge!,
    };
    tight.forEach((name, style) {
      expect(
        style.letterSpacing,
        isNegative,
        reason: '$name should have negative letterSpacing',
      );
    });
  });
}
