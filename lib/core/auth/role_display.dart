/// How a role is shown to a human.
///
/// Kept out of `permissions.dart` so that file stays free of Flutter and of
/// localisation, and kept out of the model so `EmployeeRole` stays a plain
/// enum. Three screens name a role; one switch is better than three.
library;

import 'package:flutter/material.dart';

import '../../data/models/employee.dart';
import '../../l10n/gen/app_localizations.dart';

String roleLabel(AppLocalizations l10n, EmployeeRole role) => switch (role) {
  EmployeeRole.cashier => l10n.employeeRoleCashier,
  EmployeeRole.manager => l10n.employeeRoleManager,
  EmployeeRole.owner => l10n.employeeRoleOwner,
};

IconData roleIcon(EmployeeRole role) => switch (role) {
  EmployeeRole.cashier => Icons.person_outline_rounded,
  EmployeeRole.manager => Icons.manage_accounts_rounded,
  EmployeeRole.owner => Icons.admin_panel_settings_rounded,
};

/// Up to two initials for an avatar. Falls back to a dot rather than rendering
/// an empty circle when the name is blank.
///
/// Shared by the on-duty chip and the account picker so one person is not two
/// different sets of letters depending on which screen you are looking at.
String initialsFor(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty);
  if (parts.isEmpty) return '·';
  return parts.take(2).map((p) => p[0].toUpperCase()).join();
}
