import 'package:flutter/widgets.dart';
import '../../data/device/till_coordinator.dart';
import 'l10n.dart';

String tillErrorMessage(BuildContext context, TillOperationException error) => switch(error.code) {
  'register_busy' => context.l10n.tillRegisterBusy,
  'cashier_busy' => context.l10n.tillCashierBusy,
  'sync_before_handover' => context.l10n.tillSyncRequired,
  'cashier_auth_required' || 'cashier_required' => context.l10n.tillLoginRequired,
  'session_not_confirmed' || 'session_closed' || 'session_not_owned' => context.l10n.tillSessionUnconfirmed,
  _ => context.l10n.tillOnlineRequired,
};
