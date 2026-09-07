/// Enum helpers shared across data models.
library;

enum OrderType { dineIn, takeaway, delivery }

enum PaymentMethod { cash, qris, card }

/// Where an order stands.
///
/// The first five describe where the food is; the last two describe money that
/// did not stay with the business. [cancelled] is a sale that was struck out
/// before it counted, [refunded] is one that counted and was then given back —
/// both are excluded from revenue, and both return their stock to the shelf,
/// but they are separate because "we voided 3 orders" and "we refunded 3
/// orders" are very different sentences to read in a report.
enum OrderStatus { pending, preparing, ready, served, paid, cancelled, refunded }

enum TableStatus { available, occupied, reserved }

/// How many options a modifier group lets a cashier pick.
///
/// [single] renders as a radio list and caps at one pick; [multiple] renders
/// as a checkbox list, optionally capped by [ModifierGroup.maxSelect].
enum ModifierSelectionType { single, multiple }

extension OrderTypeX on OrderType {
  String get wire => name;
  static OrderType fromWire(String v) => OrderType.values.firstWhere(
    (e) => e.name == v,
    orElse: () => OrderType.dineIn,
  );
}

extension PaymentMethodX on PaymentMethod {
  String get wire => name;
  static PaymentMethod fromWire(String v) => PaymentMethod.values.firstWhere(
    (e) => e.name == v,
    orElse: () => PaymentMethod.cash,
  );
}

extension OrderStatusX on OrderStatus {
  String get wire => name;
  static OrderStatus fromWire(String v) => OrderStatus.values.firstWhere(
    (e) => e.name == v,
    orElse: () => OrderStatus.pending,
  );

  bool get isTerminal =>
      this == OrderStatus.paid ||
      this == OrderStatus.cancelled ||
      this == OrderStatus.refunded;

  /// Whether the money stayed with the business.
  ///
  /// Every revenue figure in the app filters on this, so voiding or refunding
  /// an order removes it from the dashboard, the report and the drawer
  /// expectation in one move.
  bool get countsAsRevenue =>
      this != OrderStatus.cancelled && this != OrderStatus.refunded;

  /// Whether the goods went back on the shelf.
  bool get returnsStock =>
      this == OrderStatus.cancelled || this == OrderStatus.refunded;
}

/// SQL fragment matching the statuses that count as revenue.
///
/// Written once because it appears in seven aggregate queries, and a report
/// where six of them exclude refunds and the seventh does not is a bug nobody
/// spots until the columns fail to add up.
const kRevenueStatusSql = "status NOT IN ('cancelled', 'refunded')";

extension TableStatusX on TableStatus {
  String get wire => name;
  static TableStatus fromWire(String v) => TableStatus.values.firstWhere(
    (e) => e.name == v,
    orElse: () => TableStatus.available,
  );
}

extension ModifierSelectionTypeX on ModifierSelectionType {
  String get wire => name;
  static ModifierSelectionType fromWire(String v) =>
      ModifierSelectionType.values.firstWhere(
        (e) => e.name == v,
        orElse: () => ModifierSelectionType.single,
      );
}
