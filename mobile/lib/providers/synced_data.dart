import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'catalog_provider.dart';
import 'employee_provider.dart';
import 'modifier_provider.dart';
import 'order_provider.dart';
import 'pricing_provider.dart';
import 'promo_provider.dart';
import 'stock_provider.dart';
import 'customer_provider.dart';
import 'settings_provider.dart';

/// Re-read synced SQLite rows without resetting the router, session or cart.
/// Also called after a failed pull: earlier pages may already have committed.
void invalidateSyncedData(ProviderContainer container) {
  container.invalidate(categoriesProvider);
  container.invalidate(productsProvider);
  container.invalidate(customersProvider);
  container.invalidate(productVariantsProvider);
  container.invalidate(lowStockProvider);
  container.invalidate(employeesProvider);
  // Pulled stock snapshots and movements change counts and the ledger.
  container.invalidate(stockHistoryProvider);
  // Modifiers, promos and their scoping (Fase 6).
  container.invalidate(modifierGroupsProvider);
  container.invalidate(productModifierGroupsProvider);
  container.invalidate(modifierOptionsByGroupProvider);
  container.invalidate(productModifierGroupsForProvider);
  container.invalidate(modifierOptionsForProvider);
  container.invalidate(productModifierOptionScopeProvider);
  container.invalidate(productModifierDefaultsProvider);
  container.invalidate(productModifierOptionScopeForProvider);
  container.invalidate(promosProvider);
  container.invalidate(activePromosProvider);
  // The floor plan and each table's status.
  container.invalidate(tablesProvider);
  container.invalidate(activeTablesProvider);
  container.invalidate(tableManagementProvider);
  // Business settings, sales types, payment methods, discounts and prices
  // (Fase 3). The cart quote watches this, so it re-prices on its own.
  container.invalidate(pricingContextProvider);
  container.invalidate(serverCandidatesProvider);
  // Apply staff deactivation and role changes to the live principal after the
  // rows above have committed. This intentionally keeps the outbox intact.
  container.read(settingsProvider.notifier).refreshSignedInEmployee();
}
