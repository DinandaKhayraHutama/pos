import 'package:flutter/material.dart';

import '../../core/localization/l10n.dart';
import '../../core/theme/app_dimensions.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/glass/glass_card.dart';
import '../../core/widgets/product_thumbnail.dart';
import '../../data/models/product.dart';
import '../../data/models/product_variant.dart';

/// Asks which variant of [product] is being sold.
///
/// One tap per option, no confirm button: at a till the cashier's second tap
/// is the customer waiting, and every option here is reversible from the cart
/// anyway. Each row shows the price it will actually charge rather than the
/// delta — "+Rp 5.000" makes the cashier do arithmetic they should not have
/// to while someone is holding out a note.
class VariantPickerSheet extends StatelessWidget {
  const VariantPickerSheet({
    super.key,
    required this.product,
    required this.variants,
  });

  final Product product;
  final List<ProductVariant> variants;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final design = context.design;

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
                ProductThumbnail(
                  product: product,
                  size: 44,
                  borderRadius: AppDimensions.radiusSm,
                ),
                const SizedBox(width: AppDimensions.space12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        product.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: design.textHigh,
                        ),
                      ),
                      Text(
                        l10n.posChooseOption,
                        style: TextStyle(
                          fontSize: 12,
                          color: design.textMedium,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: Icon(Icons.close_rounded, color: design.textMedium),
                ),
              ],
            ),
            const SizedBox(height: AppDimensions.space12),
            for (final v in variants)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: GlassCard.solid(
                  onTap: () => Navigator.of(context).pop(v),
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppDimensions.space14,
                    vertical: AppDimensions.space12,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          v.name,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: design.textHigh,
                          ),
                        ),
                      ),
                      Text(
                        MoneyFormatter.format(product.price + v.priceDelta),
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                          color: design.primary,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
