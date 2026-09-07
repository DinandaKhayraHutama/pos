import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nti_pos/core/theme/app_colors.dart';
import 'package:nti_pos/core/theme/app_theme.dart';
import 'package:nti_pos/core/widgets/segmented_selector.dart';

void main() {
  testWidgets('tapping a segment fires onChanged with its value', (tester) async {
    String? picked;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(BrandPreset.presets.first),
      home: Scaffold(
        body: SegmentedSelector<String>(
          value: 'a',
          onChanged: (v) => picked = v,
          segments: const [
            Segment(value: 'a', label: 'A'),
            Segment(value: 'b', label: 'B'),
            Segment(value: 'c', label: 'C'),
          ],
        ),
      ),
    ));
    await tester.tap(find.text('B'));
    await tester.pump();
    expect(picked, 'b');
  });

  testWidgets('renders all segment labels', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(BrandPreset.presets.first),
      home: Scaffold(
        body: SegmentedSelector<int>(
          value: 1,
          onChanged: (_) {},
          segments: const [
            Segment(value: 1, label: 'One'),
            Segment(value: 2, label: 'Two'),
          ],
        ),
      ),
    ));
    expect(find.text('One'), findsOneWidget);
    expect(find.text('Two'), findsOneWidget);
  });

  testWidgets('selected label resolves to onPrimary, unselected to textMedium', (
    tester,
  ) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(BrandPreset.presets.first),
      home: Scaffold(
        body: SegmentedSelector<int>(
          value: 1,
          onChanged: (_) {},
          segments: const [
            Segment(value: 1, label: 'One'),
            Segment(value: 2, label: 'Two'),
          ],
        ),
      ),
    ));
    final design = BrandPreset.presets.first.light;
    final one = tester.widget<Text>(find.text('One'));
    final two = tester.widget<Text>(find.text('Two'));
    expect(one.style?.color, design.onPrimary);
    expect(two.style?.color, design.textMedium);
  });
}
