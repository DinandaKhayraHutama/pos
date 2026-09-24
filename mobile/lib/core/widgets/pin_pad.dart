import 'package:flutter/material.dart';

import '../theme/app_dimensions.dart';
import '../theme/app_theme.dart';
import 'glass/glass_card.dart';

/// A four-dot PIN entry with its own keypad.
///
/// Extracted because two screens need it — signing in, and a manager
/// approving something a cashier is blocked from — and a keypad that behaves
/// differently in those two places is a keypad people mistrust. The parent
/// owns the digits; this widget only reports what was typed.
class PinPad extends StatelessWidget {
  const PinPad({
    super.key,
    required this.pin,
    required this.onDigit,
    required this.onBackspace,
    this.length = 4,
    this.error = false,
    this.errorText,
    this.trailing,
  });

  /// Digits entered so far. Display only.
  final String pin;

  /// A single digit was pressed.
  ///
  /// Deliberately NOT `onChanged(newValue)`. With that shape this widget had
  /// to assemble the value from `widget.pin`, which only refreshes when the
  /// parent rebuilds — so two taps inside one frame both read the same stale
  /// string and the second digit overwrote the first. Emitting the keystroke
  /// keeps the parent's own field the single, synchronous source of truth.
  final ValueChanged<String> onDigit;

  final VoidCallback onBackspace;

  final int length;

  /// Paints the dots red and reveals [errorText].
  final bool error;
  final String? errorText;

  /// Optional widget for the bottom-left key, which is otherwise blank.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(length, (i) {
            final filled = i < pin.length;
            return AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              margin: const EdgeInsets.symmetric(horizontal: 8),
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                // In the error state the dots go red, but the UNFILLED ones
                // stay faint. A rejected PIN is cleared, so painting all four
                // solid red read as "four digits are still entered" at the
                // exact moment the user needs to see an empty field to retype
                // into.
                color: error
                    ? design.error.withValues(alpha: filled ? 1 : 0.35)
                    : (filled
                          ? design.primary
                          : design.textLow.withValues(alpha: 0.5)),
              ),
            );
          }),
        ),
        // Reserved rather than conditional: an error message that appears out
        // of nowhere shifts the keypad under the finger already reaching for
        // it, and the retry lands on the wrong digit.
        AnimatedOpacity(
          opacity: error ? 1 : 0,
          duration: const Duration(milliseconds: 180),
          child: Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
              errorText ?? '',
              textAlign: TextAlign.center,
              style: TextStyle(color: design.error, fontSize: 12),
            ),
          ),
        ),
        const SizedBox(height: AppDimensions.space20),
        GridView.count(
          crossAxisCount: 3,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(
            horizontal: AppDimensions.space16,
          ),
          mainAxisSpacing: AppDimensions.space10,
          crossAxisSpacing: AppDimensions.space10,
          childAspectRatio: 1.4,
          children: [
            for (final n in const ['1', '2', '3', '4', '5', '6', '7', '8', '9'])
              _PinKey(label: n, onTap: () => onDigit(n)),
            _PinKey(onTap: () {}, child: trailing ?? const SizedBox.shrink()),
            _PinKey(label: '0', onTap: () => onDigit('0')),
            _PinKey(
              onTap: onBackspace,
              child: Icon(Icons.backspace_rounded, color: design.textMedium),
            ),
          ],
        ),
      ],
    );
  }
}

class _PinKey extends StatelessWidget {
  const _PinKey({this.label, required this.onTap, this.child});

  final String? label;
  final VoidCallback onTap;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    return GlassCard.solid(
      onTap: onTap,
      padding: EdgeInsets.zero,
      child: Center(
        child:
            child ??
            Text(
              label ?? '',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w600,
                color: design.textHigh,
              ),
            ),
      ),
    );
  }
}
