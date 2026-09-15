import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:nti_pos/data/database/app_database.dart';
import 'package:nti_pos/data/repositories/pos_register_repository.dart';

import '../helpers/db_helper.dart';

const _bintaro = 'outlet-1';
const _kemang = 'outlet-2';

void main() {
  setUpAll(() async {
    await initFfi();
  });

  late Database db;
  final repo = PosRegisterRepository.instance;

  setUp(() async {
    db = await openInMemoryAppDb(seed: true);
    await AppDatabase.instance.useTestDb(db);
  });
  tearDown(() async {
    if (db.isOpen) await db.close();
  });

  group('PosRegisterRepository — seeded chain', () {
    test('every seeded branch gets at least one till', () async {
      expect(await repo.byOutlet(_bintaro), isNotEmpty);
      expect(await repo.byOutlet(_kemang), isNotEmpty);
    });

    test('the first branch demonstrates both kinds of till', () async {
      final registers = await repo.byOutlet(_bintaro);
      // One that runs the floor plan and one that does not, in the same shop.
      // A demo where every till is identical cannot show what the setting is
      // for, and per-register scoping bugs need a second till to leak into.
      expect(registers.any((r) => r.tableService), isTrue);
      expect(registers.any((r) => !r.tableService), isTrue);
    });

    test('byOutlet never returns another branch tills', () async {
      final bintaro = await repo.byOutlet(_bintaro);
      expect(bintaro.every((r) => r.outletId == _bintaro), isTrue);
    });

    test('onlyActive hides a retired till', () async {
      final first = (await repo.byOutlet(_bintaro)).first;
      await repo.upsert(first.copyWith(active: false));

      final all = await repo.byOutlet(_bintaro);
      final active = await repo.byOutlet(_bintaro, onlyActive: true);
      expect(all.any((r) => r.id == first.id), isTrue);
      expect(active.any((r) => r.id == first.id), isFalse);
    });
  });

  group('PosRegisterRepository — naming', () {
    test('two branches each hold their own till of the same name', () async {
      const name = 'Kasir 1';
      // The seed already does this, which is the cleanest possible statement
      // of the rule: names are unique PER BRANCH, never globally. Forcing
      // global uniqueness would put the branch into the button a cashier taps
      // forty times a shift.
      expect((await repo.byOutlet(_bintaro)).where((r) => r.name == name),
          hasLength(1));
      expect((await repo.byOutlet(_kemang)).where((r) => r.name == name),
          hasLength(1));
      expect(await repo.isNameTaken(name, outletId: _bintaro), isTrue);
      expect(await repo.isNameTaken(name, outletId: _kemang), isTrue);
    });

    test('a name free at this branch is reported free', () async {
      // "Takeaway" is seeded only at the first branch, so it must read as
      // available at the second — the per-branch scoping seen from the other
      // direction.
      expect(await repo.isNameTaken('Takeaway', outletId: _bintaro), isTrue);
      expect(await repo.isNameTaken('Takeaway', outletId: _kemang), isFalse);
    });

    test('a till does not collide with itself when renamed', () async {
      final first = (await repo.byOutlet(_bintaro)).first;
      expect(
        await repo.isNameTaken(
          first.name,
          outletId: _bintaro,
          exceptId: first.id,
        ),
        isFalse,
      );
    });

    test('matching ignores case', () async {
      expect(await repo.isNameTaken('KASIR 1', outletId: _bintaro), isTrue);
    });
  });

  group('PosRegisterRepository — deletion guards', () {
    test('a till that has held a session reports it', () async {
      final register = (await repo.byOutlet(_bintaro)).first;
      expect(await repo.sessionCount(register.id), 0);

      await db.insert('shifts', {
        'id': 'shift_1',
        'employee_id': 'emp_1',
        'employee_name': 'Siti',
        'pos_id': register.id,
        'pos_name': register.name,
        'outlet_id': _bintaro,
        'opened_at': DateTime.now().millisecondsSinceEpoch,
        'opening_cash': 100000,
      });

      // The management screen reads this before offering to delete: a drawer
      // count filed against an id that resolves to nothing is a number with no
      // story behind it.
      expect(await repo.sessionCount(register.id), 1);
    });

    test('a till that has rung up sales reports it', () async {
      final register = (await repo.byOutlet(_bintaro)).first;
      final before = await repo.orderCount(register.id);
      // The seeded demo month is distributed across tills, so this is already
      // non-zero on a fresh install — which is exactly the state that must
      // block a delete.
      expect(before, greaterThan(0));
    });

    test('upsert replaces rather than duplicating', () async {
      final register = (await repo.byOutlet(_bintaro)).first;
      final count = (await repo.byOutlet(_bintaro)).length;
      await repo.upsert(register.copyWith(name: 'Bar'));

      final after = await repo.byOutlet(_bintaro);
      expect(after.length, count);
      expect(after.firstWhere((r) => r.id == register.id).name, 'Bar');
    });
  });
}
