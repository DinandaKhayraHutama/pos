import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/io_client.dart';
import 'package:nti_pos/data/database/app_database.dart';
import 'package:nti_pos/data/device/device_registration.dart';
import 'package:nti_pos/data/device/till_binding.dart';
import 'package:nti_pos/data/models/enums.dart';
import 'package:nti_pos/data/repositories/order_repository.dart';
import 'package:nti_pos/data/repositories/shift_repository.dart';
import 'package:nti_pos/data/sync/dead_letter_store.dart';
import 'package:nti_pos/data/sync/device_sync_runner.dart';
import 'package:nti_pos/data/sync/order_push.dart';
import 'package:nti_pos/data/sync/outbox_store.dart';
import 'package:nti_pos/data/sync/sync_client.dart';

import '../helpers/db_helper.dart';

/// Opt-in: this app's v2 sync against a real Go API.
///
/// Skipped unless `JUSTCLICK_LIVE_BASE_URL` (the `/api/v2` root) and
/// `JUSTCLICK_LIVE_TOKEN` (a device token for a disposable tenant) are set —
/// `mobile/docs/PHASE_4_VERIFICATION.md` shows how the fixture is made.
///
/// What it proves that no mock can: the payloads this app builds pass the
/// server's own schema and money checks (`additionalProperties: false`, totals
/// that reconcile, immutable first revisions), and the server's responses
/// parse here.
void main() {
  final base = Platform.environment['JUSTCLICK_LIVE_BASE_URL'];
  final token = Platform.environment['JUSTCLICK_LIVE_TOKEN'];
  final skip = base == null || token == null
      ? 'set JUSTCLICK_LIVE_BASE_URL and JUSTCLICK_LIVE_TOKEN'
      : null;

  test(
    'a drawer and its sales round-trip through the real server',
    () async {
      final db = await openInMemoryAppDb();
      await AppDatabase.instance.useTestDb(db);
      addTearDown(db.close);

      final http = HttpClient()
        // The local Caddy CA only; any other host keeps full verification.
        ..badCertificateCallback = (_, host, _) =>
            host == 'localhost' || host == '127.0.0.1';
      final client = SyncClient(
        baseUrl: base!,
        token: token!,
        client: IOClient(http),
      );
      // The till is bound exactly as an activated device is: to the register
      // and outlet the token names, read from the server itself.
      final me = await client.get('/devices/me');
      final data = me['data'] as Map<String, dynamic>;
      final registerId = (data['pos_register'] as Map)['id'] as String;
      final outletId = (data['outlet'] as Map)['id'] as String;
      TillBinding.configure(
        TillBinding(outletId: outletId, registerId: registerId),
      );
      addTearDown(() => TillBinding.configure(null));

      // A drawer on any other register is refused before it is written.
      await expectLater(
        ShiftRepository.instance.open(
          employeeId: 'e1',
          employeeName: 'Kasir Kontrak',
          openingCash: 0,
          posId: 'another-register',
          posName: 'Kasir 2',
        ),
        throwsA(isA<TillBindingException>()),
      );

      final runner = DeviceSyncRunner(
        binding: DeviceRegistration(
          baseUrl: base,
          token: token,
          expiresAt: DateTime.utc(2030),
          device: {'id': 'live'},
          tenant: {'id': 'live', 'name': 'Live'},
          outlet: {'id': 'outlet', 'name': 'Outlet'},
          register: {
            'id': 'register',
            'outlet_id': 'outlet',
            'name': 'Kasir 1',
            'table_service': true,
          },
        ),
        client: client,
      );
      addTearDown(runner.close);

      Future<String> sell(String sessionId) async =>
          (await OrderRepository.instance.create(
            type: OrderType.dineIn,
            items: const [
              OrderItemDraft(
                productId: 'p_1726000000000',
                productName: 'Kopi Susu',
                unitPrice: 18000,
                quantity: 2,
                modifiers: [
                  (groupName: 'Susu', optionName: 'Oat', priceDelta: 3000),
                ],
              ),
              OrderItemDraft(
                productId: 'p2',
                productName: 'Roti Bakar',
                unitPrice: 12000,
                quantity: 1,
              ),
            ],
            subtotal: 48000,
            discount: 2000,
            serviceChargeAmount: 2300,
            tax: 4830,
            total: 53130,
            amountPaid: 60000,
            pb1Rate: 10,
            serviceChargeRate: 5,
            paymentMethod: PaymentMethod.cash,
            cashierId: 'e1',
            cashierName: 'Kasir Kontrak',
            posId: registerId,
            posName: 'Kasir 1',
            posSessionId: sessionId,
            tableId: 'table_1726000000000',
            tableName: 'Meja 1',
          )).id;

      Future<void> expectClean(SyncOutcome? outcome, String step) async {
        expect(outcome, isNotNull, reason: step);
        expect(outcome!.failure, isNull, reason: '$step: ${outcome.failure}');
        final letters = await DeadLetterStore.instance.all();
        expect(
          letters.map((l) => '${l.entity} ${l.code} ${l.message}'),
          isEmpty,
          reason: step,
        );
        expect(await OutboxStore.instance.count(), 0, reason: step);
      }

      final shift = await ShiftRepository.instance.open(
        employeeId: 'e1',
        employeeName: 'Kasir Kontrak',
        openingCash: 100000,
        posId: registerId,
        posName: 'Kasir 1',
        outletName: 'Outlet',
      );
      final sold = [for (var i = 0; i < 3; i++) await sell(shift.id)];

      // First contact: every feed, then the drawer and three sales.
      await expectClean(await runner.syncNow(full: true), 'first sync');

      // A sale made after a sync carries the measured clock offset.
      sold.add(await sell(shift.id));

      // Every later revision the server must accept.
      await OrderRepository.instance.setStatus(sold[0], OrderStatus.served);
      await OrderRepository.instance.voidOrder(
        orderId: sold[1],
        authorizedBy: 'Manajer',
        reason: 'Salah input',
      );
      await OrderRepository.instance.refundOrder(
        orderId: sold[2],
        authorizedBy: 'Manajer',
        reason: 'Komplain tamu',
      );
      await ShiftRepository.instance.close(
        shift: shift,
        countedCash: 250000,
        closedById: 'e1',
        closedByName: 'Kasir Kontrak',
      );
      final beforeSecond = await OutboxStore.instance.pending(
        entity: OrderPush.entity,
      );
      await expectClean(await runner.syncNow(), 'revisions');

      // The response to an accepted push was "lost": the same snapshot goes up
      // again and must be accepted, not duplicated or refused.
      for (final entry in beforeSecond) {
        await db.insert(OutboxStore.table, {
          'entity': entry.entity,
          'entity_id': entry.entityId,
          'queued_at': entry.queuedAt,
          'attempts': 0,
          'revision': entry.revision,
          'payload': entry.payload,
        });
      }
      await expectClean(await runner.syncNow(), 'exact retry');
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
