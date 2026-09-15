import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nti_pos/core/theme/app_colors.dart';
import 'package:nti_pos/core/theme/app_theme.dart';
import 'package:nti_pos/core/widgets/glass/glass_card.dart';

/// `GlassCard` is the workhorse glassmorphism container every screen composes
/// over `AppBackground`. These tests lock down the three invariants callers
/// rely on:
///   1. `.solid` skips the `BackdropFilter` (so a scroll list of N cards
///      doesn't allocate N GPU blurs).
///   2. `onTap` is wired through to the gesture handler.
///   3. The default (`blur: true`) path does paint a `BackdropFilter`.
void main() {
  Widget host({required Widget child}) {
    return MaterialApp(
      theme: AppTheme.light(BrandPreset.presets.first),
      home: Scaffold(body: Center(child: child)),
    );
  }

  testWidgets(
    'GlassCard.solid renders its child and skips BackdropFilter',
    (tester) async {
      final childKey = UniqueKey();
      await tester.pumpWidget(
        host(
          child: GlassCard.solid(child: SizedBox(key: childKey)),
        ),
      );

      expect(find.byKey(childKey), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(GlassCard),
          matching: find.byType(BackdropFilter),
        ),
        findsNothing,
        reason: '.solid is the list-item variant; no blur',
      );
    },
  );

  testWidgets('tapping a GlassCard with onTap fires the callback', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      host(
        child: GlassCard(
          onTap: () => taps++,
          child: const Icon(Icons.add_rounded),
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.add_rounded));
    await tester.pump();

    expect(taps, 1);
  });

  testWidgets('GlassCard with blur:true contains a BackdropFilter', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(child: const GlassCard(child: SizedBox.shrink())),
    );

    expect(
      find.descendant(
        of: find.byType(GlassCard),
        matching: find.byType(BackdropFilter),
      ),
      findsOneWidget,
      reason: 'default blur:true must paint the substrate blur',
    );
  });

  testWidgets('a supplied tint keeps its own alpha', (tester) async {
    // The regression this guards. `glassOpacity` belongs to the DEFAULT tint;
    // forcing it onto a caller's colour overwrote that colour's alpha, and
    // since the flat-genre change set glassOpacity to 1.0, every soft
    // container token — `primaryContainer` is `primary` at 14% — painted as
    // the full-strength brand colour. Call sites then paired it with
    // `onXContainer` text, tuned for a pale wash, so the checkout total read
    // as dark navy on saturated blue.
    final brand = BrandPreset.presets.first;
    final soft = brand.light.primaryContainer;

    await tester.pumpWidget(
      host(child: GlassCard.solid(tint: soft, child: const SizedBox())),
    );

    final painted = tester
        .widgetList<DecoratedBox>(find.byType(DecoratedBox))
        .map((d) => d.decoration)
        .whereType<BoxDecoration>()
        .where((d) => d.color != null)
        .map((d) => d.color!)
        .toList();

    expect(
      painted,
      contains(soft),
      reason: 'the tint must be painted exactly as given, alpha included',
    );
    expect(
      painted,
      isNot(contains(soft.withValues(alpha: 1.0))),
      reason: 'a 14% container must not be painted at full strength',
    );
  });
}
