import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'helpers/pos_session.dart';

import 'package:nti_pos/core/widgets/glass/glass_chip.dart';
import 'package:nti_pos/core/widgets/glass/glass_nav.dart';
import 'package:nti_pos/core/widgets/status_badge.dart';
import 'package:nti_pos/data/models/enums.dart';
import 'package:nti_pos/features/pos/product_card.dart';
import 'package:nti_pos/main.dart' as app;
import 'package:nti_pos/providers/settings_provider.dart';

/// Integration test for the table-management flow: changing a table's status
/// to occupied survives navigating away and back (the change is persisted to
/// the on-device DB, not just held in provider state), and starting an order
/// from an available table navigates to POS.
///
/// Locale-agnostic throughout: status is read off the tile's [StatusBadge]
/// `status` field (an enum — never the translated label), the status chips in
/// the action sheet are located by [GlassFilterChip] type + their fixed order
/// (available/occupied/reserved), and tables are opened by tapping the
/// `table_restaurant_rounded` icon each tile carries. No translated label is
/// matched.
///
/// The occupied-persistence sub-flow runs first because its status-chip tap
/// closes the action sheet via `Navigator.pop` (clean — no modal left behind).
/// The start-order sub-flow runs last: its `context.go('/')` navigates to POS
/// but does not itself pop the modal, so we do not navigate again afterwards.
///
/// Run:
///   flutter test integration_test/table_flow_test.dart \
///     -d 810AB071-8AFC-41C5-B526-02246E314C4B
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'occupied status persists across navigation; start order opens POS',
      (tester) async {
    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 3));

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
    await container.read(settingsProvider.notifier).logout();
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // === STEP 1: Login (2345, a cashier) -> pick a till -> POS, then Tables
    // Pick the account before the keypad: the PIN is verified against the
    // chosen row, so digits alone never leave the picker.
    await pickFirstCashierAccount(tester);
    for (final digit in ['2', '3', '4', '5']) {
      await tester.tap(find.text(digit).first);
      await tester.pump(const Duration(milliseconds: 200));
    }
    await tester.pumpAndSettle(const Duration(seconds: 2));
    // Table service is a per-till setting now, so this flow needs a till that
    // actually runs the floor plan — the seeded branch also has a takeaway
    // counter, and opening that one would correctly hide the Tables tab.
    await openPosSessionIfNeeded(tester, container, requireTableService: true);
    addTearDown(() => closePosSessionIfAny(tester, container));
    expect(find.byType(GridView), findsOneWidget, reason: 'POS should mount');
    await _tapNavDestination(tester, 2);
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(find.byType(StatusBadge), findsWidgets,
        reason: 'Table tiles with status badges should render');

    // === STEP 2: Flip a table to occupied ===
    print('=== STEP 2: Set a table occupied ===');
    final before = _tileStatuses(tester);
    expect(before, isNotEmpty, reason: 'Tables should be loaded');
    // Pick the FIRST non-occupied table. The bottom grid row sits close to the
    // GlassNav, so a tile there can be miss-tapped as a nav destination (its
    // icon center falls inside the nav's hit region); the first tile sits at
    // the top of the grid, clear of the nav.
    final targetIdx = before.indexWhere((s) => s != TableStatus.occupied);
    expect(targetIdx, greaterThanOrEqualTo(0),
        reason: 'A non-occupied table should exist to mark occupied');
    await tester.tap(find.byIcon(Icons.table_restaurant_rounded).at(targetIdx));
    await tester.pumpAndSettle(const Duration(milliseconds: 600));
    // The action sheet's status chips live inside the open BottomSheet, in
    // fixed order: available(0), occupied(1), reserved(2). Scope to the sheet
    // so any stray chips elsewhere on the page don't shift the index.
    final chips = find.descendant(
      of: find.byType(BottomSheet).first,
      matching: find.byType(GlassFilterChip),
    );
    expect(chips, findsNWidgets(3),
        reason: 'Action sheet should show exactly three status chips');
    await tester.tap(chips.at(1)); // occupied -> setStatus + pop
    await tester.pumpAndSettle(const Duration(milliseconds: 800));
    print('Table at index $targetIdx set occupied');

    // === STEP 3: Navigate away and back -> status persisted ===
    print('=== STEP 3: Nav away and back, assert persisted ===');
    await _tapNavDestination(tester, 0); // POS
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await _tapNavDestination(tester, 2); // Tables again
    await tester.pumpAndSettle(const Duration(seconds: 1));
    final after = _tileStatuses(tester);
    expect(after.length, before.length,
        reason: 'The tables grid should hold the same number of tiles');
    expect(after[targetIdx], TableStatus.occupied,
        reason:
            'The table marked occupied must still be occupied after navigating '
            'away and back (persisted to the on-device DB, not just provider '
            'state)');
    print('Occupied status persisted across navigation');

    // === STEP 4: Start order from an available table -> POS ===
    print('=== STEP 4: Start order from an available table ===');
    final statuses = _tileStatuses(tester);
    final availIdx = statuses.indexOf(TableStatus.available);
    expect(availIdx, greaterThanOrEqualTo(0),
        reason: 'At least one table should be available on a fresh seed');
    await tester.tap(find.byIcon(Icons.table_restaurant_rounded).at(availIdx));
    await tester.pumpAndSettle(const Duration(milliseconds: 600));
    expect(find.byIcon(Icons.add_shopping_cart_rounded), findsOneWidget,
        reason: 'An available table should offer a start-order action');
    await tester.tap(find.byIcon(Icons.add_shopping_cart_rounded));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(find.byType(ProductCard), findsWidgets,
        reason: 'Start order should navigate to the POS catalog');
    print('Start order navigated to POS');

    print('=== TABLE FLOW TEST PASSED ===');
  });
}

/// Status of every table tile's [StatusBadge], in tile order. Only call this
/// when no action sheet is open — the sheet carries its own [StatusBadge]
/// which would otherwise pollute the order.
List<dynamic> _tileStatuses(WidgetTester tester) {
  return find
      .byType(StatusBadge)
      .evaluate()
      .map((e) => (e.widget as StatusBadge).status)
      .toList();
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
