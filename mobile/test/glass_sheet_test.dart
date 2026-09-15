import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nti_pos/core/theme/app_colors.dart';
import 'package:nti_pos/core/theme/app_theme.dart';
import 'package:nti_pos/core/widgets/glass/glass_sheet.dart';

/// `showGlassSheet` is the modal helper later tasks (cart, checkout, table
/// picker) will call instead of hand-rolling `showModalBottomSheet`. This test
/// locks down the contract callers rely on:
///   1. It actually presents a [GlassSheet] (so the wrapper is wired in).
///   2. The caller's payload ends up on screen.
///   3. The sheet paints a [BackdropFilter] (the whole point of "glass" —
///      without this it's just a translucent rectangle).
void main() {
  testWidgets('showGlassSheet presents payload inside a GlassSheet', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(BrandPreset.presets.first),
        home: Builder(
          builder: (c) => ElevatedButton(
            onPressed: () => showGlassSheet(
              context: c,
              builder: (_) => const Padding(
                padding: EdgeInsets.all(16),
                child: Text('PAYLOAD', key: ValueKey('payload')),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byType(GlassSheet), findsOneWidget);
    expect(find.text('PAYLOAD'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(GlassSheet),
        matching: find.byType(BackdropFilter),
      ),
      findsOneWidget,
    );
  });
}
