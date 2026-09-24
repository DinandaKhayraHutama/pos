import 'package:flutter_test/flutter_test.dart';
import 'package:nti_pos/core/auth/permissions.dart';
import 'package:nti_pos/data/models/employee.dart';

/// The permission table is the one place a role's authority is decided, and
/// every screen trusts it. These are the boundaries that matter — not that
/// each role has some list, but that the separations the business asked for
/// actually hold.
void main() {
  group('role boundaries', () {
    test('a cashier can sell and count their own drawer', () {
      final p = permissionsFor(EmployeeRole.cashier);
      expect(p, contains(AppPermission.sell));
      expect(p, contains(AppPermission.openCloseShift));
      expect(p, contains(AppPermission.viewOwnOrders));
    });

    test('a cashier cannot void, refund or discount by hand', () {
      final p = permissionsFor(EmployeeRole.cashier);
      expect(p, isNot(contains(AppPermission.voidOrder)));
      expect(p, isNot(contains(AppPermission.refundOrder)));
      expect(p, isNot(contains(AppPermission.applyManualDiscount)));
    });

    test('a cashier cannot reach the catalogue, staff or the money view', () {
      final p = permissionsFor(EmployeeRole.cashier);
      expect(p, isNot(contains(AppPermission.manageCatalogue)));
      expect(p, isNot(contains(AppPermission.manageEmployees)));
      expect(p, isNot(contains(AppPermission.viewFinancialReports)));
      expect(p, isNot(contains(AppPermission.viewAllOrders)));
    });

    test('a manager can fix the floor', () {
      final p = permissionsFor(EmployeeRole.manager);
      expect(p, contains(AppPermission.voidOrder));
      expect(p, contains(AppPermission.refundOrder));
      expect(p, contains(AppPermission.applyManualDiscount));
      expect(p, contains(AppPermission.viewCashDrawer));
      expect(p, contains(AppPermission.adjustStock));
    });

    test('a manager still cannot change prices or read the money view', () {
      // This is the separation the role exists for. If it ever stops holding,
      // "manager" and "owner" have collapsed into one role.
      final p = permissionsFor(EmployeeRole.manager);
      expect(p, isNot(contains(AppPermission.manageCatalogue)));
      expect(p, isNot(contains(AppPermission.viewFinancialReports)));
      expect(p, isNot(contains(AppPermission.manageEmployees)));
      expect(p, isNot(contains(AppPermission.managePromos)));
    });

    test('neither a manager nor an owner may run the till', () {
      // The rule that replaced "a manager can do everything a cashier can".
      // Their focus is the data and the money; a sale rung up under a
      // manager's or owner's name is attribution nobody asked for, and the
      // drawer belongs to whoever counted it.
      for (final role in [EmployeeRole.manager, EmployeeRole.owner]) {
        final p = permissionsFor(role);
        expect(p, isNot(contains(AppPermission.sell)), reason: '$role');
        expect(
          p,
          isNot(contains(AppPermission.openCloseShift)),
          reason: '$role',
        );
      }
    });

    test('a manager keeps the floor and the exceptions', () {
      // What survives losing the till: watching service, and unsticking it.
      final p = permissionsFor(EmployeeRole.manager);
      expect(p, contains(AppPermission.manageTables));
      expect(p, contains(AppPermission.voidOrder));
      expect(p, contains(AppPermission.viewAllOrders));
    });

    test('an owner holds every permission except the till', () {
      // Spelled against the full enum rather than a copy of the list, so a
      // newly added permission is caught here if the owner set is ever
      // hand-maintained again. The two till permissions are the only
      // deliberate exclusions.
      expect(
        permissionsFor(EmployeeRole.owner),
        equals(
          AppPermission.values.toSet()
            ..remove(AppPermission.sell)
            ..remove(AppPermission.openCloseShift),
        ),
      );
    });
  });

  group('overrides and landing', () {
    test('only manager and owner can approve an override', () {
      expect(canAuthorizeOverrides(EmployeeRole.cashier), isFalse);
      expect(canAuthorizeOverrides(EmployeeRole.manager), isTrue);
      expect(canAuthorizeOverrides(EmployeeRole.owner), isTrue);
    });

    test('only a cashier lands on the till', () {
      // A manager now lands on the numbers too — they cannot open the sell
      // screen at all, so landing there would bounce them straight back out.
      expect(homeRouteFor(EmployeeRole.owner), '/dashboard');
      expect(homeRouteFor(EmployeeRole.manager), '/dashboard');
      expect(homeRouteFor(EmployeeRole.cashier), '/');
    });

    test('every role can reach its own home route', () {
      // A role whose landing page it cannot open would bounce forever in
      // `redirect`. Cheap to assert, catastrophic to get wrong.
      for (final role in EmployeeRole.values) {
        final home = homeRouteFor(role);
        final needed = const {
          '/dashboard': AppPermission.viewDailySummary,
          '/': AppPermission.sell,
        }[home];
        expect(
          needed == null || permissionsFor(role).contains(needed),
          isTrue,
          reason: '$role lands on $home but cannot open it',
        );
      }
    });
  });

  group('custom roles (Fase 3)', () {
    test('a custom access lands where it can open, never in a loop', () {
      final cases = {
        '/': EmployeeAccess.custom(['sell'], posAccess: true),
        '/dashboard': EmployeeAccess.custom([
          'viewDailySummary',
        ], posAccess: true),
        '/settings': EmployeeAccess.custom(['adjustStock'], posAccess: true),
      };
      cases.forEach((home, access) {
        expect(homeRouteForAccess(access), home);
      });
    });

    test('unknown permission names grant nothing', () {
      final access = EmployeeAccess.custom([
        'sell',
        'launchRockets',
      ], posAccess: true);
      expect(access.permissions, {AppPermission.sell});
    });

    test('an unresolved role is locked, never a cashier', () {
      expect(EmployeeRoleX.fromWire('supervisor'), EmployeeRole.custom);
      expect(EmployeeAccess.system(EmployeeRole.custom).permissions, isEmpty);
      expect(EmployeeAccess.system(EmployeeRole.custom).posAccess, isFalse);
      expect(EmployeeAccess.locked.can(AppPermission.sell), isFalse);
    });

    test('enterCustomAmount reaches the owner by derivation only', () {
      expect(
        permissionsFor(EmployeeRole.owner),
        contains(AppPermission.enterCustomAmount),
      );
      expect(
        permissionsFor(EmployeeRole.manager),
        isNot(contains(AppPermission.enterCustomAmount)),
      );
      expect(
        permissionsFor(EmployeeRole.cashier),
        isNot(contains(AppPermission.enterCustomAmount)),
      );
    });
  });
}
