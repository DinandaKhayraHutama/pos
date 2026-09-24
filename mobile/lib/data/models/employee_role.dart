class EmployeeRoleDefinition {
  const EmployeeRoleDefinition({
    required this.id,
    required this.name,
    required this.permissions,
    required this.posAccess,
    required this.backofficeAccess,
    this.systemKey,
  });

  final String id;
  final String name;
  final String? systemKey;
  final Set<String> permissions;
  final bool posAccess;
  final bool backofficeAccess;

  factory EmployeeRoleDefinition.fromMap(Map<String, Object?> row) =>
      EmployeeRoleDefinition(
        id: row['id']! as String,
        name: row['name']! as String,
        systemKey: row['system_key'] as String?,
        permissions: ((row['permissions'] as String?) ?? '')
            .split(',')
            .where((value) => value.isNotEmpty)
            .toSet(),
        posAccess: (row['pos_access'] as int? ?? 0) == 1,
        backofficeAccess: (row['backoffice_access'] as int? ?? 0) == 1,
      );
}
