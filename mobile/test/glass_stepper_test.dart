import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nti_pos/core/theme/app_colors.dart';
import 'package:nti_pos/core/theme/app_theme.dart';
import 'package:nti_pos/core/widgets/glass/glass_stepper.dart';

void main() {
  testWidgets('qty 0 shows add affordance; tapping fires onAdd', (tester) async {
    int adds = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(BrandPreset.presets.first),
        home: Scaffold(
          body: GlassStepper(
            quantity: 0,
            onAdd: () => adds++,
            onDecrement: () {},
            addLabel: 'Add',
          ),
        ),
      ),
    );
    await tester.tap(find.text('Add'));
    expect(adds, 1);
  });

  testWidgets('qty 2 shows number and +/- fire correct callbacks', (
    tester,
  ) async {
    int adds = 0, decs = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(BrandPreset.presets.first),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 160,
              child: GlassStepper(
                quantity: 2,
                onAdd: () => adds++,
                onDecrement: () => decs++,
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('2'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.add_rounded));
    expect(adds, 1);
    await tester.tap(find.byIcon(Icons.remove_rounded));
    expect(decs, 1);
  });

  testWidgets('qty 1 shows delete icon for decrement', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(BrandPreset.presets.first),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 160,
              child: GlassStepper(
                quantity: 1,
                onAdd: () {},
                onDecrement: () {},
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.byIcon(Icons.delete_outline_rounded), findsOneWidget);
  });

  testWidgets('disabled stepper does not fire callbacks', (tester) async {
    int adds = 0, decs = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(BrandPreset.presets.first),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 160,
              child: GlassStepper(
                quantity: 2,
                enabled: false,
                onAdd: () => adds++,
                onDecrement: () => decs++,
              ),
            ),
          ),
        ),
      ),
    );
    // Tapping the increment and decrement icons must NOT fire while disabled.
    await tester.tap(find.byIcon(Icons.add_rounded), warnIfMissed: false);
    await tester.tap(find.byIcon(Icons.remove_rounded), warnIfMissed: false);
    await tester.pump();
    expect(adds, 0);
    expect(decs, 0);
    // And confirm the dimming wrapper exists.
    expect(find.byType(Opacity), findsWidgets);
  });
}
