import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/account_picker.dart';
import '../../core/localization/l10n.dart';
import '../../core/theme/app_dimensions.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_background.dart';
import '../../core/widgets/brand_mark.dart';
import '../../core/widgets/glass/glass_card.dart';
import '../../core/widgets/pin_pad.dart';
import '../../data/models/employee.dart';
import '../../data/repositories/employee_repository.dart';
import '../../providers/outlet_provider.dart';
import '../../providers/settings_provider.dart';

/// Sign-in, in two steps: pick the account, then type its PIN.
///
/// The PIN identifies WHICH employee is at the till, so every order, receipt
/// and shift is attributed to a real person rather than to a name typed once
/// in Settings. Naming the accounts first is what makes that visible — a bare
/// keypad looks like one shared password, which is the opposite of what the
/// app does.
///
/// The PIN is checked against the *chosen* account, never globally. Otherwise
/// tapping one name and typing another person's PIN would sign that other
/// person in, and the choice would be theatre.
///
/// Seeded PINs: 9999 (Farhan Sabili, owner), 1234 (Siwi Wiyono Raharjo,
/// manager), 2345 and 3456 (cashiers). Which one is used decides what the app
/// shows — the navigation bar, the settings list and the order history all
/// differ.
class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  /// Null on the picker step, set on the keypad step. The only piece of state
  /// that decides which of the two screens is showing.
  Employee? _account;
  String _pin = '';
  bool _error = false;

  void _select(Employee employee) {
    setState(() {
      _account = employee;
      _pin = '';
      _error = false;
    });
  }

  void _clearSelection() {
    setState(() {
      _account = null;
      _pin = '';
      _error = false;
    });
  }

  void _onDigit(String digit) {
    if (_pin.length >= 4) return;
    setState(() {
      _pin += digit;
      _error = false;
    });
    if (_pin.length == 4) _verify();
  }

  void _onBackspace() {
    if (_pin.isEmpty) return;
    setState(() {
      _pin = _pin.substring(0, _pin.length - 1);
      _error = false;
    });
  }

  /// Checks the typed PIN against the chosen account and signs them in.
  Future<void> _verify() async {
    final account = _account;
    if (account == null) return;
    final employee = await EmployeeRepository.instance.verify(
      id: account.id,
      pin: _pin,
    );
    if (!mounted) return;
    if (employee != null) {
      HapticFeedback.lightImpact();
      await ref.read(settingsProvider.notifier).signIn(employee);
    } else {
      HapticFeedback.heavyImpact();
      setState(() {
        _error = true;
        _pin = '';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final design = context.design;
    final outlet = ref.watch(activeOutletProvider).valueOrNull;

    return PopScope(
      // Back on the keypad step returns to the account list rather than doing
      // nothing — this is the root route, so without it "back" is a dead key
      // and the only way out of a wrong choice is the Change button.
      canPop: _account == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _clearSelection();
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.dark,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: AppBackground(
            child: SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 360),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Branding on the picker step only. The keypad step
                        // adds a header card and 300dp of keys; keeping the
                        // logo as well pushed the bottom row of the keypad off
                        // a short screen, and a keypad you have to scroll to
                        // reach is worse than no logo.
                        if (_account == null) ...[
                          SizedBox(
                            width: 88,
                            height: 88,
                            child: GlassCard(
                              padding: EdgeInsets.zero,
                              child: const Center(child: BrandMark(size: 56)),
                            ),
                          ),
                          const SizedBox(height: AppDimensions.space20),
                        ],
                        Text(
                          l10n.authWelcome,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(
                                fontWeight: FontWeight.w800,
                                color: design.textHigh,
                                letterSpacing: -0.3,
                              ),
                        ),
                        const SizedBox(height: AppDimensions.space4),
                        Text(
                          _account == null
                              ? l10n.authChooseAccountHint
                              : l10n.authLoginHint,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: design.textMedium,
                            fontSize: 14,
                          ),
                        ),
                        // Which branch this till belongs to, said BEFORE
                        // anyone signs in. This is the last moment the
                        // information is free: after the first sale, a device
                        // pointed at the wrong shop has already filed takings
                        // in the wrong place and sold off the wrong shelf.
                        if (outlet != null) ...[
                          const SizedBox(height: AppDimensions.space12),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.storefront_rounded,
                                size: 14,
                                color: design.primary,
                              ),
                              const SizedBox(width: 5),
                              Flexible(
                                child: Text(
                                  outlet.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    color: design.primary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                        const SizedBox(height: AppDimensions.space28),
                        if (_account == null)
                          AccountPicker(onSelected: _select)
                        else ...[
                          SelectedAccountHeader(
                            employee: _account!,
                            onChange: _clearSelection,
                          ),
                          const SizedBox(height: AppDimensions.space16),
                          PinPad(
                            pin: _pin,
                            onDigit: _onDigit,
                            onBackspace: _onBackspace,
                            error: _error,
                            errorText: l10n.authWrongPin,
                            trailing: Icon(
                              Icons.fingerprint_rounded,
                              color: design.textMedium,
                            ),
                          ),
                        ],
                        // The "Demo PIN: 1234" badge used to sit here. It was the
                        // loudest thing on the first screen a prospective client
                        // sees, and it announced the app as a mock-up before they
                        // had touched anything. The PIN belongs in the hands of
                        // whoever runs the demo, not on the login screen.
                        // `authDemoPin` stays in the .arb files, unused.
                        const SizedBox(height: AppDimensions.space20),
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
  }
}
