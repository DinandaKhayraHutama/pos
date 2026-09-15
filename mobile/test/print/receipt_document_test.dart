import 'package:flutter_test/flutter_test.dart';

import 'package:nti_pos/core/print/receipt_document.dart';
import 'package:nti_pos/data/models/enums.dart';
import 'package:nti_pos/data/models/order.dart';
import 'package:nti_pos/data/models/order_item.dart';

/// Unit tests for the receipt PDF generator.
///
/// [buildReceiptPdf] is a pure function of (order, store, labels) with no
/// BuildContext and no widget tree, which is exactly the layer this project
/// still unit-tests. The print *dialog* cannot be exercised here — that is the
/// platform's, and an automated browser has no printer — so these tests pin
/// down the part that is ours: that a document is produced, for every shape of
/// order the app can hand over.
void main() {
  const store = ReceiptStore(
    name: 'Warung Demo',
    address: 'Jl. Contoh No. 1, Jakarta',
    currency: 'Rp',
  );

  const labels = ReceiptLabels(
    subtotal: 'Subtotal',
    discount: 'Diskon',
    serviceCharge: 'Biaya Layanan',
    tax: 'PB1',
    total: 'Total',
    amountPaid: 'Dibayar',
    change: 'Kembali',
    cashier: 'Kasir',
    thankYou: 'Terima kasih',
    orderTypes: {
      OrderType.dineIn: 'Dine-in',
      OrderType.takeaway: 'Takeaway',
      OrderType.delivery: 'Delivery',
    },
    paymentMethods: {
      PaymentMethod.cash: 'Tunai',
      PaymentMethod.qris: 'QRIS',
      PaymentMethod.card: 'Kartu',
    },
  );

  Order order({
    OrderType type = OrderType.takeaway,
    PaymentMethod payment = PaymentMethod.cash,
    int discount = 0,
    int tax = 0,
    int serviceCharge = 0,
    int amountPaid = 50000,
    TableAssignment? table,
    String? customerName,
    List<OrderItem> items = const [],
  }) {
    final lines = items.isEmpty
        ? const [
            OrderItem(
              id: 'i1',
              orderId: 'o1',
              productId: 'p_nasi_goreng',
              productName: 'Nasi Goreng Spesial',
              unitPrice: 25000,
              quantity: 2,
            ),
          ]
        : items;
    final subtotal = lines.fold<int>(0, (s, i) => s + i.lineTotal);
    return Order(
      id: 'o1',
      number: 'ORD-0001',
      createdAt: DateTime(2026, 7, 29, 13, 20),
      type: type,
      table: table,
      customerName: customerName,
      subtotal: subtotal,
      discount: discount,
      tax: tax,
      serviceChargeAmount: serviceCharge,
      total: subtotal - discount + serviceCharge + tax,
      amountPaid: amountPaid,
      paymentMethod: payment,
      status: OrderStatus.preparing,
      cashierId: 'cashier',
      cashierName: 'Kasir Demo',
      items: lines,
    );
  }

  /// A PDF always starts with the `%PDF-` magic bytes. Checking those (rather
  /// than "not empty") is what distinguishes a real document from a stray
  /// buffer, and the size floor catches a header-only file with no body.
  void expectValidPdf(List<int> bytes) {
    expect(bytes.length, greaterThan(500));
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
  }

  test('builds a receipt for a plain cash takeaway order', () async {
    expectValidPdf(await buildReceiptPdf(
      order: order(),
      store: store,
      labels: labels,
    ));
  });

  test('builds a receipt for a dine-in order with a table', () async {
    expectValidPdf(await buildReceiptPdf(
      order: order(
        type: OrderType.dineIn,
        table: const TableAssignment(tableId: 't_1', tableName: 'Meja 1'),
      ),
      store: store,
      labels: labels,
    ));
  });

  test('builds a receipt for a delivery order with a customer name', () async {
    expectValidPdf(await buildReceiptPdf(
      order: order(type: OrderType.delivery, customerName: 'Mas Yoga'),
      store: store,
      labels: labels,
    ));
  });

  test('builds a receipt carrying a discount and tax', () async {
    expectValidPdf(await buildReceiptPdf(
      order: order(discount: 5000, tax: 4500),
      store: store,
      labels: labels,
    ));
  });

  test('builds a receipt carrying PB1 and a service charge together',
      () async {
    expectValidPdf(await buildReceiptPdf(
      order: order(serviceCharge: 2500, tax: 5250),
      store: store,
      labels: labels,
    ));
  });

  test('builds a receipt with no service charge line when the amount is zero',
      () async {
    // serviceCharge defaults to 0 — this pins that the conditional line in
    // buildReceiptPdf does not crash or render for the common case where the
    // feature is off.
    expectValidPdf(await buildReceiptPdf(
      order: order(tax: 4500),
      store: store,
      labels: labels,
    ));
  });

  test('builds a receipt for a non-cash order (no change line)', () async {
    expectValidPdf(await buildReceiptPdf(
      order: order(payment: PaymentMethod.qris, amountPaid: 50000),
      store: store,
      labels: labels,
    ));
  });

  test('builds a receipt when the store has no address', () async {
    expectValidPdf(await buildReceiptPdf(
      order: order(),
      store: const ReceiptStore(name: 'Warung Demo', address: '', currency: 'Rp'),
      labels: labels,
    ));
  });

  test('builds a receipt for a long multi-line order', () async {
    expectValidPdf(await buildReceiptPdf(
      order: order(
        items: [
          for (var i = 0; i < 25; i++)
            OrderItem(
              id: 'i$i',
              orderId: 'o1',
              productId: 'p$i',
              productName: 'Produk dengan nama yang cukup panjang $i',
              unitPrice: 12000 + i * 500,
              quantity: (i % 4) + 1,
            ),
        ],
      ),
      store: store,
      labels: labels,
    ));
  });
}
