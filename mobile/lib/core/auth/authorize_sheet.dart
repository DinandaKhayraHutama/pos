import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/models/employee.dart';
import '../../data/repositories/employee_repository.dart';
import '../localization/l10n.dart';
import '../theme/app_dimensions.dart';
import '../theme/app_theme.dart';
import '../widgets/glass/glass_sheet.dart';
import '../widgets/pin_pad.dart';
import 'account_picker.dart';
import 'permissions.dart';

/// Asks someone senior to approve an action, without signing anyone out.
///
/// This is the manager-override pattern a real till needs: the cashier stays
/// signed in — their name still belongs on the next sale — and a manager
/// reaches over, types their own PIN, and the one action goes through with
/// their name attached to it. Signing out and back in would be the obvious
/// alternative and it is wrong: it loses the cart, and it attributes the rest
/// of the shift to the wrong person.
///
/// Returns the approving [Employee], or null when dismissed.
Future<Employee?> requestAuthorization(
  BuildContext context, {
  required String reason,
  required AppPermission permission,
}) {
  return showGlassSheet<Employee>(
    context: context,
    builder: (ctx) => _PinPromptSheet(
      title: ctx.l10n.authorizeTitle,
      subtitle: reason,
      icon: Icons.lock_outline_rounded,
      permission: permission,
      deniedMessage: ctx.l10n.authorizeDenied,
      // The approver picks their own account, then types their PIN — the same
      // two steps as sign-in. This used to be a bare keypad resolved with
      // `EmployeeRepository.byPin`, which stopped being safe when PINs stopped
      // being unique (product decision, 2026-09-13): a cashier whose four
      // digits happen to equal a manager's would be "approved" as that
      // manager, and a manager sharing digits with a cashier would be refused.
      // A PIN on its own cannot say who typed it. Only accounts that hold
      // [permission] are listed, so no tile is offered that could not approve.
      pickAccount: true,
      pickSubtitle: ctx.l10n.authorizePickHint,
      accountFilter: (employee) =>
          permissionsFor(employee.role).contains(permission),
    ),
  );
}

/// Hands the till to whoever types their PIN next.
///
/// The multi-cashier case: one device, several people through the day. The
/// person who types their PIN here becomes the name recorded on every
/// subsequent sale, and gets their own shift and their own scoped history.
///
/// Deliberately NOT gated on a permission — any active employee may take the
/// till, which is the whole point. And deliberately not routed through the
/// login screen: that would clear the cart, so a handover mid-order would cost
/// the customer their basket.
///
/// Returns the [Employee] taking over, or null when dismissed.
Future<Employee?> requestCashierSwitch(BuildContext context) {
  return showGlassSheet<Employee>(
    context: context,
    builder: (ctx) => _PinPromptSheet(
      title: ctx.l10n.posSwitchCashier,
      subtitle: ctx.l10n.posSwitchCashierHint,
      pickSubtitle: ctx.l10n.posSwitchCashierPickHint,
      icon: Icons.switch_account_rounded,
      permission: null,
      deniedMessage: ctx.l10n.authWrongPin,
      pickAccount: true,
    ),
  );
}

/// Confirms the SIGNED-IN cashier's own PIN before closing their POS session.
///
/// Deliberately narrower than [requestAuthorization]: there is no account
/// list and no permission check, because the question is not "does this PIN
/// carry enough authority" but "does this PIN belong to [employeeId]
/// specifically" — the same thing sign-in checks. A colleague's own valid PIN
/// is rejected exactly like a wrong one; closing someone else's drawer is not
/// a manager override, it is signing a count that is not this cashier's to
/// sign.
///
/// Returns the confirmed [Employee] once the PIN matches, or null when the
/// cashier backs out — callers must not save the closing cash or close the
/// session on a null result.
Future<Employee?> requestSessionClosePin(
  BuildContext context, {
  required String employeeId,
}) {
  return showGlassSheet<Employee>(
    context: context,
    builder: (ctx) => _PinPromptSheet(
      title: ctx.l10n.shiftCloseConfirmTitle,
      subtitle: ctx.l10n.shiftCloseConfirmHint,
      icon: Icons.lock_outline_rounded,
      permission: null,
      deniedMessage: ctx.l10n.authWrongPin,
      pickAccount: false,
      verifyAgainstEmployeeId: employeeId,
    ),
  );
}

/// The shared PIN prompt behind both entry points.
///
/// One widget rather than two because the difference is a single predicate —
/// "must hold this permission" versus "must simply exist" — and two keypads
/// that behave slightly differently is how people learn to distrust a keypad.
class _PinPromptSheet extends StatefulWidget {
  const _PinPromptSheet({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.permission,
    required this.deniedMessage,
    required this.pickAccount,
    this.pickSubtitle,
    this.verifyAgainstEmployeeId,
    this.accountFilter,
  });

  /// Narrows the picker to the accounts that could pass — for an approval,
  /// those holding [permission]. Ignored when [pickAccount] is false.
  final bool Function(Employee employee)? accountFilter;

  final String title;
  final String subtitle;
  final IconData icon;

  /// Null means any active employee is accepted.
  final AppPermission? permission;

  final String deniedMessage;

  /// When true the sheet opens on the account list and reaches the keypad only
  /// after someone is chosen.
  final bool pickAccount;

  /// Shown instead of [subtitle] on the picker step, where "enter your PIN" is
  /// not yet the instruction. Ignored when [pickAccount] is false.
  final String? pickSubtitle;

  /// When set, the PIN is checked against THIS employee and no one else —
  /// never a picker, and never any other active account's PIN, however valid.
  ///
  /// The re-confirmation case: closing a POS session asks the signed-in
  /// cashier to type their own PIN again, the same way sign-in does. That is
  /// a different question from [permission] ("does whoever typed this PIN
  /// hold the authority") — here the identity itself is what is being
  /// checked, so a colleague's correct PIN has to fail exactly like a wrong
  /// one. Implies [pickAccount] is false.
  final String? verifyAgainstEmployeeId;

  @override
  State<_PinPromptSheet> createState() => _PinPromptSheetState();
}

class _PinPromptSheetState extends State<_PinPromptSheet> {
  Employee? _account;
  String _pin = '';
  bool _error = false;
  bool _busy = false;

  void _onBackspace() {
    if (_pin.isEmpty) return;
    setState(() {
      _pin = _pin.substring(0, _pin.length - 1);
      _error = false;
    });
  }

  Future<void> _onDigit(String digit) async {
    if (_pin.length >= 4 || _busy) return;
    setState(() {
      _pin += digit;
      _error = false;
    });
    if (_pin.length < 4) return;

    final typed = _pin;
    final account = _account;
    final fixedId = widget.verifyAgainstEmployeeId;
    setState(() => _busy = true);
    // Two shapes, one keypad. [fixedId] wins when set — the re-confirmation
    // case, where only that one identity may ever pass. Otherwise the PIN is
    // checked against the chosen account and nobody else. There is no
    // "whoever owns this PIN" path: PINs are not unique, so a bare PIN cannot
    // say who typed it, and a keypad reached without a chosen account refuses.
    final employee = fixedId != null
        ? await EmployeeRepository.instance.verify(id: fixedId, pin: typed)
        : account != null
        ? await EmployeeRepository.instance.verify(id: account.id, pin: typed)
        : null;
    if (!mounted) return;

    // Two separate checks, one message. Whether the PIN is unknown or simply
    // belongs to someone without the authority, saying which would let anyone
    // at the till map out who holds what — and a wrong PIN is the same dead
    // end either way.
    final accepted =
        employee != null &&
        (widget.permission == null ||
            permissionsFor(employee.role).contains(widget.permission));
    if (accepted) {
      HapticFeedback.lightImpact();
      Navigator.of(context).pop(employee);
      return;
    }
    HapticFeedback.heavyImpact();
    setState(() {
      _error = true;
      _pin = '';
      _busy = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    final showPicker = widget.pickAccount && _account == null;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppDimensions.space16,
          AppDimensions.space8,
          AppDimensions.space16,
          AppDimensions.space16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(widget.icon, color: design.primary),
                const SizedBox(width: AppDimensions.space10),
                Expanded(
                  child: Text(
                    widget.title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: design.textHigh,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: Icon(Icons.close_rounded, color: design.textMedium),
                ),
              ],
            ),
            const SizedBox(height: AppDimensions.space4),
            Text(
              showPicker
                  ? (widget.pickSubtitle ?? widget.subtitle)
                  : widget.subtitle,
              style: TextStyle(color: design.textMedium, fontSize: 13),
            ),
            const SizedBox(height: AppDimensions.space20),
            if (showPicker)
              AccountPicker(
                filter: widget.accountFilter,
                onSelected: (e) => setState(() {
                  _account = e;
                  _pin = '';
                  _error = false;
                }),
              )
            else ...[
              if (_account != null) ...[
                SelectedAccountHeader(
                  employee: _account!,
                  onChange: () => setState(() {
                    _account = null;
                    _pin = '';
                    _error = false;
                  }),
                ),
                const SizedBox(height: AppDimensions.space16),
              ],
              PinPad(
                pin: _pin,
                onDigit: _onDigit,
                onBackspace: _onBackspace,
                error: _error,
                errorText: widget.deniedMessage,
              ),
            ],
            const SizedBox(height: AppDimensions.space8),
          ],
        ),
      ),
    );
  }
}
