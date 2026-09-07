import 'package:flutter_test/flutter_test.dart';
import 'package:nti_pos/data/models/promo.dart';

Promo _percent(int v, {int min = 0, bool active = true}) => Promo(
  id: 'p',
  name: 'p',
  kind: PromoKind.percent,
  value: v,
  minSpend: min,
  active: active,
);

Promo _amount(int v, {int min = 0, bool active = true}) => Promo(
  id: 'a',
  name: 'a',
  kind: PromoKind.amount,
  value: v,
  minSpend: min,
  active: active,
);

void main() {
  group('discountFor', () {
    test('percent takes a share of the subtotal, floored', () {
      // 15% of 33.333 is 4999.95 — integer division floors, which errs in the
      // shop's favour by one rupiah rather than the customer's.
      expect(_percent(15).discountFor(33333), 4999);
      expect(_percent(10).discountFor(50000), 5000);
    });

    test('a flat amount comes off whole', () {
      expect(_amount(10000).discountFor(75000), 10000);
    });

    test('a voucher larger than the bill clamps to the bill', () {
      // Without the clamp this produces a negative total, and the cashier is
      // asked to hand out change on a sale that took no money.
      expect(_amount(50000).discountFor(20000), 20000);
    });

    test('100% clears the bill exactly, never past it', () {
      expect(_percent(100).discountFor(12345), 12345);
    });

    test('an empty bill discounts to zero, not to a negative', () {
      expect(_amount(10000).discountFor(0), 0);
      expect(_percent(50).discountFor(0), 0);
    });
  });

  group('isEligible', () {
    test('a retired promo is never eligible, even above the minimum', () {
      expect(_percent(10, active: false).isEligible(999999), isFalse);
    });

    test('the minimum spend is inclusive', () {
      final p = _amount(10000, min: 75000);
      expect(p.isEligible(74999), isFalse);
      expect(p.isEligible(75000), isTrue);
    });

    test('no minimum means any bill qualifies', () {
      expect(_percent(10).isEligible(1), isTrue);
    });
  });

  test('round-trips through toMap/fromMap', () {
    const original = Promo(
      id: 'promo_x',
      name: 'Happy Hour',
      kind: PromoKind.amount,
      value: 7500,
      minSpend: 30000,
      active: false,
      sortOrder: 3,
    );
    final copy = Promo.fromMap(original.toMap());
    expect(copy.id, original.id);
    expect(copy.name, original.name);
    expect(copy.kind, original.kind);
    expect(copy.value, original.value);
    expect(copy.minSpend, original.minSpend);
    expect(copy.active, original.active);
    expect(copy.sortOrder, original.sortOrder);
  });
}
