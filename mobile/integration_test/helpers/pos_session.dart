import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nti_pos/core/auth/permissions.dart';
import 'package:nti_pos/data/models/pos_register.dart';
import 'package:nti_pos/data/repositories/pos_register_repository.dart';
import 'package:nti_pos/data/repositories/shift_repository.dart';
import 'package:nti_pos/providers/outlet_provider.dart';
import 'package:nti_pos/providers/settings_provider.dart';

/// Picks the first cashier on the login screen, so the keypad appears.
///
/// Sign-in is two steps — pick the account, then type its PIN — and the PIN is
/// verified against the CHOSEN row, so a flow that taps digits without picking
/// first never gets past the picker.
///
/// Anchored on the role ICON rather than a name: names are seed data that has
/// already been changed once, and an icon is locale-agnostic. The first
/// cashier tile is Siti Rahayu, whose PIN `2345` is the one every till flow
/// here types.
Future<void> pickFirstCashierAccount(WidgetTester tester) async {
  final cashierTile = find.byIcon(Icons.person_outline_rounded);
  if (cashierTile.evaluate().isEmpty) return;
  await tester.tap(cashierTile.first);
  await tester.pumpAndSettle(const Duration(seconds: 1));
}

/// Signs the device on to a till, so a cashier flow can reach the sell screen.
///
/// Selling requires an open POS session — `PosPage` renders `_SessionGate` in
/// place of the catalogue until there is one. Every flow that signs in as a
/// cashier therefore needs this step before it can assert on the POS
/// catalogue.
///
/// Driven through the repository and the provider rather than by tapping the
/// picker, for the same reason these tests already force-logout through the
/// container: this is SETUP, not the thing under test, and a programmatic step
/// cannot be broken by a layout change or a translated label.
///
/// No-ops for a role that cannot sell — a manager or owner never holds a
/// session — and for a device that already has one, so it is safe to call
/// unconditionally after sign-in.
///
/// Set [requireTableService] for a flow that needs the floor plan: the seeded
/// first branch deliberately has one till that runs tables and one that does
/// not, and picking the wrong one would hide the Tables tab.
Future<void> openPosSessionIfNeeded(
  WidgetTester tester,
  ProviderContainer container, {
  bool requireTableService = false,
}) async {
  final settings = container.read(settingsProvider).valueOrNull;
  if (settings == null) return;
  if (settings.hasPosSession) return;
  if (!settings.can(AppPermission.sell)) return;

  final outlet = await container.read(activeOutletProvider.future);
  if (outlet == null) return;

  final registers = await PosRegisterRepository.instance.byOutlet(
    outlet.id,
    onlyActive: true,
  );

  PosRegister? chosen;
  for (final register in registers) {
    if (requireTableService && !register.tableService) continue;
    // A till somebody else is already holding cannot be opened — that lock is
    // the point of the feature, so the helper respects it rather than
    // reaching around it.
    if (await ShiftRepository.instance.openSessionForRegister(register.id) !=
        null) {
      continue;
    }
    chosen = register;
    break;
  }
  if (chosen == null) return;

  final shift = await ShiftRepository.instance.open(
    employeeId: settings.employeeId.isEmpty ? 'cashier' : settings.employeeId,
    employeeName: settings.cashierName,
    openingCash: 100000,
    posId: chosen.id,
    posName: chosen.name,
    outletId: outlet.id,
    outletName: outlet.name,
  );
  await container.read(settingsProvider.notifier).openPosSession(shift.id);
  await tester.pumpAndSettle(const Duration(seconds: 1));
}

/// Closes whatever session this device holds, releasing its till.
///
/// Worth calling at the end of a flow that opened one: these tests run against
/// a real on-disk database, so a session left open would still be holding that
/// till on the next run and the helper above would quietly pick a different
/// one — or, on a single-till branch, none at all.
Future<void> closePosSessionIfAny(
  WidgetTester tester,
  ProviderContainer container,
) async {
  final sessionId =
      container.read(settingsProvider).valueOrNull?.posSessionId ?? '';
  if (sessionId.isEmpty) return;
  final shift = await ShiftRepository.instance.byId(sessionId);
  if (shift != null && shift.isOpen) {
    await ShiftRepository.instance.close(
      shift: shift,
      countedCash: shift.openingCash,
      closedById: shift.employeeId,
      closedByName: shift.employeeName,
    );
  }
  await container.read(settingsProvider.notifier).closePosSession();
  await tester.pumpAndSettle(const Duration(seconds: 1));
}
