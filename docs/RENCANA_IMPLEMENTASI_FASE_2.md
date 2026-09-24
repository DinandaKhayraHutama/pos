# Rencana Implementasi Fase 2 — Kelengkapan Katalog dan Pelanggan Dasar

**Status implementasi:** selesai secara implementasi dan verifikasi otomatis lokal; gate lingkungan yang belum tersedia dicatat di [FASE_2_VERIFICATION.md](FASE_2_VERIFICATION.md). Acuan fase:
[RENCANA_PARITAS_FITUR_MOKAPOS.md](RENCANA_PARITAS_FITUR_MOKAPOS.md) bagian F2.
Bukti implementasi dicatat terpisah dalam [FASE_2_VERIFICATION.md](FASE_2_VERIFICATION.md),
mengikuti pola [FASE_0_VERIFICATION.md](FASE_0_VERIFICATION.md) dan
[FASE_1_VERIFICATION.md](FASE_1_VERIFICATION.md).

## 1. Ringkasan dan keputusan

F2 menambahkan merek dan basis pelanggan ke dalam katalog, menyambungkan
pelanggan serta catatan ke alur kasir, dan membuat katalog dapat dibawa
keluar-masuk lewat CSV tanpa menggandakan entitas.

Empat celah nyata yang ditemukan dari penelusuran kode, bukan dari daftar fitur:

1. **Brand tidak ada sama sekali.** Penelusuran `brand` pada Go, SQL, dan templ
   hanya mengenai kelas CSS sidebar.
2. **Pelanggan belum menjadi modul.** Satu-satunya jejak adalah string
   `customer_name` di dalam `payload jsonb` order, dibaca
   `backend-go/internal/domain/history/history.go:392-409`. Tidak ada tabel,
   pencarian, maupun riwayat pembelian.
3. **Nama pelanggan dan catatan sudah lengkap dari state sampai wire, tetapi
   tidak punya satu pun pemanggil UI.** `setCustomerName`
   (`mobile/lib/providers/cart_provider.dart:345`), `setOrderNote` (`:347`), dan
   `setNote` (`:324`) tidak dipanggil dari mana pun di `lib/features/`. Kolom
   `orders.customer_name`, `orders.note`, dan `order_items.note` sudah ada;
   `mobile/lib/data/sync/order_push.dart:146-147` sudah mengirimnya; kunci l10n
   `posCustomerName`, `posNote`, dan `posNoteHint` sudah ada di kedua ARB tanpa
   pemakai. Kasir hari ini tidak punya cara mengisinya, dan `order.note` tidak
   dirender di mana pun.
4. **Importer katalog hanya memperbarui harga**
   (`backend-go/internal/domain/catalogue/import.go`), dan tidak ada ekspor
   katalog sama sekali.

### Keputusan yang sudah disetujui

| Aspek | Keputusan |
|---|---|
| Lokasi impor/ekspor | Backoffice saja. Flutter tidak mendapat file picker pada fase ini. |
| Izin | Membuat dan mencari pelanggan dari POS ikut `sell`. Pengelolaan Backoffice memakai izin baru `manageCustomers`, ditambahkan eksplisit ke set manajer; owner memperolehnya lewat derivasi. Brand ikut `manageCatalogue`. |
| Pelanggan di POS | Buat dan lampirkan saja; tidak ada edit maupun hapus. |
| Dimensi brand | Rollup penuh dengan penghitungan ulang histori, tanpa menaikkan `calculation_version`. |
| Importer produk | Satu importer create/update. Berkas dua kolom `sku;harga` tetap sekali terap dengan teks yang sama; preview hanya untuk berkas multi-kolom. |
| Pencarian pelanggan di POS | Dari SQLite lokal hasil pull feed. Tidak ada endpoint HTTP baru. |

**Kriteria lulus fase** (roadmap): ekspor–impor dapat dilakukan tanpa
menggandakan entitas; pelanggan yang dibuat offline tersinkron dengan ID tetap;
perubahan nama master tidak mengubah isi struk lama.

## 2. Tiga keputusan desain yang menyimpang dari rancangan awal

Ketiganya lahir dari pembacaan kode, dan masing-masing menghindari kerusakan
nyata.

### a. Pelanggan: POS membuat, Backoffice menyunting

`_push_revisions` (`mobile/lib/data/sync/outbox_store.dart:160-186`) memulai
revisi dari **1 per perangkat**. Itu aman untuk `orders` dan `pos_sessions`
karena barisnya lahir di perangkat itu. Untuk pelanggan yang ditarik dari server
lalu disunting di dua till, keduanya mengirim `revision: 1` untuk id yang sama,
dan pola `AND revision < (p->>'revision')`
(`backend-go/internal/store/queries/ingest.sql:54`) akan menelan salah satunya
tanpa jejak — sementara Backoffice tidak memiliki nomor revisi untuk ikut
bertanding. Wire v2 tidak mempunyai konsep base-revision.

Maka push pelanggan bersifat **create-only dan idempoten**. UUID perangkat
adalah kunci idempotensi. Itu sudah memenuhi kriteria "pelanggan offline
tersinkron dengan ID tetap"; edit dua arah tidak diminta F2.

### b. `customer_id` menjadi kolom, `customer_name` tidak

`customer_name` sudah dibaca dari payload
(`backend-go/internal/domain/history/history.go:392-409`), sejajar dengan
`table_name`, `promo_name`, dan `category_id`. Mempromosikannya menjadi kolom
memaksa salah satu dari dua hal buruk: setiap pembaca ber-`COALESCE(kolom,
payload->>…)` selamanya, atau UPDATE backfill melintasi seluruh partisi
`orders` — persis penulisan ulang sejarah yang F1 tolak eksplisit
(`backend-go/migrations/20260922000022_reporting_f1.sql:22`).

Maka hanya `orders.customer_id` yang menjadi kolom: nullable, tanpa foreign key,
ditulis hanya pada `InsertOrder`, tidak pernah ditulis ulang saat merge, rename,
atau hapus. Nama pada struk tetap dari payload, sehingga kriteria "perubahan
nama master tidak mengubah isi struk lama" justru lebih terjamin.

### c. Brand pada laporan: snapshot dari payload, tanpa menaikkan versi

Dua temuan mengubah rancangan awal:

- **`category_key` bukan kolom snapshot.** Ia dibaca
  `COALESCE(it.payload->>'category_id','')`
  (`backend-go/internal/domain/reporting/product_net.go:25`), dan `product_key`
  dari `it.payload->>'product_id'`
  (`backend-go/internal/domain/reporting/rollup.go:88`). Brand karena itu tidak
  boleh menjadi kolom baru pada `order_items` — itu DDL pada tabel terpartisi
  terpanas untuk sesuatu yang sudah punya tempat. Brand ikut ke
  `OrderItem.brand_id` pada payload, dan rollup membacanya dengan cara yang sama.
- **`calculation_version` tidak dinaikkan.**
  `backend-go/internal/domain/reporting/report.go:252` menghitung
  `calculation_version < 2`. Menaikkannya ke 3 akan menandai setiap slice yang
  sudah bersih sebagai belum final untuk seluruh merchant, padahal tidak satu
  pun definisi waterfall berubah. Menambahkan tabel rollup baru tidak mengubah
  metrik lama, jadi versi tetap 2 dan kelengkapan brand dilacak terpisah.

Batas data yang harus dipahami: item yang terjual sebelum F2 tidak mempunyai
`brand_id` di payload, sehingga seluruh sejarah jatuh ke satu keranjang **"Tanpa
brand"**. Itu hasil yang jujur — merekonstruksinya dari master hari ini dilarang
bagian E aturan desain roadmap — tetapi artinya penghitungan ulang historis
menghasilkan rekonsiliasi yang benar, bukan wawasan baru. Penandaan slice lama
adalah satu pernyataan `INSERT INTO report_dirty_slices` yang dapat dihilangkan
tanpa mengubah apa pun selain kelengkapan tabel brand untuk periode lama.

## 3. Urutan implementasi

### Jalur A — dapat dimulai hari pertama, paralel, tanpa dependensi

#### F2.4 — Antarmuka kasir · P1 · ukuran kecil

Nol migrasi dan nol perubahan kontrak; state, kolom, payload, serta l10n sudah
tersedia seluruhnya.

- `mobile/lib/features/pos/cart_panel.dart`: field nama pelanggan dan catatan
  pesanan dipasang di bawah `_TableField` (`:167-181`), mengikuti pola
  conditional-nya.
- Catatan per item pada `_CartLineTile` (`:380-489`). `onTap` sudah dipakai
  `_editLine`, jadi catatan masuk ke sheet yang sama, bukan entry point kedua.
- Render `order.note` pada `order_detail_page.dart` dan `receipt_document.dart`.
- Kunci l10n baru ditambahkan ke `app_en.arb` **dan** `app_id.arb`, lalu
  `fvm flutter gen-l10n`. Checklist layar baru pada `mobile/CLAUDE.md:828-849`
  berlaku penuh.

#### Proteksi formula injection pada ekspor POS · P1 · ukuran kecil

`mobile/lib/core/print/report_csv.dart:127` hanya menangani koma, kutip, dan
newline. Nama kategori dan kasir sudah masuk CSV hari ini, dan nama pelanggan
serta brand menambah dua permukaan lagi. Tiru `safeText`
(`backend-go/internal/domain/reporting/csv.go:50`).

### Jalur B — rantai backend, berurutan

#### F2.1 — Master brand dan feed · P0 · ukuran sedang

Migrasi `20260923000023_brands.sql`:

- Tabel `brands` mengikuti pola `categories`
  (`backend-go/migrations/20260910000007_catalogue.sql:22-39`), kolom
  `products.brand_id` dengan foreign key komposit `(tenant_id, brand_id)`, RLS
  `ENABLE` dan `FORCE`, policy `tenant_id = app.current_tenant_id()`, serta
  `GRANT` ke `justclick_app`.
- `brands_sync_feed_idx`, dan **DROP lalu CREATE `products_sync_feed_idx`** agar
  `brand_id` masuk daftar `INCLUDE`. Presedennya
  `backend-go/migrations/20260911000009_backoffice_writes.sql:16-18`. Bagian
  `Down` harus mengembalikan daftar `INCLUDE` persis seperti
  `20260910000007_catalogue.sql:125-127`, atau roll-down CI merah.

Kemudian, dalam urutan ini:

1. `backend-go/internal/domain/syncfeed/registry.go:89` — sisipkan entity
   `brands` **sebelum** `products`; tambahkan `uuidCol("brand_id")` ke allow-list
   kolom `products` dan `"brands"` ke `DependsOn`-nya. Urutan slice adalah
   kontrak.
2. `backend-go/internal/infra/syncfixture/seed.go:66` — cabang `default:`
   mengembalikan error, sehingga entity baru tanpa case di sini langsung
   mematikan `TestPullUsesAnIndexOnlyScan`,
   `TestRealPostgresRowsConformToOpenAPI`, `verify-sync`, `verify-sync-load`,
   `verify-flutter`, dan `loadtest/fleet.go`. Ini pekerjaan pertama, bukan
   terakhir.
3. `backend-go/api/openapi.yaml` — schema `BrandRow`, dan `brand_id` ditambahkan
   ke `ProductRow` pada `required` **dan** `properties`.
   `TestPublishedColumnsExactlyMatchFrozenRowSchemas` memakai
   `require.Len(t, s.Properties, len(cols))` tanpa toleransi properti ekstra.
4. Dua peta entity ke schema, bukan satu:
   `backend-go/internal/domain/syncfeed/contract_test.go:13` dan
   `wire_rows_test.go:18`.
5. Domain `SaveBrand` dan `DeleteBrand` mencontoh `SaveCategory` dan
   `DeleteCategory` (`internal/domain/catalogue/catalogue.go:97,150`), termasuk
   `claim()` sebelum update dan aturan hanya menulis perbedaan. **Menghapus
   brand yang masih dipakai ditolak**, mengikuti preseden `ErrCategoryInUse`
   (`internal/backoffice/catalogue.go:116`) — bukan cascade-null, yang akan
   menuntut renumbering `products` ala `retire.go:31` dan di perangkat justru
   menghapus produk.
6. Backoffice CRUD `/backoffice/catalogue/brands` di dalam grup
   `auth.ManageCatalogue`, entri pada grup **Library** di
   `internal/backoffice/views/nav.go:70`, dan `Select` brand pada form produk.
   `templ generate` wajib, hasilnya di-commit.
7. `go run ./scripts/verify-sync` harus hijau sebelum melanjutkan.

#### F2.5a — Ekspor katalog · P1 · ukuran kecil

Read-only, risiko terendah, dan mendefinisikan skema berkas untuk importer,
sehingga dikerjakan lebih dulu. CSV dengan `id` uuid pada kolom pertama, memakai
ulang `RenderCSV` dan `safeText` sehingga BOM UTF-8 serta proteksi formula
injection ikut terwarisi. Foto tidak masuk CSV.

#### F2.5b — Importer produk create/update · P1 · ukuran sedang

Memperluas `internal/domain/catalogue/import.go` dan mempertahankan sifat yang
sudah benar: all-or-nothing di satu `feed.Write`, `FOR UPDATE` sebelum
membandingkan, hanya baris berubah yang mendapat `sync_seq`, dan pesan kesalahan
per baris dalam Bahasa Indonesia.

- **Jalur lama tidak boleh berubah perilakunya.**
  `backend-go/scripts/verify-backoffice-crud/main.go:458-467` mengunggah
  `sku;harga`, menuntut teks `1 harga berubah`, **langsung** menarik feed dan
  menuntut harga sampai ke till pada POST yang sama, lalu menuntut `tidak ada
  harga yang diubah` untuk berkas cacat. Preview yang menuntut POST kedua
  mematahkan ketiganya sekaligus. Maka berkas dua kolom tetap sekali terap
  dengan teks identik; preview hanya untuk berkas multi-kolom.
- **`pg_advisory_xact_lock` per tenant untuk seluruh transaksi impor.**
  `products.sku` tidak mempunyai unique constraint; `ImportPrices` aman hanya
  karena `FOR UPDATE OF p` mengunci baris yang sudah ada. Begitu importer boleh
  membuat, dua impor bersamaan menghasilkan SKU kembar yang setelahnya membuat
  setiap impor berbasis SKU ditolak selamanya.
- Pencocokan baris: `id` lebih dulu, lalu `sku` (ambigu ditolak, tidak ditebak),
  selain itu baris baru. **`id` yang tidak dikenal ditolak, tidak dibuat** —
  membuat baris dengan id pilihan klien melanggar kalimat pembuka paket `ingest`
  dan membuka jalan impor lintas tenant.
- Kolom yang hadir di header menentukan field yang diperbarui. Referensi
  kategori atau brand yang tidak dikenal ditolak per baris. Baris yang tidak
  tercantum dalam berkas tidak berarti dihapus.
- **Preview terikat pada isi berkas**: dihitung di dalam transaksi yang
  di-rollback dan mengembalikan hash isi berkas; commit menolak hash yang tidak
  cocok.
- Parser `readPriceList` (`internal/backoffice/catalogue.go:563-626`)
  digeneralisasi dengan mempertahankan strip BOM, auto-deteksi delimiter `;`
  versus `,`, dan `parseRupiah` sebagai satu-satunya pembaca uang.

#### F2.2 — Master pelanggan dan feed pull+push · P0 · ukuran sedang

Migrasi `…0024_customers.sql`, **terpisah** dari brands supaya roll-down lebih
bersih dan F2.1 dapat dirilis lebih dulu.

- Tabel `customers` dengan kolom normalisasi `phone_norm` dan `email_norm`
  (index non-unik, untuk **menandai** duplikat), `merged_into_id` dengan
  `CHECK (merged_into_id <> id)`, covering index feed, RLS, dan grant.
- `registry.go`: entity `customers`, `ScopeCompany`, `Push: true`. Sertakan case
  `syncfixture`, dua peta schema, dan `CustomerRow` di openapi.
- **Ingest wajib dibungkus `s.feed.Write`.**
  `internal/domain/ingest/ingest.go:145` hanya membungkus stok, table status
  events, dan orders. Pelanggan menomori feed yang ditarik, sehingga tanpa ini
  pelanggan dari till A tidak pernah sampai ke till B — dan tidak ada yang gagal
  dengan keras.
- **Ingest wajib idempoten.** `internal/domain/ingest/ingest.go:283-285`
  memetakan `23505` ke `duplicate` dengan `retry: false`, yang berakhir sebagai
  `rejected` lalu dead-letter. ACK yang hilang di jaringan lalu kirim ulang byte
  yang sama akan membuang pelanggan yang baru dibuat kasir ke dead-letter,
  sementara order yang menyebut id-nya tetap naik. Gunakan
  `ON CONFLICT (tenant_id, id) DO NOTHING` lalu balas `accepted`, mengikuti
  aturan "exact retry diterima" pada `backend-go/CLAUDE.md:620`.
- Izin `manageCustomers` menyentuh `internal/domain/auth/permission.go`
  (konstanta, `AllPermissions` dalam urutan deklarasi enum Dart, dan
  `managerPermissions`) serta `mobile/lib/core/auth/permissions.dart` (enum dan
  `_manager`). Keduanya dijaga `TestPermissionStringsMatchTheDartEnum`.
- Backoffice `/backoffice/customers`: daftar berhalaman dengan pencarian
  mengikuti pola `catalogue.go:productsPage:182`, form, aturan "nonaktifkan,
  jangan hapus", dan badge duplikat kontak.

#### F2.3 — Pelanggan melekat pada transaksi · P0 · ukuran sedang

Migrasi `…0025` menambahkan `orders.customer_id` saja.

- `api/openapi.yaml`: `Order.customer_id` nullable dan `OrderItem.brand_id`.
  Keduanya memakai `additionalProperties: false`, sehingga spesifikasi harus
  lebih dulu. **Naikkan Device API 2.5.0 menjadi 2.6.0**; master-data feed tetap
  versi 1. Perbarui `backend-go/CLAUDE.md:610` ("16 current feeds") dan `:1090`.
- `internal/store/queries/ingest.sql:37` `InsertOrder` mengekstrak `customer_id`.
  Regenerasi sqlc mengubah `internal/store/models.go`.
- Halaman detail pelanggan dengan riwayat pembelian: `orders` adalah
  `PARTITION BY RANGE (business_date)`, sehingga `WHERE customer_id = ?` tanpa
  batas tanggal membuka seluruh partisi. Wajib memakai jendela tanggal (default
  12 bulan) melalui filter periode yang sudah ada di `internal/domain/history`.

#### F2.6 — Impor/ekspor pelanggan, duplikat, dan merge · P1 · ukuran sedang

Dikerjakan setelah F2.2 dan F2.3.

- Ekspor dan impor CSV memakai mesin serta pelaporan kesalahan yang sama dengan
  F2.5. Ekspor pelanggan adalah data pribadi yang keluar dari sistem: lewat
  `safeText`, dan catat satu baris audit.
- Duplikat kontak ditandai pada daftar, tidak ditolak saat impor.
- Merge: pemenang dipilih, yang lain menerima `merged_into_id` dan tombstone.
  **Resolusi dilakukan saat membaca, bukan saat menulis** — perangkat yang
  offline seminggu dapat mengirim order yang menyebut id yang sudah dilebur, dan
  menerjemahkannya di ingest berarti menulis sesuatu yang tidak dikirim till.
  Rantai A ke B ke C dicegah dengan path-compression saat merge. Order tidak
  pernah ditulis ulang.

### Jalur C — mobile, satu kali kenaikan skema

SQLite **v31 tunggal** memuat `brands`, `customers`, dan `orders.customer_id`
sekaligus: satu siklus `migration_test.dart`, bukan tiga. Tabel yang server-nya
belum siap tidak berbahaya karena `supportedEntities` beririsan dengan manifest.

- `mobile/lib/data/database/app_database.dart`: konstanta DDL dipakai **dua
  kali** (`_createSchemaV2` untuk instalasi baru, blok `if (oldVersion < 31)`
  untuk upgrade), `_addColumnIfMissing` untuk kolom. Blok versi hanya DDL;
  seeder dan backfill apa pun masuk bagian *deferred data steps* (`:644-728`).
- **`orders.customer_id` lokal tanpa foreign key.** `catalogue_sync` menerapkan
  tombstone sebagai `txn.delete`, dan pola rumah di perangkat adalah cascade
  (`products.category_id … ON DELETE CASCADE`, `:2056`). Dengan FK cascade,
  merge pelanggan berarti menghapus order di till. Uji ini secara eksplisit.
- Empat daftar yang harus berubah serempak: `CatalogueSync.supportedEntities`
  (`lib/data/sync/catalogue_sync.dart:95`), `_connectedStoreTables`
  (`app_database.dart:1965`, anak sebelum induk), `invalidateSyncedData`
  (`lib/providers/synced_data.dart`), dan daftar delete `AppDatabase.reset()`
  (`app_database.dart:3197`).
- Outbox: `CustomerPush` disisipkan ke `OutboxStore.pushOrder`
  (`lib/data/sync/outbox_store.dart:68`, sebelum `OrderPush.entity`) **dan** ke
  switch `payloadWithin` (`:88-101`). Tanpa keduanya entity baru tidak akan
  pernah dikirim.
- **Gate rilis.** `Order` memakai `additionalProperties: false` dan payload
  outbox dibekukan saat enqueue. Build till yang mengirim `customer_id` ke server
  yang masih 2.5.0 menghasilkan `schema_rejected`, yang berstatus rejected dan
  bukan retry, sehingga struk masuk dead-letter. Kirim `customer_id` dan
  `brand_id` hanya bila manifest mengiklankan entity `customers` dan `brands`.
  `lib/data/sync/outbox_push.dart` belum pernah membaca manifest, jadi gate ini
  dipasang di sana dengan cache `SyncMetaStore`.
- Repository brand dan pelanggan, serta sheet pencarian/pembuatan pelanggan di
  POS. Editor master di-gate `TillBinding.current != null` mengikuti pola
  `modifier_repository.dart:16-20` dan gate rute `app_router.dart:150-155`.

### Jalur D — terakhir

#### F2.7 — Dimensi brand pada laporan · P1 · ukuran sedang

Migrasi `…0026_reporting_brand.sql`: tabel `daily_brand_rollup` mengikuti pola
`daily_category_rollup`, dengan RLS, grant, dan index tanggal, **tanpa menyentuh
`calculation_version`**, ditambah `INSERT INTO report_dirty_slices` untuk
menandai slice historis.

- Brand dibaca `COALESCE(it.payload->>'brand_id','')`. Sentinel kosong dirender
  "Tanpa brand" mengikuti `reporting.Uncategorised`
  (`internal/domain/reporting/allocate.go:10`). Alokasi memakai largest-remainder
  yang sudah ada, sehingga jumlah net per brand sama dengan jumlah net per
  produk dan dengan net harian.
- Titik sentuh reporting: `rollup.go:16` (`rollupTables`), `consistency.go:18-22`
  (peta fingerprint), dan `report.go` — **batch query-nya posisional**, sehingga
  menyisipkan `batch.Queue` di tengah menggeser seluruh indeks pembacaan.
  Kemudian `tables.go`, `csv.go`, `xlsx.go`, `pdf.go`, `exports.go`,
  `internal/httpapi/v2/reports.go:169`, `render_test.go:22`, `rollup_test.go:57`,
  dan `fixture_test.go`.
- Fixture Go (`internal/domain/reporting/fixture_test.go`) dan padanan Dart
  (`mobile/test/repositories/report_waterfall_test.dart`) diperbarui bersama
  dengan angka harapan ditulis eksplisit.

#### F2.8 — Verifikasi dan dokumentasi · P1 · ukuran kecil–sedang

- `scripts/verify-catalog-io` dan `scripts/verify-customers` mengikuti pola
  verify-* yang ada: program Go yang menembak HTTP ke stack berjalan, fungsi
  `check(name, ok, …)`, `VERIFY_BASE_URL`, cookiejar dan parsing CSRF.
- Daftarkan keduanya di `.github/workflows/backend-go.yml:132-143` setelah
  `verify-history`.
- Perbarui [MANUAL_TEST_LOKAL.md](MANUAL_TEST_LOKAL.md), `api/openapi.yaml`, dan
  status fase pada [RENCANA_PARITAS_FITUR_MOKAPOS.md](RENCANA_PARITAS_FITUR_MOKAPOS.md).

### Paralelisasi yang aman

Jalur A sepenuhnya paralel dengan Jalur B. F2.5a dapat berjalan bersamaan dengan
F2.2. Jalur C boleh dimulai setelah F2.1 selesai dan diselesaikan setelah F2.2.

## 4. Titik sentuh yang mudah terlewat

| Berkas | Mengapa patah |
|---|---|
| `internal/infra/syncfixture/seed.go:66` | Cabang `default:` mengembalikan error; entity baru tanpa case mematikan lima gate sekaligus |
| `syncfeed/contract_test.go:13` dan `wire_rows_test.go:18` | Dua peta entity ke schema yang terpisah |
| `syncfeed/pull_test.go:271` | Menuntut nama index persis `<table>_sync_feed_idx` |
| `api/contract_test.go:34` | Menghitung respons 2xx per operasi; aman selama tidak ada endpoint HTTP baru |
| `internal/store/models.go` dan `*.sql.go` | sqlc membaca seluruh `migrations/`; setiap ALTER memicu regenerasi |
| `internal/httpapi/wire/models.gen.go` | DTO dihasilkan dari `api/openapi.yaml` |
| `internal/backoffice/views/*_templ.go` | Di-commit; CI gagal atas diff `templ generate` |
| `internal/infra/pgtest` | Nama template database membawa hash berkas migrasi |
| `mobile/test/repositories/migration_test.dart`, `native_file_persistence_test.dart:60` | Memakai `AppDatabase.currentVersion` |
| `.github/workflows/flutter.yml:46` | Menjalankan `test/repositories` dan `test/sync` |

## 5. Pengujian dan kriteria selesai

Perintah Go dijalankan dari `backend-go/`, Flutter dari `mobile/`.

```bash
# backend
go build ./... && go vet ./...
templ generate && go generate ./api ./internal/store    # harus 0 diff
go test ./... -count=1                                   # butuh PostgreSQL dan Redis nyata
go run ./cmd/justclick migrate up                        # lalu down lalu up pada database berisi data
go run ./scripts/verify-activation                       # dijalankan PERTAMA: rate limiter Redis
go run ./scripts/verify-sync ./scripts/verify-backoffice-crud
go run ./scripts/verify-catalog-io ./scripts/verify-customers
go run ./scripts/verify-reports ./scripts/verify-history

# mobile
fvm flutter gen-l10n && fvm flutter analyze --no-fatal-infos
fvm flutter test && fvm flutter build apk --debug
```

### Pengujian otomatis

Sesuai `mobile/.claude/rules/testing-policy.md`, unit test untuk model,
repository, dan kalkulasi tetap ditulis; suite widget maupun E2E baru tidak.
Yang ditambahkan: migrasi v30 ke v31 memakai pola berkas nyata seperti
`test/repositories/history_migration_test.dart`, `BrandRepository` dan
`CustomerRepository`, payload push pelanggan, serta angka rollup brand yang
dipatok tangan. Sisi Go tetap menulis test domain, kontrak, migrasi, konkurensi,
dan isolasi terhadap PostgreSQL serta Redis nyata.

### UAT lokal dua perangkat

Skenario yang harus benar-benar dibuktikan:

1. Buat pelanggan **offline** di perangkat A, tutup aplikasi, buka kembali, lalu
   sambungkan. Pelanggan naik dengan **UUID yang sama**, muncul di Backoffice,
   dan tertarik perangkat B.
2. Push diterima lalu ACK hilang, perangkat mengirim ulang byte yang sama.
   Hasilnya `accepted`, satu pelanggan, nol dead-letter.
3. Ekspor katalog lalu impor berkas yang sama tanpa perubahan: nol entitas baru,
   nol kenaikan `sync_seq`, till tidak terbangun.
4. Unggah berkas lama `sku;harga`: perilaku dan teks persis seperti sebelum fase
   ini.
5. Dua impor bersamaan pada tenant yang sama: advisory lock membuatnya
   berurutan, nol SKU kembar.
6. Ganti nama brand dan pelanggan setelah struk terbit: struk lama dan detail
   transaksinya tidak berubah.
7. Merge dua pelanggan: riwayat pemenang memuat keduanya, nol order hilang di
   till (uji FK cascade), dan till berhenti menawarkan yang dilebur.
8. Laporan brand menjumlah ke penjualan bersih yang sama; periode sebelum F2
   seluruhnya berada di "Tanpa brand".
9. Build till baru terhadap server 2.5.0: `customer_id` tidak dikirim, struk
   tetap naik.
10. Manipulasi lintas tenant pada id brand, pelanggan, atau impor ditolak server.

### Gate lingkungan

Gate yang sudah diketahui belum dapat dijalankan pada host pengembangan tetap
dicatat sebagai **tertunda**, bukan lulus: build rilis Windows (Visual Studio
dengan workload Desktop development with C++ belum terpasang) dan eksekusi
workflow GitHub aktual.

F2 dinyatakan selesai setelah bukti pengujian dicatat di
`docs/FASE_2_VERIFICATION.md` dan seluruh kriteria yang relevan lulus.
Pengujian yang belum dapat dijalankan ditulis sebagai tertunda, bukan dianggap
berhasil.

## 6. Batas fase dan asumsi

- F2 tidak menambahkan sales type, profil pajak/layanan, diskon per item, custom
  amount, saved bill, split payment, refund parsial, role kustom, loyalty,
  maupun feedback pelanggan.
- Pelanggan tidak dapat diedit atau dihapus dari POS; perangkat hanya membuat
  dan melampirkan.
- Brand adalah label datar tanpa hierarki, dan belum menjadi filter pada grid
  kasir.
- Impor tidak pernah menghapus: baris yang tidak tercantum adalah baris yang
  tidak disebut.
- Foto produk tetap dikelola melalui alur unggah gambar; tidak ada kolom gambar
  di CSV.
- Riwayat pembelian adalah tampilan atas order yang ada dalam jendela tanggal.
  Transaksi lama yang tidak pernah merekam pelanggan ditampilkan sebagai tanpa
  pelanggan.
- Laporan brand untuk periode sebelum F2 seluruhnya berada di "Tanpa brand".
  Itu batas data, bukan cacat.
- Implementasi mengikuti Jalur A sampai D di atas, dengan pengujian pada setiap
  bagian dan verifikasi gabungan sebelum fase ditutup.
