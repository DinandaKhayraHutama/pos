import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/io_client.dart';
import 'package:nti_pos/data/database/app_database.dart';
import 'package:nti_pos/data/device/device_registration.dart';
import 'package:nti_pos/data/device/till_binding.dart';
import 'package:nti_pos/data/models/enums.dart';
import 'package:nti_pos/data/repositories/order_repository.dart';
import 'package:nti_pos/data/repositories/promo_repository.dart';
import 'package:nti_pos/data/repositories/shift_repository.dart';
import 'package:nti_pos/data/repositories/table_repository.dart';
import 'package:nti_pos/data/sync/dead_letter_store.dart';
import 'package:nti_pos/data/sync/device_sync_runner.dart';
import 'package:nti_pos/data/sync/outbox_store.dart';
import 'package:nti_pos/data/sync/sync_client.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/db_helper.dart';

/// Repository/HTTP contract, not a UI test. Two independent on-disk stores
/// consume real PostgreSQL projections and send the app's actual payloads.
void main() {
  final env = Platform.environment;
  final base = env['JUSTCLICK_LIVE_BASE_URL'];
  final tokens = [env['JUSTCLICK_LIVE_TOKEN'], env['JUSTCLICK_LIVE_TOKEN_B']];
  test(
    'populated catalogue and two tills converge on a contested floor',
    () async {
      initFfi();
      final dir = await Directory.systemTemp.createTemp(
        'justclick_live_floor_',
      );
      Database? db;
      DeviceSyncRunner? runner;
      String? outletId;
      String? registerId;
      addTearDown(() async {
        runner?.close();
        TillBinding.configure(null);
        if (db?.isOpen ?? false) await db!.close();
        await dir.delete(recursive: true);
      });

      Future<void> use(int till) async {
        runner?.close();
        if (db?.isOpen ?? false) await db!.close();
        db = await AppDatabase.openForTest(
          path: '${dir.path}/$till.db',
          seed: false,
        );
        await AppDatabase.instance.useTestDb(db!);
        final http = HttpClient()
          ..badCertificateCallback = (_, host, _) =>
              host == 'localhost' || host == '127.0.0.1';
        final client = SyncClient(
          baseUrl: base!,
          token: tokens[till]!,
          client: IOClient(http),
        );
        final data =
            (await client.get('/devices/me'))['data'] as Map<String, dynamic>;
        outletId = (data['outlet'] as Map)['id'] as String;
        registerId = (data['pos_register'] as Map)['id'] as String;
        TillBinding.configure(
          TillBinding(outletId: outletId!, registerId: registerId!),
        );
        runner = DeviceSyncRunner(
          client: client,
          binding: DeviceRegistration(
            baseUrl: base,
            token: tokens[till]!,
            expiresAt: DateTime.utc(2030),
            device: Map<String, dynamic>.from(data['device'] as Map),
            tenant: Map<String, dynamic>.from(data['tenant'] as Map),
            outlet: Map<String, dynamic>.from(data['outlet'] as Map),
            register: Map<String, dynamic>.from(data['pos_register'] as Map),
          ),
        );
      }

      Future<void> sync() async {
        final result = await runner!.syncNow(full: true);
        expect(result!.failure, isNull);
        expect(
          (await DeadLetterStore.instance.all()).map(
            (e) => '${e.code}: ${e.message}',
          ),
          isEmpty,
        );
        expect(await OutboxStore.instance.count(), 0);
      }

      Future<Map<String, Object?>> table() async =>
          (await db!.query('tables')).single;

      await use(0);
      await sync();
      final tableId = (await table())['id'] as String;
      for (final entity in [
        'categories',
        'products',
        'product_variants',
        'modifier_groups',
        'modifier_options',
        'product_modifier_groups',
        'product_modifier_options',
      ]) {
        expect(await db!.query(entity), hasLength(1), reason: entity);
      }
      expect(
        await PromoRepository.instance.all(
          onlyActive: true,
          outletId: outletId,
        ),
        hasLength(1),
      );
      expect(
        await PromoRepository.instance.all(
          onlyActive: true,
          outletId: 'other-branch',
        ),
        isEmpty,
      );
      await use(1);
      await sync();
      // Both act on the same old snapshot. A's checkout and status share one
      // SQLite transaction; B's reservation is made later but still offline.
      await use(0);
      final product = (await db!.query('products')).single;
      final shift = await ShiftRepository.instance.open(
        employeeId: 'live',
        employeeName: 'Live A',
        openingCash: 0,
      posId: registerId!,
        posName: 'Live A',
      );
      final price = product['price'] as int;
      await OrderRepository.instance.create(
        type: OrderType.dineIn,
        items: [
          OrderItemDraft(
            productId: product['id'] as String,
            productName: product['name'] as String,
            unitPrice: price,
            quantity: 1,
          ),
        ],
        subtotal: price,
        discount: 0,
        tax: 0,
        total: price,
        amountPaid: price,
        paymentMethod: PaymentMethod.cash,
        cashierId: 'live',
        cashierName: 'Live A',
        posId: registerId,
        posSessionId: shift.id,
        tableId: tableId,
        tableName: 'Feed Table 1',
      );
      expect(
        await OutboxStore.instance.pending(entity: 'table_status_events'),
        hasLength(1),
      );
      expect(
        await OutboxStore.instance.pending(entity: 'stock_movements'),
        hasLength(1),
      );
      await use(1);
      await TableRepository.instance.setStatus(
        tableId,
        TableStatus.reserved,
        employeeName: 'Live B',
      );
      await use(0);
      await sync();
      await use(1);
      await sync();
      for (final till in [0, 1]) {
        await use(till);
        await sync();
        expect((await table())['status'], 'reserved');
        expect((await table())['contested'], 1);
        expect((await db!.query('outlet_stock')).single['stock'], 0);
      }
      // An explicit action after seeing the conflict resolves it.
      await TableRepository.instance.setStatus(tableId, TableStatus.available);
      final receipt = (await OutboxStore.instance.pending(
        entity: 'table_status_events',
      )).single;
      await sync();
      // Lost ACK: replay identical bytes, not a new event.
      await db!.insert('_outbox', {
        'entity': receipt.entity,
        'entity_id': receipt.entityId,
        'queued_at': receipt.queuedAt,
        'revision': receipt.revision,
        'payload': receipt.payload,
      });
      await sync();
      await use(0);
      await sync();
      expect((await table())['status'], 'available');
      expect((await table())['contested'], 0);
    },
    skip: base == null || tokens.any((t) => t == null)
        ? 'run backend-go/scripts/verify-flutter against a disposable fixture'
        : null,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
