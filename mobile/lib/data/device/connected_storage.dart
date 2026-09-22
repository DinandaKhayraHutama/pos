import 'package:sqflite/sqflite.dart';

import '../database/app_database.dart';
import '../preferences/app_preferences.dart';
import 'device_registration.dart';
import 'till_binding.dart';
import 'till_coordinator.dart';

/// Activation opens a store of this merchant's own, and it starts EMPTY.
///
/// The namespace is separate — a different merchant, or the demo, keeps its own
/// database file and preference keys — so activating never overwrites what was
/// there. The demo store is untouched and still holds its full seeded month.
///
/// **Nothing is copied in from the demo.** An earlier version did copy it, and
/// that is what produced duplicated staff and a doubled catalogue: the demo
/// rows carry hand-written ids (`emp_owner`, `cat_food`, `p_nasi_goreng`) while
/// the server sends UUIDs, so `UPDATE … WHERE id = <uuid>` never matched a
/// copied row and the sync inserted a second one for the same person or dish.
/// Two id spaces that can never meet cannot be reconciled after the fact.
///
/// So the rule is simply: the server owns master data, and a connected till
/// gets it by syncing. Only the bound outlet and register are seeded locally,
/// because a device has to know which till it is before its first pull.
Future<AppPreferences> prepareConnectedStorage(
  DeviceRegistration binding,
) async {
  await AppDatabase.instance.configureConnectedStore(binding.storageScope);
  TillCoordinator.current?.client.close();
  TillCoordinator.current = TillCoordinator(binding);
  AppPreferences.configureScope(binding.storageScope);
  TillBinding.configure(
    TillBinding(
      outletId: binding.outlet['id'] as String,
      registerId: binding.register['id'] as String,
    ),
  );
  final prefs = await AppPreferences.instance();

  await seedBindingRows(binding);
  await prefs.setOutletId(binding.outlet['id'] as String);
  await prefs.setStoreName(binding.tenant['name'] as String);
  return prefs;
}

/// Writes the bound outlet and register only when this store has no row for
/// them yet.
///
/// **Insert, never overwrite.** Once the `outlets` and `pos_registers` feeds
/// have delivered these rows they are newer than any binding held in secure
/// storage, and the feed's cursor has already moved past them. Replacing them
/// with the stored binding on every launch put an old register name or
/// table-service setting back, and nothing would ever send the newer one again.
Future<void> seedBindingRows(DeviceRegistration binding) async {
  final db = await AppDatabase.instance.db;
  await db.insert('outlets', {
    'id': binding.outlet['id'],
    'name': binding.outlet['name'],
    'address': binding.outlet['address'] as String? ?? '',
    'active': 1,
    'sort_order': 0,
  }, conflictAlgorithm: ConflictAlgorithm.ignore);
  await db.insert('pos_registers', {
    'id': binding.register['id'],
    'outlet_id': binding.outlet['id'],
    'name': binding.register['name'],
    'table_service': binding.register['table_service'] == true ? 1 : 0,
    'active': 1,
    'sort_order': 0,
  }, conflictAlgorithm: ConflictAlgorithm.ignore);
}
