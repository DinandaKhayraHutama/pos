/// Named `TextStyle`s built on top of the bundled Plus Jakarta Sans family.
///
/// These are thin helpers — they do not read the [Theme] (so they're safe to
/// use from places that don't have a [BuildContext] yet, e.g. declarative
/// styles in lists). For widgets that live inside the tree, prefer pulling
/// the ambient [TextStyle] via `Theme.of(context).textTheme.*` and merging.
///
/// Money / quantity styles always enable [FontFeature.tabularFigures] so
/// digit columns (prices, totals, qty steppers) don't shift width as the
/// digits change.
library;

import 'package:flutter/material.dart';

/// Font family name as registered in `pubspec.yaml` under `flutter.fonts`.
const String kPlusJakartaSansFamily = 'PlusJakartaSans';

const List<FontFeature> _kTabularFigures = <FontFeature>[
  FontFeature.tabularFigures(),
];

/// Text style for money / price strings: Plus Jakarta Sans, tabular figures
/// so digits don't jitter, caller-supplied [color] / [fontSize] / [weight].
///
/// Example:
/// ```dart
/// Text(
///   '\$12.40',
///   style: moneyStyle(Theme.of(context).colorScheme.onSurface, fontSize: 18),
/// );
/// ```
TextStyle moneyStyle(
  Color color, {
  double fontSize = 14,
  FontWeight weight = FontWeight.w600,
  double letterSpacing = -0.1,
  TextDecoration decoration = TextDecoration.none,
  Color? decorationColor,
  double height = 1.2,
}) {
  return TextStyle(
    fontFamily: kPlusJakartaSansFamily,
    fontFeatures: _kTabularFigures,
    color: color,
    fontSize: fontSize,
    fontWeight: weight,
    letterSpacing: letterSpacing,
    decoration: decoration,
    decorationColor: decorationColor,
    height: height,
  );
}

/// Tight display style for large headings (hero numbers, screen titles).
TextStyle displayStyle(
  Color color, {
  double fontSize = 32,
  FontWeight weight = FontWeight.w700,
  double letterSpacing = -0.5,
  double height = 1.1,
}) {
  return TextStyle(
    fontFamily: kPlusJakartaSansFamily,
    color: color,
    fontSize: fontSize,
    fontWeight: weight,
    letterSpacing: letterSpacing,
    height: height,
  );
}

/// Headline style for card titles, dialog headings, section labels.
TextStyle headlineStyle(
  Color color, {
  double fontSize = 22,
  FontWeight weight = FontWeight.w700,
  double letterSpacing = -0.3,
  double height = 1.15,
}) {
  return TextStyle(
    fontFamily: kPlusJakartaSansFamily,
    color: color,
    fontSize: fontSize,
    fontWeight: weight,
    letterSpacing: letterSpacing,
    height: height,
  );
}

/// Style for quantity steppers and other numeric UI that is not money:
/// tabular figures keep digit columns aligned.
TextStyle numericStyle(
  Color color, {
  double fontSize = 14,
  FontWeight weight = FontWeight.w600,
  double letterSpacing = 0,
}) {
  return TextStyle(
    fontFamily: kPlusJakartaSansFamily,
    fontFeatures: _kTabularFigures,
    color: color,
    fontSize: fontSize,
    fontWeight: weight,
    letterSpacing: letterSpacing,
  );
}
