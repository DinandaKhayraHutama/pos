import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nti_pos/core/widgets/glass/glass_card.dart';
import 'package:nti_pos/core/widgets/glass/glass_nav.dart';
import 'package:nti_pos/core/widgets/glass/glass_text_field.dart';
import 'package:nti_pos/features/products/product_form_sheet.dart';
import 'package:nti_pos/main.dart' as app;
import 'package:nti_pos/providers/catalog_provider.dart';
import 'package:nti_pos/providers/settings_provider.dart';

/// Integration test for the product CRUD flow: add a product (unique name +
/// price + a category), confirm it appears in the POS grid, edit it to drop
/// availability and confirm it leaves the POS grid, then delete it and confirm
/// it leaves the management list.
///
/// Locale-agnostic throughout: every interaction is anchored on an icon
/// (`add_rounded` FAB, `inventory_2_outlined` mgmt entry, `delete_outline_rounded`
/// trash), a widget type ([GlassTextField], [FilledButton], [BackButton],
/// [Switch], [ProductFormSheet]), or text that is DATA not UI copy - the
/// product name is caller-entered, and the category name is read out of the
/// catalog provider rather than matched against a translated label. No
/// translated string is matched.
///
/// The product-management tile, the product tiles, and the POS catalog are all
/// lazy scrollables and the new product sorts towards the bottom, so finds drag
/// the specific scrollable until the item is built + visible.
///
/// Run:
///   flutter test integration_test/product_crud_flow_test.dart \
///     -d 810AB071-8AFC-41C5-B526-02246E314C4B
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('add, edit (unavailable), and delete a product', (tester) async {
    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 3));

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
    await container.read(settingsProvider.notifier).logout();
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // === STEP 1: Login -> Settings -> product management ===
    for (final digit in ['1', '2', '3', '4']) {
      await tester.tap(find.text(digit).first);
      await tester.pump(const Duration(milliseconds: 200));
    }
    await tester.pumpAndSettle(const Duration(seconds: 2));
    await _tapNavDestination(tester, 4); // Settings
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await _scrollTo(tester, find.byIcon(Icons.inventory_2_outlined),
        find.byType(ListView));
    await tester.tap(find.byIcon(Icons.inventory_2_outlined));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // A category is required to save a product; read the first one's name out
    // of the catalog (DATA, not a translated label) so the chip tap is stable.
    final catName = container.read(categoriesProvider).valueOrNull!.first.name;
    final prodName = 'QA20-${DateTime.now().millisecondsSinceEpoch}';
    print('Managing product: $prodName (category: $catName)');

    // === STEP 2: Add product via the form ===
    print('=== STEP 2: Add product ===');
    await tester.tap(find.byIcon(Icons.add_rounded));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await _fillAndSaveProduct(tester, name: prodName, price: '50000', catName: catName);
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // === STEP 3: It appears on the POS grid ===
    print('=== STEP 3: Assert on POS grid ===');
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await _tapNavDestination(tester, 0); // POS
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await _scrollTo(tester, find.text(prodName), find.byType(GridView));
    expect(find.text(prodName), findsWidgets,
        reason: 'The new product should appear in the POS catalog');
    print('Product visible on POS');

    // === STEP 4: Edit -> mark unavailable -> leaves POS grid ===
    print('=== STEP 4: Edit (unavailable) ===');
    await _tapNavDestination(tester, 4); // Settings
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await _scrollTo(tester, find.byIcon(Icons.inventory_2_outlined),
        find.byType(ListView));
    await tester.tap(find.byIcon(Icons.inventory_2_outlined));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    // The product list is lazy; scroll the tile into view, then tap to open
    // the edit form.
    await _scrollTo(tester, find.text(prodName), find.byType(ListView));
    await tester.tap(find.text(prodName));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(find.byType(ProductFormSheet), findsOneWidget,
        reason: 'Tapping a product tile should open the edit form');
    // Change the price and flip availability off.
    await tester.enterText(find.byType(GlassTextField).at(1), '60000');
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    final availSwitch = find.descendant(
      of: find.byType(ProductFormSheet),
      matching: find.byType(Switch),
    );
    await tester.tap(availSwitch.at(0)); // available -> off
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    await _tapSave(tester);
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await _tapNavDestination(tester, 0); // POS
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(find.text(prodName), findsNothing,
        reason:
            'A product marked unavailable must be hidden from the POS catalog');
    print('Product hidden from POS after marking unavailable');

    // === STEP 5: Delete -> gone from management list ===
    print('=== STEP 5: Delete product ===');
    await _tapNavDestination(tester, 4); // Settings
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await _scrollTo(tester, find.byIcon(Icons.inventory_2_outlined),
        find.byType(ListView));
    await tester.tap(find.byIcon(Icons.inventory_2_outlined));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await _scrollTo(tester, find.text(prodName), find.byType(ListView));
    expect(find.text(prodName), findsWidgets,
        reason: 'Unavailable product should still be listed in management');
    // The trash icon lives on the product's own tile (the nearest GlassCard
    // ancestor of the name text).
    final tile = find
        .ancestor(of: find.text(prodName), matching: find.byType(GlassCard))
        .first;
    await tester.ensureVisible(tile);
    await tester.tap(
      find.descendant(of: tile, matching: find.byIcon(Icons.delete_outline_rounded)),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 500));
    // Confirm dialog -> Delete (the error-tinted FilledButton).
    await tester.tap(find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(FilledButton),
    ));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(find.text(prodName), findsNothing,
        reason: 'Deleted product must leave the management list');
    print('Product deleted from management');

    print('=== PRODUCT CRUD FLOW TEST PASSED ===');
  });
}

/// Drag [scrollable] up until [item] is built + visible. Avoids
/// `scrollUntilVisible`'s multi-Scrollable ambiguity (the POS screen mounts a
/// horizontal chip ListView alongside the catalog GridView).
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

/// Fill the product form (name + price + pick the category by its data name)
/// and tap Save. The form fields are GlassTextFields in fixed order:
/// name(0), price(1), description(2).
Future<void> _fillAndSaveProduct(
  WidgetTester tester, {
  required String name,
  required String price,
  required String catName,
}) async {
  expect(find.byType(ProductFormSheet), findsOneWidget,
      reason: 'Product form sheet should be open');
  await tester.enterText(find.byType(GlassTextField).at(0), name);
  await tester.pumpAndSettle(const Duration(milliseconds: 300));
  await tester.enterText(find.byType(GlassTextField).at(1), price);
  await tester.pumpAndSettle(const Duration(milliseconds: 300));
  // Select the category by its DATA name (read from the catalog provider),
  // scoped to the form so the product-list subtitles behind the modal don't
  // collide.
  await tester.tap(find.descendant(
    of: find.byType(ProductFormSheet),
    matching: find.text(catName),
  ).first);
  await tester.pumpAndSettle(const Duration(milliseconds: 300));
  await _tapSave(tester);
}

/// Scroll the form's Save button into view and tap it.
Future<void> _tapSave(WidgetTester tester) async {
  final save = find.descendant(
    of: find.byType(ProductFormSheet),
    matching: find.byType(FilledButton),
  );
  await tester.ensureVisible(save);
  await tester.tap(save);
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
