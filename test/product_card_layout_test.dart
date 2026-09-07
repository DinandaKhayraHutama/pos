import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nti_pos/core/localization/l10n.dart';
import 'package:nti_pos/core/theme/app_colors.dart';
import 'package:nti_pos/core/theme/app_theme.dart';
import 'package:nti_pos/data/models/product.dart';
import 'package:nti_pos/features/pos/product_card.dart';
import 'package:nti_pos/l10n/gen/app_localizations.dart';

/// The POS grid used to size its tiles with a fixed childAspectRatio, which
/// left only a few pixels of slack: a two-line product name plus a slightly
/// larger text scale overflowed the card and clipped the action button.
///
/// [productCardExtent] now derives the height from the tile width and the text
/// scale, so these tests assert the invariant directly: a card given exactly
/// that height must never overflow.
void main() {
  const shortName = Product(
    id: 'p1',
    name: 'Es Teh',
    categoryId: 'drinks',
    price: 5000,
  );

  // The case that broke: a name long enough to wrap onto two lines.
  const longName = Product(
    id: 'p2',
    name: 'Nasi Goreng Spesial Kampung Extra Pedas',
    categoryId: 'food',
    price: 25000,
    isPopular: true,
  );

  const unavailable = Product(
    id: 'p3',
    name: 'Kentang Goreng',
    categoryId: 'food',
    price: 18000,
    available: false,
  );

  Widget host({
    required Product product,
    required double tileWidth,
    required double textScale,
    required int inCartQty,
    required Locale locale,
  }) {
    return MaterialApp(
      theme: AppTheme.light(BrandPreset.presets.first),
      locale: locale,
      supportedLocales: kSupportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: Scaffold(
          body: Center(
            child: Builder(
              builder: (context) => SizedBox(
                width: tileWidth,
                height: productCardExtent(context, tileWidth),
                child: ProductCard(
                  product: product,
                  inCartQty: inCartQty,
                  onAdd: () {},
                  onDecrement: () {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('card never overflows the height the grid gives it', (
    tester,
  ) async {
    // Narrow phone column through to a wide tablet column.
    const widths = <double>[140, 160, 174, 190, 200];
    // main.dart clamps the text scaler to this range.
    const scales = <double>[0.85, 1.0, 1.15];
    const products = <Product>[shortName, longName, unavailable];
    const locales = <Locale>[Locale('en'), Locale('id')];

    for (final width in widths) {
      for (final scale in scales) {
        for (final product in products) {
          for (final locale in locales) {
            for (final qty in <int>[0, 3]) {
              await tester.pumpWidget(
                host(
                  product: product,
                  tileWidth: width,
                  textScale: scale,
                  inCartQty: qty,
                  locale: locale,
                ),
              );
              expect(
                tester.takeException(),
                isNull,
                reason:
                    'overflow at width $width, scale $scale, qty $qty, '
                    'locale ${locale.languageCode}, product ${product.id}',
              );
            }
          }
        }
      }
    }
  });

  testWidgets('extent grows with the text scale and the tile width', (
    tester,
  ) async {
    late double small;
    late double scaled;
    late double wide;

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(),
          child: Builder(
            builder: (context) {
              small = productCardExtent(context, 174);
              wide = productCardExtent(context, 200);
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.15)),
          child: Builder(
            builder: (context) {
              scaled = productCardExtent(context, 174);
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    expect(scaled, greaterThan(small));
    expect(wide, greaterThan(small));
  });

  testWidgets('action row switches between add button and stepper', (
    tester,
  ) async {
    // Locale-agnostic assertions: icons only, never translated text.
    await tester.pumpWidget(
      host(
        product: shortName,
        tileWidth: 174,
        textScale: 1.0,
        inCartQty: 0,
        locale: const Locale('id'),
      ),
    );
    expect(find.byIcon(Icons.add_rounded), findsOneWidget);
    expect(find.byIcon(Icons.remove_rounded), findsNothing);

    await tester.pumpWidget(
      host(
        product: shortName,
        tileWidth: 174,
        textScale: 1.0,
        inCartQty: 3,
        locale: const Locale('id'),
      ),
    );
    expect(find.byIcon(Icons.add_rounded), findsOneWidget);
    expect(find.byIcon(Icons.remove_rounded), findsOneWidget);

    // The last unit reads as "remove from cart" rather than "minus one".
    await tester.pumpWidget(
      host(
        product: shortName,
        tileWidth: 174,
        textScale: 1.0,
        inCartQty: 1,
        locale: const Locale('id'),
      ),
    );
    expect(find.byIcon(Icons.delete_outline_rounded), findsOneWidget);
  });

  testWidgets('stepper decrements instead of adding', (tester) async {
    var added = 0;
    var decremented = 0;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(BrandPreset.presets.first),
        locale: const Locale('id'),
        supportedLocales: kSupportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Scaffold(
          body: Center(
            child: Builder(
              builder: (context) => SizedBox(
                width: 174,
                height: productCardExtent(context, 174),
                child: ProductCard(
                  product: shortName,
                  inCartQty: 2,
                  onAdd: () => added++,
                  onDecrement: () => decremented++,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    // The card body is also tappable; the stepper must win over it.
    await tester.tap(find.byIcon(Icons.remove_rounded));
    await tester.pump();
    expect(decremented, 1);
    expect(added, 0, reason: 'minus must not bubble up to the card onTap');

    await tester.tap(find.byIcon(Icons.add_rounded));
    await tester.pump();
    expect(added, 1);
    expect(decremented, 1);
  });
}
