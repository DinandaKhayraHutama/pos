import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/localization/l10n.dart';
import '../../core/print/print_receipt.dart';
import '../../core/theme/app_dimensions.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/brand_colors.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/glass/glass_buttons.dart';
import '../../core/widgets/glass/glass_card.dart';
import '../../core/widgets/glass/glass_chip.dart';
import '../../core/widgets/glass/glass_sheet.dart';
import '../../core/widgets/glass/glass_text_field.dart';
import '../../core/widgets/segmented_selector.dart';
import '../../data/device/till_binding.dart';
import '../../data/models/employee.dart';
import '../../data/models/enums.dart';
import '../../data/models/order.dart';
import '../../data/models/sales_config.dart';
import '../../data/repositories/sales_config_repository.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../providers/cart_provider.dart';
import '../../providers/order_provider.dart';
import '../../providers/pricing_provider.dart';
import '../../providers/settings_provider.dart';
import '../../core/widgets/app_snack_bar.dart';

/// Final payment confirmation. Handles the order placement and shows the
/// success receipt.
class CheckoutSheet extends ConsumerStatefulWidget {
  const CheckoutSheet({super.key});

  @override
  ConsumerState<CheckoutSheet> createState() => _CheckoutSheetState();
}

class _CheckoutSheetState extends ConsumerState<CheckoutSheet> {
  PaymentMethod _method = PaymentMethod.cash;
  String? _paymentMethodId;

  /// The server picked on this sheet; null until the cashier picks one, when
  /// the cart's own choice or the signed-in cashier stands in.
  String? _servedById;
  final _amountCtrl = TextEditingController();
  final _referenceCtrl = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Typing, tapping a quick-cash chip, and tapping the exact-cash button
    // all mutate `_amountCtrl.text`; without a listener the change row, the
    // chip `selected` state, and the exact-cash feedback never rebuilt.
    _amountCtrl.addListener(_onAmountChanged);
  }

  void _onAmountChanged() => setState(() {});

  @override
  void dispose() {
    _amountCtrl.removeListener(_onAmountChanged);
    _amountCtrl.dispose();
    _referenceCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final design = context.design;
    final settings = ref.watch(settingsProvider).valueOrNull;
    // The same quote the cart panel showed and the order will record.
    final total = ref.watch(cartQuoteProvider).result.total;
    final pricing =
        ref.watch(pricingContextProvider).valueOrNull ?? PricingContext.empty;
    final methods = pricing.paymentMethods;
    final selectedMethod = _selectedMethod(methods);
    final servers = pricing.trackServer
        ? ref.watch(serverCandidatesProvider).valueOrNull ?? const <Employee>[]
        : const <Employee>[];
    final servedById =
        _servedById ??
        ref.watch(cartProvider).servedById ??
        settings?.employeeId;
    final paid = _paidValue(total);
    final change = paid - total;

    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(
          left: AppDimensions.space16,
          right: AppDimensions.space16,
          bottom:
              MediaQuery.of(context).viewInsets.bottom + AppDimensions.space16,
          top: AppDimensions.space8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  l10n.posCheckout,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: design.textHigh,
                  ),
                ),
                const Spacer(),
                IconButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: Icon(Icons.close_rounded, color: design.textMedium),
                ),
              ],
            ),
            const SizedBox(height: AppDimensions.space8),
            // A full-strength brand fill, said out loud. It used to ask for
            // `primaryContainer` and get the saturated colour anyway through
            // the alpha bug — so the intent and the paint now agree, and the
            // text uses the foreground token that belongs to a primary fill.
            GlassCard.solid(
              tint: design.primary,
              child: Column(
                children: [
                  Text(
                    l10n.posTotal,
                    style: TextStyle(
                      color: design.onPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    MoneyFormatter.format(total),
                    style: TextStyle(
                      fontSize: 34,
                      fontWeight: FontWeight.w900,
                      color: design.onPrimary,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppDimensions.space16),
            Text(
              l10n.posPaymentMethod,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: design.textMedium,
              ),
            ),
            const SizedBox(height: 8),
            if (methods.isEmpty)
              SegmentedSelector<PaymentMethod>(
                value: _method,
                onChanged: (v) => setState(() {
                  _method = v;
                  if (v != PaymentMethod.cash) _amountCtrl.clear();
                }),
                segments: [
                  Segment(
                    value: PaymentMethod.cash,
                    label: l10n.posCash,
                    icon: Icons.payments_rounded,
                  ),
                  Segment(
                    value: PaymentMethod.qris,
                    label: l10n.posQris,
                    icon: Icons.qr_code_rounded,
                  ),
                  Segment(
                    value: PaymentMethod.card,
                    label: l10n.posCard,
                    icon: Icons.credit_card_rounded,
                  ),
                ],
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final method in methods)
                    ChoiceChip(
                      label: Text(method.name),
                      selected: selectedMethod?.id == method.id,
                      onSelected: (_) => setState(() {
                        _paymentMethodId = method.id;
                        _method = PaymentMethodX.fromWire(method.kind);
                        _referenceCtrl.clear();
                        if (_method != PaymentMethod.cash) _amountCtrl.clear();
                      }),
                    ),
                ],
              ),
            if (_method != PaymentMethod.cash) ...[
              const SizedBox(height: AppDimensions.space8),
              Text(
                l10n.posPaymentManual,
                style: TextStyle(fontSize: 12, color: design.textMedium),
              ),
            ],
            if (selectedMethod?.requiresReference == true) ...[
              const SizedBox(height: AppDimensions.space14),
              GlassTextField(
                controller: _referenceCtrl,
                hint: l10n.posPaymentReference,
                prefix: Icons.tag_rounded,
              ),
            ],
            if (servers.isNotEmpty) ...[
              const SizedBox(height: AppDimensions.space14),
              Text(
                l10n.posServedBy,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: design.textMedium,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final server in servers)
                    ChoiceChip(
                      label: Text(server.name),
                      selected: servedById == server.id,
                      onSelected: (_) =>
                          setState(() => _servedById = server.id),
                    ),
                ],
              ),
            ],
            if (_method == PaymentMethod.cash) ...[
              const SizedBox(height: AppDimensions.space14),
              GlassTextField(
                controller: _amountCtrl,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                hint: l10n.posAmountPaid,
                prefix: Icons.payments_rounded,
                prefixText: '${settings?.currency ?? 'Rp'} ',
                suffix: IconButton(
                  icon: Icon(Icons.check_circle_rounded, color: design.primary),
                  onPressed: () {
                    _amountCtrl.text = total.toString();
                    _amountCtrl.selection = TextSelection.fromPosition(
                      TextPosition(offset: _amountCtrl.text.length),
                    );
                  },
                  tooltip: l10n.posExactCash,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _quickCash(total).map((v) {
                  return GlassFilterChip(
                    label: MoneyFormatter.format(v, symbol: ''),
                    selected: _paidValue(total) == v,
                    onTap: () {
                      _amountCtrl.text = v.toString();
                      _amountCtrl.selection = TextSelection.fromPosition(
                        TextPosition(offset: _amountCtrl.text.length),
                      );
                    },
                  );
                }).toList(),
              ),
              if (change > 0)
                Padding(
                  padding: const EdgeInsets.only(top: AppDimensions.space10),
                  child: Row(
                    children: [
                      Text(
                        l10n.posChange,
                        style: TextStyle(
                          color: design.textMedium,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        MoneyFormatter.format(change),
                        style: TextStyle(
                          color: design.primary,
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
            ],
            const SizedBox(height: AppDimensions.space16),
            PrimaryButton(
              onPressed: _busy ? null : _placeOrder,
              loading: _busy,
              child: Text(l10n.posPlaceOrder),
            ),
          ],
        ),
      ),
    );
  }

  int _paidValue(int total) {
    if (_method != PaymentMethod.cash) return total;
    final raw = _amountCtrl.text.replaceAll(RegExp(r'[^\d]'), '');
    if (raw.isEmpty) return total;
    return int.tryParse(raw) ?? 0;
  }

  List<int> _quickCash(int total) {
    const denominations = [5000, 10000, 20000, 50000, 100000];
    final set = <int>{};
    for (final d in denominations) {
      if (d >= total) set.add(d);
    }
    // Round up to nearest 5k
    final rounded = ((total + 4999) ~/ 5000) * 5000;
    set.add(rounded);
    final list = set.toList()..sort();
    return list.take(5).toList();
  }

  /// The configured method the cashier picked, or — before they touched
  /// anything — the one matching the default kind, so a sale left on cash
  /// still records WHICH cash method it was.
  PaymentMethodConfig? _selectedMethod(List<PaymentMethodConfig> methods) =>
      methods
          .where(
            (method) =>
                method.id == _paymentMethodId ||
                (_paymentMethodId == null && method.kind == _method.wire),
          )
          .firstOrNull;

  Future<void> _placeOrder() async {
    final l10n = AppLocalizations.of(context)!;
    final total = ref.read(cartQuoteProvider).result.total;
    final pricing =
        ref.read(pricingContextProvider).valueOrNull ?? PricingContext.empty;
    final selected = _selectedMethod(pricing.paymentMethods);
    final reference = _referenceCtrl.text.trim();
    final String? refusal;
    if (selected?.requiresReference == true && reference.isEmpty) {
      refusal = l10n.posPaymentReferenceRequired;
    } else if (_method == PaymentMethod.cash && _paidValue(total) < total) {
      // Short cash is a sale the drawer cannot cover: the change owed would
      // be negative and the drawer expectation would read more than was
      // handed over.
      refusal = l10n.posCashShort;
    } else {
      refusal = null;
    }
    if (refusal != null) {
      showAppSnackBar(context, refusal, error: true);
      return;
    }

    // The server named on the bill, when the outlet tracks one. Written into
    // the cart just before it is placed, so nothing else reads a half-made
    // choice.
    final cart = ref.read(cartProvider.notifier);
    if (pricing.trackServer) {
      final servers =
          ref.read(serverCandidatesProvider).valueOrNull ?? const <Employee>[];
      final id =
          _servedById ??
          ref.read(cartProvider).servedById ??
          ref.read(settingsProvider).valueOrNull?.employeeId;
      final server = servers.where((e) => e.id == id).firstOrNull;
      if (server == null) {
        showAppSnackBar(context, l10n.posServedByRequired, error: true);
        return;
      }
      cart.setServedBy(id: server.id, name: server.name);
    } else {
      cart.setServedBy();
    }

    setState(() => _busy = true);
    try {
      final order = await placeOrderFromCart(
        read: ref.read,
        invalidate: ref.invalidate,
        paymentMethod: _method,
        paymentMethodId: selected?.id,
        paymentMethodName: selected?.name,
        paymentReference: reference.isEmpty ? null : reference,
        amountPaid: _paidValue(total),
      );
      if (!mounted) return;
      // How many routes sit above the POS page depends on the layout, so the
      // number of pops has to as well. Below the tablet breakpoint the cart is
      // a bottom sheet and checkout stacks on top of it — two routes. At or
      // above it the cart is inline (`_openCartSheet` goes straight to
      // `_openCheckout`) and checkout is the only route. Popping a fixed two
      // therefore over-popped on tablet, desktop and web: it unmounted the
      // shell route itself, the Navigator asserted `!_debugLocked` while
      // finalizing the tree, and the app went blank immediately after a
      // successful sale. The order was already committed, so the crash lost no
      // data — but it landed on the exact screen a demo ends on.
      final navigator = Navigator.of(context);
      final cartWasASheet =
          MediaQuery.sizeOf(context).width < AppDimensions.tabletWidth;
      navigator.pop(); // close checkout
      if (cartWasASheet) navigator.pop(); // close cart sheet
      HapticFeedback.mediumImpact();
      showAppSnackBar(
        context,
        AppLocalizations.of(context)!.posOrderPlaced,
        success: true,
      );
      showGlassSheet<void>(
        context: context,
        isDismissible: false,
        builder: (_) => _SuccessReceipt(order: order),
      );
    } on TillBindingException {
      // The sale names a till or session this device is not bound to. Nothing
      // was written, the cart is intact, and the message says why.
      if (!mounted) return;
      showAppSnackBar(
        context,
        AppLocalizations.of(context)!.tillBindingMismatch,
        error: true,
      );
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(context, '$e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

class _SuccessReceipt extends ConsumerWidget {
  const _SuccessReceipt({required this.order});
  final Order order;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final design = context.design;
    final settings = ref.watch(settingsProvider).valueOrNull;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(AppDimensions.space20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: AppDimensions.space8),
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: design.successContainer,
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.check_rounded, color: design.success, size: 36),
            ),
            const SizedBox(height: AppDimensions.space12),
            Text(
              l10n.posOrderPlaced,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: design.textHigh,
              ),
            ),
            const SizedBox(height: AppDimensions.space4),
            Text(
              l10n.posOrderNumber(order.number),
              style: TextStyle(color: design.textMedium),
            ),
            const SizedBox(height: AppDimensions.space20),
            GlassCard.solid(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _line(
                    settings?.storeName ?? '',
                    order.items.first.productName.isEmpty
                        ? ''
                        : order.items.first.productName,
                    design: design,
                    bold: true,
                  ),
                  Divider(height: 20, color: design.glassBorder),
                  for (final it in order.items)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        children: [
                          Text(
                            '${it.quantity}x',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: design.textHigh,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              it.displayName,
                              style: TextStyle(
                                fontSize: 13,
                                color: design.textHigh,
                              ),
                            ),
                          ),
                          Text(
                            MoneyFormatter.format(it.lineTotal),
                            style: TextStyle(
                              fontSize: 13,
                              color: design.textHigh,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  Divider(height: 20, color: design.glassBorder),
                  _line(
                    l10n.posSubtotal,
                    MoneyFormatter.format(order.subtotal),
                    design: design,
                  ),
                  if (order.discount > 0)
                    _line(
                      l10n.posDiscount,
                      '- ${MoneyFormatter.format(order.discount)}',
                      design: design,
                    ),
                  if (order.serviceChargeAmount > 0)
                    _line(
                      l10n.posServiceCharge,
                      MoneyFormatter.format(order.serviceChargeAmount),
                      design: design,
                    ),
                  // The tax added on top; the included part is already in
                  // the prices and is shown below the total instead.
                  if (order.tax - order.taxIncluded > 0)
                    _line(
                      l10n.posTax,
                      MoneyFormatter.format(order.tax - order.taxIncluded),
                      design: design,
                    ),
                  if (order.roundingAmount != 0)
                    _line(
                      l10n.posRounding,
                      MoneyFormatter.format(order.roundingAmount),
                      design: design,
                    ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        l10n.posTotal,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: design.textMedium,
                        ),
                      ),
                      Text(
                        MoneyFormatter.format(order.total),
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 18,
                          color: design.primary,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                  if (order.taxIncluded > 0)
                    _line(
                      l10n.posTaxIncluded,
                      MoneyFormatter.format(order.taxIncluded),
                      design: design,
                    ),
                  if (order.servedByName?.isNotEmpty == true)
                    _line(
                      l10n.posServedBy,
                      order.servedByName!,
                      design: design,
                    ),
                ],
              ),
            ),
            const SizedBox(height: AppDimensions.space16),
            Row(
              children: [
                Expanded(
                  child: GhostButton(
                    // Stays open while the print dialog is up: closing the
                    // receipt first would leave the cashier with no way back to
                    // it if they dismiss the dialog by accident.
                    onPressed: settings == null
                        ? null
                        : () => printOrderReceipt(context, order, settings),
                    child: Text(l10n.ordersPrintReceipt),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: PrimaryButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(l10n.commonDone),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _line(
    String a,
    String b, {
    required BrandColors design,
    bool bold = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            a,
            style: TextStyle(
              fontSize: 13,
              fontWeight: bold ? FontWeight.w800 : FontWeight.w400,
              color: design.textHigh,
            ),
          ),
          Text(
            b,
            style: TextStyle(
              fontSize: 13,
              color: design.textHigh,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
