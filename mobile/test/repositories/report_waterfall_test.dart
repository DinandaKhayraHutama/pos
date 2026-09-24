import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:nti_pos/data/database/app_database.dart';
import 'package:nti_pos/data/models/enums.dart';
import 'package:nti_pos/data/repositories/order_repository.dart';

import '../helpers/db_helper.dart';

/// The F1 waterfall, on the SAME four receipts as the Go fixture and against
/// the SAME hand-worked numbers.
///
/// This is the point of the shared fixture: demo mode computes locally and a
/// connected till reads the server's rollups, and the two must agree about
/// what "net sales" means. A test that recomputed the answer with the app's
/// own arithmetic would prove only that the app is consistent with itself, so
/// the figures below are written out — they were worked from the receipts by
/// hand, and they are the specification for both implementations.
///
/// The day, matching `backend-go/internal/domain/reporting/fixture_test.go`:
///
///   paid      55000 − 5500 + 4950 PB1            = 54450
///   paid      20000 − 0    + 2000 PB1 + 1000 SC  = 23000
///   cancelled 30000                                (never a sale)
///   refunded  15000 + 0                            , 12000 handed back
const _expectedGrossSales = 90000;
const _expectedDiscounts = 5500;
const _expectedSalesReturns = 15000;
const _expectedNetSales = 69500;
const _expectedTax = 6950;
const _expectedServiceCharge = 1000;
const _expectedRevenue = 77450;
const _expectedOrders = 2;
const _expectedAverageSale = 34750;
const _expectedItemsSold = 5;
const _expectedCostOfGoods = 15000;
const _expectedGrossProfit = 54500;
const _expectedCancelled = 30000;
const _expectedRefundedMoney = 12000;

/// A line. The category is NOT set here: `create` resolves it from the
/// product, and this store holds no catalogue, so every line lands in the
/// uncategorised bucket. That is enough for what this file checks — that the
/// category column still sums to net sales — and it keeps the fixture about
/// money rather than about seeding a menu.
OrderItemDraft _line(
  String name, {
  required int price,
  int qty = 1,
  int? cost,
}) => OrderItemDraft(
  productId: 'p_$name',
  productName: name,
  unitPrice: price,
  quantity: qty,
  unitCost: cost,
);

void main() {
  setUpAll(initFfi);

  group('the local report computes the F1 waterfall', () {
    late Database db;
    late DateTime day;

    setUp(() async {
      db = await openInMemoryAppDb(seed: false);
      await AppDatabase.instance.useTestDb(db);
      final now = DateTime.now();
      day = DateTime(now.year, now.month, now.day);

      final repo = OrderRepository.instance;

      // 09:15 — 2 × Kopi Susu at 15000 (cost 5000) + Nasi Goreng at 25000,
      // less a 5500 promo, plus 4950 PB1.
      await repo.create(
        type: OrderType.dineIn,
        items: [
          _line('Kopi Susu', price: 15000, qty: 2, cost: 5000),
          _line('Nasi Goreng', price: 25000),
        ],
        subtotal: 55000,
        discount: 5500,
        tax: 4950,
        total: 54450,
        amountPaid: 54450,
        paymentMethod: PaymentMethod.cash,
        cashierId: 'siti',
        cashierName: 'Siti',
      );

      // 13:40 — Kopi Susu + a bottle of water with no category and no cost,
      // plus 2000 PB1 and 1000 service charge.
      await repo.create(
        type: OrderType.takeaway,
        items: [
          _line('Kopi Susu', price: 15000, cost: 5000),
          _line('Air Mineral', price: 5000),
        ],
        subtotal: 20000,
        discount: 0,
        tax: 2000,
        serviceChargeAmount: 1000,
        total: 23000,
        amountPaid: 23000,
        paymentMethod: PaymentMethod.qris,
        cashierId: 'budi',
        cashierName: 'Budi',
      );

      // 11:00 — cancelled: never a sale, and never subtracted from one.
      final cancelled = await repo.create(
        type: OrderType.dineIn,
        items: [_line('Kopi Susu', price: 15000, qty: 2, cost: 5000)],
        subtotal: 30000,
        discount: 0,
        tax: 0,
        total: 30000,
        amountPaid: 30000,
        paymentMethod: PaymentMethod.cash,
        cashierId: 'siti',
        cashierName: 'Siti',
      );
      await repo.voidOrder(
        orderId: cancelled.id,
        authorizedBy: 'Manajer A',
        authorizedById: 'manager',
        reason: 'Salah input',
      );

      // 15:00 — refunded, with LESS money handed back than the sale: a partial
      // refund the till recorded honestly. The return and the money are two
      // different figures and both are reported.
      final refunded = await repo.create(
        type: OrderType.dineIn,
        items: [_line('Nasi Goreng', price: 15000)],
        subtotal: 15000,
        discount: 0,
        tax: 0,
        total: 15000,
        amountPaid: 15000,
        paymentMethod: PaymentMethod.cash,
        cashierId: 'budi',
        cashierName: 'Budi',
      );
      await repo.refundOrder(
        orderId: refunded.id,
        authorizedBy: 'Owner',
        authorizedById: 'owner',
        reason: 'Komplain',
        amount: 12000,
      );
    });

    tearDown(() async {
      if (db.isOpen) await db.close();
    });

    test('every figure matches the numbers worked out by hand', () async {
      final report = await OrderRepository.instance.report(from: day, to: day);

      expect(report.grossSales, _expectedGrossSales);
      expect(report.allDiscount, _expectedDiscounts);
      expect(report.salesReturns, _expectedSalesReturns);
      expect(report.netSales, _expectedNetSales);
      expect(report.tax, _expectedTax);
      expect(report.serviceCharge, _expectedServiceCharge);
      expect(report.revenue, _expectedRevenue);
      expect(report.orderCount, _expectedOrders);
      expect(report.averageOrder, _expectedAverageSale);
      expect(report.itemsSold, _expectedItemsSold);
      expect(report.costOfGoods, _expectedCostOfGoods);
      expect(report.grossProfit, _expectedGrossProfit);
      expect(report.cancelledValue, _expectedCancelled);
      expect(report.refundedValue, _expectedRefundedMoney);
    });

    test('the waterfall closes and agrees with the revenue transactions', () async {
      final report = await OrderRepository.instance.report(from: day, to: day);

      expect(
        report.grossSales - report.allDiscount - report.salesReturns,
        report.netSales,
        reason: 'gross less discounts less returns IS net sales',
      );
      expect(
        report.subtotal - report.discount,
        report.netSales,
        reason: 'and it agrees with the transactions revenue already counts',
      );
    });

    test('tax and service charge raise receipts and never profit', () async {
      final report = await OrderRepository.instance.report(from: day, to: day);

      expect(report.netSales + report.tax + report.serviceCharge, report.revenue);
      expect(report.grossProfit, report.netSales - report.costOfGoods);
      // The correction F1 exists for: the old definition put 7950 of PB1 and
      // service charge into the basis of profit.
      expect(
        report.grossProfit,
        lessThan(report.revenue - report.costOfGoods),
        reason: 'profit is not takings minus cost',
      );
    });

    test('a refund is a return, and the money handed back is a separate figure', () async {
      final report = await OrderRepository.instance.report(from: day, to: day);

      expect(report.salesReturns, 15000, reason: 'the sale that was returned');
      expect(report.refundedValue, 12000, reason: 'the money actually handed back');
      expect(report.refundedCount, 1);
      // The cancelled transaction is shown separately and is NOT taken out of
      // the waterfall a second time: it was never in gross sales to begin with.
      expect(report.cancelledCount, 1);
      expect(report.cancelledValue, 30000);
      expect(
        report.grossSales,
        _expectedGrossSales,
        reason: 'a cancellation never entered gross sales',
      );
    });

    test('the category split adds up to net sales', () async {
      final report = await OrderRepository.instance.report(from: day, to: day);

      final categoryNet = report.byCategory.fold<int>(0, (a, c) => a + c.netSales);
      expect(categoryNet, report.netSales);
    });

    test('a margin over no sales is undefined, not zero percent', () async {
      final empty = await OrderRepository.instance.report(
        from: day.subtract(const Duration(days: 30)),
        to: day.subtract(const Duration(days: 29)),
      );

      expect(empty.netSales, 0);
      final (margin, defined) = empty.grossMargin;
      expect(defined, isFalse);
      expect(margin, 0);
    });
  });
}
