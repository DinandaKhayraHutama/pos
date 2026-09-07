import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nti_pos/core/theme/app_colors.dart';
import 'package:nti_pos/core/theme/app_theme.dart';
import 'package:nti_pos/core/widgets/glass/glass_app_bar.dart';

void main() {
  testWidgets('GlassAppBar renders title and a BackdropFilter', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(BrandPreset.presets.first),
        home: const Scaffold(
          appBar: GlassAppBar(title: 'Orders'),
          body: SizedBox.shrink(),
        ),
      ),
    );
    expect(find.text('Orders'), findsOneWidget);
    expect(find.byType(BackdropFilter), findsWidgets);
  });

  testWidgets('GlassAppBar hosts a bottom widget and exposes its height',
      (tester) async {
    const bottomHeight = 48.0;
    final bottom = PreferredSize(
      preferredSize: const Size.fromHeight(bottomHeight),
      child: const SizedBox.shrink(),
    );
    final bar = GlassAppBar(title: 'x', bottom: bottom);
    expect(
      bar.preferredSize.height,
      kToolbarHeight + bottomHeight,
      reason: 'preferredSize should add bottom height on top of the toolbar',
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(BrandPreset.presets.first),
        home: Scaffold(appBar: bar, body: const SizedBox.shrink()),
      ),
    );
    expect(find.byType(GlassAppBar), findsOneWidget);
  });

  testWidgets('GlassAppBar.large reserves extra height', (tester) async {
    final bar = const GlassAppBar(title: 'x', large: true);
    expect(
      bar.preferredSize.height,
      kToolbarHeight + 28,
      reason: 'large:true should add 28dp of reserved height',
    );
  });
}
