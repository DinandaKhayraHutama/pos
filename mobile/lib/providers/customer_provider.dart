import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/customer.dart';
import '../data/repositories/customer_repository.dart';

final customersProvider = FutureProvider.autoDispose<List<Customer>>((ref) {
  return CustomerRepository.instance.search('');
});
