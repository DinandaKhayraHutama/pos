import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/auth/permissions.dart';
import '../data/device/till_coordinator.dart';
import '../data/models/enums.dart';
import '../data/models/order.dart';
import '../data/repositories/order_repository.dart';
import '../data/repositories/remote_order_repository.dart';
import 'outlet_provider.dart';
import 'settings_provider.dart';

/// The filter the history screen is showing.
///
/// A plain [StateProvider] rather than a field on the notifier: changing a
/// filter has to REPLACE the list rather than append to it, and watching the
/// filter is what makes that automatic — a cursor is a position in one
/// ordering, so carrying it into another would page through a list nobody
/// asked for.
final orderHistoryFilterProvider = StateProvider<OrderHistoryFilter>(
  (ref) => OrderHistoryFilter.today(),
);

/// What the history screen is asking for.
class OrderHistoryFilter {
  const OrderHistoryFilter({
    required this.from,
    required this.to,
    this.status,
    this.receipt = '',
    this.wholeOutlet = false,
  });

  factory OrderHistoryFilter.today() {
    final now = DateTime.now();
    final day = DateTime(now.year, now.month, now.day);
    return OrderHistoryFilter(from: day, to: day);
  }

  final DateTime from;
  final DateTime to;
  final OrderStatus? status;
  final String receipt;

  /// Whether to ask the server for every till in the branch. Needs
  /// [AppPermission.viewAllOrders]; the server refuses otherwise rather than
  /// narrowing silently, and the screen reports what it refused.
  final bool wholeOutlet;

  bool get isToday {
    final now = DateTime.now();
    final day = DateTime(now.year, now.month, now.day);
    return from == day && to == day;
  }

  OrderHistoryFilter copyWith({
    DateTime? from,
    DateTime? to,
    Object? status = _unset,
    String? receipt,
    bool? wholeOutlet,
  }) => OrderHistoryFilter(
    from: from ?? this.from,
    to: to ?? this.to,
    status: status == _unset ? this.status : status as OrderStatus?,
    receipt: receipt ?? this.receipt,
    wholeOutlet: wholeOutlet ?? this.wholeOutlet,
  );

  static const _unset = Object();

  String get key =>
      '${from.toIso8601String()}|${to.toIso8601String()}'
      '|${status?.wire ?? ''}|$receipt|$wholeOutlet';

  @override
  bool operator ==(Object other) =>
      other is OrderHistoryFilter && other.key == key;

  @override
  int get hashCode => key.hashCode;
}

/// One screen's worth of history: the rows so far, and what they are.
class OrderHistoryState {
  const OrderHistoryState({
    this.orders = const [],
    this.loadingMore = false,
    this.hasMore = false,
    this.scope = RemoteScope.register,
    this.fromCache = false,
    this.cachedAt,
    this.serverAvailable = true,
    this.rangeComplete = true,
    this.localOnly = false,
  });

  final List<Order> orders;
  final bool loadingMore;
  final bool hasMore;

  /// The scope the SERVER applied. Compared against what was asked for, so a
  /// cashier who asked for the branch and got their register is told.
  final String scope;

  /// True when the server could not be reached and this came from the cache.
  final bool fromCache;
  final DateTime? cachedAt;

  /// False when the last fetch failed. Distinct from [fromCache]: a cache hit
  /// after a failure is still a failure worth naming.
  final bool serverAvailable;

  /// False when the cached range was never downloaded to its end, so "no more
  /// rows" means "this device has not seen them" rather than "there are none".
  final bool rangeComplete;

  /// True in demo mode and before activation: there is no server to ask, and
  /// the list is this device's own orders and nothing else.
  final bool localOnly;

  OrderHistoryState copyWith({
    List<Order>? orders,
    bool? loadingMore,
    bool? hasMore,
    String? scope,
    bool? fromCache,
    DateTime? cachedAt,
    bool? serverAvailable,
    bool? rangeComplete,
    bool? localOnly,
  }) => OrderHistoryState(
    orders: orders ?? this.orders,
    loadingMore: loadingMore ?? this.loadingMore,
    hasMore: hasMore ?? this.hasMore,
    scope: scope ?? this.scope,
    fromCache: fromCache ?? this.fromCache,
    cachedAt: cachedAt ?? this.cachedAt,
    serverAvailable: serverAvailable ?? this.serverAvailable,
    rangeComplete: rangeComplete ?? this.rangeComplete,
    localOnly: localOnly ?? this.localOnly,
  );
}

final orderHistoryProvider =
    AsyncNotifierProvider.autoDispose<OrderHistoryNotifier, OrderHistoryState>(
      OrderHistoryNotifier.new,
    );

/// Pages transaction history, merging this device's own orders with the
/// server's.
///
/// Two sources, two cursors, one list:
///
///  * The LOCAL rows are the receipts this device rang up. They are the
///    authority for their own ids — an order still in the outbox exists here
///    and nowhere else, and a status changed locally is newer than the
///    server's copy of it.
///  * The REMOTE rows are everything else in scope, read-only.
///
/// The two are deduplicated by UUID with the local row winning, and each keeps
/// its own cursor so neither runs ahead of the other.
class OrderHistoryNotifier extends AutoDisposeAsyncNotifier<OrderHistoryState> {
  String? _localCursorId;
  int? _localCursorAt;
  String _remoteCursor = '';
  bool _localExhausted = false;
  bool _remoteExhausted = false;

  /// Bumped on every reset. A response that arrives carrying an older
  /// generation is dropped: switching filters twice quickly used to let the
  /// first, slower answer land on top of the second.
  int _generation = 0;

  static const _pageSize = 50;

  @override
  Future<OrderHistoryState> build() {
    // Watched, not read. Signing a different person in re-scopes the list, and
    // moving the device to another branch re-scopes it too — a manager in
    // Kemang reading Bintaro's receipts would void the wrong sale.
    final settings = ref.watch(settingsProvider).valueOrNull;
    final outletId = ref.watch(activeOutletProvider).valueOrNull?.id;
    final filter = ref.watch(orderHistoryFilterProvider);
    return _reset(filter, settings, outletId);
  }

  Future<OrderHistoryState> _reset(
    OrderHistoryFilter filter,
    SettingsState? settings,
    String? outletId,
  ) async {
    _generation++;
    _localCursorId = null;
    _localCursorAt = null;
    _remoteCursor = '';
    _localExhausted = false;
    _remoteExhausted = false;
    return _load(
      const OrderHistoryState(),
      filter,
      settings,
      outletId,
      _generation,
    );
  }

  /// Loads the next slice of both sources and folds it into [current].
  Future<OrderHistoryState> _load(
    OrderHistoryState current,
    OrderHistoryFilter filter,
    SettingsState? settings,
    String? outletId,
    int generation,
  ) async {
    final connected = TillCoordinator.current != null && settings != null;
    final seesEverything = settings?.can(AppPermission.viewAllOrders) ?? true;

    final local = await _localPage(filter, settings, outletId, seesEverything);
    if (!_localExhausted && local.isNotEmpty) {
      _localCursorAt = local.last.createdAt.millisecondsSinceEpoch;
      _localCursorId = local.last.id;
    }
    _localExhausted = local.length < _pageSize;

    if (!connected) {
      return _merge(
        current,
        local,
        const [],
        generation,
      ).copyWith(localOnly: true, hasMore: !_localExhausted);
    }

    RemoteOrderPage remote = const RemoteOrderPage(
      orders: [],
      next: '',
      scope: RemoteScope.register,
      fromCache: false,
    );
    if (!_remoteExhausted) {
      remote = await RemoteOrderRepository.page(
        settings.employeeId,
        _remoteFilter(filter, settings, seesEverything),
        cursor: _remoteCursor,
      );
      _remoteCursor = remote.next;
      _remoteExhausted = remote.next.isEmpty;
    }

    return _merge(current, local, remote.orders, generation).copyWith(
      hasMore: !_localExhausted || !_remoteExhausted,
      scope: remote.scope,
      fromCache: remote.fromCache,
      cachedAt: remote.cachedAt,
      serverAvailable: !remote.fromCache,
      rangeComplete: remote.complete,
      localOnly: false,
    );
  }

  RemoteOrderFilter _remoteFilter(
    OrderHistoryFilter filter,
    SettingsState settings,
    bool seesEverything,
  ) => RemoteOrderFilter(
    from: filter.from,
    to: filter.to,
    // The server refuses a scope this account may not have, so asking for one
    // it cannot hold would fail the whole page rather than widening it.
    scope: filter.wholeOutlet && seesEverything
        ? RemoteScope.outlet
        : RemoteScope.register,
    status: filter.status?.wire,
    receipt: filter.receipt.isEmpty ? null : filter.receipt,
    // A cashier may only name themselves, and the server enforces that. Naming
    // them explicitly keeps the cached filter key honest about whose list it
    // is, so a handover cannot read the previous person's cache.
    cashierId: seesEverything ? null : settings.employeeId,
  );

  Future<List<Order>> _localPage(
    OrderHistoryFilter filter,
    SettingsState? settings,
    String? outletId,
    bool seesEverything,
  ) {
    if (_localExhausted) return Future.value(const []);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return OrderRepository.instance.page(
      limit: _pageSize,
      status: filter.status,
      // A cashier's own sales, for the current day only — the same rule the
      // server applies, so the two halves of the list agree about scope.
      cashierId: seesEverything
          ? null
          : (settings?.employeeId.isEmpty ?? true
                ? 'cashier'
                : settings!.employeeId),
      outletId: outletId,
      from: seesEverything ? filter.from : today,
      to: seesEverything ? filter.to : today,
      receipt: filter.receipt,
      beforeCreatedAt: _localCursorAt,
      beforeId: _localCursorId,
    );
  }

  /// Folds new rows in, local winning on a shared id, and re-sorts.
  ///
  /// Sorting the whole list rather than appending: the two sources advance at
  /// different rates, so a remote row older than a local one can arrive on a
  /// later page and still belong higher up.
  OrderHistoryState _merge(
    OrderHistoryState current,
    List<Order> local,
    List<Order> remote,
    int generation,
  ) {
    if (generation != _generation) return current;
    final byId = <String, Order>{
      for (final o in current.orders) o.id: o,
      for (final o in remote) o.id: o,
      for (final o in local) o.id: o,
    };
    final merged = byId.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return current.copyWith(orders: merged);
  }

  /// Loads the next page. Ignored while one is in flight, so a fast scroll
  /// does not fire four overlapping requests for the same cursor.
  Future<void> loadMore() async {
    final current = state.valueOrNull;
    if (current == null || current.loadingMore || !current.hasMore) return;
    final settings = ref.read(settingsProvider).valueOrNull;
    final outletId = ref.read(activeOutletProvider).valueOrNull?.id;
    final filter = ref.read(orderHistoryFilterProvider);
    final generation = _generation;

    state = AsyncValue.data(current.copyWith(loadingMore: true));
    final next = await AsyncValue.guard(
      () => _load(current, filter, settings, outletId, generation),
    );
    if (generation != _generation) return;
    state = next.whenData((v) => v.copyWith(loadingMore: false));
  }

  /// Starts the whole range again.
  ///
  /// Refresh rather than "fetch newer": a receipt uploaded late lands in the
  /// middle of the ordering, and a status can change on a row already read, so
  /// only re-walking the range finds both.
  Future<void> refresh() async {
    final settings = ref.read(settingsProvider).valueOrNull;
    final outletId = ref.read(activeOutletProvider).valueOrNull?.id;
    final filter = ref.read(orderHistoryFilterProvider);
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(() => _reset(filter, settings, outletId));
  }
}
