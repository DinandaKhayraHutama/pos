import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/category.dart';
import '../data/models/product.dart';
import '../data/models/product_variant.dart';
import '../data/repositories/category_repository.dart';
import '../data/repositories/product_repository.dart';
import 'outlet_provider.dart';

/// The branch whose shelf the catalogue should show, or empty when the
/// business has no open outlet.
///
/// Watched rather than read, in every provider that reports a count: moving a
/// device to another branch has to redraw the stock pills, not leave the
/// previous shop's numbers on screen.
String _outletOf(Ref ref) =>
    ref.watch(activeOutletProvider).valueOrNull?.id ?? '';

/// Cached product catalog. Pass [forceRefresh] to re-read.
final productsProvider =
    AsyncNotifierProvider.autoDispose<ProductsNotifier, List<Product>>(
      ProductsNotifier.new,
    );

class ProductsNotifier extends AutoDisposeAsyncNotifier<List<Product>> {
  @override
  Future<List<Product>> build() =>
      ProductRepository.instance.all(outletId: _outletOf(ref));

  Future<void> refresh() async {
    final outletId = ref.read(activeOutletProvider).valueOrNull?.id ?? '';
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(
      () => ProductRepository.instance.all(outletId: outletId),
    );
  }

  Future<void> upsert(Product p) async {
    await ProductRepository.instance.upsert(p);
    await refresh();
  }

  Future<void> delete(String id) async {
    await ProductRepository.instance.delete(id);
    await refresh();
  }
}

final categoriesProvider =
    AsyncNotifierProvider.autoDispose<CategoriesNotifier, List<Category>>(
      CategoriesNotifier.new,
    );

class CategoriesNotifier extends AutoDisposeAsyncNotifier<List<Category>> {
  @override
  Future<List<Category>> build() => CategoryRepository.instance.all();

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(() => CategoryRepository.instance.all());
  }

  Future<void> upsert(Category c) async {
    await CategoryRepository.instance.upsert(c);
    await refresh();
  }

  Future<void> delete(String id) async {
    await CategoryRepository.instance.delete(id);
    await refresh();
  }
}

/// Every variant in the catalogue, keyed by product id.
///
/// One provider for the whole map rather than a family per product: the sell
/// grid renders every card at once and each one has to know whether it opens
/// a picker, so a family would mean 26 concurrent loads on first paint.
final productVariantsProvider =
    FutureProvider.autoDispose<Map<String, List<ProductVariant>>>((ref) {
      return ProductRepository.instance.variantsByProduct();
    });

/// Products at or below the low-stock threshold, scarcest first.
final lowStockProvider = FutureProvider.autoDispose<List<Product>>((ref) {
  return ProductRepository.instance.lowStock(outletId: _outletOf(ref));
});
