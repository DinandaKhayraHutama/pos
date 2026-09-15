/// The outlet and register an activated device IS, as the server knows it.
///
/// The server never reads a register from a pushed row: it takes it from the
/// device token. So a connected till that let a cashier sign on to another
/// register would record the drawer and its sales under that register locally,
/// while the server filed them under the bound one — two books that disagree,
/// and, once stock rides on sales, two shelves. This is the one place the data
/// layer asks which till it is, and every write that names a register or an
/// outlet checks against it.
///
/// Null in demo mode, where the device may stand in any branch and sign on to
/// any till. Set by `prepareConnectedStorage`, next to the database and
/// preference scopes it belongs with; the bound register never changes for a
/// store, because activating against another register opens another store.
class TillBinding {
  const TillBinding({required this.outletId, required this.registerId});

  final String outletId;
  final String registerId;

  static TillBinding? _current;

  static TillBinding? get current => _current;

  static void configure(TillBinding? binding) => _current = binding;
}

/// A write named a register or outlet other than the one this device is bound
/// to. Never a network condition: nothing is retried, and nothing is written.
class TillBindingException implements Exception {
  const TillBindingException(this.detail);

  final String detail;

  @override
  String toString() => 'TillBindingException: $detail';
}
