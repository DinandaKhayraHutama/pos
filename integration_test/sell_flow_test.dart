import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'helpers/pos_session.dart';

import 'package:nti_pos/core/widgets/glass/glass_buttons.dart';
import 'package:nti_pos/core/widgets/glass/glass_nav.dart';
import 'package:nti_pos/features/pos/product_card.dart';
import 'package:nti_pos/main.dart' as app;
import 'package:nti_pos/providers/cart_provider.dart';
import 'package:nti_pos/providers/order_provider.dart';
import 'package:nti_pos/providers/settings_provider.dart';

/// Integration test for the core POS sell flow: add a product to the cart,
/// checkout with exact cash, confirm the success receipt, and verify the
/// placed order shows up in Orders with its line item intact.
///
/// This is exactly the end-to-end path that would have caught the Task 11
/// bug where `OrderRepository.create` returned an [Order] with `items: []`,
/// throwing on every checkout when `_SuccessReceipt` read
/// `order.items.first`. The receipt + order-detail assertions here are the
/// whole point of this test - if that regresses, this test catches it.
///
/// Locale-agnostic throughout: every tap is anchored on an [IconData] or a
/// widget type, never a translated label. The order number and product name
/// asserted at the end are DATA (from the DB / the placed order), not UI
/// copy, so matching them by text is fine.
///
/// Run:
///   flutter test integration_test/sell_flow_test.dart \
///     -d 810AB071-8AFC-41C5-B526-02246E314C4B
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'add product to cart, checkout with exact cash, order appears in Orders',
      (tester) async {
    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 3));

    // Force logout to reach the login page from scratch, regardless of
    // whatever session state was left over from a previous test run.
    final container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
    await container.read(settingsProvider.notifier).logout();
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // === STEP 1: Login (2345, a cashier) -> pick a till -> POS ===
    print('=== STEP 1: Login ===');
    // Pick the account before the keypad: the PIN is verified against the
    // chosen row, so digits alone never leave the picker.
    await pickFirstCashierAccount(tester);
    for (final digit in ['2', '3', '4', '5']) {
      await tester.tap(find.text(digit).first);
      await tester.pump(const Duration(milliseconds: 200));
    }
    await tester.pumpAndSettle(const Duration(seconds: 2));
    // Selling needs an open POS session, so a cashier lands on the till picker
    // rather than on the catalogue. Setup, not the assertion.
    await openPosSessionIfNeeded(tester, container);
    addTearDown(() => closePosSessionIfAny(tester, container));
    expect(find.byType(GridView), findsOneWidget,
        reason: 'POS catalog grid should be mounted');
    expect(find.byType(ProductCard), findsWidgets,
        reason: 'Product cards should render');
    await IntegrationTestWidgetsFlutterBinding.instance
        .takeScreenshot('18_01_pos_page');

    // === STEP 2: Tap a product -> cart count increments ===
    print('=== STEP 2: Add product to cart ===');
    await tester.tap(find.byType(ProductCard).first);
    await tester.pumpAndSettle(const Duration(milliseconds: 500));
    expect(container.read(cartProvider).itemCount, 1,
        reason: 'Cart should hold one item after tapping a product card');
    final productName = container.read(cartProvider).lines.first.product.name;
    print('Added product to cart: $productName');

    // === STEP 3: Open the cart (bottom sheet on phone) ===
    print('=== STEP 3: Open cart ===');
    // The header cart icon (Icons.shopping_cart_checkout_rounded) opens the
    // cart sheet on phone width - a stable icon anchor, distinct from the
    // checkout CTA inside the sheet.
    await tester.tap(find.byIcon(Icons.shopping_cart_checkout_rounded));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await IntegrationTestWidgetsFlutterBinding.instance
        .takeScreenshot('18_02_cart_sheet');

    // Switch order type to takeaway (SegmentedSelector's takeaway segment
    // icon) so checkout doesn't first require picking a dine-in table -
    // that table-selection detour is orthogonal to what this test covers.
    await tester.tap(find.byIcon(Icons.shopping_bag_rounded));
    await tester.pumpAndSettle(const Duration(milliseconds: 500));
    expect(container.read(cartProvider).type.name, 'takeaway',
        reason: 'Cart type should switch to takeaway');

    // === STEP 4: Proceed to checkout ===
    print('=== STEP 4: Proceed to checkout ===');
    // The cart summary's checkout button carries Icons.payment_rounded.
    await tester.tap(find.byIcon(Icons.payment_rounded));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await IntegrationTestWidgetsFlutterBinding.instance
        .takeScreenshot('18_03_checkout_sheet');

    // === STEP 5: Set cash to the exact total, then place the order ===
    print('=== STEP 5: Exact cash + place order ===');
    // Payment method defaults to cash, so the cash field (and its
    // exact-cash suffix button) is already visible - no need to tap the
    // cash payment-method segment. The exact-cash button
    // (Icons.check_circle_rounded) sets the cash field to the exact total.
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget,
        reason: 'Exact-cash button should be visible on the cash field');
    await tester.tap(find.byIcon(Icons.check_circle_rounded));
    await tester.pumpAndSettle(const Duration(milliseconds: 500));

    expect(find.byType(PrimaryButton), findsOneWidget,
        reason:
            'Only the place-order PrimaryButton should exist pre-placement');
    await tester.tap(find.byType(PrimaryButton));
    // placeOrderFromCart runs against the real on-device sqflite DB and the
    // UI pops two sheets + mounts a third (the receipt) - give this
    // generous time to settle.
    await tester.pumpAndSettle(const Duration(seconds: 3));
    await IntegrationTestWidgetsFlutterBinding.instance
        .takeScreenshot('18_04_success_receipt');

    // === STEP 6: Success receipt appears ===
    print('=== STEP 6: Success receipt ===');
    // _SuccessReceipt's large header icon (Icons.check_rounded) is a
    // distinctive, locale-agnostic anchor distinct from the success
    // snackbar's Icons.check_circle_rounded shown at the same time. Its
    // presence proves order.items.first didn't throw (the Task 11 bug).
    expect(find.byIcon(Icons.check_rounded), findsOneWidget,
        reason:
            '_SuccessReceipt success icon should appear after placing the order');
    expect(find.text(productName), findsWidgets,
        reason: 'The receipt should show the line item for the added product');

    final placedOrder = container.read(lastPlacedOrderProvider);
    expect(placedOrder, isNotNull,
        reason: 'lastPlacedOrderProvider should hold the newly placed order');
    final orderNumber = placedOrder!.number;
    print('Order placed: $orderNumber');

    // === STEP 7: Dismiss the receipt -> back on POS ===
    print('=== STEP 7: Dismiss receipt ===');
    // The checkout sheet has already popped itself before the receipt
    // mounts, so the receipt's "Done" PrimaryButton is the only one left.
    expect(find.byType(PrimaryButton), findsOneWidget,
        reason: 'Only the receipt Done PrimaryButton should remain');
    await tester.tap(find.byType(PrimaryButton));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(find.byType(GridView), findsOneWidget,
        reason: 'Dismissing the receipt should land back on POS');
    print('Back on POS');

    // === STEP 8: Navigate to Orders -> the new order tile is present ===
    print('=== STEP 8: Orders tab ===');
    // The success snackbar (posOrderPlaced) floats over the bottom of the
    // screen and intercepts taps on the GlassNav, so clear it deterministically
    // before navigating (waiting it out is flaky).
    tester
        .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger).first)
        .clearSnackBars();
    await tester.pumpAndSettle(const Duration(milliseconds: 500));
    await _tapNavDestination(tester, 1);
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await IntegrationTestWidgetsFlutterBinding.instance
        .takeScreenshot('18_05_orders_page');
    expect(find.text(orderNumber), findsOneWidget,
        reason:
            'The new order should appear in the Orders list by its order number');

    // === STEP 9: Tap it -> order detail shows the line item ===
    print('=== STEP 9: Order detail ===');
    await tester.tap(find.text(orderNumber));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await IntegrationTestWidgetsFlutterBinding.instance
        .takeScreenshot('18_06_order_detail');
    expect(find.text(orderNumber), findsWidgets,
        reason: 'Order detail header should show the order number');
    expect(find.text(productName), findsWidgets,
        reason: 'Order detail should show the line item for the product sold');

    print('=== SELL FLOW TEST PASSED ===');
  });
}

/// Tap a [GlassNav] destination by zero-based index (same pattern as
/// `integration_test/app_e2e_test.dart`). [GlassNav] destinations are
/// `InkWell`s inside a `Row`, not a `NavigationBar`, so we descend from the
/// nav bar rather than matching on translated labels.
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
