# Rencana Implementasi Fase 3 — Pengaturan Bisnis, Akses, dan Mesin Harga

**Status:** rencana disetujui pada 23 September 2026; **implementasi selesai
24 September 2026** — bukti di [FASE_3_VERIFICATION.md](FASE_3_VERIFICATION.md),
penyimpangan di bagian 7. Acuan fase: [RENCANA_PARITAS_FITUR_MOKAPOS.md](RENCANA_PARITAS_FITUR_MOKAPOS.md)
bagian F3 dan aturan desain A–E. Bukti implementasi dicatat terpisah di
`FASE_3_VERIFICATION.md`, mengikuti pola
[FASE_2_VERIFICATION.md](FASE_2_VERIFICATION.md). Path Go relatif ke
`backend-go/`, path Dart relatif ke `mobile/`.

## Konteks

F2 selesai. F3 memindahkan konfigurasi bisnis ke server (dicache offline),
mengganti tiga role tetap dengan role berbasis permission, dan membangun satu
mesin harga integer yang identik di Go dan Flutter, beserta master sales type,
metode pembayaran, dan diskon, tanpa membiarkan till lama salah membaca model
baru.

### Celah nyata yang ditemukan dari kode

1. **Tidak ada tabel pengaturan di server.** PB1, service charge, nama/alamat
   toko hidup di SharedPreferences tiap till (`lib/data/preferences/app_preferences.dart`)
   dan tetap bisa diedit lokal di till terhubung tanpa pernah naik
   (`lib/features/settings/settings_page.dart:157-261`). `manageSettings` tidak
   dicek di mana pun di server.
2. **Perubahan role/active tidak pernah sampai ke sesi yang sedang login.**
   `invalidateSyncedData` (`lib/providers/synced_data.dart:13-37`) tidak
   menyegarkan `settingsProvider`; pegawai yang di-tombstone kembali sebagai
   **owner** saat cold start (`settings_provider.dart:232`); pegawai nonaktif
   tetap login (`EmployeeRepository.byId` tanpa filter active).
3. **Fallback yang justru dilarang roadmap:** `OrderTypeX.fromWire` → `dineIn`,
   `PaymentMethodX.fromWire` → `cash` (`lib/data/models/enums.dart:34-48`),
   `EmployeeRoleX.fromWire` → `cashier` (`lib/data/models/employee.dart:33-36`).
4. **Uang dihitung dengan double dan tanpa alokasi sisa** (`lib/providers/cart_provider.dart:162-203`).
   Go sama sekali tidak menghitung pajak/layanan; ingest hanya mencocokkan
   penjumlahan header (`internal/domain/ingest/validate.go:44`) dan baris (`:60-83`).
5. **Server memeriksa nama role, bukan permission:** `ingest/till.go:129,206`
   (`role != "cashier"`), `ingest/till_history.go:124`, `staff/staff.go:108`,
   `backoffice/auth.go:105`, `staff/manage.go:191-370`.
6. **Nama approver diskon manual masuk `promo_name`** (`providers/order_provider.dart:235`),
   tercetak di struk sebagai `Diskon (<nama approver>)`
   (`core/print/receipt_document.dart:174-175`) dan sengaja dipakai sebagai
   label di `adjustmentSQL` (`reporting/rollup.go:131-137`).
7. Checkout tidak memeriksa uang tunai ≥ total (`features/pos/checkout_sheet.dart:244-281`)
   dan total dihitung tiga kali terpisah (`:68`, `:270`, `order_provider.dart:186-198`).
8. Kunci media terkunci ke `products/…` (`internal/infra/media/media.go:46-47`),
   tidak ada tempat untuk logo struk. Timezone tenant tidak bisa diedit, dan
   `hourlySQL` (`rollup.go:122-127`) membaca timezone *saat ini* untuk seluruh
   histori. Loadtest mengirim `"dinein"` (`scripts/loadtest/device.go:243`, `scale.go:358`).

### Keputusan yang sudah disetujui

| Aspek | Keputusan |
|---|---|
| Role kustom | Boleh menggabungkan `sell`/`openCloseShift` dengan izin manajerial. Cek server menjadi `Grants(openCloseShift)`/`Grants(sell)`. Tiga role sistem tetap persis seperti sekarang; owner tetap diturunkan (semua − set till). |
| Mesin harga | Paket murni di Go dan Dart, dijaga golden vector JSON bersama. Ingest menolak **hanya** penjumlahan header/baris yang tidak menutup; selisih hitung ulang server dari snapshot order **ditandai anomali**, tidak ditolak. |
| Timezone | Per tenant, diedit owner, dibatasi Asia/Jakarta, Asia/Makassar, Asia/Jayapura (offset tetap). Till memakai offset untuk `business_date`; perubahan menandai slice dirty; histori tidak ditulis ulang. |
| Gate perangkat | Till mengirim header kapabilitas; server menyimpannya di `devices`. Backoffice memblokir aktivasi fitur selama ada device aktif yang belum mampu. Till baru vs server lama memakai gate manifest F2. |

### Default yang dipilih perencana (dapat dikoreksi sebelum eksekusi)

| # | Default | Alasan |
|---|---|---|
| D1 | Satu saklar per outlet `pricing_model` (`legacy`/`v2`) dengan kapabilitas `pricing-v2`. Harga per sales type, sales type kustom, mode include, pembulatan, diskon item, custom amount, dan jenis bayar baru (`ewallet`/`transfer`/`other`) semuanya di baliknya. | Satu gate mudah dijelaskan dan diuji; armada campuran mustahil. |
| D2 | Kapabilitas terpisah `roles-v1`, dicek **se-tenant**, sebelum role kustom boleh ditugaskan. | Feed pegawai company-wide; app lama membaca role asing sebagai kasir yang boleh jual. |
| D3 | Satu pajak (PB1) dan satu service charge per outlet: default tenant di `business_settings`, override outlet di `outlet_settings` (`null` = warisi, `0` = override sah). Produk tetap `tax_rate` (`null` = warisi, `0` = bebas). | Memenuhi "profil pajak/layanan" tanpa model multi-pajak. |
| D4 | Service charge selalu ditambahkan di atas. Mode include: pajak *diekstrak* dari harga item; pajak atas bagian service *ditambahkan*. `service_taxable` default true. | Mempertahankan urutan sekarang (SC dulu, PB1 di atasnya). |
| D5 | Pembulatan pada total bill untuk semua metode bayar (unit 0/100/500/1000; nearest/up/down). | Total yang berubah per metode merusak split payment F5. |
| D6 | Izin baru `enterCustomAmount` ditambahkan **di akhir** enum. Owner memperolehnya lewat derivasi; **tidak** ditambahkan ke manager; bisa masuk role kustom. Diskon item dan diskon nilai kustom memakai `applyManualDiscount`. | Tafsir ketat "role lama tidak mendapat akses tambahan". |
| D7 | Track server: `served_by_*` dipilih dari pegawai aktif yang rolenya punya akses POS. Tanpa izin baru. | Sederhana. |
| D8 | Selama owner belum menyimpan pengaturan outlet di Backoffice (`configured_at IS NULL`), till terhubung tetap memakai preferensi lokal dan menandainya "hanya perangkat ini". Setelah dikonfigurasi, nilai server berlaku dan bagian Bisnis menjadi read-only. | Tidak diam-diam mengubah tarif merchant yang mengaturnya di till. |
| D9 | Outlet tanpa baris penugasan memakai semua sales type/metode bayar aktif. | "Tanpa baris = warisi", tanpa seed per outlet. |
| D10 | Device API 2.7.0 → **2.8.0 dalam satu rilis kontrak**, dikirim **sebelum** feed konfigurasi yang bisa menghasilkan field baru. | Lihat 2h. |

**Kriteria lulus fase:** dataset yang sama menghasilkan nominal identik di Go
dan Flutter; perubahan konfigurasi tidak mengubah bill/struk yang sudah
dibekukan; role lama tidak mendapat akses tambahan tanpa penetapan.

## 2. Keputusan desain yang menyimpang dari rancangan naif

### a. Role: tabel untuk identitas, kode untuk set izin sistem, `employees.role` diturunkan trigger

- Tabel `roles` (`id, tenant_id, name, system_key NULL CHECK IN (cashier,manager,owner), permissions text[], pos_access, backoffice_access, sort_order, sync_seq, deleted_at`), `UNIQUE (tenant_id, system_key)`, `CHECK (system_key IS NULL OR permissions = '{}')`.
- **Role sistem tetap mengambil izin dari kode** (`rolePermissions`, `internal/domain/auth/permission.go:107`), sehingga owner tetap diturunkan dan permission baru sampai ke owner tanpa reseed. Role kustom menyimpan daftar izin; string asing dibuang saat dibaca, tidak pernah diberikan.
- **Seed lewat trigger `AFTER INSERT ON tenants`** plus backfill tenant lama — jika tidak, setiap fixture, `tenancy/provision.go:113`, `pgtest`, dan seed loadtest patah pada `role_id NOT NULL`.
- **`employees.role_id` + trigger derivasi dua arah** (`BEFORE INSERT OR UPDATE OF role, role_id`): `role := COALESCE(system_key,'custom')`, atau `role_id :=` baris sistem untuk `role`. CHECK dilonggarkan menjadi `+ 'custom'`. Semua lookup `role = 'owner'` yang ada (`staff/manage.go:370`, `platform/impersonation.go:71`, `platform/tenants.go:201,635`) tetap bekerja tanpa diubah, dan `role` tidak bisa melenceng dari `role_id`.
- **Go:** `auth.Access{System, perms, POS, Backoffice}` dengan `Grants(p)`; `staff.Employee.Can` (`staff/staff.go:45`, satu-satunya titik cek Backoffice) mendelegasikan ke sana; `UsesBackoffice()` menjadi flag `Backoffice`. `tillEmployee` (`ingest/till.go:89-97`) join `roles`, tetap dibaca live per request; `TillLogin` menolak role tanpa `pos_access`. `resolveHistory`: `viewAllOrders` → cakupan bebas, `viewOwnOrders` → tiga batas hari ini, keduanya tidak → `forbidden_scope` (hasil role sistem identik dengan sekarang).
- **Tanpa eskalasi:** izin yang boleh diberikan = izin editor ∪ `TillPermissions`; tidak boleh menugaskan/mengedit role di luar itu, tidak boleh mengubah role sendiri atau role yang dipegang sendiri; hanya owner yang menugaskan role owner; baris sistem tidak bisa diedit/dihapus; role yang dipakai tidak bisa dihapus (pola `ErrCategoryInUse`).
- **Dart:** feed `roles`; resolver `role_id` → sistem → `permissionsFor(system)`; kustom → izin terurai; `role_id` ada tapi baris belum ditarik → **terkunci** (set kosong, login POS ditolak); `role_id` null → teks `role` lama, asing → **terkunci**, bukan kasir. `SettingsState` membawa `EmployeeAccess`. `homeRouteFor(access)`: `sell ? '/' : viewDailySummary ? '/dashboard' : '/settings'` (`/settings` tidak ada di `routePermissions`, jadi tidak ada loop redirect).

### b. Kontrak mesin harga

- Lokasi: `internal/domain/pricing` (tanpa DB) dan `lib/core/pricing/` (Dart murni; test memastikan tanpa import `package:flutter`).
- **Aturan integer:** tarif dalam basis point (0–10000; `products.tax_rate` yang `double precision` dikonversi di till). `mulDiv` eksak (Go memakai pola `big.Int` `reporting/allocate.go:156-165`; Dart jatuh ke `BigInt` di atas 2^53 karena int web adalah double). Diskon persen dibulatkan ke bawah (seperti sekarang), pajak dan layanan half-up.
- **Alokasi:** floor lalu **seluruh sisa ke bobot terbesar, seri ke indeks baris terkecil** — metode rumah yang sudah dipakai `reporting.allocate` dan `aggregateCategorySales`, diekspor sekali sebagai `Allocate(total, weights)` agar split/refund F5 memakai fungsi yang sama.
- **Algoritma v2** (per baris: `U` = harga dasar terselesaikan + delta varian + Σ delta modifier, `Q`, tarif `r`):
  1. `G = U·Q`; `subtotal = ΣG`.
  2. Diskon baris → `D`; `A = G − D`.
  3. Diskon bill atas `ΣA` → `BD`, dialokasikan dengan bobot `A` → `S`; `N = A − S`; `discount = ΣD + BD`.
  4. Include: `E = roundHalfUp(N·10000/(10000+r))`, `TI = N − E`. Exclude: `TI = 0`, `E = N`. `net_amount = E`.
  5. `SC = roundHalfUp(ΣE · sc/10000)`, dialokasikan dengan bobot `E` → `SS`.
  6. Exclude: `TX = roundHalfUp((E + [taxable]·SS)·r/10000)`. Include: `TX = TI + roundHalfUp([taxable]·SS·r/10000)`. `tax = ΣTX`, `tax_included = ΣTI`.
  7. `pre = subtotal − discount + SC + tax − tax_included`, dibulatkan ke unit menurut mode, tidak pernah < 0; `rounding_amount = R − pre`; `total = R`.
- **v1 (legacy)** = port persis `cart_provider.dart:133-203` (termasuk share floor tanpa sisa, tanpa pembulatan). `test/cart/cart_math_test.dart:223-401` **tidak disentuh** (6039, 550, 503, 54900+2745+5765). Go juga mengimplementasikan v1 agar satu format vector mencakup keduanya; server tidak pernah menghitung ulang order v1. Order lama adalah snapshot dan tidak dihitung ulang.
- **Persamaan header** (`validate.go:44`) menjadi `total == subtotal − discount + tax − tax_included + service_charge_amount + rounding_amount` dengan `0 ≤ tax_included ≤ tax`. Client lama mengirim keduanya 0 → persamaan hari ini.
- **Rincian baris di payload item:** `tax_rate_bp, line_discount, bill_discount_share, service_share, tax_amount, tax_included, net_amount`, spesifikasi diskon, `base_price`, `price_source`, `custom`. Untuk `pricing_version = 2` ingest juga menolak bila Σ baris ≠ header atau `net ≠ U·Q − ld − bs − ti`. Setelah itu `pricing.Compute(snapshot)`; beda → `orders.pricing_mismatch = true` (ditulis saat insert saja) + catatan `ingest_log`.
- **Kolom baru `orders`:** `tax_included bigint NOT NULL DEFAULT 0`, `rounding_amount bigint NOT NULL DEFAULT 0`, `pricing_mismatch boolean NOT NULL DEFAULT false` — default konstan, metadata-only pada tabel terpartisi, **tanpa CHECK baru** (CHECK yang ada hanya menyebut enam kolom, `20260913000012_financial_ingest.sql:71`; menambah CHECK memindai semua partisi). OpenAPI `rounding_amount` = integer int64 −1.000.000..1.000.000, bukan `Money`. Menyimpang dari preseden F2 (`customer_name` tetap di payload) karena ini uang yang dibutuhkan setiap ekspresi net dan anomali; default 0 **benar** untuk seluruh histori, jadi tidak ada backfill.
- **Laporan:** net = `subtotal − discount − tax_included`; waterfall mendapat baris "Pajak termasuk harga"; retur memakai rumus yang sama; pembulatan tampil terpisah, bukan penjualan. **`calculation_version` tidak dinaikkan** (preseden F2, `report.go:252`): definisi hanya berubah untuk order ber-`tax_included`/`rounding_amount`, yang baru mungkin ada setelah outlet diaktifkan v2 — dan tombol aktivasi v2 digabung paling akhir (F3.11). Untuk order v2, net kategori/produk/brand membaca `net_amount` snapshot baris (`reporting/product_net.go:23-31`), karena diskon item tidak proporsional; order v1 tetap memakai alokasi sekarang.

### c. Sales type dan tabel harga

- `sales_types` (company: `name, system_key dineIn|takeaway|delivery, uses_table, active, sort_order`, sistem di-seed trigger) dan `outlet_sales_types` (outlet scope, ketersediaan; tanpa baris = semua, D9).
- Harga di **dua tabel karena scope feed berbeda**: `product_sales_type_prices` (company) dan `outlet_product_sales_type_prices` (outlet scope — override satu outlet tidak boleh sampai ke semua till). Resolusi: outlet+sales type → sales type bisnis → `products.price`; delta varian dan modifier ditambahkan **sekali** ke harga dasar terselesaikan; custom amount melewati resolusi. Harga per varian per sales type di luar cakupan.
- Wire: `type` tetap (system key untuk baris sistem, literal `'custom'` untuk kustom) + snapshot `sales_type_id`/`sales_type_name`. `OrderType` Dart mendapat `other`; fallback `fromWire` → `other`, label dari `sales_type_name`. Sales type kustom hanya ada di outlet v2 (D1), jadi till lama tidak pernah melihatnya.

### d. Metode pembayaran

- `payment_groups` (company), `payment_methods` (company: `name, kind CHECK IN (cash,card,qris,ewallet,transfer,other), group_id, system_key, requires_reference, active, sort_order`; cash/card/qris di-seed trigger), `outlet_payment_methods` (outlet scope).
- **Wire `payment_method` tetap berisi KIND**, sehingga ekspektasi kas laci yang membandingkan `'cash'` tidak berubah (`ingest/recovery.go:157`, `history/sessions.go:141`, `lib/data/repositories/shift_repository.dart:184-200`). Order menambah `payment_method_id`, `payment_method_name`, `payment_reference` opsional.
- Enum Dart `PaymentMethod` + `ewallet, transfer, other`; fallback → `other`, **tidak pernah cash**. `PaymentLabel` (`reporting/report.go:555-569`) + `other`. Struk dan checkout menandai non-tunai "dicatat manual". Validasi tunai `paid ≥ total`.

### e. Pengaturan bisnis dan yang tetap preferensi perangkat

- `business_settings` (company, satu baris): default `tax_rate_bp, tax_mode, service_rate_bp, service_enabled, service_taxable`, unit/mode pembulatan, URL+hash logo, footer default, `configured_at`.
- `outlet_settings` (outlet scope, kunci `outlet_id`): field yang sama sebagai override nullable + header/footer struk, tampil alamat/telepon, `track_server`, `default_sales_type_id`, `pricing_model`, `configured_at`.
- **Nama dan timezone tenant tetap di `tenants`** dan sampai ke till lewat binding: `Authenticate` menghitung `RevisionMs = GREATEST(d, t, o, r .updated_at)` (`internal/domain/devices/devices.go:290-291`), till memanggil `/devices/me` saat revisi berubah, dan binding menyimpan `tenant` sebagai map mentah — `Tenant.timezone` cukup ditambahkan ke schema binding.
- Tetap preferensi perangkat: tema, warna brand, bahasa, nav rail, printer, pointer outlet/sesi.
- `SettingsState` mendapat `EffectiveBusinessConfig` = outlet ?? bisnis ?? (belum dikonfigurasi → preferensi, D8). Di till terhubung: bagian Bisnis read-only setelah dikonfigurasi; `/employees`, `/outlets`, `/registers` masuk blok redirect (`core/router/app_router.dart:150-156`); "Reset data demo" disembunyikan.

### f. Diskon

- Master baru `discounts` (bukan memperluas `promos`): `name, scope bill|item, kind percent|amount, value (null = nominal diisi saat checkout), requires_authorization, active, sort_order`. Till lama menarik `promos` dan memperlakukan semuanya sebagai diskon bill (`features/pos/discount_sheet.dart:143-160`); menaruh diskon item di sana akan salah diterapkan tanpa jejak.
- Izin: diskon bernama nilai tetap tanpa flag otorisasi → `sell`; nilai kustom, flag otorisasi, diskon manual ad-hoc, atau diskon item → `applyManualDiscount`, selain itu sheet override. Custom amount → `enterCustomAmount`.
- Order: `discount_id, discount_name, discount_authorized_by_id/_name` (bill) dan padanannya per baris. **`promo_name` kembali khusus promo**; label rollup menjadi `COALESCE(promo_name, discount_name, discount_authorized_by_name, '')`; struk menampilkan nama diskon, tidak pernah nama approver.
- Custom amount: item `product_id` null, `custom: true`, qty 1, label diketik kasir, tanpa efek stok, pajak default outlet; di laporan masuk sentinel tanpa kategori dengan kunci produk `name:<label>`.

### g. Track server

`served_by_id`/`served_by_name` pada order, terpisah dari `cashier_*` (penerima bayar), `authorized_by` (void/refund), dan `discount_authorized_by_*`. Tampil di struk dan detail transaksi; rollup per server ditunda ke F4.

### h. Header kapabilitas dan rilis kontrak

- `X-Device-Capabilities: pricing-v2,roles-v1` — token `[a-z0-9-]`, ≤16 token, ≤256 byte, token asing dibuang registry server. Dikirim `lib/data/sync/sync_client.dart` (di samping `X-Schema-Version`, `:118`), aktivasi, dan klien koordinator till.
- `devices.capabilities text[] NOT NULL DEFAULT '{}'` + `capabilities_reported_at`. Ditulis **hanya bila set berubah**, **tanpa menyentuh `updated_at`** (revisi device, pola `Touch` di `devices/cache.go:145-152`); trigger `device_auth_version` hanya bereaksi pada kolom token (`20260913000011_identity_hardening.sql:31`), jadi entri cache device itu dihapus eksplisit. Downgrade dicatat sebagai peringatan, sync tidak diblokir.
- `devices.IncompatibleDevices(tenant, outlet?, token)`: device tidak di-revoke dan token belum kedaluwarsa yang tidak memiliki token (verifikasi dulu apakah token kedaluwarsa bisa hidup lagi tanpa aktivasi ulang; jika bisa, hapus filter kedaluwarsa). Mengaktifkan v2 mengunci baris outlet `FOR UPDATE`, memeriksa, lalu mengubah; penugasan role kustom memeriksa se-tenant. Aktivasi mengunci outlet `FOR SHARE` dan menolak app lama bila v2/role kustom sudah aktif. Tetap di pool tenant (bukan `unscoped`).
- **Rilis kontrak F3.C0 (API 2.8.0):** `Order`/`OrderItem` memakai `additionalProperties: false` dan payload outbox dibekukan saat enqueue, maka seluruh field order opsional baru dan schema baris baru masuk OpenAPI, ingest, dan migrasi 028 **sebelum** feed apa pun yang bisa menghasilkannya. Till juga hanya mengirim field baru bila tersimpan di baris **dan** manifest mengiklankan `outlet_settings` (pola `lib/data/sync/order_push.dart:36-43`); keputusan disimpan di baris sehingga setiap revisi identik byte. `SchemaVersion`/`MinDeviceSchemaVersion` tetap 1.

### i. Penyegaran role/active pada sesi till

`SettingsNotifier.refreshSignedInEmployee()` dipanggil dari `invalidateSyncedData`
(bukan `invalidate(settingsProvider)`, yang akan menampilkan `/splash` lewat
`app_router.dart:161`). Membaca ulang pegawai **dan** baris role:

- Hilang/tombstone, nonaktif, atau tanpa `pos_access` → `logout()` (sesi POS tetap terbuka untuk pemiliknya, cache remote dilupakan, outbox dan cart utuh). Bila sheet checkout terbuka, ditunda sampai penjualan commit.
- Izin berubah → perbarui `access`; kehilangan `viewAllOrders` → `RemoteOrderRepository.forget`; guard rute berjalan ulang.
- Cold start dengan id yang tidak terselesaikan → keluar, **tidak pernah owner** (fallback owner hanya untuk mode standalone tanpa `employeeId`).
- `byPin`/`verify` menolak role terkunci dan non-POS. Revokasi instan saat offline tetap tidak dijanjikan.

### j. Timezone

- Owner mengedit di halaman Pengaturan Bisnis (`manageSettings`), divalidasi ke tiga zona, menaikkan `tenants.updated_at` (propagasi binding gratis).
- Dart: peta `{Jakarta: +420, Makassar: +480, Jayapura: +540}`; `businessDateFor` (`lib/data/sync/wire_values.dart`, dipanggil `order_repository.dart:305`) memakai `utcNow + offset`; tidak dikenal/server lama → jam perangkat seperti sekarang. Order membawa `tz_offset_minutes`.
- **`tenants.legacy_timezone`** dibekukan migrasi ke nilai saat ini (belum pernah ada yang mengedit, jadi eksak untuk semua order pra-F3). `hourlySQL` memakai `COALESCE(offset order, legacy_timezone)` sehingga recompute slice lama tidak memindahkan jamnya.
- Perubahan menandai dirty slice `business_date ≥ hari ini` (zona lama) untuk semua outlet; jendela "hari ini" dan jadwal laporan memakai zona baru. Till lama tetap memakai jam perangkat (keterbatasan terdokumentasi).

## 3. Urutan implementasi

Migrasi mulai `…028` (prefix `20260924`). SQLite **satu kenaikan ke v32**
(pola F2: satu siklus `migration_test.dart`; tabel yang server-nya belum siap
tidak berbahaya karena `supportedEntities` beririsan dengan manifest).

### Jalur A — konfigurasi dan akses

**F3.0 — Perbaikan sesi till dan mode terhubung · P0 · kecil** (hari pertama, tanpa kontrak)
- `providers/settings_provider.dart` (`refreshSignedInEmployee`, tanpa fallback owner saat id ada), `providers/synced_data.dart` (memanggilnya), `data/repositories/employee_repository.dart` (`byIdForSession` sadar-active), `core/router/app_router.dart:150-156` (redirect `/employees`, `/outlets`, `/registers`), `features/settings/settings_page.dart` (sembunyikan reset dan editor), `features/pos/checkout_sheet.dart` (tunai ≥ total).
- Jangan patah: default owner mode demo/standalone; `settings_provider_test`, `till_binding_test`.

**F3.C0 — Rilis kontrak Device API 2.8.0 · P0 · sedang** (spesifikasi lebih dulu)
- `api/openapi.yaml`: `Order` (+`pricing_version, tax_included, rounding_amount, sales_type_*, payment_method_id/_name, payment_reference, served_by_*, discount_*, tz_offset_minutes`), `OrderItem` (rincian, diskon, custom), `Tenant.timezone`, parameter header kapabilitas, seluruh `*Row` baru (required **dan** properties).
- Migrasi `…028_order_contract_f3.sql` (tiga kolom `orders`); `internal/store/queries/ingest.sql` `InsertOrder`; regenerasi sqlc/oapi.
- `internal/domain/ingest/validate.go`: persamaan baru dan jumlah v2; `pricing_mismatch` stub sampai F3.7.
- Jangan patah: `immutableOrder`, payload lama identik byte, `api/contract_test.go:34`.

**F3.1 — Kapabilitas perangkat · P0 · kecil–sedang**
- Migrasi `…029_device_capabilities.sql`; `internal/domain/devices/devices.go` (Authenticate, Activate), `devices/cache.go`, `internal/httpapi/v2` middleware, `internal/backoffice/devices.go` (kolom + peringatan); Dart `sync_client.dart:118` + klien aktivasi/koordinator, konstanta `kClientCapabilities`.
- Jangan patah: `seen_test.go` (tanpa perubahan `updated_at`), stabilitas revisi device.

**F3.2 — Role kustom dan kontak staf · P0 · besar**
- Migrasi `…030_roles.sql`: tabel + RLS `ENABLE`/`FORCE` + grant, trigger tenant, backfill, `employees.role_id` + `phone`, trigger derivasi, CHECK dilonggarkan, **DROP/CREATE `employees_sync_feed_idx`** dengan `role_id` (Down mengembalikan persis `20260910000007_catalogue.sql:145-146`), `roles_sync_feed_idx`.
- Go: `auth/permission.go` (`Access`, `EnterCustomAmount` di akhir, `TillPermissions` tetap), `staff/{staff.go,manage.go}` (akses, aturan eskalasi, last-owner lewat role sistem, `SetPassword` berdasar flag akses, CRUD role, penugasan kustom di-gate `roles-v1`), `ingest/{till.go,till_history.go}`, `httpapi/v2/reports.go:45-46,81-83,112,117`, `backoffice/{auth.go,employees.go}` + `/backoffice/staff/roles`, `views/{models.go,staff.templ,nav.go}`. Registry: `roles` sebelum `employees`; `employees` + `uuidCol("role_id")`, `DependsOn roles`. Telepon staf hanya Backoffice, **tidak dipublikasikan** ke till.
- Dart: `core/auth/permissions.dart` (enum + `EmployeeAccess`, `homeRouteFor`), `data/models/employee.dart` (fallback terkunci), `core/auth/role_display.dart`, `features/employees/employee_management_page.dart`, `core/auth/authorize_sheet.dart:48,210` (pakai resolver), repository role.
- Jangan patah: `TestPermissionStringsMatchTheDartEnum`, `TestOwnerIsDerivedFromTheFullSet`, lookup owner platform, impersonation.

**F3.3 — Pengaturan bisnis/outlet, akun, timezone, profil struk · P0/P1 · sedang–besar**
- Migrasi `…031_business_settings.sql`: `business_settings`, `outlet_settings`, index feed, `tenants.legacy_timezone`.
- Go: paket baru `internal/domain/settings` (pola `claim()` + tulis selisih seperti catalogue); edit timezone + dirty slice di transaksi yang sama; `infra/media/media.go` pola kunci `^(products|receipts)/…`; ekspor `processImage` berparameter dari `catalogue/imageproc.go` (logo: sisi terpanjang 576 px, PNG).
- Backoffice: grup nav "Pengaturan" (`CanSettings = Can(ManageSettings)`): Bisnis, Pengaturan per outlet, preview struk (aproksimasi templ 58/80 mm); `/backoffice/account` untuk setiap pengguna Backoffice (nama, ganti password dengan password lama, di balik `refuseWhileImpersonating`). Teks struk dibatasi Latin-1 tercetak (PDF memakai Helvetica).
- Dart: repository pengaturan, `EffectiveBusinessConfig`, timezone di `wire_values.dart`, unduh logo ke cache connected-scope berkunci hash.

### Jalur B — master penjualan dan pembayaran (setelah F3.C0, paralel dengan Jalur A)

**F3.4 — Sales type dan harga · P0 · sedang** — migrasi `…032_sales_types_and_prices.sql` (4 tabel, trigger seed, index feed); domain di `internal/domain/catalogue` (harga `manageCatalogue`, master `manageSettings`); grid harga pada form produk; urutan registry `sales_types` → `outlet_sales_types` → (setelah products) `product_sales_type_prices` → `outlet_product_sales_type_prices`. Perbaiki loadtest ke `dineIn`.

**F3.5 — Grup/metode pembayaran · P0 · sedang** — migrasi `…033_payment_methods.sql`; `reporting/report.go:555` `PaymentLabel`; halaman Backoffice; fallback enum Dart → `other` dan perbarui setiap switch (`cart_panel.dart`, `checkout_sheet.dart`, `pos_page.dart:699`, `orders_page.dart:567-586`, `report_page.dart`, `print_receipt.dart:49-58`, `receipt_document.dart:143,186-192`, `report_csv.dart:74-84`, `order_repository.dart:340,907-924`).

**F3.6 — Master diskon · P1 · kecil–sedang** — migrasi `…034_discounts.sql`; Library › "Diskon" (`managePromos`).

### Jalur C — kalkulasi (engine mulai hari pertama; integrasi menyusul)

**F3.7 — Mesin harga dan golden vector · P0 · besar**
- `backend-go/internal/domain/pricing/{pricing.go,legacy.go,allocate.go}` dan `mobile/lib/core/pricing/{pricing.dart,legacy.dart,allocate.dart}`.
- Vector di root repo `testdata/pricing/{legacy_v1,v2_exclusive,v2_inclusive,rounding,allocation_edge,overflow}.json`, format `{name, input, expected}` dengan seluruh output header dan baris. Tambahkan `testdata/**` ke `paths:` kedua workflow (sekarang hanya `backend-go/**` dan `mobile/**`).
- Sambungkan `pricing.Compute` ke ingest untuk `pricing_mismatch`.

**F3.8 — SQLite v32 · P0 · sedang** — `lib/data/database/app_database.dart`: 11 tabel baru, `employees.role_id`, kolom baru `orders`/`order_items` (2b–g) termasuk `receipt_snapshot`; konstanta DDL dipakai dua kali; `_addColumnIfMissing`; **tanpa FK dari orders/employees ke master** (tombstone = cascade delete, pelajaran F2). Empat daftar serempak: `CatalogueSync.supportedEntities` (`lib/data/sync/catalogue_sync.dart:96-115`), `_connectedStoreTables` (anak sebelum induk), `invalidateSyncedData`, `reset()`.

**F3.9 — Integrasi till · P0 · besar**
- `cart_provider.dart` menjadi pemegang state tipis; satu `quoteProvider` memanggil engine (v1/v2 menurut konfigurasi efektif) dan sheet, `_placeOrder`, serta `placeOrderFromCart` membaca **quote yang sama**.
- Selector sales type (`cart_panel.dart:144-165`), diskon item di sheet edit baris, entri custom amount, diskon bernama di `discount_sheet.dart`, grid pembayaran per grup + field referensi (`checkout_sheet.dart:145-168`), pemilih pelayan.
- `order_repository.dart` menyimpan snapshot; `order_push.dart` mengirim field baru hanya bila tersimpan di baris dan gate manifest lulus. Checklist l10n/tema/responsif `mobile/CLAUDE.md:828-849` berlaku penuh (kunci baru di kedua ARB, `fvm flutter gen-l10n`).

### Jalur D — antarmuka, struk, laporan (terakhir)

**F3.10 — Struk · P1 · sedang** — `core/print/receipt_document.dart` dan `print_receipt.dart`: logo, header/footer (footer menggantikan ucapan tetap bila diisi), sales type, pelayan, nama metode + "(manual)", diskon baris, label pajak beserta tarif dan include/exclude, baris pembulatan, baris custom. **Cetak ulang memakai `orders.receipt_snapshot`**, bukan alamat outlet live (hari ini `print_receipt.dart:66-80` memilih alamat live). Tampilan sukses checkout (`checkout_sheet.dart:417-461`) mengikuti.

**F3.11 — Laporan · P1 · sedang**
- Migrasi `…035_reporting_f3.sql`: `daily_sales_rollup` + `tax_included`, `rounding`; tabel baru `daily_sales_type_rollup` dan `daily_payment_method_rollup` (pola F2, dirty slice historis, tanpa kenaikan versi).
- Konstanta SQL bersama `netExpr`/`expectedTotalExpr` untuk `rollup.go`, `reporting/anomalies.go`, `history/history.go:239`, `history/sessions.go:140`, `report.go:265`; anomali + `OR pricing_mismatch`; net baris v2 di `product_net.go`; offset di `hourlySQL`; label diskon baru di `adjustmentSQL`.
- `report.go` batch **posisional** — antre baru di akhir; peta fingerprint `consistency.go`; `tables/csv/xlsx/pdf/exports`; `httpapi/v2/reports.go` `by_sales_type`; Dart `ServerReport.asPresentation` mengisi `byOrderType`, `sales_report.dart:95`, `order_repository.dart:1012`.
- **Tombol Backoffice "aktifkan harga v2" digabung di sini, paling akhir.**

**F3.12 — Verifikasi dan dokumentasi · P1 · kecil–sedang** — lihat bagian 5; perbarui `backend-go/CLAUDE.md` (`:610` jumlah feed, `:1090` versi API, invarian role/pricing/kapabilitas), `mobile/CLAUDE.md` (v32, role, pricing), `docs/MANUAL_TEST_LOKAL.md` (bagian J — Fase 3), OpenAPI, roadmap, `docs/FASE_3_VERIFICATION.md`.

### Paralelisasi yang aman

F3.0 dan F3.7 sejak hari pertama. F3.C0 → lalu F3.1–F3.3 (Jalur A) paralel
dengan F3.4–F3.6 (Jalur B); migrasi di berkas terpisah, digabung sesuai nomor.
F3.8 mulai setelah schema baris dibekukan di F3.C0. F3.9 butuh F3.7 + F3.8.
Jalur D terakhir.

## 4. Titik sentuh yang mudah terlewat

| Berkas | Mengapa patah |
|---|---|
| `internal/infra/syncfixture/seed.go:66` | Cabang `default:` error; tiap entity baru (11) butuh case, atau index-only-scan, kontrak, `verify-sync`, dan loadtest mati |
| `syncfeed/contract_test.go:13`, `wire_rows_test.go:18` | Dua peta entity → schema terpisah |
| `syncfeed/pull_test.go:271` | Menuntut nama index `<table>_sync_feed_idx` |
| `TestPublishedColumnsExactlyMatchFrozenRowSchemas` | `EmployeeRow` + `role_id` di required **dan** properties |
| `migrations/…030` Down | Harus mengembalikan INCLUDE `employees_sync_feed_idx` persis `catalogue.sql:145-146` |
| `internal/store/*.sql.go`, `models.go`, `httpapi/wire/models.gen.go`, `views/*_templ.go` | Regenerasi sqlc/oapi/templ, 0 diff |
| `internal/infra/pgtest` | Nama template membawa hash migrasi |
| `auth/permission.go` + `core/auth/permissions.dart` | `TestPermissionStringsMatchTheDartEnum`; `enterCustomAmount` di akhir keduanya |
| `backoffice.New` | Wajib menyalin setiap field `Deps` baru (settings, pricing, roles) |
| `backoffice/routes_test.go`, `views/nav_test.go` | Menelusuri router/nav; grup "Pengaturan" dan rute akun |
| `reporting/report.go` | Batch posisional |
| `reporting/anomalies.go`, `history/sessions.go:140`, `history.go:239` | Ekspresi net dan total harapan |
| `ingest/recovery.go:157`, `history/sessions.go:141`, `shift_repository.dart:184-200` | Harus tetap membaca kind `'cash'` |
| `scripts/loadtest/device.go:243`, `scale.go:358` | `"dinein"` → `"dineIn"` |
| `app_router.dart` `homeRouteFor`, `authorize_sheet.dart:48,210` | Harus memakai akses terselesaikan, bukan `permissionsFor(role)` |
| `migration_test.dart`, `native_file_persistence_test.dart:60` | Memakai `currentVersion` (32) |
| `.github/workflows/{flutter,backend-go}.yml` `paths:` | Tambah `testdata/**`, atau perubahan vector tidak menjalankan CI mana pun |
| `devices/cache.go` | Penulisan kapabilitas tidak boleh menyentuh `updated_at` |
| `tenancy/provision.go:113`, semua fixture tenant | Tercakup trigger; tambahkan test provisioning menghasilkan tiga role sistem |
| `receipt_document.dart` font | Helvetica Latin-1; validasi footer di server |
| `TestUnscopedImportersAreCountable` | Relevan hanya bila query kompatibilitas lewat `unscoped`; tetap di pool tenant |

## 5. Pengujian dan verifikasi

```bash
# backend (dari backend-go/, PostgreSQL + Redis nyata)
templ generate && go generate ./api ./internal/store   # 0 diff
go build ./... && go vet ./...
go test ./... -count=1
go run ./cmd/justclick migrate up                     # lalu down/up pada DB berisi data
go run ./scripts/verify-activation                    # PERTAMA (rate limiter Redis)
go run ./scripts/verify-sync ./scripts/verify-backoffice-crud
go run ./scripts/verify-reports ./scripts/verify-history ./scripts/verify-pricing

# mobile (dari mobile/)
fvm flutter gen-l10n && fvm flutter analyze --no-fatal-infos
fvm flutter test && fvm flutter build apk --debug
```

- **Golden vector bersama** `testdata/pricing/*.json`: Go `pricing/vectors_test.go` naik dari `os.Getwd()` sampai menemukan `testdata/pricing`; Dart `test/pricing/vectors_test.dart` membaca `File('../testdata/pricing/…')`. Keduanya memeriksa setiap field header dan baris, plus cek jumlah vector agar tidak ada sisi yang diam-diam melewatkan berkas. Isi: angka `cart_math_test` sebagai v1; include/exclude dengan baris 0%; seri alokasi; diskon 100%; pembulatan up/down/nearest di batas ±unit/2; nominal ~1e12 (jalur `BigInt`).
- **Go:** izin role sistem pra-F3 dibekukan; migrasi 027 → 030 dengan pegawai tiga role → `role_id` benar dan **izin efektif identik**; matriks eskalasi, last owner via `system_key`, penugasan kustom ditolak saat ada device tanpa `roles-v1`; ingest (jumlah v2 menolak, mismatch diterima dan ditandai, pembulatan negatif diterima, `tax_included > tax` ditolak, payload lama identik byte, field baru immutable antar revisi); devices (parsing header, tulis bila berubah, revisi tidak berubah, aktivasi ditolak, race aktivasi v2 vs aktivasi); fixture reporting include + pembulatan + diskon item (identitas waterfall, Σ kategori = Σ produk = net harian, rollup sales type dan metode bayar, jam `legacy_timezone`); isolasi lintas tenant untuk `role_id`, `sales_type_id`, harga, diskon.
- **Dart unit** (sesuai `mobile/.claude/rules/testing-policy.md`, tanpa widget test baru): resolver akses (fallback terkunci, `homeRouteFor`); `refreshSignedInEmployee` (tombstone → keluar, bukan owner; nonaktif; downgrade melupakan cache remote); migrasi v31 → v32 pada berkas nyata (pola `history_migration_test.dart`); `catalogue_sync` entity baru (tombstone role tidak menghapus pegawai); `order_push` field baru hanya bila tersimpan dan ada di manifest; fallback enum → `other`; `businessDateFor` dengan offset; `receipt_document_test` (logo, footer, pembulatan, "(manual)"); `report_waterfall_test` dengan angka eksplisit.
- **Skrip:** `scripts/verify-pricing` baru (konfigurasi outlet → aktivasi dengan header kapabilitas → aktifkan v2 → pull → push order include + pembulatan → cek angka laporan; mismatch diterima dan ditandai; jumlah tidak menutup ditolak; device header lama memblokir aktivasi v2). Perluas `verify-backoffice-crud` (role, pengaturan, password akun, timezone). Daftarkan `verify-pricing` setelah `verify-history` di `.github/workflows/backend-go.yml:132-143`.
- **UI:** verifikasi langsung Windows/Android/Backoffice sesuai skill `verify-flutter-app`, bukan suite widget baru.

### UAT lokal dua perangkat

1. Keranjang yang sama di perangkat A dan di Go (`verify-pricing`): subtotal, diskon, pajak, pajak termasuk, layanan, pembulatan, total identik per baris dan header.
2. Owner mengubah PB1/mengaktifkan include saat B **offline**; B tetap menjual dengan cache, lalu sync: order membawa snapshot lama, diterima, tidak ditandai; cetak ulang struk lama B tidak berubah.
3. Aktivasi v2 saat satu device outlet masih build lama: ditolak dan device disebut; setelah update: diizinkan; aktivasi device build lama baru sesudahnya: ditolak.
4. Build baru terhadap server 2.7.0: field baru tidak dikirim, matematika legacy, struk tetap naik.
5. Role kasir yang sedang login diubah menjadi tanpa `sell`: setelah sync ia pindah ke home barunya, laci tetap terbuka untuk pemiliknya, outbox utuh. Pegawai login dinonaktifkan/dihapus lalu cold start: keluar, **tidak pernah owner**.
6. Role kustom `sell` + `refundOrder`: buka shift, jual, refund tanpa override. Menugaskannya saat ada device build lama: ditolak.
7. Include + pembulatan 100 + diskon item + diskon bill + layanan: struk, detail Backoffice, dan laporan cocok; ekspektasi kas laci = Σ total tunai.
8. Timezone diganti Asia/Jayapura pukul 23.30 WIB: penjualan baru bertanggal WIT; slice kemarin tidak berubah; jam order lama tetap setelah recompute paksa.
9. Sales type kustom "GoFood" dengan override harga outlet: harga benar, laporan menampilkan namanya.
10. Id lintas tenant disuntikkan ke harga, role, diskon, dan order: ditolak.
11. Diskon manual: struk menampilkan nama diskon atau "Diskon", bukan approver; laporan adjustment tetap mengatribusikannya.

### Gate lingkungan

Build rilis Windows (Visual Studio belum terpasang) dan eksekusi workflow
GitHub aktual dicatat **tertunda**, bukan lulus. F3 selesai setelah bukti
tercatat di `docs/FASE_3_VERIFICATION.md`.

## 6. Batas fase dan asumsi

- Tidak termasuk: saved bill dan pre-bill (F4), split payment/bill dan refund parsial (F5), promo otomatis (F9), QRIS dinamis/integrasi pembayaran, pengiriman email, multi-pajak, harga sales type per varian, scoping diskon per outlet, harga sales type di CSV produk, rollup per pelayan, revokasi instan saat offline, render ulang struk lama, timezone selain tiga zona Indonesia.
- Till lama tetap memakai tanggal dari jam perangkat. Order pra-F3 tidak punya rincian baris; laporan memakai alokasi sekarang untuk mereka dan tidak mengarang rincian.
- Default D1–D10 berlaku kecuali dikoreksi sebelum eksekusi dimulai.

## Langkah pertama implementasi

Mulai F3.0 dan F3.7 paralel, lalu F3.C0. Commit mengikuti Conventional Commits
per jalur (`feat(pos):`, `feat(api):`).

## 7. Penyimpangan dari rencana saat implementasi

Dicatat agar pembaca tidak mencari di kode sesuatu yang sengaja dibuat berbeda.

| # | Rencana | Implementasi | Alasan |
|---|---|---|---|
| 1 | Alokasi: seluruh sisa ke bobot terbesar | Hamilton largest-remainder (`pricing.Allocate` / `allocate`) | "Seluruh sisa ke satu baris" bisa memberi baris lebih dari bobotnya sendiri (diskon melebihi harga baris); Hamilton menjamin setiap bagian ≤ bobot dan jumlahnya tepat |
| 2 | `outlet_sales_types` dan `outlet_payment_methods` sebagai tabel/feed sendiri | Disimpan sebagai array di `outlet_settings` (`sales_type_ids`, `payment_group_id` → `payment_groups.method_ids`) | Satu baris per outlet sudah ada; dua feed join tambahan hanya menambah urutan dependensi. Hasil: **9** feed baru (total 27), bukan 11 |
| 3 | Penugasan metode bayar per outlet | Outlet memilih satu **grup** pembayaran; tanpa grup = semua metode aktif | Sesuai model Mokapos (grup pembayaran) dan cukup untuk D9 |
| 4 | — | `Entity.Singleton` dan `Entity.SystemRows` di registry feed | `syncfixture`/`verify-sync` perlu tahu tabel satu-baris dan baris sistem yang di-seed trigger |
| 5 | Header kapabilitas dicatat di semua klien | Dicatat pada rute `/sync/*` (header kosong = build lama) dan aktivasi; rute lain tidak mengubahnya | Rute non-sync bisa dipanggil klien lain; sinkron adalah satu-satunya jalur yang pasti dilalui setiap till |
| 6 | `OrderType.other` | `OrderType.custom` (wire literal `custom`) | Sama dengan literal wire server; fallback nilai asing juga ke `custom`, tidak pernah `dineIn` |
| 7 | Logo struk diunduh ke cache lokal berkunci hash | Diambil saat mencetak; gagal (offline) → struk tanpa logo | Cetak tidak boleh gagal karena logo; cache lokal ditunda (lihat FASE_3_VERIFICATION) |
| 8 | D7 pelayan dipilih bebas | Wajib bila outlet `track_server`; bawaan = kasir yang login; hanya pegawai aktif dengan akses POS | Mencegah order tanpa pelayan pada outlet yang melacaknya |
| 9 | Form staf mengirim id peran | Handler juga menerima kunci peran sistem (`cashier`/`manager`/`owner`) | Kompatibel dengan form pra-F3 dan skrip verifikasi |
| 10 | Diskon bernama bill memakai izin `sell` bila bernilai tetap tanpa flag | Sesuai rencana; diskon item **selalu** `applyManualDiscount` | — |

Sebagian implementasi dikerjakan bersama asisten lain (Codex) saat sesi
terputus. Seluruh kontribusinya diaudit; cacat yang ditemukan dan diperbaiki
tercatat di [FASE_3_VERIFICATION.md](FASE_3_VERIFICATION.md) bagian "Audit".
