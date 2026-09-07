import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/localization/l10n.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimensions.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/glass/glass_card.dart';
import '../../core/widgets/glass/glass_stepper.dart';
import '../../core/widgets/product_thumbnail.dart';
import '../../data/models/product.dart';

// Geometry of a [ProductCard]. The POS grid derives its tile height from these
// via [productCardExtent] instead of guessing a childAspectRatio, so the card
// can never be clipped - at any tile width, on any screen, at any text scale.
const double _cardPadding = AppDimensions.space10;
const double _imageAspectRatio = 4 / 3;
const double _nameFontSize = 12.5;
const double _nameLineHeight = 1.25;
const int _nameMaxLines = 2;
const double _priceFontSize = 12.5;
const double _priceLineHeight = 1.3;
const double _actionFontSize = 12;
const double _actionMinHeight = 34;
const double _gapAfterImage = AppDimensions.space8;
const double _gapAfterName = AppDimensions.space4;
const double _gapBeforeAction = AppDimensions.space6;

/// Height a [ProductCard] needs when laid out [tileWidth] wide.
///
/// Everything below the thumbnail scales with the user's text scale, so the
/// grid must ask rather than assume: a fixed aspect ratio left only a few
/// device-pixels of slack and clipped the action button once a product name
/// wrapped to two lines.
double productCardExtent(BuildContext context, double tileWidth) {
  final scaler = MediaQuery.textScalerOf(context);
  final contentWidth = math.max(1.0, tileWidth - _cardPadding * 2);
  final imageHeight = contentWidth / _imageAspectRatio;

  return _cardPadding * 2 +
      imageHeight +
      _gapAfterImage +
      _nameBlockHeight(scaler) +
      _gapAfterName +
      _priceBlockHeight(scaler) +
      _gapBeforeAction +
      _actionBlockHeight(scaler);
}

/// Text line heights are rounded up when a paragraph is laid out, so every
/// block below reserves whole pixels per line. Reserving the exact fractional
/// height overflowed by a fraction of a pixel.
double _lineHeight(TextScaler scaler, double fontSize, double height) =>
    (scaler.scale(fontSize) * height).ceilToDouble();

double _nameBlockHeight(TextScaler scaler) =>
    _lineHeight(scaler, _nameFontSize, _nameLineHeight) * _nameMaxLines;

double _priceBlockHeight(TextScaler scaler) =>
    _lineHeight(scaler, _priceFontSize, _priceLineHeight);

/// The action row keeps a comfortable tap target but still grows if the label
/// would otherwise not fit.
double _actionBlockHeight(TextScaler scaler) => math.max(
      _actionMinHeight,
      scaler.scale(_actionFontSize) * 1.3 + AppDimensions.space12,
    );

/// A single product tile in the POS grid.
///
/// Tapping the card body adds one - the fast path for a cashier. Once the
/// product is in the cart the action row turns into a stepper so the quantity
/// can be corrected without leaving the grid.
class ProductCard extends StatelessWidget {
  const ProductCard({
    super.key,
    required this.product,
    required this.inCartQty,
    required this.onAdd,
    required this.onDecrement,
    this.hasVariants = false,
  });

  final Product product;
  final int inCartQty;

  /// Whether tapping opens a size/option picker instead of adding directly.
  /// Marked on the card so the cashier is not surprised by a sheet.
  final bool hasVariants;

  final VoidCallback onAdd;
  final VoidCallback onDecrement;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    final scaler = MediaQuery.textScalerOf(context);
    final inCart = inCartQty > 0;
    final (accentFg, _) = CategoryColor.of(product.categoryId);

    return GlassCard.solid(
      borderColor: inCart ? design.primary : null,
      onTap: product.isSellable ? onAdd : null,
      padding: const EdgeInsets.all(_cardPadding),
      radius: AppDimensions.radiusLg,
      child: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Product thumbnail (network image with icon fallback)
              AspectRatio(
                aspectRatio: _imageAspectRatio,
                child: ProductThumbnail(
                  product: product,
                  borderRadius: AppDimensions.radiusMd,
                ),
              ),
              const SizedBox(height: _gapAfterImage),
              // Product name. Fixed to two lines so the price and the
              // action row stay aligned across a row of cards.
              SizedBox(
                height: _nameBlockHeight(scaler),
                child: Text(
                  product.name,
                  style: TextStyle(
                    fontSize: _nameFontSize,
                    fontWeight: FontWeight.w700,
                    color: design.textHigh,
                    height: _nameLineHeight,
                  ),
                  maxLines: _nameMaxLines,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(height: _gapAfterName),
              // Price row
              SizedBox(
                height: _priceBlockHeight(scaler),
                child: Row(
                  children: [
                    if (product.isPopular) ...[
                      Icon(Icons.local_fire_department_rounded,
                          size: 12, color: accentFg),
                      const SizedBox(width: 2),
                    ],
                    Expanded(
                      child: Text(
                        MoneyFormatter.format(product.price),
                        style: TextStyle(
                          fontSize: _priceFontSize,
                          fontWeight: FontWeight.w800,
                          color: design.primary,
                          height: _priceLineHeight,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    // An icon, not a word: the price row's height is part of
                    // the computed card extent, and a label would grow with
                    // the text scaler and clip the card.
                    if (hasVariants)
                      Icon(
                        Icons.tune_rounded,
                        size: 13,
                        color: design.textLow,
                      ),
                  ],
                ),
              ),
              const SizedBox(height: _gapBeforeAction),
              // The action row's reserved height (_actionBlockHeight) bottoms
              // out at _actionMinHeight (34), which matches GlassStepper's
              // fixed _minHeight, so the stepper fills the reserved block
              // exactly at every text scale the app allows (≤1.15).
              //
              // GlassStepper wraps the add label in a Flexible(ellipsis), so
              // the "Add"/"Tambah" label renders without overflowing even on
              // the narrowest 2-column phone tile (~140dp).
              GlassStepper(
                quantity: inCartQty,
                enabled: product.isSellable,
                onAdd: onAdd,
                onDecrement: onDecrement,
                addLabel: context.l10n.commonAdd,
              ),
            ],
          ),
          // Remaining-stock pill. Deliberately a Positioned inside the existing
          // Stack rather than a row in the Column: the card's height is a
          // computed extent (productCardExtent, locked by
          // product_card_layout_test), so anything that adds to the Column
          // would have to be reflected there or the card clips. Only shown for
          // tracked products that are low — a full shelf is not news.
          if (product.isLowStock)
            Positioned(
              top: 4,
              right: 4,
              child: _StockPill(
                label: context.l10n.posStockLeft(product.stock!),
                background: design.warningContainer,
                foreground: design.warning,
              ),
            ),
          if (!product.isSellable)
            Positioned.fill(
              child: Container(
                color: design.surfaceBase.withValues(alpha: 0.72),
                alignment: Alignment.center,
                child: Text(
                  product.isOutOfStock
                      ? context.l10n.posOutOfStock
                      : context.l10n.posUnavailable,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: design.error,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Small remaining-stock badge drawn over the product thumbnail.
class _StockPill extends StatelessWidget {
  const _StockPill({
    required this.label,
    required this.background,
    required this.foreground,
  });

  final String label;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(AppDimensions.radius8),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: foreground,
        ),
      ),
    );
  }
}
