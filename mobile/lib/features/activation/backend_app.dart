import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/localization/l10n.dart';
import '../../core/theme/app_dimensions.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_background.dart';
import '../../core/widgets/brand_mark.dart';
import '../../core/widgets/glass/glass_card.dart';
import '../../data/device/connected_storage.dart';
import '../../data/device/device_activation_repository.dart';
import '../../data/device/device_registration.dart';
import '../../data/preferences/app_preferences.dart';
import '../../data/sync/device_sync_controller.dart';
import '../../data/sync/device_sync_runner.dart';
import '../../data/sync/sync_scheduler.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../providers/device_sync_provider.dart';
import '../../providers/synced_data.dart';

/// The complete v2 API root, e.g. `https://pos.example.com/api/v2`.
const backendApiUrl = String.fromEnvironment('API_BASE_URL');

/// Activation precedes all settings/PIN/database providers. Revocation disposes
/// the whole connected provider container; no signed-in cashier state survives.
class BackendApp extends StatefulWidget {
  const BackendApp({
    super.key,
    required this.initialPreferences,
    required this.appBuilder,
  });
  final AppPreferences initialPreferences;
  final Widget Function(AppPreferences preferences) appBuilder;

  @override
  State<BackendApp> createState() => _BackendAppState();
}

class _BackendAppState extends State<BackendApp> with WidgetsBindingObserver {
  final _code = TextEditingController();
  DeviceActivationRepository? _repository;
  DeviceRegistration? _binding;
  AppPreferences? _preferences;
  ActivationFailure? _failure;
  bool _busy = true;
  bool _entered = false;
  bool _checking = false;
  DeviceSyncController? _sync;
  final _scopeContextKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // No periodic `/devices/me` poll. Revocation shows up as a 401 on the next
    // sync, and a binding change as a new `device_revision` in `/sync/changes`
    // — fifteen thousand tills asking every thirty seconds bought nothing.
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      _repository ??= DeviceActivationRepository(baseUrl: backendApiUrl);
      final binding = await _repository!.load();
      if (binding != null) {
        // No `/devices/me` here. A launch with an unexpired binding opens its
        // own store offline-first, and its first request of any kind waits out
        // the startup spread. Revocation arrives as a 401 on that first sync;
        // a changed binding as a new `device_revision` in `/sync/changes`,
        // which triggers exactly one check.
        await _accept(binding, justActivated: false);
      }
    } on DeviceActivationException catch (e) {
      if (mounted) setState(() => _failure = e.failure);
    } catch (_) {
      if (mounted) setState(() => _failure = ActivationFailure.storage);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _activate() async {
    if (_repository == null) return;
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      final binding = await _repository!.activate(
        _code.text,
        platform: kIsWeb ? 'web' : defaultTargetPlatform.name,
      );
      _code.clear();
      await _accept(binding, justActivated: true);
    } on DeviceActivationException catch (e) {
      if (mounted) setState(() => _failure = e.failure);
    } catch (_) {
      if (mounted) setState(() => _failure = ActivationFailure.storage);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _accept(
    DeviceRegistration binding, {
    required bool justActivated,
  }) async {
    final preferences = await prepareConnectedStorage(binding);

    _sync?.dispose();
    final sync = DeviceSyncController(
      // A revoked device cannot be fixed by retrying, so drop straight back to
      // the activation screen rather than spinning on a token nobody honours.
      runner: DeviceSyncRunner(binding: binding, onUnauthorized: _revoked),
      reconnections: connectivityRegained(),
      onDeviceRevisionChanged: _verify,
      onDataChanged: _refreshSyncedData,
    );
    _sync = sync;

    if (mounted) {
      setState(() {
        _binding = binding;
        _preferences = preferences;
      });
    }

    if (justActivated) {
      // Awaited deliberately rather than fired and forgotten: a device that has
      // just activated has an empty catalogue and no server-issued staff, so
      // going straight to a PIN screen would show an empty till and no one to
      // sign in as. A failure here does not block entry.
      sync.start(initialDelay: const Duration(minutes: 1));
      await sync.syncNow();
    } else {
      // A launch with a saved binding already holds its catalogue. Its first
      // sync waits hash(device_id) mod 300 seconds, so a whole fleet opening at
      // eight o'clock is a five-minute ramp rather than one spike. Resuming the
      // app or regaining a network still nudges a sync sooner.
      sync.start(initialDelay: startupSpreadFor(binding.deviceId));
    }
  }

  /// Pulled rows were written; mounted screens re-read them without resetting
  /// the router, cashier session or cart.
  void _refreshSyncedData() {
    if (!mounted || _binding == null) return;
    final scopeContext = _scopeContextKey.currentContext;
    if (scopeContext != null && scopeContext.mounted) {
      invalidateSyncedData(
        ProviderScope.containerOf(scopeContext, listen: false),
      );
    }
  }

  void _revoked() {
    if (!mounted) return;
    final previous = _sync;
    _sync = null;
    setState(() {
      _binding = null;
      _entered = false;
      _failure = ActivationFailure.revoked;
    });
    // Disposed after the frame that unmounts the connected scope, so nothing
    // still listening to it is handed a disposed notifier.
    WidgetsBinding.instance.addPostFrameCallback((_) => previous?.dispose());
  }

  /// Fetches, stores and adopts the refreshed binding. Only ever called from a
  /// sync that saw a new `device_revision`, so it sits inside the startup
  /// spread and behind the shared `Retry-After` gate like every other request.
  ///
  /// The refreshed binding replaces the one in memory and — inside
  /// `verify` — the one in secure storage, so the next launch starts from it.
  /// The outlet and register ROWS are not touched: their feeds own them.
  Future<bool> _verify() async {
    final binding = _binding;
    final repository = _repository;
    if (binding == null || repository == null || _checking) return false;
    _checking = true;
    try {
      final refreshed = await repository.verify(binding, gate: _sync?.gate);
      if (mounted && _binding?.storageScope == refreshed.storageScope) {
        setState(() => _binding = refreshed);
      }
      return true;
    } on DeviceActivationException catch (e) {
      if (e.failure == ActivationFailure.revoked) _revoked();
      return false;
    } catch (_) {
      // Storage/network failures retain this merchant's data for recovery.
      return false;
    } finally {
      _checking = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;

    // Coming back to the app is the moment a price changed overnight is most
    // likely to matter, and the cheapest one to catch it. Debounced by the
    // scheduler, bounded by the startup spread and `Retry-After`; the till
    // stays usable while it runs. No direct `/devices/me`: the sync's
    // `device_revision` decides whether that request is needed.
    _sync?.nudge();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _repository?.close();
    _sync?.dispose();
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_binding != null && _entered) {
      return ProviderScope(
        key: ValueKey(_binding!.storageScope),
        overrides: [deviceSyncControllerProvider.overrideWithValue(_sync)],
        child: Builder(
          key: _scopeContextKey,
          builder: (_) => widget.appBuilder(_preferences!),
        ),
      );
    }
    final prefs = widget.initialPreferences;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(prefs.brand),
      darkTheme: AppTheme.dark(prefs.brand),
      themeMode: prefs.themeMode,
      locale: prefs.locale,
      supportedLocales: kSupportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: Builder(
        builder: (context) {
          final l10n = context.l10n;
          final binding = _binding;
          return Scaffold(
            body: AppBackground(
              child: SafeArea(
                child: Center(
                  child: SingleChildScrollView(
                    padding: AppDimensions.screenPadding,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxWidth: AppDimensions.phoneWidth,
                      ),
                      child: GlassCard(
                        child: Padding(
                          padding: const EdgeInsets.all(AppDimensions.space24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const Center(child: BrandMark.plated(size: 72)),
                              const SizedBox(height: AppDimensions.space24),
                              Text(
                                binding == null
                                    ? l10n.activationTitle
                                    : l10n.activationComplete,
                                style: Theme.of(
                                  context,
                                ).textTheme.headlineSmall,
                              ),
                              const SizedBox(height: AppDimensions.space12),
                              if (binding == null) ...[
                                Text(l10n.activationInstructions),
                                const SizedBox(height: AppDimensions.space16),
                                TextField(
                                  controller: _code,
                                  enabled: !_busy,
                                  textCapitalization:
                                      TextCapitalization.characters,
                                  autocorrect: false,
                                  enableSuggestions: false,
                                  maxLength: 16,
                                  onSubmitted: (_) =>
                                      _busy ? null : _activate(),
                                  decoration: InputDecoration(
                                    labelText: l10n.activationCodeLabel,
                                  ),
                                ),
                              ] else ...[
                                Text(
                                  binding.tenant['name'] as String,
                                  style: Theme.of(context).textTheme.titleLarge,
                                ),
                                Text(
                                  '${binding.outlet['name']} · ${binding.register['name']}',
                                ),
                                const SizedBox(height: AppDimensions.space16),
                                Text(l10n.activationNextPhase),
                              ],
                              if (_failure != null)
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: AppDimensions.space12,
                                  ),
                                  child: Text(
                                    switch (_failure!) {
                                      ActivationFailure.invalidCode =>
                                        l10n.activationInvalid,
                                      ActivationFailure.rateLimited =>
                                        l10n.activationRateLimited,
                                      ActivationFailure.network =>
                                        l10n.activationNetwork,
                                      ActivationFailure.storage =>
                                        l10n.activationStorage,
                                      ActivationFailure.revoked =>
                                        l10n.activationRevoked,
                                      ActivationFailure.configuration =>
                                        l10n.activationConfiguration,
                                    },
                                    style: TextStyle(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.error,
                                    ),
                                  ),
                                ),
                              const SizedBox(height: AppDimensions.space16),
                              if (_busy)
                                const Center(child: CircularProgressIndicator())
                              else if (binding != null)
                                FilledButton(
                                  onPressed: () =>
                                      setState(() => _entered = true),
                                  child: Text(l10n.activationContinue),
                                )
                              else ...[
                                FilledButton(
                                  onPressed: _repository == null
                                      ? null
                                      : _activate,
                                  child: Text(l10n.activationSubmit),
                                ),
                                TextButton(
                                  onPressed: _load,
                                  child: Text(l10n.activationRetry),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
