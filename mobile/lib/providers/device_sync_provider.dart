import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/sync/device_sync_controller.dart';

/// The activated till's sync controller, or null in demo mode.
///
/// `BackendApp` overrides it inside the connected store's `ProviderScope`. The
/// demo app never does, so a screen can ask "is there a server at all" without
/// importing the activation layer.
final deviceSyncControllerProvider = Provider<DeviceSyncController?>(
  (ref) => null,
);
