/// The till's port of `backend-go/internal/domain/pricing` — the one
/// definition of how a bill's money is computed.
///
/// Both ports are held to the shared vectors in `testdata/pricing` at the
/// repository root (`test/pricing/vectors_test.dart` here,
/// `vectors_test.go` there). Change one side and the other's vectors fail.
///
/// Every amount is integer rupiah and every rate is basis points
/// (1000 = 10%). Nothing here uses `double`: the first cart implementation
/// rounded double products, which is exactly the result two languages cannot
/// promise to agree on. Every multiplication runs through [BigInt] because a
/// Flutter web build represents `int` as a double, and amount × basis points
/// passes 2^53 well inside the Money ceiling.
///
/// Pure Dart on purpose — no Flutter import — so the engine is testable and
/// portable exactly like its Go twin.
library;

const int pricingVersionLegacy = 1;
const int pricingVersionV2 = 2;

const int maxRateBp = 10000;

enum TaxMode {
  exclusive,
  inclusive;

  String get wire => name;
  static TaxMode fromWire(String? s) =>
      s == 'inclusive' ? TaxMode.inclusive : TaxMode.exclusive;
}

enum RoundingMode {
  nearest,
  up,
  down;

  String get wire => name;
  static RoundingMode fromWire(String? s) => switch (s) {
    'up' => RoundingMode.up,
    'down' => RoundingMode.down,
    _ => RoundingMode.nearest,
  };
}

enum DiscountKind {
  /// Value in basis points, 0..10000.
  percent,

  /// Value in rupiah.
  amount;

  String get wire => name;
  static DiscountKind? tryWire(String? s) => switch (s) {
    'percent' => DiscountKind.percent,
    'amount' => DiscountKind.amount,
    _ => null,
  };
}

/// A discount specification, not its result.
class DiscountSpec {
  const DiscountSpec(this.kind, this.value);

  /// [percent] is a whole-number percentage (10 = 10%) as the till's UI types
  /// it; stored as basis points.
  factory DiscountSpec.percent(num percent) =>
      DiscountSpec(DiscountKind.percent, (percent * 100).round());
  const DiscountSpec.amount(int rupiah) : this(DiscountKind.amount, rupiah);

  final DiscountKind kind;
  final int value;

  Map<String, Object> toJson() => {'kind': kind.wire, 'value': value};

  static DiscountSpec? fromJson(Object? json) {
    if (json is! Map) return null;
    final kind = DiscountKind.tryWire(json['kind'] as String?);
    final value = json['value'];
    if (kind == null || value is! int) return null;
    return DiscountSpec(kind, value);
  }

  @override
  bool operator ==(Object other) =>
      other is DiscountSpec && other.kind == kind && other.value == value;

  @override
  int get hashCode => Object.hash(kind, value);
}

/// One priced line. [unitPrice] already includes variant and modifier
/// deltas, exactly as `CartLine.unitPrice` always has.
class PriceLine {
  const PriceLine({
    required this.unitPrice,
    required this.quantity,
    required this.taxRateBp,
    this.discount,
  });

  final int unitPrice;
  final int quantity;
  final int taxRateBp;
  final DiscountSpec? discount;
}

class PriceInput {
  const PriceInput({
    required this.version,
    required this.lines,
    this.taxMode = TaxMode.exclusive,
    this.serviceRateBp = 0,
    this.serviceTaxable = true,
    this.roundingUnit = 0,
    this.roundingMode = RoundingMode.nearest,
    this.billDiscount,
  });

  final int version;
  final TaxMode taxMode;
  final int serviceRateBp;
  final bool serviceTaxable;
  final int roundingUnit;
  final RoundingMode roundingMode;
  final DiscountSpec? billDiscount;
  final List<PriceLine> lines;
}

class LineResult {
  const LineResult({
    required this.gross,
    this.lineDiscount = 0,
    this.billDiscountShare = 0,
    this.serviceShare = 0,
    this.taxAmount = 0,
    this.taxIncluded = 0,
    required this.netAmount,
  });

  final int gross;
  final int lineDiscount;
  final int billDiscountShare;
  final int serviceShare;
  final int taxAmount;
  final int taxIncluded;
  final int netAmount;

  Map<String, int> toJson() => {
    'gross': gross,
    'line_discount': lineDiscount,
    'bill_discount_share': billDiscountShare,
    'service_share': serviceShare,
    'tax_amount': taxAmount,
    'tax_included': taxIncluded,
    'net_amount': netAmount,
  };
}

/// A priced bill. For version 2 the lines always reconcile with the header:
/// Σ(line discount + bill share) = discount, Σ service share = service,
/// Σ tax = tax, Σ included = included, and
/// total = subtotal − discount + service + tax − included + rounding.
class PriceResult {
  const PriceResult({
    required this.subtotal,
    required this.discount,
    required this.serviceCharge,
    required this.tax,
    required this.taxIncluded,
    required this.rounding,
    required this.total,
    required this.lines,
  });

  static const empty = PriceResult(
    subtotal: 0,
    discount: 0,
    serviceCharge: 0,
    tax: 0,
    taxIncluded: 0,
    rounding: 0,
    total: 0,
    lines: [],
  );

  final int subtotal;
  final int discount;
  final int serviceCharge;
  final int tax;
  final int taxIncluded;
  final int rounding;
  final int total;
  final List<LineResult> lines;

  /// What the sale is worth before tax and service: subtotal − discount −
  /// included tax. The report's net sales.
  int get netSales => subtotal - discount - taxIncluded;

  Map<String, Object> toJson() => {
    'subtotal': subtotal,
    'discount': discount,
    'service_charge': serviceCharge,
    'tax': tax,
    'tax_included': taxIncluded,
    'rounding': rounding,
    'total': total,
    'lines': [for (final l in lines) l.toJson()],
  };
}

class PricingException implements Exception {
  const PricingException(this.message);
  final String message;
  @override
  String toString() => 'PricingException: $message';
}

/// Prices a bill with the algorithm [PriceInput.version] names.
PriceResult computePrice(PriceInput input) {
  _validate(input);
  return switch (input.version) {
    pricingVersionLegacy => _computeLegacy(input),
    pricingVersionV2 => _computeV2(input),
    _ => throw const PricingException('unknown pricing version'),
  };
}

void _validate(PriceInput input) {
  if (input.serviceRateBp < 0 ||
      input.serviceRateBp > maxRateBp ||
      input.roundingUnit < 0 ||
      !_validDiscount(input.billDiscount)) {
    throw const PricingException('invalid input');
  }
  for (final l in input.lines) {
    if (l.unitPrice < 0 ||
        l.quantity < 0 ||
        l.taxRateBp < 0 ||
        l.taxRateBp > maxRateBp ||
        !_validDiscount(l.discount)) {
      throw const PricingException('invalid line');
    }
  }
}

bool _validDiscount(DiscountSpec? d) {
  if (d == null) return true;
  return switch (d.kind) {
    DiscountKind.percent => d.value >= 0 && d.value <= maxRateBp,
    DiscountKind.amount => d.value >= 0,
  };
}

PriceResult _computeV2(PriceInput input) {
  final n = input.lines.length;
  final gross = List<int>.filled(n, 0);
  final lineDisc = List<int>.filled(n, 0);
  final after = List<int>.filled(n, 0);
  var subtotal = 0, sumAfter = 0, lineDiscounts = 0;

  // 1–2. Gross, then each line's own discount.
  for (var i = 0; i < n; i++) {
    final l = input.lines[i];
    gross[i] = _mul(l.unitPrice, l.quantity);
    lineDisc[i] = _discountOn(l.discount, gross[i]);
    after[i] = gross[i] - lineDisc[i];
    subtotal += gross[i];
    sumAfter += after[i];
    lineDiscounts += lineDisc[i];
  }

  // 3. Bill discount on what the lines still owe, shared back over them.
  final billDiscount = _discountOn(input.billDiscount, sumAfter);
  final shares = allocate(billDiscount, after);

  // 4. Included tax extracted from each line's discounted amount.
  final exTax = List<int>.filled(n, 0);
  final included = List<int>.filled(n, 0);
  var sumExTax = 0;
  for (var i = 0; i < n; i++) {
    final rate = input.lines[i].taxRateBp;
    final net = after[i] - shares[i];
    var e = net;
    if (input.taxMode == TaxMode.inclusive && rate > 0) {
      e = _divHalfUp(
        BigInt.from(net) * BigInt.from(maxRateBp),
        BigInt.from(maxRateBp + rate),
      );
    }
    exTax[i] = e;
    included[i] = net - e;
    sumExTax += e;
  }

  // 5. Service on the pre-tax amount, shared over the lines.
  final service = _mulDivHalfUp(sumExTax, input.serviceRateBp, maxRateBp);
  final serviceShares = allocate(service, exTax);

  // 6. Tax.
  var tax = 0, taxIncluded = 0;
  final lines = <LineResult>[];
  for (var i = 0; i < n; i++) {
    final rate = input.lines[i].taxRateBp;
    final taxedService = input.serviceTaxable ? serviceShares[i] : 0;
    final tx = input.taxMode == TaxMode.inclusive
        ? included[i] + _mulDivHalfUp(taxedService, rate, maxRateBp)
        : _mulDivHalfUp(exTax[i] + taxedService, rate, maxRateBp);
    tax += tx;
    taxIncluded += included[i];
    lines.add(
      LineResult(
        gross: gross[i],
        lineDiscount: lineDisc[i],
        billDiscountShare: shares[i],
        serviceShare: serviceShares[i],
        taxAmount: tx,
        taxIncluded: included[i],
        netAmount: exTax[i],
      ),
    );
  }

  // 7. Final rounding of what the customer pays.
  final discount = lineDiscounts + billDiscount;
  final pre = subtotal - discount + service + tax - taxIncluded;
  final total = _roundTo(pre, input.roundingUnit, input.roundingMode);
  return PriceResult(
    subtotal: subtotal,
    discount: discount,
    serviceCharge: service,
    tax: tax,
    taxIncluded: taxIncluded,
    rounding: total - pre,
    total: total,
    lines: lines,
  );
}

/// The till's pre-F3 cart math, reproduced exactly. See `legacy.go`: one bill
/// discount, service on subtotal − discount, per-line tax on floored shares
/// that deliberately do not reconcile, no rounding.
PriceResult _computeLegacy(PriceInput input) {
  final n = input.lines.length;
  final gross = [for (final l in input.lines) _mul(l.unitPrice, l.quantity)];
  final sub = gross.fold<int>(0, (a, g) => a + g);
  final discount = _discountOn(input.billDiscount, sub);
  final base = sub - discount;
  final service = base > 0 && input.serviceRateBp > 0
      ? _mulDivHalfUp(base, input.serviceRateBp, maxRateBp)
      : 0;
  var tax = 0;
  final lines = <LineResult>[];
  for (var i = 0; i < n; i++) {
    final g = gross[i];
    if (sub <= 0) {
      lines.add(LineResult(gross: g, netAmount: g));
      continue;
    }
    final dShare = discount == 0 ? 0 : _mulDiv(discount, g, sub);
    final sShare = service == 0 ? 0 : _mulDiv(service, g, sub);
    final rate = input.lines[i].taxRateBp;
    final tx = rate == 0
        ? 0
        : _mulDivHalfUp(g - dShare + sShare, rate, maxRateBp);
    tax += tx;
    lines.add(
      LineResult(
        gross: g,
        billDiscountShare: dShare,
        serviceShare: sShare,
        taxAmount: tx,
        netAmount: g - dShare,
      ),
    );
  }
  return PriceResult(
    subtotal: sub,
    discount: discount,
    serviceCharge: service,
    tax: tax,
    taxIncluded: 0,
    rounding: 0,
    total: base + service + tax,
    lines: lines,
  );
}

int _discountOn(DiscountSpec? d, int base) {
  if (d == null || base <= 0) return 0;
  final v = switch (d.kind) {
    DiscountKind.percent => _mulDiv(base, d.value, maxRateBp),
    DiscountKind.amount => d.value,
  };
  return v.clamp(0, base);
}

int _roundTo(int v, int unit, RoundingMode mode) {
  if (unit <= 1 || v <= 0) return v;
  var q = v ~/ unit;
  final r = v % unit;
  switch (mode) {
    case RoundingMode.up:
      if (r > 0) q++;
    case RoundingMode.down:
      break;
    case RoundingMode.nearest:
      if (2 * r >= unit) q++;
  }
  return q * unit;
}

/// Splits [total] over [weights] by the Hamilton largest-remainder method:
/// floors first, then one rupiah each to the largest remainders, ties to the
/// lowest index. Identical to Go's `pricing.Allocate`; never gives a row more
/// than its weight when total ≤ Σ weights.
List<int> allocate(int total, List<int> weights) {
  final out = List<int>.filled(weights.length, 0);
  final sum = weights.fold<int>(0, (a, w) => a + w);
  if (total == 0 || sum <= 0) return out;
  final bt = BigInt.from(total), bs = BigInt.from(sum);
  final rems = List<BigInt>.filled(weights.length, BigInt.zero);
  var given = 0;
  for (var i = 0; i < weights.length; i++) {
    final p = bt * BigInt.from(weights[i]);
    out[i] = (p ~/ bs).toInt();
    rems[i] = p.remainder(bs);
    given += out[i];
  }
  var left = total - given;
  final order = List<int>.generate(weights.length, (i) => i);
  // Insertion sort, stable — the same order Go's port produces.
  for (var i = 1; i < order.length; i++) {
    for (var j = i; j > 0 && rems[order[j]] > rems[order[j - 1]]; j--) {
      final t = order[j];
      order[j] = order[j - 1];
      order[j - 1] = t;
    }
  }
  for (var k = 0; k < order.length && left > 0; k++) {
    out[order[k]]++;
    left--;
  }
  return out;
}

int _mul(int a, int b) => (BigInt.from(a) * BigInt.from(b)).toInt();

int _mulDiv(int a, int b, int c) =>
    (BigInt.from(a) * BigInt.from(b) ~/ BigInt.from(c)).toInt();

int _mulDivHalfUp(int a, int b, int c) =>
    _divHalfUp(BigInt.from(a) * BigInt.from(b), BigInt.from(c));

/// n / d rounded half up: ⌊(2n + d) / 2d⌋, for non-negative operands.
int _divHalfUp(BigInt n, BigInt d) =>
    ((n * BigInt.two + d) ~/ (d * BigInt.two)).toInt();
