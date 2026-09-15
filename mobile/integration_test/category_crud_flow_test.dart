import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nti_pos/core/widgets/glass/glass_card.dart';
import 'package:nti_pos/core/widgets/glass/glass_nav.dart';
import 'package:nti_pos/core/widgets/glass/glass_text_field.dart';
import 'package:nti_pos/main.dart' as app;
import 'package:nti_pos/providers/settings_provider.dart';

/// Integration test for the category CRUD flow: add a category (unique name)
/// and confirm it appears in the Categories management list, then delete it
/// and confirm it leaves the list.
///
/// Locale-agnostic throughout: every interaction is anchored on an icon
/// (`add_rounded` FAB, `inventory_2_outlined` mgmt entry, `delete_outline_rounded`
/// trash), a widget type ([Tab], [GlassTextField], [FilledButton], [BackButton]),
/// or text that is DATA not UI copy - the category name is caller-entered. The
/// category form (`_CategoryFormSheet`) is private, so it is driven through the
/// single [GlassTextField] (name) and single [FilledButton] (save) it mounts.
/// No translated string is matched.
///
/// The new category sorts to the bottom of the management list (a lazy
/// scrollable), so the find drags the list into view first. (The
/// category-as-POS-filter behaviour is covered by the POS widget tests; this
/// test asserts the CRUD persisted via the management list.)
///
/// Run:
///   flutter test integration_test/category_crud_flow_test.dart \
///     -d 810AB071-8AFC-41C5-B526-02246E314C4B
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('add a category then delete it', (tester) async {
    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 3));

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
    await container.read(settingsProvider.notifier).logout();
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // === STEP 1: Login -> Settings -> product management -> Categories tab ===
    for (final digit in ['1', '2', '3', '4']) {
      await tester.tap(find.text(digit).first);
      await tester.pump(const Duration(milliseconds: 200));
    }
    await tester.pumpAndSettle(const Duration(seconds: 2));
    await _tapNavDestination(tester, 4); // Settings
    await tester.pumpAndSettle(const Duration(seconds: 1));
    // The product-management tile is below the fold in the lazy settings list.
    await _scrollTo(tester, find.byIcon(Icons.inventory_2_outlined),
        find.byType(ListView));
    await tester.tap(find.byIcon(Icons.inventory_2_outlined));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    // The TabBar's second tab is Categories.
    await tester.tap(find.byType(Tab).at(1));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    final catName = 'QAC-${DateTime.now().millisecondsSinceEpoch}';
    print('Managing category: $catName');

    // === STEP 2: Add category ===
    print('=== STEP 2: Add category ===');
    await tester.tap(find.byIcon(Icons.add_rounded));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    // The category form has a single name field + a single Save button.
    await tester.enterText(find.byType(GlassTextField), catName);
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // === STEP 3: It appears in the Categories management list ===
    print('=== STEP 3: Assert in management list ===');
    await _scrollTo(tester, find.text(catName), find.byType(ListView));
    expect(find.text(catName), findsOneWidget,
        reason: 'The new category should appear in the management list');
    print('Category present in management list');

    // === STEP 4: Delete -> gone from management list ===
    print('=== STEP 4: Delete category ===');
    // The trash icon lives on the category's own tile (nearest GlassCard
    // ancestor of the name text).
    final tile = find
        .ancestor(of: find.text(catName), matching: find.byType(GlassCard))
        .first;
    await tester.ensureVisible(tile);
    await tester.tap(
      find.descendant(of: tile, matching: find.byIcon(Icons.delete_outline_rounded)),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 500));
    await tester.tap(find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(FilledButton),
    ));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(find.text(catName), findsNothing,
        reason: 'Deleted category must leave the management list');
    print('Category deleted from management');

    print('=== CATEGORY CRUD FLOW TEST PASSED ===');
  });
}

/// Drag [scrollable] up until [item] is built + visible. Avoids
/// `scrollUntilVisible`'s multi-Scrollable ambiguity.
Future<void> _scrollTo(
  WidgetTester tester,
  Finder item,
  Finder scrollable,
) async {
  for (var i = 0; i < 40 && item.evaluate().isEmpty; i++) {
    await tester.drag(scrollable, const Offset(0, -500));
    await tester.pumpAndSettle(const Duration(milliseconds: 150));
  }
}

/// Tap a [GlassNav] destination by zero-based index (same pattern as
/// `integration_test/app_e2e_test.dart`).
Future<void> _tapNavDestination(WidgetTester tester, int index) async {
  final navBar = find.byType(GlassNav);
  expect(navBar, findsOneWidget,
      reason: 'GlassNav bottom bar should be mounted');
  final destinations = find.descendant(
    of: navBar,
    matching: find.byType(InkWell),
  );
  await tester.tap(destinations.at(index));
  await tester.pumpAndSettle(const Duration(milliseconds: 800));
}
