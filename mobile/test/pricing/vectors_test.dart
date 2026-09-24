import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nti_pos/core/pricing/pricing.dart';

/// The vectors are shared with `backend-go/internal/domain/pricing`. Tests run
/// from `mobile/`, so the repository root is one level up. Both ports must
/// reproduce every header and line figure, and neither may skip a file.
const _expectedVectorFiles = 5;

Directory _vectorDir() {
  var dir = Directory.current;
  while (true) {
    final candidate = Directory('${dir.path}/testdata/pricing');
    if (candidate.existsSync()) return candidate;
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError('testdata/pricing not found above ${Directory.current}');
    }
    dir = parent;
  }
}

PriceInput _input(Map<String, dynamic> j) => PriceInput(
  version: j['version'] as int,
  taxMode: TaxMode.fromWire(j['tax_mode'] as String?),
  serviceRateBp: (j['service_rate_bp'] as int?) ?? 0,
  serviceTaxable: (j['service_taxable'] as bool?) ?? false,
  roundingUnit: (j['rounding_unit'] as int?) ?? 0,
  roundingMode: RoundingMode.fromWire(j['rounding_mode'] as String?),
  billDiscount: DiscountSpec.fromJson(j['bill_discount']),
  lines: [
    for (final l in (j['lines'] as List).cast<Map<String, dynamic>>())
      PriceLine(
        unitPrice: l['unit_price'] as int,
        quantity: l['quantity'] as int,
        taxRateBp: l['tax_rate_bp'] as int,
        discount: DiscountSpec.fromJson(l['discount']),
      ),
  ],
);

void main() {
  final dir = _vectorDir();

  test('every vector file is exercised', () {
    final files = dir
        .listSync()
        .whereType<File>()
        .where(
          (f) => f.path.endsWith('.json') && !f.path.endsWith('allocate.json'),
        )
        .toList();
    expect(files, hasLength(_expectedVectorFiles));
  });

  for (final file in dir.listSync().whereType<File>()) {
    if (!file.path.endsWith('.json') || file.path.endsWith('allocate.json')) {
      continue;
    }
    final doc = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final base = file.uri.pathSegments.last;
    for (final v in (doc['vectors'] as List).cast<Map<String, dynamic>>()) {
      test('$base/${v['name']}', () {
        final input = _input(v['input'] as Map<String, dynamic>);
        final got = computePrice(input);
        expect(got.toJson(), v['expected']);
        if (input.version == pricingVersionV2) {
          var disc = 0, svc = 0, tax = 0, incl = 0;
          for (final l in got.lines) {
            disc += l.lineDiscount + l.billDiscountShare;
            svc += l.serviceShare;
            tax += l.taxAmount;
            incl += l.taxIncluded;
            expect(
              l.netAmount,
              l.gross - l.lineDiscount - l.billDiscountShare - l.taxIncluded,
            );
          }
          expect(disc, got.discount);
          expect(svc, got.serviceCharge);
          expect(tax, got.tax);
          expect(incl, got.taxIncluded);
        }
      });
    }
  }

  group('allocate', () {
    final doc =
        jsonDecode(File('${dir.path}/allocate.json').readAsStringSync())
            as Map<String, dynamic>;
    for (final c in (doc['cases'] as List).cast<Map<String, dynamic>>()) {
      test(c['name'] as String, () {
        expect(
          allocate(c['total'] as int, (c['weights'] as List).cast<int>()),
          (c['expected'] as List).cast<int>(),
        );
      });
    }
  });

  test('the engine imports no Flutter code', () {
    final src = File('lib/core/pricing/pricing.dart').readAsStringSync();
    expect(src.contains("package:flutter"), isFalse);
  });

  test('invalid input is refused', () {
    expect(
      () => computePrice(const PriceInput(version: 3, lines: [])),
      throwsA(isA<PricingException>()),
    );
    expect(
      () => computePrice(
        const PriceInput(
          version: 2,
          lines: [PriceLine(unitPrice: -1, quantity: 1, taxRateBp: 0)],
        ),
      ),
      throwsA(isA<PricingException>()),
    );
  });
}
