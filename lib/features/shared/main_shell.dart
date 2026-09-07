import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/account_picker.dart';
import '../../core/auth/permissions.dart';
import '../../core/localization/l10n.dart';
import '../../core/theme/app_dimensions.dart';
import '../../core/widgets/app_background.dart';
import '../../core/widgets/glass/glass_nav.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../providers/cart_provider.dart';
import '../../providers/settings_provider.dart';

/// Hosts the bottom navigation bar and renders the active feature page.
class MainShell extends ConsumerStatefulWidget {
  const MainShell({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<MainShell> createState() => _MainShellState();
}

/// A candidate tab. [permission] is null for tabs every role gets.
class _Tab {
  const _Tab({
    required this.path,
    required this.active,
    required this.inactive,
    this.permission,
    this.needsTableService = false,
  });

  final String path;
  final IconData active;
  final IconData inactive;
  final AppPermission? permission;

  /// Whether this destination only makes sense in a store that seats guests at
  /// tables. Separate from [permission] on purpose: one asks what the business
  /// does, the other what the person may do, and a tab needs both.
  final bool needsTableService;
}

class _MainShellState extends ConsumerState<MainShell> {
  /// Every tab the shell can show, in display order.
  ///
  /// The visible set is derived from the signed-in role, so a cashier's bar
  /// has four destinations and an owner's has five. Deriving it — rather than
  /// keeping a hardcoded index map as this did before — is what keeps the
  /// selected tab correct: with a static map, hiding Dashboard left Settings
  /// highlighting the wrong slot.
  static final _tabs = <_Tab>[
    _Tab(
      path: '/',
      active: Icons.storefront_rounded,
      inactive: Icons.storefront_outlined,
      permission: AppPermission.sell,
    ),
    _Tab(
      path: '/orders',
      active: Icons.receipt_long_rounded,
      inactive: Icons.receipt_long_outlined,
    ),
    _Tab(
      path: '/tables',
      active: Icons.table_restaurant_rounded,
      inactive: Icons.table_restaurant_outlined,
      permission: AppPermission.manageTables,
      needsTableService: true,
    ),
    _Tab(
      path: '/dashboard',
      active: Icons.bar_chart_rounded,
      inactive: Icons.bar_chart_outlined,
      permission: AppPermission.viewDailySummary,
    ),
    _Tab(
      path: '/settings',
      active: Icons.settings_rounded,
      inactive: Icons.settings_outlined,
    ),
  ];

  /// The index within [visible] that [location] belongs to.
  ///
  /// Falls back to the first visible tab rather than to a hardcoded 0: for a
  /// role that cannot sell, slot 0 is Orders, not POS.
  int _indexFromLocation(String location, List<_Tab> visible) {
    final path = Uri.parse(location).path;
    // Longest path first so '/orders/abc' matches '/orders' and never '/'.
    var best = -1;
    var bestLength = -1;
    for (var i = 0; i < visible.length; i++) {
      final p = visible[i].path;
      final matches = p == '/'
          ? path == '/'
          : path == p || path.startsWith('$p/');
      if (matches && p.length > bestLength) {
        best = i;
        bestLength = p.length;
      }
    }
    return best < 0 ? 0 : best;
  }

  String _label(AppLocalizations l10n, String path) => switch (path) {
    '/orders' => l10n.navOrders,
    '/tables' => l10n.navTables,
    '/dashboard' => l10n.navDashboard,
    '/settings' => l10n.navSettings,
    _ => l10n.navPos,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final location = GoRouterState.of(context).uri.path;
    final cartCount = ref.watch(cartProvider.select((c) => c.itemCount));
    final isTablet =
        MediaQuery.of(context).size.width >= AppDimensions.tabletWidth;

    final settings = ref.watch(settingsProvider).valueOrNull;
    final visible = [
      for (final t in _tabs)
        if ((t.permission == null || settings?.can(t.permission!) != false) &&
            (!t.needsTableService || settings?.tableServiceEnabled != false))
          t,
    ];
    final index = _indexFromLocation(location, visible);

    final items = [
      for (final t in visible)
        GlassNavItem(
          active: t.active,
          inactive: t.inactive,
          label: _label(l10n, t.path),
          // Only the till carries the cart badge; a count on Orders would
          // read as unread orders, which is a different thing entirely.
          badge: t.path == '/' ? cartCount : 0,
        ),
    ];

    void onTap(int i) => context.go(visible[i].path);

    if (isTablet) {
      // Default from the window, then whatever the user last chose. A 248dp
      // rail is a quarter of a 900dp tablet and most of that is empty label
      // space, so a tablet starts collapsed and a desktop starts open —
      // until someone says otherwise, and then their choice is what counts.
      final width = MediaQuery.of(context).size.width;
      final expanded =
          settings?.navRailExpanded ?? width >= AppDimensions.desktopWidth;

      return Scaffold(
        backgroundColor: Colors.transparent,
        body: AppBackground(
          child: Row(
            children: [
              GlassNavRail(
                index: index,
                onChanged: onTap,
                items: items,
                expanded: expanded,
                onToggleExpanded: (v) =>
                    ref.read(settingsProvider.notifier).setNavRailExpanded(v),
                footer: OnDutyRailTile(expanded: expanded),
              ),
              Expanded(child: widget.child),
            ],
          ),
        ),
      );
    }

    // The nav bar lives INSIDE AppBackground (not in `bottomNavigationBar`)
    // so two things hold:
    //   1. The brand gradient + blobs paint behind the navbar's translucent
    //      tint, so the bar reads as glass over the same substrate as the body
    //      instead of as a flat opaque slab against a black void.
    //   2. The bottom safe-area strip (home-indicator inset) is covered by the
    //      GlassNav's own DecoratedBox — `SafeArea(top: false)` inside the nav
    //      extends the tint down through the inset. The Scaffold's
    //      `bottomNavigationBar` slot strips MediaQuery bottom padding, which
    //      defeated the inner SafeArea and left a black strip in light mode.
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AppBackground(
        child: Column(
          children: [
            Expanded(child: widget.child),
            GlassNav(index: index, onChanged: onTap, items: items),
          ],
        ),
      ),
    );
  }
}
