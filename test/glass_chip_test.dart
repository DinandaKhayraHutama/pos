import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nti_pos/core/theme/app_colors.dart';
import 'package:nti_pos/core/theme/app_theme.dart';
import 'package:nti_pos/core/widgets/glass/glass_chip.dart';

void main() {
  testWidgets('tap fires callback', (tester) async {
    int taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(BrandPreset.presets.first),
        home: Scaffold(
          body: GlassFilterChip(
            label: 'All',
            selected: false,
            onTap: () => taps++,
          ),
        ),
      ),
    );
    await tester.tap(find.text('All'));
    expect(taps, 1);
  });

  testWidgets('selected chip renders label and icon', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(BrandPreset.presets.first),
        home: const Scaffold(
          body: GlassFilterChip(
            label: 'Drinks',
            icon: Icons.local_drink_rounded,
            selected: true,
            onTap: _noop,
          ),
        ),
      ),
    );
    expect(find.text('Drinks'), findsOneWidget);
    expect(find.byIcon(Icons.local_drink_rounded), findsOneWidget);
  });

  testWidgets('selected and unselected chips paint different fills',
      (tester) async {
    final brand = BrandPreset.presets.first;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(brand),
      home: Scaffold(body: Row(children: const [
        GlassFilterChip(label: 'On', selected: true, onTap: _noop),
        GlassFilterChip(label: 'Off', selected: false, onTap: _noop),
      ])),
    ));

    BoxDecoration decorationFor(String label) {
      final chip = tester
          .widget<GlassFilterChip>(find.widgetWithText(GlassFilterChip, label));
      final animated = tester.widget<AnimatedContainer>(
        find.descendant(
          of: find.byWidget(chip),
          matching: find.byType(AnimatedContainer),
        ),
      );
      return (animated.decoration as BoxDecoration?) ?? const BoxDecoration();
    }

    final onDeco = decorationFor('On');
    final offDeco = decorationFor('Off');

    expect(onDeco.color, brand.light.primary,
        reason: 'selected chip should fill with brand primary');
    expect(onDeco.color, isNot(offDeco.color),
        reason: 'selected vs unselected must differ');
    expect(onDeco.border, isNull, reason: 'selected chip has no hairline border');
    expect(offDeco.border, isNotNull,
        reason: 'unselected chip has a hairline border');
  });
}

void _noop() {}
