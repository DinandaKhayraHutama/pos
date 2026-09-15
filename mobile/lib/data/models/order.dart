import 'enums.dart';
import 'order_item.dart';

class Order {
  final String id;
  final String number; // human-friendly, e.g. K1-0023

  /// The integer behind [number], counted per register.
  ///
  /// Stored so the next number is `MAX(number_seq) WHERE pos_id = ?` rather
  /// than a `COUNT(*)` over every order the device has ever taken — the count
  /// version handed two tills the same number, and handed one till a duplicate
  /// after a void.
  ///
  /// Null on orders written before v24, which keep their `ORD-xxxx` string. A
  /// receipt already in a customer's hand must not be renumbered.
  final int? numberSeq;
  final DateTime createdAt;
  final OrderType type;
  final TableAssignment? table;
  final String? customerName;
  final String? note;

  final int subtotal;
  final int discount; // absolute amount in currency
  final int tax; // PB1 amount — column/name unchanged, meaning narrowed to PB1
  final int serviceChargeAmount; // NOT NULL, 0 for a pre-v19 row
  final int total; // = subtotal - discount + serviceChargeAmount + tax

  /// Store-wide PB1 rate in effect when this order was rung up, or null for
  /// a pre-v19 row (the concept did not exist, and the exact historical
  /// rate is unrecoverable if it ever changed). This is the STORE rate, not
  /// necessarily every line's effective rate — a per-product override can
  /// still make one line's tax differ, the same gap that already exists for
  /// `product_name` snapshots versus per-line pricing.
  final double? pb1Rate;

  /// Service Charge rate actually applied to this order — 0.0 when the
  /// feature was off (not whatever rate happened to be configured but
  /// unused), so `serviceChargeAmount` always reconciles against it. Null
  /// only for a pre-v19 row, where the concept did not exist at all.
  final double? serviceChargeRate;
  final int amountPaid;
  final PaymentMethod paymentMethod;
  final OrderStatus status;

  final String cashierId;
  final String cashierName;

  /// Which branch took the money, snapshot name included.
  ///
  /// Null only on a business with no outlet defined at all — the app sells
  /// without one rather than blocking the till. The name is copied in at write
  /// time, like the cashier's: renaming or closing a branch must not rewrite
  /// what an old receipt says about where the money was taken.
  final String? outletId;
  final String? outletName;

  /// Which till rang it up, and during which session.
  ///
  /// [posSessionId] is what makes a drawer reconcilable: the shift's expected
  /// cash is the sum of exactly the orders carrying its id, including any rung
  /// up by a second cashier after a handover — the money went into the same
  /// box, so it has to count towards the same expectation.
  ///
  /// Null on sales that predate registers, and on the seeded demo history for
  /// an install that upgraded into them. [posName] is a snapshot alongside the
  /// id, like the outlet's: renaming or retiring a till must not rewrite what
  /// a reprinted receipt says about where the sale was rung up.
  final String? posId;
  final String? posName;
  final String? posSessionId;

  /// Which promo produced [discount], or null when it was typed by hand or
  /// there was none. Kept so a report can answer "what did Happy Hour cost
  /// us?" without guessing from the amount.
  final String? promoName;

  /// Who approved voiding or refunding this order, and why.
  ///
  /// A void with no name on it is the exact thing a manager PIN exists to
  /// prevent, so the name is written in the same update that changes the
  /// status — there is no path that sets one without the other.
  final String? authorizedBy;
  final String? voidReason;

  /// How much was handed back. Equals [total] for a full refund; a partial
  /// refund records less. Null until a refund happens.
  final int? refundedAmount;

  final List<OrderItem> items;
  final int? itemCount;

  const Order({
    required this.id,
    required this.number,
    this.numberSeq,
    required this.createdAt,
    required this.type,
    this.table,
    this.customerName,
    this.note,
    required this.subtotal,
    required this.discount,
    required this.tax,
    // Defaulted, unlike subtotal/discount/tax which have always been
    // required — this field is new, and every construction site that
    // predates it (fixtures, seed history) means exactly the same thing by
    // omitting it as a pre-v19 order does: no service charge applied.
    this.serviceChargeAmount = 0,
    this.pb1Rate,
    this.serviceChargeRate,
    required this.total,
    required this.amountPaid,
    required this.paymentMethod,
    required this.status,
    required this.cashierId,
    required this.cashierName,
    this.outletId,
    this.outletName,
    this.posId,
    this.posName,
    this.posSessionId,
    this.promoName,
    this.authorizedBy,
    this.voidReason,
    this.refundedAmount,
    this.items = const [],
    this.itemCount,
  });

  int get resolvedItemCount => itemCount ?? items.length;

  int get change => amountPaid - total;

  /// Cost of goods for the lines that were loaded, or null when no line
  /// carried a cost. Null rather than zero on purpose: a zero would read as
  /// "100% margin" in a profit report, which is worse than an honest gap.
  int? get costOfGoods {
    var total = 0;
    var any = false;
    for (final it in items) {
      if (it.unitCost == null) continue;
      any = true;
      total += it.unitCost! * it.quantity;
    }
    return any ? total : null;
  }

  Order copyWith({
    OrderStatus? status,
    String? authorizedBy,
    String? voidReason,
    int? refundedAmount,
    List<OrderItem>? items,
  }) => Order(
    id: id,
    number: number,
    numberSeq: numberSeq,
    createdAt: createdAt,
    type: type,
    table: table,
    customerName: customerName,
    note: note,
    subtotal: subtotal,
    discount: discount,
    tax: tax,
    serviceChargeAmount: serviceChargeAmount,
    pb1Rate: pb1Rate,
    serviceChargeRate: serviceChargeRate,
    total: total,
    amountPaid: amountPaid,
    paymentMethod: paymentMethod,
    status: status ?? this.status,
    cashierId: cashierId,
    cashierName: cashierName,
    outletId: outletId,
    outletName: outletName,
    posId: posId,
    posName: posName,
    posSessionId: posSessionId,
    promoName: promoName,
    authorizedBy: authorizedBy ?? this.authorizedBy,
    voidReason: voidReason ?? this.voidReason,
    refundedAmount: refundedAmount ?? this.refundedAmount,
    items: items ?? this.items,
    itemCount: itemCount,
  );

  factory Order.fromMapRow(Map<String, dynamic> m, {List<OrderItem>? items}) {
    return Order(
      id: m['id'] as String,
      number: m['number'] as String,
      numberSeq: (m['number_seq'] as num?)?.toInt(),
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (m['created_at'] as num).toInt(),
      ),
      type: OrderTypeX.fromWire((m['type'] as String?) ?? 'dineIn'),
      customerName: m['customer_name'] as String?,
      note: m['note'] as String?,
      subtotal: (m['subtotal'] as num).toInt(),
      discount: (m['discount'] as num?)?.toInt() ?? 0,
      tax: (m['tax'] as num?)?.toInt() ?? 0,
      serviceChargeAmount: (m['service_charge_amount'] as num?)?.toInt() ?? 0,
      pb1Rate: (m['pb1_rate'] as num?)?.toDouble(),
      serviceChargeRate: (m['service_charge_rate'] as num?)?.toDouble(),
      total: (m['total'] as num).toInt(),
      amountPaid: (m['amount_paid'] as num?)?.toInt() ?? 0,
      paymentMethod: PaymentMethodX.fromWire(
        (m['payment_method'] as String?) ?? 'cash',
      ),
      status: OrderStatusX.fromWire((m['status'] as String?) ?? 'pending'),
      cashierId: (m['cashier_id'] as String?) ?? 'cashier',
      cashierName: (m['cashier_name'] as String?) ?? 'Cashier',
      outletId: m['outlet_id'] as String?,
      outletName: m['outlet_name'] as String?,
      posId: m['pos_id'] as String?,
      posName: m['pos_name'] as String?,
      posSessionId: m['pos_session_id'] as String?,
      promoName: m['promo_name'] as String?,
      authorizedBy: m['authorized_by'] as String?,
      voidReason: m['void_reason'] as String?,
      refundedAmount: (m['refunded_amount'] as num?)?.toInt(),
      table: m['table_id'] != null
          ? TableAssignment(
              tableId: m['table_id'] as String,
              tableName: m['table_name'] as String? ?? '',
            )
          : null,
      items: items ?? const [],
      itemCount: (m['item_count'] as num?)?.toInt(),
    );
  }

  Map<String, dynamic> toMap() => {
    'id': id,
    'number': number,
    'number_seq': numberSeq,
    'created_at': createdAt.millisecondsSinceEpoch,
    'type': type.wire,
    'table_id': table?.tableId,
    'table_name': table?.tableName,
    'customer_name': customerName,
    'note': note,
    'subtotal': subtotal,
    'discount': discount,
    'tax': tax,
    'service_charge_amount': serviceChargeAmount,
    'pb1_rate': pb1Rate,
    'service_charge_rate': serviceChargeRate,
    'total': total,
    'amount_paid': amountPaid,
    'payment_method': paymentMethod.wire,
    'status': status.wire,
    'cashier_id': cashierId,
    'cashier_name': cashierName,
    'outlet_id': outletId,
    'outlet_name': outletName,
    'pos_id': posId,
    'pos_name': posName,
    'pos_session_id': posSessionId,
    'promo_name': promoName,
    'authorized_by': authorizedBy,
    'void_reason': voidReason,
    'refunded_amount': refundedAmount,
  };
}

class TableAssignment {
  final String tableId;
  final String tableName;
  const TableAssignment({required this.tableId, required this.tableName});
}
