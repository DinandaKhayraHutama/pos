/// A company-wide product brand pulled from the server catalogue feed.
class CatalogueBrand {
  const CatalogueBrand({required this.id, required this.name});

  final String id;
  final String name;

  factory CatalogueBrand.fromMap(Map<String, Object?> row) =>
      CatalogueBrand(id: row['id'] as String, name: row['name'] as String);
}
