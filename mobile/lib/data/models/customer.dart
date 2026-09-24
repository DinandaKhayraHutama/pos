class Customer {
  const Customer({
    required this.id,
    required this.name,
    this.phone,
    this.email,
    this.address,
    this.note,
    this.active = true,
  });

  final String id;
  final String name;
  final String? phone;
  final String? email;
  final String? address;
  final String? note;
  final bool active;

  factory Customer.fromMap(Map<String, Object?> row) => Customer(
    id: row['id'] as String,
    name: row['name'] as String,
    phone: row['phone'] as String?,
    email: row['email'] as String?,
    address: row['address'] as String?,
    note: row['note'] as String?,
    active: ((row['active'] as num?)?.toInt() ?? 1) == 1,
  );

  Map<String, Object?> toMap() => {
    'id': id,
    'name': name,
    'phone': phone,
    'email': email,
    'address': address,
    'note': note,
    'active': active ? 1 : 0,
  };
}
