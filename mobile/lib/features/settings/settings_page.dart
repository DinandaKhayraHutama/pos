import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/permissions.dart';
import '../../core/auth/role_display.dart';
import '../../core/localization/l10n.dart';
import '../../core/pricing/pricing.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimensions.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/glass/glass_app_bar.dart';
import '../../core/widgets/glass/glass_buttons.dart';
import '../../core/widgets/glass/glass_card.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/glass/glass_text_field.dart';
import '../../data/models/sales_config.dart';
import '../../providers/device_sync_provider.dart';
import '../../providers/pricing_provider.dart';
import '../../data/device/till_binding.dart';
import '../../providers/settings_provider.dart';
import 'sync_status_card.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final design = context.design;
    final settings = ref.watch(settingsProvider);

    return settings.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('$e')),
      data: (data) {
        // Once the owner has saved the business settings in the Backoffice,
        // they are the ones in force on a connected till and this device
        // only shows them. Until then the till keeps its own values (D8).
        final businessConfig = TillBinding.current == null
            ? null
            : ref.watch(pricingContextProvider).valueOrNull?.config;
        return Scaffold(
          backgroundColor: Colors.transparent,
          appBar: GlassAppBar(title: l10n.settingsTitle),
          body: ListView(
            padding: const EdgeInsets.all(AppDimensions.space16),
            children: [
              if (TillBinding.current != null) ...[
                Text(l10n.connectedMasterDataNotice),
                const SizedBox(height: AppDimensions.space16),
              ],
              _SectionTitle(text: l10n.settingsAppearance),
              const SizedBox(height: AppDimensions.space8),
              _Card(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Label(text: l10n.settingsTheme),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _ChoiceChip(
                          label: l10n.settingsThemeLight,
                          icon: Icons.light_mode_rounded,
                          selected: data.themeMode == ThemeMode.light,
                          onTap: () => ref
                              .read(settingsProvider.notifier)
                              .setThemeMode(ThemeMode.light),
                        ),
                        _ChoiceChip(
                          label: l10n.settingsThemeDark,
                          icon: Icons.dark_mode_rounded,
                          selected: data.themeMode == ThemeMode.dark,
                          onTap: () => ref
                              .read(settingsProvider.notifier)
                              .setThemeMode(ThemeMode.dark),
                        ),
                        _ChoiceChip(
                          label: l10n.settingsThemeSystem,
                          icon: Icons.brightness_auto_rounded,
                          selected: data.themeMode == ThemeMode.system,
                          onTap: () => ref
                              .read(settingsProvider.notifier)
                              .setThemeMode(ThemeMode.system),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppDimensions.space16),
                    _Label(text: l10n.settingsBrandColor),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: BrandPreset.presets.map((p) {
                        final selected = data.brand.id == p.id;
                        return GestureDetector(
                          onTap: () =>
                              ref.read(settingsProvider.notifier).setBrand(p),
                          child: Tooltip(
                            message: p.name,
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 180),
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                color: p.swatch,
                                shape: BoxShape.circle,
                                border: selected
                                    ? Border.all(
                                        color: design.textHigh,
                                        width: 3,
                                      )
                                    : null,
                                boxShadow: [
                                  BoxShadow(
                                    color: p.swatch.withValues(alpha: 0.3),
                                    blurRadius: 6,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                              ),
                              alignment: Alignment.center,
                              child: selected
                                  ? const Icon(
                                      Icons.check_rounded,
                                      color: Colors.white,
                                      size: 22,
                                    )
                                  : null,
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppDimensions.space16),
              _SectionTitle(text: l10n.settingsLanguage),
              const SizedBox(height: AppDimensions.space8),
              _Card(
                child: Column(
                  children: [
                    _LangTile(
                      code: 'EN',
                      label: l10n.settingsLanguageEn,
                      selected: data.locale.languageCode == 'en',
                      onTap: () => ref
                          .read(settingsProvider.notifier)
                          .setLocale(const Locale('en')),
                    ),
                    const Divider(height: 1),
                    _LangTile(
                      code: 'ID',
                      label: l10n.settingsLanguageId,
                      selected: data.locale.languageCode == 'id',
                      onTap: () => ref
                          .read(settingsProvider.notifier)
                          .setLocale(const Locale('id')),
                    ),
                  ],
                ),
              ),
              if (data.can(AppPermission.manageSettings) &&
                  businessConfig != null) ...[
                const SizedBox(height: AppDimensions.space16),
                _SectionTitle(text: l10n.settingsBusiness),
                const SizedBox(height: AppDimensions.space8),
                _ManagedBusinessCard(config: businessConfig),
              ],
              if (data.can(AppPermission.manageSettings) &&
                  businessConfig == null) ...[
                const SizedBox(height: AppDimensions.space16),
                _SectionTitle(text: l10n.settingsBusiness),
                if (TillBinding.current != null) ...[
                  const SizedBox(height: AppDimensions.space4),
                  Text(
                    l10n.settingsBusinessDeviceOnly,
                    style: TextStyle(fontSize: 12, color: design.textMedium),
                  ),
                ],
                const SizedBox(height: AppDimensions.space8),
                _Card(
                  child: Column(
                    children: [
                      _SettingTile(
                        icon: Icons.storefront_outlined,
                        title: l10n.settingsStoreName,
                        value: data.storeName,
                        onTap: () => _edit(
                          context,
                          ref,
                          initial: data.storeName,
                          label: l10n.settingsStoreName,
                          onSave: (v) => ref
                              .read(settingsProvider.notifier)
                              .setStoreName(v),
                        ),
                      ),
                      const Divider(height: 1),
                      _SettingTile(
                        icon: Icons.location_on_outlined,
                        title: l10n.settingsStoreAddress,
                        value: data.storeAddress,
                        onTap: () => _edit(
                          context,
                          ref,
                          initial: data.storeAddress,
                          label: l10n.settingsStoreAddress,
                          onSave: (v) => ref
                              .read(settingsProvider.notifier)
                              .setStoreAddress(v),
                        ),
                      ),
                      const Divider(height: 1),
                      _SettingTile(
                        icon: Icons.percent_outlined,
                        title: l10n.settingsTaxRate,
                        value:
                            '${data.pb1Rate.toStringAsFixed(data.pb1Rate.truncateToDouble() == data.pb1Rate ? 0 : 1)} %',
                        onTap: () => _editNumber(
                          context,
                          ref,
                          initial: data.pb1Rate,
                          label: l10n.settingsTaxRate,
                          onSave: (v) =>
                              ref.read(settingsProvider.notifier).setPb1Rate(v),
                        ),
                      ),
                      const Divider(height: 1),
                      _SwitchRow(
                        icon: Icons.room_service_outlined,
                        title: l10n.settingsServiceCharge,
                        subtitle: data.serviceChargeEnabled
                            ? l10n.settingsServiceChargeOn
                            : l10n.settingsServiceChargeOff,
                        value: data.serviceChargeEnabled,
                        onChanged: (v) => ref
                            .read(settingsProvider.notifier)
                            .setServiceChargeEnabled(v),
                      ),
                      if (data.serviceChargeEnabled) ...[
                        const Divider(height: 1),
                        _SettingTile(
                          icon: Icons.percent_outlined,
                          title: l10n.settingsServiceChargeRate,
                          value:
                              '${data.serviceChargeRate.toStringAsFixed(data.serviceChargeRate.truncateToDouble() == data.serviceChargeRate ? 0 : 1)} %',
                          onTap: () => _editNumber(
                            context,
                            ref,
                            initial: data.serviceChargeRate,
                            label: l10n.settingsServiceChargeRate,
                            onSave: (v) => ref
                                .read(settingsProvider.notifier)
                                .setServiceChargeRate(v),
                          ),
                        ),
                      ],
                      const Divider(height: 1),
                      _SettingTile(
                        icon: Icons.payments_outlined,
                        title: l10n.settingsCurrency,
                        value: data.currency,
                        onTap: () => _edit(
                          context,
                          ref,
                          initial: data.currency,
                          label: l10n.settingsCurrency,
                          onSave: (v) => ref
                              .read(settingsProvider.notifier)
                              .setCurrency(v),
                        ),
                      ),
                      // Table service used to be a switch here, one answer for
                      // the whole business. It is a per-till setting now — see
                      // the POS / Register screen — because a restaurant can run
                      // a dine-in counter and a takeaway window in one shop, and
                      // a single switch forced both to work the same way.
                    ],
                  ),
                ),
              ],
              // Only on an activated till. The demo has no server, and a card
              // saying "not synced" there would read as something broken.
              if (ref.watch(deviceSyncControllerProvider) case final sync?) ...[
                const SizedBox(height: AppDimensions.space16),
                _SectionTitle(text: l10n.syncTitle),
                const SizedBox(height: AppDimensions.space8),
                SyncStatusCard(controller: sync),
              ],
              const SizedBox(height: AppDimensions.space16),
              _SectionTitle(text: l10n.settingsData),
              const SizedBox(height: AppDimensions.space8),
              // Every row here is permission-gated, so the section's contents
              // differ by role: a cashier sees only their till session, an
              // owner sees the whole back office. Built as a list rather than
              // inline children so the dividers land between whatever
              // survives — hardcoded dividers left a stray hairline at the
              // top of a cashier's card.
              _Card(
                child: Column(
                  children: _divided([
                    if (TillBinding.current == null &&
                        data.can(AppPermission.manageCatalogue))
                      _SettingTile(
                        icon: Icons.inventory_2_outlined,
                        iconColor: design.primary,
                        title: l10n.productManagementTitle,
                        value:
                            '${l10n.productAdd} · ${l10n.categoryManagementTitle}',
                        // Go through the router, not a raw Navigator.push: the
                        // `/products` GoRoute already exists. Pushing a bare
                        // MaterialPageRoute left the URL on /settings, so on
                        // web the browser recorded no history entry and Back
                        // skipped straight past Settings to whichever tab came
                        // before it. It also bypassed the shared transition.
                        onTap: () => context.push('/products'),
                      ),
                    if (data.can(AppPermission.adjustStock))
                      _SettingTile(
                        icon: Icons.warehouse_outlined,
                        iconColor: design.warning,
                        title: l10n.inventoryTitle,
                        value: l10n.inventoryManage,
                        onTap: () => context.push('/inventory'),
                      ),
                    if (TillBinding.current == null &&
                        data.can(AppPermission.managePromos))
                      _SettingTile(
                        icon: Icons.local_offer_outlined,
                        iconColor: design.tertiary,
                        title: l10n.promosTitle,
                        value: l10n.promosManage,
                        onTap: () => context.push('/promos'),
                      ),
                    if (data.can(AppPermission.viewFinancialReports))
                      _SettingTile(
                        icon: Icons.assessment_outlined,
                        iconColor: design.info,
                        title: l10n.reportTitle,
                        value: l10n.reportExport,
                        onTap: () => context.push('/report'),
                      ),
                    if (data.can(AppPermission.openCloseShift))
                      _SettingTile(
                        icon: Icons.point_of_sale_rounded,
                        iconColor: design.success,
                        title: l10n.shiftTitle,
                        value: l10n.shiftHistory,
                        onTap: () => context.push('/shift'),
                      ),
                    if (TillBinding.current == null &&
                        data.can(AppPermission.manageOutlets))
                      _SettingTile(
                        icon: Icons.store_mall_directory_outlined,
                        iconColor: design.primary,
                        title: l10n.outletsTitle,
                        value: l10n.outletsSubtitle,
                        onTap: () => context.push('/outlets'),
                      ),
                    // Same permission as outlets: whoever runs more than one
                    // shop is who decides how many tills each one has and what
                    // each is for. No separate permission, because the holder
                    // set would be identical and a second row in the table is
                    // a second thing to keep in step.
                    if (TillBinding.current == null &&
                        data.can(AppPermission.manageOutlets))
                      _SettingTile(
                        icon: Icons.point_of_sale_outlined,
                        iconColor: design.info,
                        title: l10n.registersTitle,
                        value: l10n.registersSubtitle,
                        onTap: () => context.push('/registers'),
                      ),
                    if (TillBinding.current == null &&
                        data.can(AppPermission.manageEmployees))
                      _SettingTile(
                        icon: Icons.badge_outlined,
                        iconColor: design.secondary,
                        title: l10n.employeesTitle,
                        value: l10n.employeesManage,
                        onTap: () => context.push('/employees'),
                      ),
                    if (TillBinding.current == null &&
                        data.can(AppPermission.manageSettings))
                      _SettingTile(
                        icon: Icons.restart_alt_rounded,
                        iconColor: design.tertiary,
                        title: l10n.settingsResetDemoData,
                        value: l10n.settingsResetConfirmBody,
                        onTap: () => _confirmReset(context, ref),
                      ),
                  ]),
                ),
              ),
              const SizedBox(height: AppDimensions.space16),
              _SectionTitle(text: l10n.settingsAbout),
              const SizedBox(height: AppDimensions.space8),
              _Card(
                child: Column(
                  children: [
                    // Who the app thinks you are. Without it, a cashier who
                    // finds the catalogue missing has no way to tell whether
                    // the feature is absent or simply not theirs.
                    _SettingTile(
                      icon: roleIcon(data.employeeRole),
                      iconColor: design.primary,
                      title: l10n.settingsSignedInAs,
                      value:
                          '${data.cashierName} · ${roleLabel(l10n, data.employeeRole)}',
                    ),
                    const Divider(height: 1),
                    _SettingTile(
                      icon: Icons.person_outline_rounded,
                      title: l10n.settingsProfile,
                      value: data.cashierName,
                      onTap: () => _edit(
                        context,
                        ref,
                        initial: data.cashierName,
                        label: l10n.settingsProfile,
                        onSave: (v) => ref
                            .read(settingsProvider.notifier)
                            .setCashierName(v),
                      ),
                    ),
                    const Divider(height: 1),
                    _SettingTile(
                      icon: Icons.info_outline_rounded,
                      title: l10n.settingsVersion,
                      value: '1.0.0',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppDimensions.space20),
              DangerButton(
                onPressed: () => _handleLogout(context, ref, data),
                child: Text(l10n.settingsLogout),
              ),
              const SizedBox(height: AppDimensions.space20),
            ],
          ),
        );
      },
    );
  }

  /// Interleaves hairline dividers between whatever rows survived their
  /// permission checks. Hardcoding a `Divider` after each tile left a stray
  /// line at the top or bottom of a card whenever a role hid the neighbour.
  static List<Widget> _divided(List<Widget> tiles) => [
    for (var i = 0; i < tiles.length; i++) ...[
      if (i > 0) const Divider(height: 1),
      tiles[i],
    ],
  ];

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref, {
    required String initial,
    required String label,
    required ValueChanged<String> onSave,
  }) async {
    final ctrl = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      // Named, not discarded: `showDialog` defaults to pushing onto the ROOT
      // navigator, while this page's own `context` sits inside MainShell's
      // ShellRoute NESTED navigator. `Navigator.of(context).pop()` — using
      // the outer context — resolved to that nested navigator instead of the
      // one actually holding this dialog, which had nothing else to pop and
      // corrupted the shell's own routing (a blank/black screen either way
      // the button was tapped). `Navigator.of(dialogContext)` is scoped to
      // the dialog's own route, so it is unambiguous regardless of which
      // navigator `showDialog` used.
      builder: (dialogContext) => AlertDialog(
        title: Text(label),
        content: GlassTextField(
          controller: ctrl,
          label: label,
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(context.l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(ctrl.text.trim()),
            child: Text(context.l10n.commonSave),
          ),
        ],
      ),
    );
    if (result != null && result.isNotEmpty) onSave(result);
  }

  Future<void> _editNumber(
    BuildContext context,
    WidgetRef ref, {
    required double initial,
    required String label,
    required ValueChanged<double> onSave,
    double min = 0,
  }) async {
    final ctrl = TextEditingController(text: initial.toStringAsFixed(1));
    final result = await showDialog<String>(
      context: context,
      // See the identical comment in `_edit` above — same navigator mismatch.
      builder: (dialogContext) => AlertDialog(
        title: Text(label),
        content: GlassTextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(context.l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(ctrl.text),
            child: Text(context.l10n.commonSave),
          ),
        ],
      ),
    );
    if (result != null) {
      final v = double.tryParse(result);
      if (v != null && v >= min) onSave(v);
    }
  }

  /// Logs out — unless this device still holds an open POS session.
  ///
  /// A session left open by a sign-out is a drawer nobody is answerable for
  /// until someone signs back in to count it, so logout is refused outright
  /// rather than quietly clearing the device's pointer to it (which is what
  /// used to happen). The dialog says why and offers the one path that
  /// actually unblocks it — closing the session — rather than leaving the
  /// cashier to work out on their own that Shift is where they need to go.
  ///
  /// The handover flow (the on-duty chip) is untouched: it never calls
  /// [logout] at all, so this gate does not sit in its way.
  Future<void> _handleLogout(
    BuildContext context,
    WidgetRef ref,
    SettingsState data,
  ) async {
    if (!data.hasPosSession) {
      await ref.read(settingsProvider.notifier).logout();
      return;
    }
    final l10n = context.l10n;
    final goToSession = await showDialog<bool>(
      context: context,
      // See the comment in `_edit` above — same navigator mismatch.
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.settingsLogoutBlockedTitle),
        content: Text(l10n.settingsLogoutBlockedBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.settingsLogoutBlockedAction),
          ),
        ],
      ),
    );
    if (goToSession == true && context.mounted) {
      context.push('/shift');
    }
  }

  Future<void> _confirmReset(BuildContext context, WidgetRef ref) async {
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      // See the comment in `_edit` above — same navigator mismatch.
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.settingsResetConfirm),
        content: Text(l10n.settingsResetConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.commonConfirm),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(settingsProvider.notifier).resetDemoData();
      ref.invalidate(settingsProvider);
    }
  }
}

// ---------------------------------------------------------------------------
// Reusable building blocks
// ---------------------------------------------------------------------------

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    return Padding(
      padding: const EdgeInsets.only(left: AppDimensions.space4),
      child: Text(
        text,
        style: TextStyle(
          color: design.textMedium,
          fontSize: 12,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    return Text(
      text,
      style: TextStyle(
        color: design.textMedium,
        fontSize: 12,
        fontWeight: FontWeight.w700,
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return GlassCard.solid(
      padding: const EdgeInsets.symmetric(
        horizontal: AppDimensions.space16,
        vertical: AppDimensions.space12,
      ),
      child: child,
    );
  }
}

class _SettingTile extends StatelessWidget {
  const _SettingTile({
    required this.icon,
    required this.title,
    required this.value,
    this.onTap,
    this.iconColor,
  });

  final IconData icon;
  final String title;
  final String value;
  final VoidCallback? onTap;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppDimensions.radius8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Row(
          children: [
            Icon(icon, size: 20, color: iconColor ?? design.textMedium),
            const SizedBox(width: AppDimensions.space12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: design.textHigh,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    value,
                    style: TextStyle(fontSize: 12, color: design.textMedium),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            // Only where there is somewhere to go. A chevron on a read-only
            // row — the version, or who you are signed in as — is an
            // affordance that does nothing, and the tap it invites is the
            // user's first impression that the app is unresponsive.
            if (onTap != null) ...[
              const SizedBox(width: 8),
              Icon(
                Icons.chevron_right_rounded,
                color: design.textLow,
                size: 20,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A toggle row for a boolean setting — same icon/title/subtitle layout as
/// [_SettingTile], but with a trailing [Switch] instead of a chevron. Mirrors
/// `register_management_page.dart`'s private `_SwitchRow` (not reused
/// directly — that one is private to its own file) so a per-till toggle and
/// a business-wide one read as the same control everywhere they appear.
class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.icon,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
      child: Row(
        children: [
          Icon(icon, size: 20, color: design.textMedium),
          const SizedBox(width: AppDimensions.space12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: design.textHigh,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: TextStyle(fontSize: 12, color: design.textMedium),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _LangTile extends StatelessWidget {
  const _LangTile({
    required this.code,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  /// Two-letter language code shown as a badge. A flag emoji was used here
  /// before, but emoji do not render on every platform - and a flag stands for
  /// a country, not a language.
  final String code;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppDimensions.radius8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Row(
          children: [
            Container(
              width: 30,
              height: 22,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: design.surfaceOverlay,
                borderRadius: BorderRadius.circular(AppDimensions.radius8),
              ),
              child: Text(
                code,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: design.textMedium,
                ),
              ),
            ),
            const SizedBox(width: AppDimensions.space12),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: design.textHigh,
                ),
              ),
            ),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: selected
                  ? Icon(
                      Icons.check_circle_rounded,
                      color: design.primary,
                      size: 22,
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChoiceChip extends StatelessWidget {
  const _ChoiceChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    return Material(
      color: selected
          ? design.primary
          : design.glassTint.withValues(alpha: design.glassOpacity),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 16,
                color: selected ? design.onPrimary : design.textMedium,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: selected ? design.onPrimary : design.textMedium,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The business settings as the Backoffice set them, shown and not edited:
/// on a connected till whose owner has saved them, they are the ones in force.
class _ManagedBusinessCard extends StatelessWidget {
  const _ManagedBusinessCard({required this.config});
  final EffectiveBusinessConfig config;

  static String _percent(int bp) =>
      bp % 100 == 0 ? '${bp ~/ 100} %' : '${(bp / 100).toStringAsFixed(2)} %';

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final design = context.design;
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(AppDimensions.space12),
            child: Text(
              l10n.settingsBusinessManaged,
              style: TextStyle(fontSize: 12, color: design.textMedium),
            ),
          ),
          const Divider(height: 1),
          _SettingTile(
            icon: Icons.percent_outlined,
            title: l10n.settingsTaxRate,
            value: _percent(config.taxRateBp),
          ),
          const Divider(height: 1),
          _SettingTile(
            icon: Icons.receipt_long_outlined,
            title: l10n.settingsTaxMode,
            value: config.taxMode == TaxMode.inclusive
                ? l10n.settingsTaxModeInclusive
                : l10n.settingsTaxModeExclusive,
          ),
          const Divider(height: 1),
          _SettingTile(
            icon: Icons.room_service_outlined,
            title: l10n.settingsServiceCharge,
            value: config.serviceRateBp == 0
                ? l10n.settingsServiceChargeOff
                : _percent(config.serviceRateBp),
          ),
          const Divider(height: 1),
          _SettingTile(
            icon: Icons.price_change_outlined,
            title: l10n.posRounding,
            value: config.roundingUnit == 0
                ? l10n.settingsRoundingNone
                : MoneyFormatter.format(config.roundingUnit),
          ),
        ],
      ),
    );
  }
}
