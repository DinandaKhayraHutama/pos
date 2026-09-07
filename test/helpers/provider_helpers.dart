import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Returns a [ProviderContainer] for use in tests. The caller is responsible
/// for calling [ProviderContainer.dispose] (typically in `tearDown`).
///
/// Pass [overrides] to swap providers with fakes/mocks.
ProviderContainer makeContainer({
  List<Override> overrides = const [],
}) {
  final container = ProviderContainer(overrides: overrides);
  return container;
}
