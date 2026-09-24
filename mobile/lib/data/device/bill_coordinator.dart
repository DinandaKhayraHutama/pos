import 'package:uuid/uuid.dart';

import '../database/app_database.dart';
import '../models/bill.dart';
import '../repositories/bill_repository.dart';
import 'till_binding.dart';
import 'till_coordinator.dart';

/// The online half of saved bills (paritas F4): the outlet's board, moving a
/// bill between tills, and seating or clearing a table.
///
/// Needs the network on purpose. A till saves, sends to the kitchen and
/// settles its OWN bills offline; which till owns a bill, and who sits at a
/// table, is decided by the server. There is no heartbeat and no timeout: a
/// bill changes hands only because a person parked it or claimed it.
///
/// **An operation id is stored before it is used.** A park, claim or seating
/// whose answer was lost is retried with the SAME id, so the server answers
/// what it did the first time instead of doing it twice. The id is dropped
/// only once an answer arrives.
class BillCoordinator {
  BillCoordinator(this.till);

  final TillCoordinator till;

  static BillCoordinator? get current {
    final till = TillCoordinator.current;
    return till == null ? null : BillCoordinator(till);
  }

  static const _uuid = Uuid();

  /// The id of an operation on [target] still awaiting its answer, or a new
  /// one — stored before the request, so a lost reply reuses it.
  static Future<String> _operationId(String kind, String target) async {
    final db = await AppDatabase.instance.db;
    final key = 'bill_op:$kind:$target';
    final rows = await db.query(
      '_sync_meta',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (rows.isNotEmpty) return rows.first['value'] as String;
    final id = _uuid.v4();
    await db.insert('_sync_meta', {'key': key, 'value': id});
    return id;
  }

  /// The operation got an answer — success or a refusal the server decided —
  /// so the next attempt is a new operation.
  static Future<void> _answered(String kind, String target) async {
    final db = await AppDatabase.instance.db;
    await db.delete(
      '_sync_meta',
      where: 'key = ?',
      whereArgs: ['bill_op:$kind:$target'],
    );
  }

  /// Runs an operation, keeping its id until the server has answered. A
  /// network failure keeps it for the retry; any answer, even a refusal,
  /// retires it.
  Future<Map<String, dynamic>> _once(
    String kind,
    String target,
    Future<Map<String, dynamic>> Function(String operationId) send,
  ) async {
    final op = await _operationId(kind, target);
    try {
      final out = await send(op);
      await _answered(kind, target);
      return out;
    } on TillOperationException catch (e) {
      if (e.code != 'network' && e.code != 'server_unavailable') {
        await _answered(kind, target);
      }
      rethrow;
    }
  }

  static Map<String, dynamic> _data(Map<String, dynamic> body) =>
      (body['data'] as Map).cast<String, dynamic>();

  /// The outlet's open bills and seatings, as the server holds them. Cached
  /// for an offline glance; the cache never makes a bill editable.
  Future<Map<String, dynamic>> board(String employee) async {
    final data = _data(await till.call(employee, '/till/bills'));
    final outlet = TillBinding.current?.outletId;
    if (outlet != null) await BillRepository.instance.cacheBoard(outlet, data);
    return data;
  }

  Future<Map<String, dynamic>> detail(String employee, String billId) async =>
      _data(await till.call(employee, '/till/bills/$billId'));

  /// Releases [billId] to the server. The server must already hold every
  /// revision and dispatch this till made — the caller pushes first — or it
  /// answers `sync_before_handoff` and nothing moves.
  Future<void> park(String employee, String billId) async {
    if (await BillRepository.instance.hasUnsentChanges(billId)) {
      throw const TillOperationException('sync_before_handoff');
    }
    final basis = await BillRepository.instance.parkBasis(billId);
    final data = _data(
      await _once(
        'park',
        billId,
        (op) => till.call(
          employee,
          '/till/bills/$billId/park',
          body: {
            'operation_id': op,
            'expected_revision': basis.revision,
            'expected_dispatches': basis.dispatches,
          },
        ),
      ),
    );
    await BillRepository.instance.markParked(
      billId,
      (data['owner_generation'] as num).toInt(),
    );
  }

  /// Makes this till the owner of a parked bill, under [sessionId], and
  /// stores the whole bill before anyone may edit it.
  Future<Bill> claim(
    String employee,
    String billId, {
    required String sessionId,
  }) async {
    final data = _data(
      await _once(
        'claim',
        billId,
        (op) => till.call(
          employee,
          '/till/bills/$billId/claim',
          body: {'operation_id': op},
        ),
      ),
    );
    final binding = TillBinding.current;
    return BillRepository.instance.adoptClaimed(
      data,
      sessionId: sessionId,
      outletId: binding?.outletId,
      posId: binding?.registerId,
    );
  }

  /// Seats [tableId]. The seating id is chosen and stored here before the
  /// request, so a lost reply retries the same seating; a table already
  /// seated by another till answers `table_busy`.
  Future<TableSeating> seat(
    String employee,
    String tableId, {
    int? guestCount,
  }) async {
    final id = await _operationId('seat', tableId);
    try {
      final data = _data(
        await till.call(
          employee,
          '/till/table-sessions',
          body: {'id': id, 'table_id': tableId, 'guest_count': ?guestCount},
        ),
      );
      await _answered('seat', tableId);
      final seating = TableSeating.fromWire(
        data,
        outletId: TillBinding.current?.outletId,
      );
      await BillRepository.instance.recordSeating(seating);
      return seating;
    } on TillOperationException catch (e) {
      if (e.code != 'network' && e.code != 'server_unavailable') {
        await _answered('seat', tableId);
      }
      rethrow;
    }
  }

  /// Clears a table once none of its bills is still open.
  Future<TableSeating> clear(String employee, String seatingId) async {
    final data = _data(
      await _once(
        'clear',
        seatingId,
        (op) => till.call(
          employee,
          '/till/table-sessions/$seatingId/close',
          body: {'operation_id': op},
        ),
      ),
    );
    final seating = TableSeating.fromWire(
      data,
      outletId: TillBinding.current?.outletId,
    );
    await BillRepository.instance.recordSeating(seating);
    return seating;
  }
}
