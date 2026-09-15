import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nti_pos/core/theme/app_colors.dart';
import 'package:nti_pos/core/theme/app_theme.dart';
import 'package:nti_pos/core/widgets/glass/skeleton.dart';
import 'package:nti_pos/core/widgets/loading_indicator.dart';

void main() {
  testWidgets('Skeleton renders a box of the given size', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(BrandPreset.presets.first),
        home: const Scaffold(body: Skeleton(width: 100, height: 16)),
      ),
    );
    final box = tester.getSize(find.byType(Skeleton));
    expect(box.width, 100);
    expect(box.height, 16);
  });

  testWidgets('LoadingIndicator.skeleton renders multiple Skeleton bars',
  (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(BrandPreset.presets.first),
        home: Scaffold(body: LoadingIndicator.skeleton(lines: 4)),
      ),
    );
    expect(find.byType(Skeleton), findsNWidgets(4));
  });

  testWidgets('LoadingIndicator.skeleton defaults to 3 lines', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(BrandPreset.presets.first),
        home: Scaffold(body: LoadingIndicator.skeleton()),
      ),
    );
    expect(find.byType(Skeleton), findsNWidgets(3));
  });
}
