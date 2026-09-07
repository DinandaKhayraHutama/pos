import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/app_dimensions.dart';
import '../../../core/theme/app_theme.dart';
import 'glass_card.dart';

/// Text input sitting on a [GlassCard.solid].
///
/// Used by the settings, checkout, and form restyle tasks. The label / hint /
/// prefix / suffix all read from [BrandColors] via `context.design`, so the
/// field re-skins automatically when the brand seed changes.
class GlassTextField extends StatelessWidget {
  const GlassTextField({
    super.key,
    this.controller,
    this.label,
    this.hint,
    this.prefix,
    this.prefixText,
    this.suffix,
    this.keyboardType,
    this.obscureText = false,
    this.inputFormatters,
    this.onChanged,
    this.onSubmitted,
    this.focusNode,
    this.autofocus = false,
    this.textInputAction,
    this.enabled = true,
    this.textCapitalization = TextCapitalization.none,
    this.maxLines = 1,
  });

  final TextEditingController? controller;
  final String? label;
  final String? hint;
  final IconData? prefix;
  final String? prefixText;
  final Widget? suffix;
  final TextInputType? keyboardType;
  final bool obscureText;
  final List<TextInputFormatter>? inputFormatters;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final FocusNode? focusNode;
  final bool autofocus;
  final TextInputAction? textInputAction;
  final bool enabled;
  final TextCapitalization textCapitalization;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final design = context.design;

    return GlassCard.solid(
      padding: const EdgeInsets.symmetric(
        horizontal: AppDimensions.space14,
        vertical: AppDimensions.space4,
      ),
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        autofocus: autofocus,
        enabled: enabled,
        keyboardType: keyboardType,
        obscureText: obscureText,
        inputFormatters: inputFormatters,
        onChanged: onChanged,
        onSubmitted: onSubmitted,
        textInputAction: textInputAction,
        textCapitalization: textCapitalization,
        maxLines: maxLines,
        cursorColor: design.primary,
        style: TextStyle(
          color: design.textHigh,
          fontSize: 15,
          fontWeight: FontWeight.w500,
        ),
        decoration: InputDecoration(
          // No fill: the global InputDecorationTheme sets `filled: true` with
          // a gray `surfaceContainerHigh` for ordinary Material text fields,
          // which is correct on a flat scaffold background but wrong here —
          // the field already sits inside a GlassCard.solid, and the gray
          // patch reads as an uneven patch on the near-opaque glass surface.
          // Override per-widget so the field blends uniformly into the card.
          filled: false,
          border: InputBorder.none,
          focusedBorder: InputBorder.none,
          enabledBorder: InputBorder.none,
          disabledBorder: InputBorder.none,
          labelText: label,
          labelStyle: TextStyle(color: design.textMedium, fontSize: 13),
          hintText: hint,
          hintStyle: TextStyle(color: design.textMedium),
          prefixIcon:
              prefix == null
                  ? null
                  : Icon(prefix, color: design.textMedium, size: 20),
          prefixText: prefixText,
          suffixIcon: suffix,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 12),
        ),
      ),
    );
  }
}
