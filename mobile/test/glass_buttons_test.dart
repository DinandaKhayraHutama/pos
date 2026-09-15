import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nti_pos/core/theme/app_colors.dart';
import 'package:nti_pos/core/theme/app_theme.dart';
import 'package:nti_pos/core/widgets/glass/glass_buttons.dart';

/// Glass button family — `PrimaryButton`, `SecondaryButton`, `GhostButton`,
/// `DangerButton`. These tests lock down the contract every caller relies on:
///   1. Tapping a `PrimaryButton` with `onPressed` fires the callback.
///   2. `loading: true` swaps the child for a `CircularProgressIndicator`
///      AND disables the tap handler (no fire).
///   3. `onPressed: null` disables the button — tap is a no-op.
///   4. `SecondaryButton` renders its caller-supplied child label.
void main() {
  Widget host({required Widget child}) {
    return MaterialApp(
      theme: AppTheme.light(BrandPreset.presets.first),
      home: Scaffold(body: Center(child: child)),
    );
  }

  testWidgets('tapping PrimaryButton fires onPressed', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      host(
        child: PrimaryButton(
          onPressed: () => taps++,
          child: const Text('Go'),
        ),
      ),
    );

    await tester.tap(find.text('Go'));
    await tester.pump();

    expect(taps, 1);
  });

  testWidgets(
    'PrimaryButton.loading shows a spinner and does not fire on tap',
    (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        host(
          child: PrimaryButton(
            onPressed: () => taps++,
            loading: true,
            child: const Text('Go'),
          ),
        ),
      );

      expect(
        find.descendant(
          of: find.byType(PrimaryButton),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
        reason: 'loading: true should swap the child for a spinner',
      );
      expect(
        find.text('Go'),
        findsNothing,
        reason: 'loading button hides its child label',
      );

      // The spinner animates forever, so pump (not pumpAndSettle).
      await tester.tap(find.byType(PrimaryButton), warnIfMissed: false);
      await tester.pump();

      expect(taps, 0, reason: 'loading button must not fire onPressed');
    },
  );

  testWidgets(
    'PrimaryButton with null onPressed does not fire on tap',
    (tester) async {
      await tester.pumpWidget(
        host(
          child: PrimaryButton(
            onPressed: null,
            child: const Text('Nope'),
          ),
        ),
      );

      // No gesture handler is attached, so the tap is a no-op.
      await tester.tap(find.text('Nope'), warnIfMissed: false);
      await tester.pump();

      // Reaching this assertion without throwing means the disabled button
      // neither crashed nor fired a callback.
      expect(find.text('Nope'), findsOneWidget);
    },
  );

  testWidgets('SecondaryButton renders its child text', (tester) async {
    await tester.pumpWidget(
      host(
        child: SecondaryButton(
          onPressed: () {},
          child: const Text('Cancel'),
        ),
      ),
    );

    expect(find.text('Cancel'), findsOneWidget);
  });

  // Min-height contract: every button in the family must be at least 52 logical
  // pixels tall so tap targets stay accessible regardless of content.
  testWidgets('PrimaryButton enforces min height 52', (tester) async {
    await tester.pumpWidget(
      host(
        child: PrimaryButton(
          onPressed: () {},
          child: const Text('Go'),
        ),
      ),
    );

    expect(
      tester.getRect(find.byType(PrimaryButton)).height,
      greaterThanOrEqualTo(52),
      reason: 'PrimaryButton must honour the _kMinHeight contract',
    );
  });

  testWidgets('SecondaryButton enforces min height 52', (tester) async {
    await tester.pumpWidget(
      host(
        child: SecondaryButton(
          onPressed: () {},
          child: const Text('Cancel'),
        ),
      ),
    );

    expect(
      tester.getRect(find.byType(SecondaryButton)).height,
      greaterThanOrEqualTo(52),
      reason:
          'SecondaryButton must honour the _kMinHeight contract even though '
          'its min-height flows through GlassCard.solid + ConstrainedBox',
    );
  });
}
