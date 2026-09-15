import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nti_pos/core/theme/app_colors.dart';
import 'package:nti_pos/core/theme/app_theme.dart';
import 'package:nti_pos/core/widgets/glass/glass_text_field.dart';

void main() {
  testWidgets(
    'typing updates the controller and shows the value',
    (tester) async {
      final ctrl = TextEditingController();
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(BrandPreset.presets.first),
          home: Scaffold(body: GlassTextField(controller: ctrl, hint: 'search')),
        ),
      );

      await tester.enterText(find.byType(TextField), 'nasi goreng');

      expect(ctrl.text, 'nasi goreng');
      expect(find.text('nasi goreng'), findsOneWidget);
    },
  );

  testWidgets('prefix icon renders', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(BrandPreset.presets.first),
        home: const Scaffold(
          body: GlassTextField(hint: 'x', prefix: Icons.search_rounded),
        ),
      ),
    );

    expect(find.byIcon(Icons.search_rounded), findsOneWidget);
  });
}
