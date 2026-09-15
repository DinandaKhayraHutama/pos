import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nti_pos/core/theme/app_colors.dart';
import 'package:nti_pos/core/theme/app_theme.dart';
import 'package:nti_pos/core/widgets/app_background.dart';

void main() {
  // This used to assert a CustomPaint, back when the substrate was a brand
  // gradient plus floating colour blobs. That treatment was what made the app
  // read as a consumer lifestyle product rather than a cashier's tool, so the
  // substrate is now a flat surfaceBase fill. The test still guards the two
  // things that matter: the background paints the token colour (not a
  // hardcoded one, and not nothing), and the child renders on top of it.
  testWidgets('AppBackground fills with surfaceBase and renders its child', (
    tester,
  ) async {
    final childKey = UniqueKey();
    final brand = BrandPreset.presets.first;
    final theme = AppTheme.light(brand);
    final design = theme.extension<BrandColors>()!;

    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: AppBackground(child: SizedBox.expand(key: childKey)),
      ),
    );

    final painted = tester.widget<ColoredBox>(
      find.descendant(
        of: find.byType(AppBackground),
        matching: find.byType(ColoredBox),
      ),
    );
    expect(painted.color, design.surfaceBase);

    expect(find.byKey(childKey), findsOneWidget);
  });
}
