# JustClick POS — Restaurant Point of Sale

A mobile-first **Restaurant POS** Flutter app for FnB clients (dkriuk / rocket chicken style). Built end-to-end and ready to demo. Comes pre-loaded with a typical Indonesian warung menu so you can take an order, charge it, and see the sale reflected on the dashboard immediately.

## ✨ Highlights

- **Responsive** — phone uses a bottom-sheet cart, tablet/desktop (≥ 900dp) uses a split POS / cart layout.
- **Single-source theming** — every color is derived from ONE seed via `ColorScheme.fromSeed`. Switch brand preset in Settings → whole app re-themes (light & dark).
- **Light / Dark / System** mode, persisted across sessions.
- **Localization** — English + Bahasa Indonesia (easy to extend via `lib/l10n/*.arb`).
- **Offline-first** — local SQLite (`sqflite`) with a clean repository abstraction. Backend team can swap implementations to REST without touching UI code.
- **Feature-complete demo flow**: PIN login → POS → cart → checkout → receipt → orders → tables → dashboard → product/category management → settings.

## 📱 Demo PIN

```
1234
```

## 🚀 Run

```bash
flutter pub get
flutter run                   # mobile / web
flutter run -d macos          # desktop (good for showing responsive split layout)
```

## 🧱 Architecture

```
lib/
├── core/                       # cross-cutting
│   ├── theme/                  # AppTheme, AppColors (single seed), AppDimensions
│   ├── localization/           # l10n helpers
│   ├── router/                 # go_router config
│   ├── widgets/                # EmptyState, LoadingIndicator, StatusBadge, etc.
│   └── utils/                  # formatters (money, date)
├── data/                       # data layer (swappable)
│   ├── database/               # sqflite + seed data
│   ├── models/                 # plain Dart models (with fromMap/toMap)
│   ├── repositories/           # CategoryRepository, ProductRepository, OrderRepository, TableRepository
│   └── preferences/            # SharedPreferences wrapper
├── providers/                  # Riverpod providers (settings, cart, catalog, orders)
├── features/                   # UI screens
│   ├── auth/   splash/  shared/
│   ├── pos/      (new sale, cart, checkout)
│   ├── orders/   (history + detail)
│   ├── tables/   (dine-in floor plan)
│   ├── products/ (CRUD product & category)
│   ├── dashboard/(sales summary)
│   └── settings/ (theme, brand color, language, tax, store info)
├── l10n/                       # app_en.arb, app_id.arb, gen/
└── main.dart                   # app bootstrap (theme + locale + router)
```

### Swapping local DB → REST API

The UI talks only to **Riverpod providers** which talk to **repositories**. To switch to a REST backend, replace the bodies of the repository classes (e.g. `ProductRepository.all()`) with HTTP calls — no UI changes needed.

```dart
class ProductRepository {
  Future<List<Product>> all() async {
    // Before (local):
    // final db = await AppDatabase.instance.db;
    // return (await db.query('products')).map(Product.fromMap).toList();
    //
    // After (REST):
    // final res = await http.get(Uri.parse('$baseUrl/products'));
    // return (jsonDecode(res.body) as List).map(Product.fromMap).toList();
  }
}
```

## 🎨 Theming — adding a brand color

Open `lib/core/theme/app_colors.dart` and add an entry to `BrandPreset.presets`:

```dart
static const List<BrandPreset> presets = [
  BrandPreset(id: 'flame',   name: 'Flame',   seed: Color(0xFFE85D04)),
  // ... add as many as you like, the picker in Settings auto-updates
  BrandPreset(id: 'midnight', name: 'Midnight', seed: Color(0xFF1E293B)),
];
```

Everything else (primary, primaryContainer, surface, error, etc. — both light & dark) is derived automatically by `ColorScheme.fromSeed`.

## 🌐 Adding a new language

1. Create `lib/l10n/app_xx.arb` (copy of `app_en.arb`, translated).
2. Add `Locale('xx')` to `kSupportedLocales` in `lib/core/localization/l10n.dart`.
3. Run `flutter gen-l10n`.

## 🔧 Configuration

All persisted settings live in `lib/data/preferences/app_preferences.dart`:
- Theme mode, brand color, locale
- Tax rate, currency symbol, store name/address
- Cashier profile name
- "Reset demo data" available in Settings → restores seed catalog & tables.
