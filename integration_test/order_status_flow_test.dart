import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nti_pos/core/widgets/glass/glass_buttons.dart';
import 'package:nti_pos/core/widgets/glass/glass_nav.dart';
import 'package:nti_pos/core/widgets/status_badge.dart';
import 'package:nti_pos/data/models/enums.dart';
import 'package:nti_pos/features/pos/product_card.dart';
import 'package:nti_pos/main.dart' as app;
import 'package:nti_pos/providers/order_provider.dart';
import 'package:nti_pos/providers/settings_provider.dart';

/// Integration test for the order-status advancement flow: place an order,
/// open it from Orders, and advance it preparing -> ready -> served -> paid,
/// asserting the [StatusBadge] in the detail header reflects each step, and
/// that the advance action disappears once the order reaches the terminal
/// `paid` status.
///
/// A freshly placed order is created with status `preparing` (see
/// `OrderRepository.create`), so the advancement sequence starts there rather
/// than at `pending`.
///
/// Locale-agnostic throughout: status is read off the [StatusBadge] `status`
/// field (an enum, never the translated label); the advance action is anchored
/// on its `arrow_forward_rounded` icon; the order is opened by its order
/// number (data from the placed order). No translated label is matched.
///
/// Run:
///   flutter test integration_test/order_status_flow_test.dart \
///     -d 810AB071-8AFC-41C5-B526-02246E314C4B
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('advance an order through preparing -> ready -> served -> paid',
      (tester) async {
    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 3));

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
    await container.read(settingsProvider.notifier).logout();
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // === STEP 1: Login + place an order inline (the status flow needs one) ===
    for (final digit in ['1', '2', '3', '4']) {
      await tester.tap(find.text(digit).first);
      await tester.pump(const Duration(milliseconds: 200));
    }
    await tester.pumpAndSettle(const Duration(seconds: 2));
    await tester.tap(find.byType(ProductCard).first);
    await tester.pumpAndSettle(const Duration(milliseconds: 500));

    // Open cart -> switch to takeaway (skip the dine-in table detour) ->
    // checkout -> exact cash -> place order.
    await tester.tap(find.byIcon(Icons.shopping_cart_checkout_rounded));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await tester.tap(find.byIcon(Icons.shopping_bag_rounded));
    await tester.pumpAndSettle(const Duration(milliseconds: 500));
    await tester.tap(find.byIcon(Icons.payment_rounded));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await tester.tap(find.byIcon(Icons.check_circle_rounded));
    await tester.pumpAndSettle(const Duration(milliseconds: 500));
    await tester.tap(find.byType(PrimaryButton));
    await tester.pumpAndSettle(const Duration(seconds: 3));

    final orderNumber = container.read(lastPlacedOrderProvider)!.number;
    expect(find.byIcon(Icons.check_rounded), findsOneWidget,
        reason: 'Receipt should appear once the order is placed');
    print('Order placed for status flow: $orderNumber');

    // Dismiss the receipt (Done is the only PrimaryButton left).
    await tester.tap(find.byType(PrimaryButton));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // === STEP 2: Orders -> open the placed order ===
    print('=== STEP 2: Open the order detail ===');
    // The success snackbar floats over the GlassNav and intercepts taps, so
    // clear it before navigating (same fix as the sell-flow test).
    tester
        .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger).first)
        .clearSnackBars();
    await tester.pumpAndSettle(const Duration(milliseconds: 500));
    await _tapNavDestination(tester, 1);
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await tester.tap(find.text(orderNumber));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // === STEP 3: Detail mounts at `preparing` ===
    print('=== STEP 3: Assert status progression ===');
    expect(find.byType(StatusBadge), findsOneWidget,
        reason: 'The detail header should carry exactly one status badge');
    expect(_detailStatus(tester), OrderStatus.preparing,
        reason: 'A freshly placed order should start at preparing');
    print('  preparing');

    // Advance: preparing -> ready.
    await _advance(tester);
    expect(_detailStatus(tester), OrderStatus.ready,
        reason: 'Advancing from preparing should reach ready');
    print('  ready');

    // Advance: ready -> served.
    await _advance(tester);
    expect(_detailStatus(tester), OrderStatus.served,
        reason: 'Advancing from ready should reach served');
    print('  served');

    // Advance: served -> paid (terminal).
    await _advance(tester);
    expect(_detailStatus(tester), OrderStatus.paid,
        reason: 'Advancing from served should reach paid');
    // The advance action is gone at the terminal status.
    expect(find.byIcon(Icons.arrow_forward_rounded), findsNothing,
        reason: 'No advance action should render once the order is paid');
    print('  paid (terminal)');

    print('=== ORDER STATUS FLOW TEST PASSED ===');
  });
}

/// The status shown in the order-detail header. The detail page renders
/// exactly one [StatusBadge] (in its header card), so this reads it directly.
OrderStatus _detailStatus(WidgetTester tester) {
  final badge = tester.widget<StatusBadge>(find.byType(StatusBadge));
  return badge.status as OrderStatus;
}

/// Tap the detail's advance-status action (the FilledButton.icon carrying
/// `arrow_forward_rounded`) and wait for the invalidated detail to rebuild.
Future<void> _advance(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.arrow_forward_rounded));
  await tester.pumpAndSettle(const Duration(seconds: 1));
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
