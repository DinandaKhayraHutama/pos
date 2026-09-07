import 'package:flutter_test/flutter_test.dart';

import 'package:nti_pos/data/models/category_sales.dart';
import 'package:nti_pos/data/repositories/order_repository.dart';

/// Builds one raw row exactly as `OrderRepository.report`'s category query
/// returns it — this is deliberately pure-Dart, no database: `aggregateCategorySales`
/// takes these maps directly, so its arithmetic can be pinned down precisely
/// and fast, without a SQLite round trip.
Map<String, Object?> _row({
  required String orderId,
  required int orderDiscount,
  required int orderSubtotal,
  required int orderCreatedAt,
  String? categoryId,
  String? snapshotName,
  String? liveName,
  required int lineTotal,
  required int qty,
}) => {
  'order_id': orderId,
  'order_discount': orderDiscount,
  'order_subtotal': orderSubtotal,
  'order_created_at': orderCreatedAt,
  'category_id': categoryId,
  'snapshot_name': snapshotName,
  'live_name': liveName,
  'line_total': lineTotal,
  'qty': qty,
};

void main() {
  final repo = OrderRepository.instance;

  group('aggregateCategorySales — money', () {
    test('a single category in a single order carries gross/net/items through',
        () {
      final result = repo.aggregateCategorySales([
        _row(
          orderId: 'o1',
          orderDiscount: 0,
          orderSubtotal: 20000,
          orderCreatedAt: 1,
          categoryId: 'cat_drinks',
          liveName: 'Minuman',
          lineTotal: 20000,
          qty: 2,
        ),
      ]);

      expect(result, hasLength(1));
      expect(result.single.categoryId, 'cat_drinks');
      expect(result.single.categoryName, 'Minuman');
      expect(result.single.itemsSold, 2);
      expect(result.single.grossSales, 20000);
      expect(result.single.netSales, 20000);
      expect(result.single.contributionPercent, 100);
    });

    test('no discount on the order means gross == net', () {
      final result = repo.aggregateCategorySales([
        _row(
          orderId: 'o1',
          orderDiscount: 0,
          orderSubtotal: 10000,
          orderCreatedAt: 1,
          categoryId: 'cat_food',
          liveName: 'Makanan',
          lineTotal: 10000,
          qty: 1,
        ),
      ]);
      expect(result.single.grossSales, result.single.netSales);
    });

    test('a discount is allocated proportionally to each category\'s share '
        'of that order\'s subtotal', () {
      // order: 30000 subtotal (10000 food + 20000 drinks), 3000 discount.
      // Exact division here (no remainder) so both branches read as plain
      // proportional shares: food gets 1000, drinks gets 2000.
      final result = repo.aggregateCategorySales([
        _row(
          orderId: 'o1',
          orderDiscount: 3000,
          orderSubtotal: 30000,
          orderCreatedAt: 1,
          categoryId: 'cat_food',
          liveName: 'Makanan',
          lineTotal: 10000,
          qty: 1,
        ),
        _row(
          orderId: 'o1',
          orderDiscount: 3000,
          orderSubtotal: 30000,
          orderCreatedAt: 1,
          categoryId: 'cat_drinks',
          liveName: 'Minuman',
          lineTotal: 20000,
          qty: 1,
        ),
      ]);

      final food = result.firstWhere((c) => c.categoryId == 'cat_food');
      final drinks = result.firstWhere((c) => c.categoryId == 'cat_drinks');
      expect(food.netSales, 10000 - 1000);
      expect(drinks.netSales, 20000 - 2000);
    });

    test(
      'largest-remainder split makes the per-order discount reconcile '
      'EXACTLY, even when proportional division does not divide evenly',
      () {
        // order: subtotal 30000 (10000 + 10000 + 10000 across 3 categories),
        // discount 100. Each category's raw share is 100/3 = 33.33..., which
        // floors to 33 -> 3*33 = 99, one rupiah short of 100. That last
        // rupiah must land on exactly one category, not vanish.
        final rows = [
          for (final id in ['cat_a', 'cat_b', 'cat_c'])
            _row(
              orderId: 'o1',
              orderDiscount: 100,
              orderSubtotal: 30000,
              orderCreatedAt: 1,
              categoryId: id,
              liveName: id,
              lineTotal: 10000,
              qty: 1,
            ),
        ];
        final result = repo.aggregateCategorySales(rows);

        final totalNet = result.fold<int>(0, (a, c) => a + c.netSales);
        final totalGross = result.fold<int>(0, (a, c) => a + c.grossSales);
        expect(totalGross, 30000);
        expect(totalNet, 30000 - 100,
            reason: 'the whole discount must be accounted for, not just the '
                'floor of each category\'s proportional share');
      },
    );

    test('two orders contributing to the SAME category accumulate, and each '
        'order\'s own discount reconciles independently', () {
      final result = repo.aggregateCategorySales([
        _row(
          orderId: 'o1',
          orderDiscount: 1000,
          orderSubtotal: 10000,
          orderCreatedAt: 1,
          categoryId: 'cat_drinks',
          liveName: 'Minuman',
          lineTotal: 10000,
          qty: 1,
        ),
        _row(
          orderId: 'o2',
          orderDiscount: 0,
          orderSubtotal: 15000,
          orderCreatedAt: 2,
          categoryId: 'cat_drinks',
          liveName: 'Minuman',
          lineTotal: 15000,
          qty: 1,
        ),
      ]);

      expect(result, hasLength(1));
      expect(result.single.grossSales, 25000);
      expect(result.single.netSales, 25000 - 1000);
      expect(result.single.itemsSold, 2);
    });

    test('subtotal == 0 never divides by zero and contributes a zero share',
        () {
      expect(
        () => repo.aggregateCategorySales([
          _row(
            orderId: 'o1',
            orderDiscount: 0,
            orderSubtotal: 0,
            orderCreatedAt: 1,
            categoryId: 'cat_x',
            liveName: 'X',
            lineTotal: 0,
            qty: 0,
          ),
        ]),
        returnsNormally,
      );
    });

    test('contributionPercent is 0 for every row when total net is 0', () {
      final result = repo.aggregateCategorySales([
        _row(
          orderId: 'o1',
          orderDiscount: 10000,
          orderSubtotal: 10000,
          orderCreatedAt: 1,
          categoryId: 'cat_x',
          liveName: 'X',
          lineTotal: 10000,
          qty: 1,
        ),
      ]);
      expect(result.single.netSales, 0);
      expect(result.single.contributionPercent, 0);
    });

    test('results are sorted by netSales descending', () {
      final result = repo.aggregateCategorySales([
        _row(
          orderId: 'o1',
          orderDiscount: 0,
          orderSubtotal: 30000,
          orderCreatedAt: 1,
          categoryId: 'cat_small',
          liveName: 'Small',
          lineTotal: 5000,
          qty: 1,
        ),
        _row(
          orderId: 'o1',
          orderDiscount: 0,
          orderSubtotal: 30000,
          orderCreatedAt: 1,
          categoryId: 'cat_big',
          liveName: 'Big',
          lineTotal: 25000,
          qty: 1,
        ),
      ]);
      expect(result.map((c) => c.categoryId), ['cat_big', 'cat_small']);
    });
  });

  group('aggregateCategorySales — grouping key and display name', () {
    test('grouped by category_id, so a rename mid-range merges into ONE row '
        'showing the CURRENT (live) name', () {
      final result = repo.aggregateCategorySales([
        _row(
          orderId: 'o1',
          orderDiscount: 0,
          orderSubtotal: 10000,
          orderCreatedAt: 1,
          categoryId: 'cat_drinks',
          snapshotName: 'Minuman', // named this at the time
          liveName: 'Beverages', // renamed since
          lineTotal: 10000,
          qty: 1,
        ),
        _row(
          orderId: 'o2',
          orderDiscount: 0,
          orderSubtotal: 10000,
          orderCreatedAt: 2,
          categoryId: 'cat_drinks',
          snapshotName: 'Beverages',
          liveName: 'Beverages',
          lineTotal: 10000,
          qty: 1,
        ),
      ]);

      expect(result, hasLength(1),
          reason: 'one category id must be one report row, regardless of '
              'how many names it has been called over time');
      expect(result.single.categoryName, 'Beverages');
      expect(result.single.grossSales, 20000);
    });

    test('a deleted category (no live row) falls back to the MOST RECENT '
        'snapshot name, not a generic placeholder', () {
      final result = repo.aggregateCategorySales([
        _row(
          orderId: 'o1',
          orderDiscount: 0,
          orderSubtotal: 10000,
          orderCreatedAt: 1,
          categoryId: 'cat_gone',
          snapshotName: 'Old Name',
          liveName: null,
          lineTotal: 10000,
          qty: 1,
        ),
        _row(
          orderId: 'o2',
          orderDiscount: 0,
          orderSubtotal: 10000,
          orderCreatedAt: 5,
          categoryId: 'cat_gone',
          snapshotName: 'Newer Name',
          liveName: null,
          lineTotal: 10000,
          qty: 1,
        ),
      ]);

      expect(result.single.categoryName, 'Newer Name');
    });

    test('two different category ids that happen to share a name stay two '
        'separate rows (grouping is by id, never by name)', () {
      final result = repo.aggregateCategorySales([
        _row(
          orderId: 'o1',
          orderDiscount: 0,
          orderSubtotal: 10000,
          orderCreatedAt: 1,
          categoryId: 'cat_old',
          liveName: null,
          snapshotName: 'Minuman',
          lineTotal: 10000,
          qty: 1,
        ),
        _row(
          orderId: 'o2',
          orderDiscount: 0,
          orderSubtotal: 10000,
          orderCreatedAt: 2,
          categoryId: 'cat_new',
          liveName: 'Minuman',
          lineTotal: 10000,
          qty: 1,
        ),
      ]);
      expect(result, hasLength(2));
    });

    test('a line with no category at all (product deleted before any '
        'snapshot could be taken) lands in the Uncategorized sentinel bucket',
        () {
      final result = repo.aggregateCategorySales([
        _row(
          orderId: 'o1',
          orderDiscount: 0,
          orderSubtotal: 10000,
          orderCreatedAt: 1,
          categoryId: null,
          snapshotName: null,
          liveName: null,
          lineTotal: 10000,
          qty: 1,
        ),
      ]);

      expect(result.single.categoryId, CategorySales.uncategorizedId);
      expect(result.single.categoryName, isEmpty,
          reason: 'the repository leaves this for the UI to localise, same '
              'as byOrderType/byPaymentMethod keep wire keys untranslated');
    });

    test('a real category and the uncategorized bucket both appear, kept '
        'separate', () {
      final result = repo.aggregateCategorySales([
        _row(
          orderId: 'o1',
          orderDiscount: 0,
          orderSubtotal: 20000,
          orderCreatedAt: 1,
          categoryId: 'cat_food',
          liveName: 'Makanan',
          lineTotal: 10000,
          qty: 1,
        ),
        _row(
          orderId: 'o1',
          orderDiscount: 0,
          orderSubtotal: 20000,
          orderCreatedAt: 1,
          categoryId: null,
          lineTotal: 10000,
          qty: 1,
        ),
      ]);
      expect(result, hasLength(2));
      expect(
        result.map((c) => c.categoryId),
        containsAll(<String>['cat_food', CategorySales.uncategorizedId]),
      );
    });
  });

  test('an empty input yields an empty list, not an error', () {
    expect(OrderRepository.instance.aggregateCategorySales(const []), isEmpty);
  });
}
