import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimensions.dart';
import '../../core/utils/icon_map.dart';
import '../../data/models/product.dart';

/// Renders a product thumbnail with the following priority:
///   1. Network [Product.imageUrl] if set
///   2. Material [Icon] from [Product.iconKey] (always renders)
///   3. [Product.emoji] as last resort
///
/// Sits on a neutral surface tile so it doesn't clash with the glass card
/// beneath. Category identity is carried by the fallback icon color.
class ProductThumbnail extends StatefulWidget {
  const ProductThumbnail({
    super.key,
    required this.product,
    this.size = 48,
    this.borderRadius,
  });

  final Product product;
  final double size;
  final BorderRadius? borderRadius;

  @override
  State<ProductThumbnail> createState() => _ProductThumbnailState();
}

class _ProductThumbnailState extends State<ProductThumbnail> {
  bool _imageFailed = false;

  @override
  Widget build(BuildContext context) {
    // Only the icon color carries category identity now; the thumbnail bg is a
    // neutral surface step so it doesn't clash with the glass card beneath.
    final (accentFg, _) = CategoryColor.of(widget.product.categoryId);
    final radius = widget.borderRadius ?? AppDimensions.radiusMd;

    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: radius,
      ),
      clipBehavior: Clip.antiAlias,
      alignment: Alignment.center,
      child: _buildContent(accentFg),
    );
  }

  Widget _buildContent(Color accentFg) {
    // 1. Try network image
    final url = widget.product.imageUrl;
    if (url != null && url.isNotEmpty && !_imageFailed) {
      return Image.network(
        url,
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        loadingBuilder: (context, child, progress) {
          if (progress == null) return child;
          return _IconFallback(
            icon: iconFromKey(widget.product.iconKey),
            color: accentFg,
            size: widget.size * 0.5,
          );
        },
        errorBuilder: (_, __, ___) {
          // Mark failed on next frame to avoid setState during build.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => _imageFailed = true);
          });
          return _IconFallback(
            icon: iconFromKey(widget.product.iconKey),
            color: accentFg,
            size: widget.size * 0.5,
          );
        },
      );
    }
    // 2. Material icon fallback (always reliable on every platform)
    return _IconFallback(
      icon: iconFromKey(widget.product.iconKey),
      color: accentFg,
      size: widget.size * 0.5,
    );
  }
}

class _IconFallback extends StatelessWidget {
  const _IconFallback({
    required this.icon,
    required this.color,
    required this.size,
  });
  final IconData icon;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Icon(icon, color: color, size: size);
  }
}
