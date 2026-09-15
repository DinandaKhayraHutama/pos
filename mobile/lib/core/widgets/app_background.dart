import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Flat substrate painted behind every screen.
///
/// This used to paint a diagonal brand gradient plus soft floating colour
/// blobs. That is the visual language of a consumer lifestyle app, and it was
/// the single biggest reason the product read as unserious: a cashier's tool is
/// judged on legibility and density, and a tinted wash costs contrast on every
/// screen while adding nothing a user can act on. It now fills with
/// [BrandColors.surfaceBase] — a near-neutral working surface that lets the
/// brand show up where it means something (primary actions, selected state,
/// money) instead of everywhere at once.
///
/// The `gradient` and `blobs` tokens still exist on [BrandColors]; nothing
/// reads them today. Kept so a per-brand substrate can come back without
/// re-deriving them, and so removing them is a deliberate decision rather than
/// a side effect of this change.
///
/// Kept as a widget rather than deleted: every screen already mounts it, and it
/// stays the one place a substrate treatment belongs.
class AppBackground extends StatelessWidget {
  const AppBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(color: context.design.surfaceBase, child: child);
  }
}
