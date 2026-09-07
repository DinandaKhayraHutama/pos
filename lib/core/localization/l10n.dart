import 'package:flutter/material.dart';

import '../../l10n/gen/app_localizations.dart';

/// Quick access to [AppLocalizations] from any build context.
extension AppLocalizationsX on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this)!;

  Locale get locale => Localizations.localeOf(this);
}

/// Supported locales - single source of truth.
const List<Locale> kSupportedLocales = [Locale('en'), Locale('id')];

const Locale kDefaultLocale = Locale('en');
