import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nti_pos/core/localization/l10n.dart';
import 'package:nti_pos/core/theme/app_colors.dart';
import 'package:nti_pos/core/theme/app_theme.dart';
import 'package:nti_pos/core/widgets/glass/glass_nav.dart';
import 'package:nti_pos/l10n/gen/app_localizations.dart';

void main() {
  // The glass widgets read `context.design` (a BrandColors ThemeExtension),
  // so every test pumps an AppTheme that carries the extension.
  final theme = AppTheme.light(BrandPreset.presets.first);

  // Five distinct active/inactive icon pairs shared across tests.
  const items = [
    GlassNavItem(
      active: Icons.looks_one_rounded,
      inactive: Icons.looks_one_outlined,
      label: 'A',
    ),
    GlassNavItem(
      active: Icons.looks_two_rounded,
      inactive: Icons.looks_two_outlined,
      label: 'B',
    ),
    GlassNavItem(
      active: Icons.looks_3_rounded,
      inactive: Icons.looks_3_outlined,
      label: 'C',
    ),
    GlassNavItem(
      active: Icons.looks_4_rounded,
      inactive: Icons.looks_4_outlined,
      label: 'D',
    ),
    GlassNavItem(
      active: Icons.looks_5_rounded,
      inactive: Icons.looks_5_outlined,
      label: 'E',
    ),
  ];

  testWidgets('GlassNav renders 5 items and tapping index 2 fires onChanged(2)',
      (tester) async {
    int? picked;
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: GlassNav(
            index: 0,
            onChanged: (i) => picked = i,
            items: items,
          ),
        ),
      ),
    );

    expect(find.text('C'), findsOneWidget);
    await tester.tap(find.text('C'));
    expect(picked, 2);
  });

  testWidgets('GlassNav paints the selected icon from the active pair',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: GlassNav(
            index: 0,
            onChanged: (_) {},
            items: items.take(2).toList(),
          ),
        ),
      ),
    );

    // Index 0 selected → active icon rendered, inactive hidden.
    expect(find.byIcon(Icons.looks_one_rounded), findsOneWidget);
    expect(find.byIcon(Icons.looks_one_outlined), findsNothing);
    // Index 1 unselected → inactive icon rendered.
    expect(find.byIcon(Icons.looks_two_outlined), findsOneWidget);
  });

  /// The rail's collapse control is tooltipped, so it needs real
  /// localizations — unlike [GlassNav], which has no strings of its own.
  Widget railApp({
    required bool expanded,
    required ValueChanged<int> onChanged,
    ValueChanged<bool>? onToggle,
  }) => MaterialApp(
    theme: theme,
    locale: const Locale('en'),
    supportedLocales: kSupportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: Scaffold(
      body: SizedBox(
        width: 900,
        child: GlassNavRail(
          index: 0,
          onChanged: onChanged,
          items: items.take(3).toList(),
          expanded: expanded,
          onToggleExpanded: onToggle ?? (_) {},
        ),
      ),
    ),
  );

  testWidgets('GlassNavRail lays items out vertically and fires onTap',
      (tester) async {
    int? picked;
    await tester.pumpWidget(railApp(expanded: true, onChanged: (i) => picked = i));

    expect(find.text('C'), findsOneWidget);
    await tester.tap(find.text('C'));
    expect(picked, 2);
  });

  testWidgets('collapsed rail hides labels but keeps every destination',
      (tester) async {
    int? picked;
    await tester.pumpWidget(
      railApp(expanded: false, onChanged: (i) => picked = i),
    );

    // The label stays in the tree — the row is laid out at the expanded width
    // so the collapse animates rather than relayouts — but it is faded out,
    // and the tooltip is what replaces it.
    final label = tester.widget<AnimatedOpacity>(
      find.ancestor(
        of: find.text('C'),
        matching: find.byType(AnimatedOpacity),
      ),
    );
    expect(label.opacity, 0);
    // The destination is still there and still tappable via its icon.
    expect(find.byIcon(Icons.looks_3_outlined), findsOneWidget);
    await tester.tap(find.byIcon(Icons.looks_3_outlined));
    expect(picked, 2);
  });

  testWidgets('the collapse control reports the requested state',
      (tester) async {
    bool? requested;
    await tester.pumpWidget(
      railApp(expanded: true, onChanged: (_) {}, onToggle: (v) => requested = v),
    );

    await tester.tap(find.byIcon(Icons.keyboard_double_arrow_left_rounded));
    expect(requested, isFalse, reason: 'expanded rail asks to collapse');
  });

  testWidgets('badge renders when count > 0', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: GlassNav(
            index: 0,
            onChanged: (_) {},
            items: const [
              GlassNavItem(
                active: Icons.looks_one_rounded,
                inactive: Icons.looks_one_outlined,
                label: 'A',
                badge: 3,
              ),
              GlassNavItem(
                active: Icons.looks_two_rounded,
                inactive: Icons.looks_two_outlined,
                label: 'B',
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.text('3'), findsOneWidget, reason: 'badge label should render');
    expect(find.byType(Badge), findsOneWidget);
  });
}
