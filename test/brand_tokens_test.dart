import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nti_pos/core/theme/app_colors.dart';
import 'package:nti_pos/core/theme/app_theme.dart';

void main() {
  test(
    'ColorScheme.primary equals the hand-tuned brand token, not a seed derivation',
    () {
      for (final b in BrandPreset.presets) {
        expect(
          AppTheme.light(b).colorScheme.primary,
          b.light.primary,
          reason: b.id,
        );
        expect(
          AppTheme.dark(b).colorScheme.primary,
          b.dark.primary,
          reason: b.id,
        );
      }
    },
  );

  test('every preset paints a distinct bootstrap primary', () {
    final xs = BrandPreset.presets
        .map((b) => AppTheme.light(b).colorScheme.primary)
        .toSet();
    expect(xs.length, BrandPreset.presets.length);
  });

  test('no brand disappears against the dark surface', () {
    // The trap a dark accent walks into, and the reason `BrandAccent` carries
    // an optional `primaryDark`: NTI's #1E40AF reads at about 1.8:1 on the
    // dark surface base — a button nobody can find. Every preset is checked so
    // the next dark brand cannot ship without its lighter dark-mode tone.
    //
    // 3:1 is the WCAG floor for a large UI component. All presets clear it
    // today; this is a regression guard, not a wish.
    for (final b in BrandPreset.presets) {
      final ratio = _contrast(b.dark.primary, b.dark.surfaceBase);
      expect(
        ratio,
        greaterThanOrEqualTo(3.0),
        reason:
            '${b.id}: dark primary on surfaceBase is only '
            '${ratio.toStringAsFixed(2)}:1 — give it a lighter primaryDark',
      );
    }
  });

  test('the default brand is legible in both brightnesses', () {
    // Scoped to the brand that actually ships. Running the same thresholds
    // over every preset fails today: `ocean` light is 2.59:1 primary-on-
    // surface and `flame` light is 3.50:1 white-on-primary. Both predate this
    // work and both are visual calls for whoever owns the palette, so they are
    // reported rather than silently repainted — and rather than encoded here
    // as an expectation that they stay wrong.
    final b = BrandPreset.presets.first;
    for (final (label, tokens) in [('light', b.light), ('dark', b.dark)]) {
      expect(
        _contrast(tokens.primary, tokens.surfaceBase),
        greaterThanOrEqualTo(3.0),
        reason: '${b.id} $label: primary on surfaceBase',
      );
      // A light `primaryDark` needs a DARK `onPrimaryDark`; forgetting the
      // second half leaves white-on-pale-blue label text.
      expect(
        _contrast(tokens.onPrimary, tokens.primary),
        greaterThanOrEqualTo(4.5),
        reason: '${b.id} $label: onPrimary on primary',
      );
    }
  });

  test('the swatch shown in Settings matches the light primary', () {
    // The swatch is a separate field, so it can drift from the palette it is
    // advertising. A Settings chip that paints a colour the app never uses is
    // a promise the theme does not keep.
    for (final b in BrandPreset.presets) {
      expect(b.swatch, b.light.primary, reason: b.id);
    }
  });

  testWidgets(
    'context.design and context.semantic resolve to BrandColors inside the theme',
    (tester) async {
      final b = BrandPreset.presets.first;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(b),
          home: Builder(
            builder: (c) {
              expect(c.design, isA<BrandColors>());
              expect(c.semantic, same(c.design));
              expect(c.design.success, isNotNull);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
    },
  );
}

/// WCAG relative luminance.
double _luminance(Color c) {
  double channel(double v) {
    final s = v; // already 0..1
    return s <= 0.03928 ? s / 12.92 : math.pow((s + 0.055) / 1.055, 2.4) as double;
  }

  return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
}

/// WCAG contrast ratio between two opaque colours, 1.0 … 21.0.
double _contrast(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}
