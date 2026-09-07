import 'package:flutter_test/flutter_test.dart';
import 'package:nti_pos/data/database/app_database.dart';
import 'package:nti_pos/data/models/enums.dart';
import 'package:nti_pos/data/models/product.dart';
import 'package:nti_pos/data/models/stock_movement.dart';
import 'package:nti_pos/data/repositories/order_repository.dart';
import 'package:nti_pos/data/repositories/product_repository.dart';
import 'package:nti_pos/data/repositories/stock_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/db_helper.dart';

/// The tests run against one branch. Multi-outlet scoping has its own
/// coverage; these are about the catalogue and the ledger, and threading a
/// second outlet through every case would only obscure that.
const _outlet = 'outlet-1';

/// The stock ledger's contract: the count and its explanation move together.
///
/// A balance nobody can explain is the failure this table exists to prevent,
/// so most of these assert the *pair* — the new count AND the row that
/// accounts for it — rather than either alone.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Database db;

  setUp(() async {
    db = await openInMemoryAppDb();
    await AppDatabase.instance.useTestDb(db);
    await db.insert('categories', {
      'id': 'cat',
      'name': 'Cat',
      'emoji': '🍽️',
      'sort_order': 0,
      'is_popular': 0,
    });
  });

  tearDown(() async {
    if (db.isOpen) await db.close();
  });

  Future<void> addProduct({
    required String id,
    int? stock,
    int price = 10000,
    int? cost,
  }) async {
    await ProductRepository.instance.upsert(
      Product(
        id: id,
        name: id,
        categoryId: 'cat',
        price: price,
        cost: cost,
        stock: stock,
      ),
    );
  }

  /// The on-hand count for the branch under test.
  ///
  /// Reads `outlet_stock`, not `products.stock` — since v14 the product row
  /// only carries the catalogue's opening figure, and asserting on it would
  /// pass while every real shelf stayed wrong.
  Future<int?> stockOf(String id) async =>
      StockRepository.countAt(db, outletId: _outlet, productId: id);

  group('adjust', () {
    test('booking stock in raises the count and writes one movement', () async {
      await addProduct(id: 'p1', stock: 4);

      final balance = await StockRepository.instance.adjust(outletId: _outlet, 
        productId: 'p1',
        delta: 12,
        reason: StockReason.received,
        employeeId: 'emp_manager',
        employeeName: 'Budi',
        note: 'supplier',
      );

      expect(balance, 16);
      expect(await stockOf('p1'), 16);

      final history = await StockRepository.instance.history(outletId: _outlet, productId: 'p1');
      expect(history, hasLength(1));
      expect(history.single.delta, 12);
      expect(history.single.balanceAfter, 16);
      expect(history.single.reason, StockReason.received);
      expect(history.single.employeeName, 'Budi');
      expect(history.single.note, 'supplier');
    });

    test('booking stock out lowers the count', () async {
      await addProduct(id: 'p1', stock: 10);
      final balance = await StockRepository.instance.adjust(outletId: _outlet, 
        productId: 'p1',
        delta: -3,
        reason: StockReason.waste,
        employeeId: 'e',
        employeeName: 'E',
      );
      expect(balance, 7);
      expect(await stockOf('p1'), 7);
    });

    test('an over-large removal floors at zero and logs what really happened',
        () async {
      await addProduct(id: 'p1', stock: 2);

      final balance = await StockRepository.instance.adjust(outletId: _outlet, 
        productId: 'p1',
        delta: -10,
        reason: StockReason.correction,
        employeeId: 'e',
        employeeName: 'E',
      );

      expect(balance, 0);
      // The ledger records the clamped -2, not the requested -10. Recording
      // the request would make the running balance stop reconciling.
      final history = await StockRepository.instance.history(outletId: _outlet, productId: 'p1');
      expect(history.single.delta, -2);
      expect(history.single.balanceAfter, 0);
    });

    test('an untracked product is refused rather than silently tracked',
        () async {
      await addProduct(id: 'p1'); // stock null
      expect(
        () => StockRepository.instance.adjust(outletId: _outlet, 
          productId: 'p1',
          delta: 5,
          reason: StockReason.received,
          employeeId: 'e',
          employeeName: 'E',
        ),
        throwsStateError,
      );
      expect(await stockOf('p1'), isNull);
    });

    test('an unknown product throws', () async {
      expect(
        () => StockRepository.instance.adjust(outletId: _outlet, 
          productId: 'nope',
          delta: 1,
          reason: StockReason.received,
          employeeId: 'e',
          employeeName: 'E',
        ),
        throwsStateError,
      );
    });
  });

  group('ledger written by the sale path', () {
    Future<void> sell(String productId, int qty) async {
      await OrderRepository.instance.create(
      outletId: _outlet,
        type: OrderType.takeaway,
        items: [
          OrderItemDraft(
            productId: productId,
            productName: productId,
            unitPrice: 10000,
            quantity: qty,
          ),
        ],
        subtotal: 10000 * qty,
        discount: 0,
        tax: 0,
        total: 10000 * qty,
        amountPaid: 10000 * qty,
        paymentMethod: PaymentMethod.cash,
        cashierId: 'emp_kasir_1',
        cashierName: 'Siti',
      );
    }

    test('a sale draws stock down and records why', () async {
      await addProduct(id: 'p1', stock: 10);
      await sell('p1', 3);

      expect(await stockOf('p1'), 7);
      final history = await StockRepository.instance.history(outletId: _outlet, productId: 'p1');
      expect(history.single.reason, StockReason.sale);
      expect(history.single.delta, -3);
      expect(history.single.balanceAfter, 7);
      expect(history.single.employeeName, 'Siti');
    });

    test('an untracked product is sold without touching the ledger', () async {
      await addProduct(id: 'p1'); // cooked to order, not counted
      await sell('p1', 2);

      expect(await stockOf('p1'), isNull);
      expect(await StockRepository.instance.history(outletId: _outlet, productId: 'p1'), isEmpty);
    });

    test('voiding puts the goods back and says who approved it', () async {
      await addProduct(id: 'p1', stock: 10);
      await sell('p1', 4);
      final order = (await OrderRepository.instance.recent()).single;

      await OrderRepository.instance.voidOrder(
        orderId: order.id,
        authorizedBy: 'Siwi Wiyono Raharjo',
        authorizedById: 'emp_manager',
        reason: 'wrong order',
      );

      expect(await stockOf('p1'), 10);
      final history = await StockRepository.instance.history(outletId: _outlet, productId: 'p1');
      expect(history.first.reason, StockReason.voidReturn);
      expect(history.first.delta, 4);
      expect(history.first.employeeName, 'Siwi Wiyono Raharjo');
    });

    test('voiding twice credits the stock only once', () async {
      // The double-tap. A second credit is invisible until someone counts the
      // shelf, which is weeks later and by then unattributable.
      await addProduct(id: 'p1', stock: 10);
      await sell('p1', 4);
      final order = (await OrderRepository.instance.recent()).single;

      for (var i = 0; i < 2; i++) {
        await OrderRepository.instance.voidOrder(
          orderId: order.id,
          authorizedBy: 'Budi',
          reason: 'wrong order',
        );
      }

      expect(await stockOf('p1'), 10);
      final returns = (await StockRepository.instance.history(outletId: _outlet, productId: 'p1'))
          .where((m) => m.reason == StockReason.voidReturn);
      expect(returns, hasLength(1));
    });

    test('refunding after a void is refused, keeping the first record',
        () async {
      await addProduct(id: 'p1', stock: 10);
      await sell('p1', 2);
      final order = (await OrderRepository.instance.recent()).single;

      await OrderRepository.instance.voidOrder(
        orderId: order.id,
        authorizedBy: 'Budi',
        reason: 'wrong order',
      );
      await OrderRepository.instance.refundOrder(
        orderId: order.id,
        authorizedBy: 'Dewi',
        reason: 'changed mind',
      );

      final after = await OrderRepository.instance.byId(order.id);
      expect(after!.status, OrderStatus.cancelled);
      expect(after.authorizedBy, 'Budi');
      expect(await stockOf('p1'), 10);
    });

    test('a refund records the amount handed back', () async {
      await addProduct(id: 'p1', stock: 10);
      await sell('p1', 2);
      final order = (await OrderRepository.instance.recent()).single;

      await OrderRepository.instance.refundOrder(
        orderId: order.id,
        authorizedBy: 'Dewi',
        reason: 'cold food',
      );

      final after = await OrderRepository.instance.byId(order.id);
      expect(after!.status, OrderStatus.refunded);
      expect(after.refundedAmount, 20000);
      expect(after.voidReason, 'cold food');
    });
  });

  group('revenue excludes settled orders', () {
    test('a refunded order stops counting as revenue', () async {
      await addProduct(id: 'p1', stock: 100);
      await OrderRepository.instance.create(
      outletId: _outlet,
        type: OrderType.takeaway,
        items: const [
          OrderItemDraft(
            productId: 'p1',
            productName: 'p1',
            unitPrice: 10000,
            quantity: 1,
          ),
        ],
        subtotal: 10000,
        discount: 0,
        tax: 0,
        total: 10000,
        amountPaid: 10000,
        paymentMethod: PaymentMethod.cash,
        cashierId: 'c',
        cashierName: 'C',
      );

      final before = await OrderRepository.instance.summaryForDay(
        DateTime.now(),
      );
      expect(before.revenue, 10000);

      final order = (await OrderRepository.instance.recent()).single;
      await OrderRepository.instance.refundOrder(
        orderId: order.id,
        authorizedBy: 'Dewi',
        reason: 'x',
      );

      final after = await OrderRepository.instance.summaryForDay(
        DateTime.now(),
      );
      expect(after.revenue, 0);
      expect(after.count, 0);
    });
  });

  group('setStatus guard', () {
    test('refuses a status that returns stock', () async {
      await addProduct(id: 'p1', stock: 5);
      await OrderRepository.instance.create(
      outletId: _outlet,
        type: OrderType.takeaway,
        items: const [
          OrderItemDraft(
            productId: 'p1',
            productName: 'p1',
            unitPrice: 1000,
            quantity: 1,
          ),
        ],
        subtotal: 1000,
        discount: 0,
        tax: 0,
        total: 1000,
        amountPaid: 1000,
        paymentMethod: PaymentMethod.cash,
        cashierId: 'c',
        cashierName: 'C',
      );
      final order = (await OrderRepository.instance.recent()).single;

      // An anonymous cancel has to be impossible, not merely discouraged.
      expect(
        () => OrderRepository.instance.setStatus(
          order.id,
          OrderStatus.cancelled,
        ),
        throwsArgumentError,
      );
      expect(
        () => OrderRepository.instance.setStatus(
          order.id,
          OrderStatus.refunded,
        ),
        throwsArgumentError,
      );
    });
  });
}
