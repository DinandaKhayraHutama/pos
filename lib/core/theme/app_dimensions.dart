import 'package:flutter/material.dart';

/// Spacing & sizing tokens used app-wide to keep the UI consistent.
class AppDimensions {
  AppDimensions._();

  // Spacing scale (4-pt grid)
  static const double space2 = 2;
  static const double space4 = 4;
  static const double space6 = 6;
  static const double space8 = 8;
  static const double space10 = 10;
  static const double space12 = 12;
  static const double space14 = 14;
  static const double space16 = 16;
  static const double space18 = 18;
  static const double space20 = 20;
  static const double space24 = 24;
  static const double space28 = 28;
  static const double space32 = 32;

  // Radii
  static const double radius2 = 2;
  static const double radius4 = 4;
  static const double radius6 = 6;
  static const double radius8 = 8;
  static const double radius10 = 10;
  static const double radius12 = 12;
  static const double radius14 = 14;
  static const double radius16 = 16;
  static const double radius18 = 18;
  static const double radius20 = 20;
  static const double radius28 = 28;
  static const double radius32 = 32;

  // Layout breakpoints
  static const double phoneWidth = 600;
  static const double tabletWidth = 900;

  /// Above this the side rail starts expanded on a fresh install. Below it a
  /// 248dp rail would eat a quarter of a 900dp tablet, so it starts collapsed.
  /// Only the *default* — once the user toggles it, their choice is kept.
  static const double desktopWidth = 1180;

  // Common component sizes.
  // No productCardHeight here on purpose: a POS tile's height depends on its
  // width and the text scale, so it is computed by productCardExtent() in
  // features/pos/product_card.dart rather than fixed.
  static const double categoryChipHeight = 44;
  static const double cartPanelWidth = 380;

  /// Side rail, expanded and collapsed. The collapsed width is a 44dp tap
  /// target plus symmetric padding — anything narrower makes the icons feel
  /// glued to the edge.
  static const double navRailWidth = 248;
  static const double navRailCollapsedWidth = 76;

  static const EdgeInsets screenPadding = EdgeInsets.all(space16);
  static const EdgeInsets cardPadding = EdgeInsets.all(space14);

  static BorderRadius get radiusSm => BorderRadius.circular(radius8);
  static BorderRadius get radiusMd => BorderRadius.circular(radius14);
  static BorderRadius get radiusLg => BorderRadius.circular(radius20);
  static BorderRadius get radiusXl => BorderRadius.circular(radius28);
}
