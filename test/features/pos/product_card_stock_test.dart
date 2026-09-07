import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nti_pos/core/localization/l10n.dart';
import 'package:nti_pos/core/theme/app_colors.dart';
import 'package:nti_pos/core/theme/app_theme.dart';
import 'package:nti_pos/data/models/product.dart';
import 'package:nti_pos/features/pos/product_card.dart';
import 'package:nti_pos/l10n/gen/app_localizations.dart';

/// Guards the three stock states a product tile has to tell apart on the sell
/// screen: untracked (say nothing), low (warn), and out (block the sale).
///
/// Worth pinning down because the states are easy to conflate in code — null
/// and 0 are different facts — and because getting it wrong either hides a
/// warning a cashier needs or refuses a sale that should go through.
void main() {
  Product product({int? stock, bool available = true}) => Product(
    id: 'p1',
    name: 'Risol Mayo',
    categoryId: 'cat_snacks',
    price: 12000,
    stock: stock,
    available: available,
  );

  Future<void> pumpCard(WidgetTester tester, Product p) async {
    var added = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(BrandPreset.presets.first),
        locale: const Locale('en'),
        supportedLocales: kSupportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 190,
              height: 260,
              child: ProductCard(
                product: p,
                inCartQty: 0,
                onAdd: () => added++,
                onDecrement: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('an untracked product shows no stock badge and no overlay', (
    tester,
  ) async {
    await pumpCard(tester, product(stock: null));

    expect(find.textContaining('left'), findsNothing);
    expect(find.text('Out of stock'), findsNothing);
  });

  testWidgets('a healthy stock level shows no badge', (tester) async {
    await pumpCard(tester, product(stock: 40));

    expect(find.textContaining('left'), findsNothing);
    expect(find.text('Out of stock'), findsNothing);
  });

  testWidgets('a low stock level shows the remaining-count badge', (
    tester,
  ) async {
    await pumpCard(tester, product(stock: 4));

    expect(find.text('4 left'), findsOneWidget);
    expect(find.text('Out of stock'), findsNothing);
  });

  testWidgets('zero stock shows the out-of-stock overlay, not a badge', (
    tester,
  ) async {
    await pumpCard(tester, product(stock: 0));

    expect(find.text('Out of stock'), findsOneWidget);
    expect(find.textContaining('left'), findsNothing);
  });

  testWidgets('an unavailable product reads unavailable, not out of stock', (
    tester,
  ) async {
    await pumpCard(tester, product(stock: 40, available: false));

    expect(find.text('Unavailable'), findsOneWidget);
    expect(find.text('Out of stock'), findsNothing);
  });
}
