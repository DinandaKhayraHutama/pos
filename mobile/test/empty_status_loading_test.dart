import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nti_pos/core/localization/l10n.dart';
import 'package:nti_pos/core/theme/app_colors.dart';
import 'package:nti_pos/core/theme/app_theme.dart';
import 'package:nti_pos/core/widgets/empty_state.dart';
import 'package:nti_pos/core/widgets/glass/glass_card.dart';
import 'package:nti_pos/core/widgets/loading_indicator.dart';
import 'package:nti_pos/core/widgets/status_badge.dart';
import 'package:nti_pos/data/models/enums.dart';
import 'package:nti_pos/l10n/gen/app_localizations.dart';

void main() {
  testWidgets('EmptyState renders title + a GlassCard', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(BrandPreset.presets.first),
        supportedLocales: kSupportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: const Scaffold(
          body: EmptyState(
            icon: Icons.search_off_rounded,
            title: 'Nothing',
            subtitle: 'try again',
          ),
        ),
      ),
    );
    expect(find.text('Nothing'), findsOneWidget);
    expect(find.byIcon(Icons.search_off_rounded), findsOneWidget);
    expect(find.byType(GlassCard), findsOneWidget);
  });

  testWidgets('StatusBadge renders for an order status', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(BrandPreset.presets.first),
        supportedLocales: kSupportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: const Scaffold(body: StatusBadge(status: OrderStatus.paid)),
      ),
    );
    expect(find.byType(StatusBadge), findsOneWidget);
    expect(find.byType(Text), findsWidgets);
  });

  testWidgets('LoadingIndicator still renders', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(BrandPreset.presets.first),
        home: const Scaffold(body: LoadingIndicator()),
      ),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
