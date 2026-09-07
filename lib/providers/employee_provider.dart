import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/employee.dart';
import '../data/repositories/employee_repository.dart';

/// The staff list. Includes inactive employees — the management screen has to
/// show them to be able to reactivate them.
final employeesProvider =
    AsyncNotifierProvider.autoDispose<EmployeesNotifier, List<Employee>>(
      EmployeesNotifier.new,
    );

class EmployeesNotifier extends AutoDisposeAsyncNotifier<List<Employee>> {
  @override
  Future<List<Employee>> build() => EmployeeRepository.instance.all();

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(EmployeeRepository.instance.all);
  }

  Future<void> upsert(Employee employee) async {
    await EmployeeRepository.instance.upsert(employee);
    await refresh();
  }

  Future<void> delete(String id) async {
    await EmployeeRepository.instance.delete(id);
    await refresh();
  }
}
