import 'package:flutter/material.dart';

import '../theme/app_dimensions.dart';

/// The JustClick mark — the one bundled image in the app.
///
/// Every other picture the app renders is a remote product photo, so this is
/// also the only place `assets:` in pubspec.yaml is used.
///
/// The asset is a 1024px render of `tool/justclick_mark.svg` rather than the
/// 152px PNG the brand ships around, because the same file is the source for
/// every launcher icon — see `tool/generate_app_icons.py`.
///
/// Two variants, because the mark is a blue-and-light-grey shape on a
/// transparent ground and that only survives on a light or dark surface:
///
/// * [BrandMark] draws it bare, for the glass surfaces (splash card, login
///   card, side rail) where the substrate is already a legible backdrop.
/// * [BrandMark.plated] sets it on an opaque rounded plate, for
///   `_BootstrapScaffold`, whose background is a solid `colorScheme.primary` —
///   the mark's own blues would sink straight into it.
///
/// Decorative in every position it is used: the wordmark or the welcome
/// heading beside it already carries the name, so it stays out of the
/// semantics tree rather than announcing a second copy.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, required this.size}) : _plated = false;

  /// The mark on an opaque plate, sized [size] overall with the mark inset.
  const BrandMark.plated({super.key, required this.size}) : _plated = true;

  /// Edge length of the widget — the mark is square.
  final double size;

  final bool _plated;

  static const String _asset = 'assets/images/justclick_logo.png';

  @override
  Widget build(BuildContext context) {
    final edge = _plated ? size * 0.68 : size;
    // The asset is a 1024px master so the launcher icons can be generated from
    // it, but nothing here draws it above ~64pt. Decoding it at full size would
    // hold 4MB per mark in the image cache, so it is decoded at exactly the
    // pixel size this call site paints.
    final pixels = (edge * MediaQuery.devicePixelRatioOf(context)).ceil();

    final mark = Image.asset(
      _asset,
      width: edge,
      height: edge,
      cacheWidth: pixels,
      cacheHeight: pixels,
      filterQuality: FilterQuality.medium,
      excludeFromSemantics: true,
    );

    if (!_plated) return mark;

    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.onPrimary,
        borderRadius: BorderRadius.circular(AppDimensions.radius20),
      ),
      child: mark,
    );
  }
}
