# Rencana: Migrasi Backend JustClick POS ke Go + Redis, sekaligus Menyelesaikan Produk

> Status implementasi 15 September 2026: Fase 0–5 direview dan diuji regresi;
> implementasi Fase 6 selesai dengan polling, modifier/promo outlet dan status
> meja dua arah. Bukti dan batas verifikasinya ada di
> [PHASE_6_VERIFICATION.md](backend-go/docs/PHASE_6_VERIFICATION.md).
> UAT/build Windows masih tertahan toolchain Visual Studio dan runtime UI;
> belum merupakan persetujuan pilot/rollout. SSE ditunda sesuai urutan di bawah.
>
> Fase 7 (rollup laporan + ekspor) selesai: gerbangnya lulus — laporan sebulan
> dari rollup sama persis dengan tabel mentah pada seed 30 hari × 6 outlet
> (46.755 order), p95 19,7 ms di domain dan 18,8 ms di halaman. PDF via gotenberg
> dan email SMTP belum diuji live (registry image tidak terjangkau). Lihat
> [PHASE_7_VERIFICATION.md](backend-go/docs/PHASE_7_VERIFICATION.md).
>
> Fase 9 (uji beban & pengerasan) selesai: harness Go `scripts/loadtest` dengan
> kelima skenario rencana, metrik Prometheus di listener terpisah, profil
> observability (Prometheus + Grafana + exporter) dengan 14 aturan alert, ukuran
> pool eksplisit, tuning PostgreSQL dan kredensial `pg_monitor` untuk exporter.
> Terukur di satu laptop: `/sync/changes` 2.000 rps dengan p50 2,6–5,1 ms (p99
> berayun 5,9–30 ms karena stall host); 200 order/s p99 266 ms tanpa satu pun
> transaksi menunggu di baris tenant dan tanpa kehilangan baris; serbuan 15.000
> till diratakan 3,9× oleh sebar-startup (288 → 73 rps puncak); satu produk
> diubah = tepat 15.000 index-only scan, nol blok dibaca dari disk; 2 juta order
> → laporan sebulan p95 100,9 ms tanpa menyentuh tabel mentah; dengan Redis mati
> satu instance menahan ±500 rps. **Belum**: run di VPS pilot dengan generator
> terpisah (itu yang menentukan kapasitas), seed 30 juta order (butuh ±36 GB),
> Alertmanager, alert backup/sertifikat. Tiga temuan dicatat: kontensi baris
> `report_dirty_slices` per outlet, TTL cache auth sama panjang dengan jendela
> sebar-startup, dan biaya collector per-tabel postgres_exporter. Lihat
> [PHASE_9_VERIFICATION.md](backend-go/docs/PHASE_9_VERIFICATION.md).
>
> Fase 8 (admin platform) selesai: panel `/platform` dengan login password +
> TOTP, onboarding perusahaan + Owner (tautan setel kata sandi sekali pakai),
> suspend/reaktivasi yang langsung menghentikan till, batas outlet/till/perangkat
> dan saklar modul yang ditegakkan di server, impersonasi yang bisa menulis
> dengan audit fail-closed, log audit append-only, halaman ops. Suite Go penuh
> dan sembilan verifier live lulus via HTTPS. Belum: QR enrolment, manajemen
> admin di panel (CLI saja), pembatasan IP `/platform`, seed tarif default, email
> tautan lewat SMTP sungguhan. Lihat
> [PHASE_8_VERIFICATION.md](backend-go/docs/PHASE_8_VERIFICATION.md).

## Context

JustClick POS adalah aplikasi POS restoran: tablet kasir Flutter (offline-first di SQLite) + backend
Laravel 12 / PostgreSQL 18 / Filament v5. Klien adalah **satu perusahaan dengan 5.000+ outlet**,
tiap outlet punya beberapa perangkat kasir. Ke depan produk ini akan jadi **SaaS multi-perusahaan**.

Kode Fase 1–7 sudah landed (device activation, catalogue pull, staff sync, session push, order push,
laporan lintas outlet) dengan 200 test backend + 547 test Flutter hijau — **tetapi belum pernah
sekalipun divalidasi end-to-end di hardware nyata** (23 baris UAT di `docs/MANUAL_TEST_FASE_1_7.md`
semuanya "Belum diuji"), dan **belum produksi di mana pun**. Tidak ada data produksi yang harus
diselamatkan.

Alasan rewrite bukan "PHP lambat". Alasannya adalah **empat cacat skala yang sudah diverifikasi
langsung di kode**, yang akan menabrak tembok jauh sebelum pilihan bahasa jadi relevan:

> Pohon Laravel sudah dihapus dari repositori. Kutipan berkas di bawah adalah
> catatan tempat bukti itu ditemukan ketika keputusan diambil, bukan tautan.

| # | Cacat | Bukti |
|---|---|---|
| 1 | Setiap order yang di-push mengunci **baris tenant** (`SELECT … FOR UPDATE`). Satu perusahaan = satu tenant, jadi seluruh transaksi dari 5.000 outlet berebut satu baris yang sama. | `OrderIngest.php:76-79` |
| 2 | `tenant_sync_counters` hanya **satu baris per tenant**, dialokasikan di dalam transaksi penulis. Desainnya benar (mencegah lost-update terdokumentasi), tapi menserialkan seluruh penulisan katalog+staf se-perusahaan. | `SyncCursor.php:49-56` |
| 3 | Balasan 2xx yang **bukan objek JSON** dan **HTTP 422** sama-sama dipetakan ke `SyncFailure.malformed`, dan `malformed` **menghapus permanen** antrean penjualan di perangkat. | [sync_client.dart:82-96](mobile/lib/data/sync/sync_client.dart#L82-L96) → [order_push.dart:64-65](mobile/lib/data/sync/order_push.dart#L64-L65) |
| 4 | Stok 100% lokal di perangkat (`outlet_stock`, `stock_movements` tidak punya padanan server). Dua kasir di satu outlet menyimpang permanen; pusat tidak bisa melihat stok sama sekali. | Tidak ada migration/endpoint stok di `backend/` |

Hasil akhir yang dituju: backend Go + Redis yang sanggup melayani 15.000 perangkat, Backoffice
pengganti Filament, plus empat area fitur yang hari ini belum ada di server sama sekali.

## Keputusan yang sudah disepakati

| Keputusan | Pilihan |
|---|---|
| Backend | Go (Flutter tetap) |
| Cache/rate limit | Redis ditambahkan |
| Backoffice | Go + templ + HTMX (bukan React, bukan Filament) |
| Status produksi | Belum produksi → **clean rebuild**, tanpa strangler, tanpa migrasi data, tanpa dual-write |
| Validasi Laravel dulu? | Tidak. Langsung ke Go. |
| Kontrak API | Boleh dirancang ulang → **v2** |
| Deploy | VPS kelola sendiri (Docker Compose) |
| Tim | 2–3 orang |
| Rollout | Pilot dulu (puluhan outlet), baru masal |
| Fitur wajib baru | Stok terpusat · Admin platform multi-perusahaan · Modifier+promo+meja ke server · Laporan lanjutan + ekspor |

---

## Stack Go

Satu binary dengan subcommand (`justclick serve api|backoffice|platform`, `worker`, `migrate`,
`tenant create`) — model mental `artisan`, satu image, tidak ada drift antara API dan worker.

| Kebutuhan | Pilihan | Alasan singkat |
|---|---|---|
| Router | `go-chi/chi/v5` | Native `net/http`; grup middleware memetakan 1:1 ke route group Laravel |
| Postgres | `jackc/pgx/v5` (pool native) + **`sqlc`** | Korektnya sistem ini hidup di SQL yang harus bisa dibaca (`ON CONFLICT … WHERE … RETURNING`, partial unique index, partisi). sqlc menghasilkan Go bertipe dari SQL yang kita tulis sendiri; ORM akan menyembunyikan semantik lock |
| Isolasi tenant | **Postgres Row-Level Security** + `SET LOCAL app.tenant_id` | Go tidak punya global scope seperti Eloquent. RLS lebih kuat: predikat yang lupa ditulis ditangkap database, bukan disiplin. `SET LOCAL` aman di bawah transaction pooling |
| Escape hatch | paket `internal/store/unscoped` (satu-satunya pool `BYPASSRLS`) | Padanan greppable dari `TenantContext::runUnscoped()` |
| Migrasi | `pressly/goose/v3` | SQL polos, bisa di-`go:embed`, mendukung migrasi Go untuk backfill data |
| Config | `caarlos0/env/v11` → satu struct, divalidasi saat boot | Env-only, cocok dengan Compose |
| Validasi | `go-playground/validator/v10` | Gagal validasi → **penolakan per baris**, bukan HTTP 422 (lihat Sync v2) |
| Log | stdlib `log/slog` (JSON) | `request_id`, `tenant_id`, `device_id`, `outlet_id` di setiap baris |
| Job async | **River** (Postgres, di atas pgx) | Menentukan: `river.Insert(ctx, tx, …)` di **transaksi yang sama** dengan penulisan order → "order commit ⟺ job rollup ter-enqueue" bersifat atomik. Asynq/Redis memunculkan kembali dual-write: order commit, enqueue gagal, rollup diam-diam tidak jalan — dan laporan itu uang |
| Backoffice | `a-h/templ` + HTMX 2.x (di-vendor, bukan CDN) | templ = Blade dengan compiler; HTMX memberi rasa Livewire tanpa runtime websocket |
| Sesi | `alexedwards/scs/v2` dengan store **Postgres** | Sengaja bukan Redis — agar "flush Redis" tidak pernah menakutkan |
| CSRF | `gorilla/csrf` (token via `hx-headers` di `<body>`) | |
| PIN/password | `x/crypto/bcrypt` **cost 10** | Wajib byte-compatible dengan `pin_hash` yang diverifikasi offline di tablet. Jangan naikkan cost |
| Token perangkat | 32 byte acak, disimpan sebagai SHA-256 | Secret berentropi tinggi tidak butuh bcrypt; bcrypt di jalur auth = 100ms/request |
| Test | stdlib `testing` + `testify/require` + Postgres asli via **template-database cloning** | Pertahankan aturan "jangan pernah SQLite": partial unique index & RLS berperilaku beda. Kloning template ≈50ms per test |
| Metrik | `prometheus/client_golang` + Sentry Go | |
| PDF | sidecar `gotenberg` merender HTML templ | Jangan menata laporan dua kali |

**Layout direktori** (batasnya = batas kepemilikan untuk 2–3 orang):

```
cmd/justclick/            main + subcommand
internal/domain/          catalogue, staff, devices, orders, sessions, stock, tables, promos, reporting, tenancy
internal/store/           output sqlc + queries/*.sql; store/unscoped (pool BYPASSRLS)
internal/httpapi/v2/      handler API perangkat, DTO, helper render
internal/backoffice/      handler + views/*.templ
internal/platform/        handler + views (super-admin)
internal/infra/           config, log, pg, redis, jobs, mail
migrations/               goose SQL
api/openapi.yaml          kontrak v2 yang dibekukan
```

Paket `domain` memegang invariant dan menerima `pgx.Tx`; handler tidak memuat logika bisnis —
aturan yang sama dengan sekarang, supaya Backoffice dan API tidak bisa berbeda pendapat.

---

## Perancangan Ulang Skema

### Hilangkan lock baris tenant
Aturan yang ditempel di dinding: **sebuah penulisan hanya boleh mengunci baris yang invariant-nya ia
lindungi.** Tidak ada `FOR UPDATE` pada `tenants`, selamanya — tambahkan grep di CI.

Ketiga jaminan `OrderIngest` menjadi predikat satu-statement, tanpa read-modify-write:

```sql
INSERT INTO orders (…) VALUES (…)
ON CONFLICT (business_date, id) DO UPDATE
  SET status = EXCLUDED.status, authorized_by = …, void_reason = …, refunded_amount = …
  WHERE orders.settled_at IS NULL
RETURNING id, (xmax = 0) AS inserted;
```

- *Never twice* → `ON CONFLICT`
- *Never rolled back* (settle-once) → `DO UPDATE … WHERE`; kalau sudah settled Postgres mengembalikan
  nol baris, dipetakan ke hasil per-baris `rejected/settled`
- *Never partly* → item ditulis di transaksi yang sama via `pgx.Batch`
- `xmax = 0` membedakan insert pertama dari retry (dibutuhkan response dan metrik)

Sesi: `ON CONFLICT (id) DO UPDATE … WHERE pos_sessions.closed_at IS NULL` — laci yang sudah ditutup
tidak bisa dibuka lagi, sebagai predikat. Satu-sesi-terbuka-per-register tetap partial unique index;
pelanggaran muncul sebagai SQLSTATE `23505` → alasan penolakan bernama yang menyebut siapa pemegang till.

Aktivasi: single-use jadi compare-and-swap pada baris kode aktivasi
(`UPDATE activation_codes SET consumed_at = now() … WHERE fingerprint = $1 AND consumed_at IS NULL AND expires_at > now() RETURNING …`),
bukan lock tenant.

### Pecah counter sync, pertahankan buktinya
Desain lock-held-to-commit di `SyncCursor` **benar dan harus bertahan** — itu satu-satunya penghalang
lost-update yang didokumentasikan di `SyncCursor.php:13-35`.
Jangan ganti dengan `SEQUENCE` biasa (`nextval` tidak menahan lock sampai commit).

Pecah sepanjang sumbu yang sudah dipakai perangkat (cursor-nya sudah per-entity):

```
sync_counters(scope_key text PRIMARY KEY, last_seq bigint NOT NULL)
  company-shared:  't:{tenant}/e:{entity}'
  outlet-scoped:   't:{tenant}/o:{outlet}/e:{entity}'
```

`AllocSeq(ctx, tx, scopeKey)` mempertahankan `INSERT … ON CONFLICT DO UPDATE … RETURNING` dan error
keras yang sama saat `tx == nil`. Efeknya: penulisan katalog tidak lagi berebut dengan penulisan staf,
dan — yang penting — **`stock_movements`, satu-satunya feed volume tinggi yang ditulis perangkat,
mendapat counter per-outlet**. Kontensi turun ke 2–4 till dalam satu outlet, persis tempat urutan total
memang diinginkan.

| Sumbu | Entity |
|---|---|
| Company-shared, pull-only | `employees`, `categories`, `products`, `product_variants`, `modifier_groups`, `modifier_options`, `product_modifier_groups`, `product_modifier_options`, `promos`, `promo_outlets`, `outlets`, `pos_registers` |
| Outlet-scoped | `outlet_stock`, `stock_movements`, `tables`, `table_status` |

`outlets`/`pos_registers` masuk feed pull karena hari ini hanya ditulis sekali dari payload aktivasi
dan tidak pernah di-pull ulang — rename register di server tidak pernah sampai ke till.

### Partisi & index
- `orders` dan `order_items` di-RANGE-partition bulanan pada `business_date` (tipe `date`, dipilih
  perangkat saat order dibuat dan immutable di outbox — **bukan** `created_at`, atau push yang telat
  sehari mendarat di laporan yang salah). PK `(business_date, id)`.
- Karena itu melemahkan idempotensi global, tambahkan penjaga kecil tanpa partisi:
  `order_dedupe(id uuid PRIMARY KEY, business_date date NOT NULL, first_seen timestamptz)`.
  Ingest menulis ke sini dulu (`ON CONFLICT (id) DO NOTHING RETURNING`); saat konflik ia membaca
  `business_date` tersimpan dan memakai **itu** untuk upsert order. Retry dengan tanggal yang bergeser
  tidak akan pernah menciptakan penjualan kedua. ±24 byte/baris, tidak pernah di-prune.
- Partisi dibuat 3 bulan di muka oleh River periodic job, plus partisi `DEFAULT` sebagai jaring
  pengaman dengan alert kalau pernah terisi.
- Setiap feed sync dapat index penutup `(scope…, sync_seq) INCLUDE (kolom yang dipublikasikan)` →
  index-only scan. Dengan 15.000 perangkat menarik data, ini keluarga index paling berpengaruh.
- `orders`: `(tenant_id, outlet_id, business_date)`, `(tenant_id, pos_session_id)`,
  `(tenant_id, business_date, outlet_id) INCLUDE (subtotal, discount, total, status)` untuk job rollup.

---

## Kontrak Sync v2

Base `/api/v2`. Aturan universal: **semua timestamp epoch-millis `int64`** (termasuk
`token_expires_at_ms` — menutup celah ISO-vs-epoch), uang integer rupiah, id selalu string non-kosong,
dan **setiap body 2xx adalah objek JSON**. Yang terakhir ditegakkan oleh satu helper `render.JSON`
plus contract test yang menyusuri `api/openapi.yaml` dan gagal kalau ada skema 2xx yang bukan objek.
DTO server digenerate `oapi-codegen` supaya drift jadi compile error.

| Endpoint | Bentuk |
|---|---|
| `POST /devices/activate` | → **200** `{data:{token, token_expires_at_ms, device, tenant, outlet, pos_register}}` |
| `GET /devices/me` | sama minus token; tidak lagi dipoll tiap 30 detik |
| `GET /sync/manifest` | `{schema_version, entities:[{name, scope:"company"|"outlet", depends_on, pull, push, apply:"upsert"|"replace"}]}` |
| `GET /sync/changes` | **jalur cepat** — `{cursors:{products:1204, outlet_stock:99321,…}, device_revision, server_time_ms, next_poll_ms}`, dilayani dari Redis |
| `GET /sync/pull` | `?entity=&after_seq=&limit=500` → `{entity, rows, next_seq, has_more, schema_version}` |
| `POST /sync/push` | `{batches:[{entity, rows:[…]}]}` campur entity dalam urutan manifest, ≤200 baris/request |
| `GET /time`, `GET /health` | |

Catatan yang load-bearing:

- `apply:"upsert"` wajib untuk `product_modifier_options` — `ConflictAlgorithm.replace` menghapus lalu
  menyisipkan ulang dan `ON DELETE CASCADE`-nya akan menghapus scoping opsi setiap produk.
- `schema_version` memungkinkan server membalas `409 device_schema_outdated` dan meminta update app,
  menggantikan perilaku sekarang di mana satu kolom tak dikenal adalah SQLite error yang mematikan
  seluruh halaman. Sisi klien berubah jadi **mengabaikan key yang tidak dikenal**.
- Port `SyncRegistry` apa adanya sebagai allow-list kolom per entity — ia ada karena pemetaan
  entity→model secara konvensi pernah menyajikan `employees` lengkap dengan hash password.
- `next_poll_ms` dikontrol server, jadi interval seluruh armada bisa dilebarkan saat insiden tanpa
  merilis aplikasi.

### Membuat jalur kehilangan uang mustahil secara struktural

Hari ini body 2xx yang bukan objek → `malformed` → **antrean penjualan dihapus permanen**; 422 juga.
Empat penghalang independen:

1. Response selalu struct Go, tidak pernah slice; contract test membuktikannya.
2. Hasil per-baris pada HTTP 200 (`status ∈ accepted | rejected | retry`) menghapus 422 dari jalur push
   sepenuhnya. 4xx hanya untuk request yang tidak terbaca atau tidak berwenang (401/403/413/429),
   tidak pernah untuk isi baris. `status:"retry"` ada supaya deadlock atau disk penuh tidak pernah
   menyamar sebagai penolakan permanen.
3. Klien: hanya `accepted` yang mengeluarkan dari antrean. Apa pun yang tidak terparse/tak dikenal →
   pertahankan baris dan backoff. Baris `rejected` **dipindahkan ke tabel `dead_letter` lokal, bukan
   dihapus**, dengan `code` dari enum tertutup (`duplicate`, `settled`, `session_closed`,
   `unknown_entity`, `schema_rejected`).
4. Server menulis setiap baris yang di-push ke `ingest_log(id, tenant_id, device_id, entity, payload jsonb, received_at)`
   — partisi harian, retensi 90 hari — **sebelum** pemrosesan domain. Bahkan baris yang ditolak domain
   tetap bisa dipulihkan. Ini asuransi uang termurah dalam desain ini.

### Penjadwalan
Poll `/sync/changes` tiap `next_poll_ms` (default 60s) × jitter seragam [0.8, 1.2]. Connectivity
listener dan app-resume memicu sync ter-debounce (5s), dibatasi sekali per 30s. Tombol "Sync now"
manual di Settings. **Sebar startup**: panggilan pertama setelah launch ditunda
`hash(device_id) mod 300` detik — deterministik, tanpa koordinasi, mengubah serbuan jam 8 pagi jadi
ramp datar 5 menit. Backoff push eksponensial 2s → 5m dengan full jitter, per-outbox bukan per-baris.
Klien menghormati `Retry-After` pada 429.

### Aturan konflik stok — bagian tersulit
Modelkan stok sebagai **ledger pergerakan append-only, tidak pernah saldo yang bisa diubah**, di kedua
sisi. Delta bersifat komutatif, jadi dua till yang menjual barang sama saat offline menghasilkan `-1`
dan `-1` dan outlet mendarat di `-2`. **Tidak ada konflik untuk diselesaikan** — itulah seluruh alasan
ledger adalah jawabannya.

- `stock_movements` (ditulis perangkat maupun HQ, dua arah, idempoten by UUID) adalah sumber kebenaran.
- `outlet_stock` adalah **proyeksi turunan**, dihitung ulang dari ledger, ditarik turun sebagai snapshot
  otoritatif dan **tidak pernah di-push ke atas**.
- Perangkat menampilkan `server_qty + Σ(delta lokal yang belum ter-push)`, jadi till offline menunjukkan
  angka yang benar secara lokal dan konvergen begitu ledger-nya mendarat.
- **Stock opname adalah satu-satunya kasus server-wins**: perangkat mengirim `counted_qty` + `basis_seq`,
  dan **server** mengubahnya jadi delta terhadap kuantitas terkini miliknya saat ingest. Hitungan fisik
  adalah fakta tentang *sekarang*, dan server punya agregat paling segar.
- Stok negatif **diizinkan** dan di-alert, tidak pernah diblokir. Menolak mencatat penjualan yang
  terbukti terjadi lebih buruk.

---

## Peran Redis (batas ketat)

**Aturannya: kalau mem-flush Redis di sistem hidup menyebabkan sesuatu yang lebih buruk daripada
melambat atau login ulang, benda itu bukan untuk Redis.** Itu mengecualikan order, sesi, ledger stok,
alokasi `sync_seq`, catatan idempotensi, dan antrean job.

1. **Cache auth perangkat.** Hari ini seluruh rantai (device → tenant → outlet → register + cek aktif)
   dibaca ulang dari Postgres di **setiap** request. Cache `dev:{token_sha256}` → binding, TTL 300s.
   Invalidasi lewat **generation counter**, bukan enumerasi key: entri menyimpan nilai
   `gen:tenant:{id}`, `gen:outlet:{id}`, `gen:register:{id}` saat ia dibangun; middleware melakukan satu
   `MGET` entri + tiga gen key. Revoke cukup `INCR` gen terkait dan semua entri turunannya langsung
   invalid. **Saat Redis mati, jatuh ke Postgres — jangan pernah fail-open.**
2. **Rate limiting.** Token bucket atomik via Lua, per token perangkat dan per IP untuk aktivasi.
   Mengeluarkan `Retry-After`. (Hari ini rate limit ada di tabel `cache` Postgres.)
3. **Watermark perubahan.** `hwm:{tenant}:{entity}` / `hwm:{tenant}:{outlet}:{entity}`, ditulis
   **setelah commit** dan **monoton** (Lua `if new > old`). Ini yang menopang `/sync/changes`. Bersifat
   advisory: nilai basi-rendah menyebabkan satu pull ekstra, basi-tinggi menyebabkan pull nol baris —
   keduanya tidak kehilangan data. Cache dingin jatuh ke `SELECT scope_key, last_seq FROM sync_counters`.
4. Cache fragmen/laporan Backoffice, dan Pub/Sub fan-out invalidasi begitu ada >1 instance API.

Config: `appendonly yes`, `appendfsync everysec`, `maxmemory` dengan **`noeviction`** (eviction LRU atas
key rate-limit = pintasan diam-diam melewati limiter), semua key ber-TTL eksplisit, `requirepass`,
hanya terikat ke jaringan Docker.

---

## Backoffice (templ + HTMX)

Handler memeriksa `HX-Request` lalu mengembalikan halaman penuh atau fragmen lewat pasangan
`render.Page` / `render.Fragment`. Form POST membalas **200** dengan fragmen terbarui + `HX-Trigger`
untuk toast; error validasi merender ulang fragmen form dengan error per-field — disiplin
"tidak pernah 422" yang sama seperti API.

**Panel merchant `/backoffice`** (sesi, digerbangi permission — selalu tanya permission, jangan
bandingkan role):

Login/logout/reset password · Dashboard (omzet, order, rata-rata struk, outlet teratas; `hx-trigger="every 30s"`
hanya pada widget) · Kategori · Produk (filter, cari, upload gambar, toggle ketersediaan, impor harga massal) ·
Varian (inline) · **Modifier group & option + penempelan per-produk (baru)** · **Promo + scoping outlet (baru)** ·
Karyawan (role, set/reset PIN, password, nonaktifkan) · Outlet · POS Register · Perangkat (terbitkan kode
aktivasi — plaintext ditampilkan tepat sekali, tidak pernah masuk flash/session; revoke) ·
**Meja: denah per-outlet + status live read-only (baru)** · **Stok: level per outlet, ledger pergerakan,
penyesuaian/penerimaan, input opname, alert stok menipis, transfer antar-outlet (baru)** ·
Order (filter + detail baris/modifier/pembayaran/audit void, read-only) · Sesi POS (selisih ekspektasi
vs hitungan) · Laporan (penjualan, per outlet, per kategori dengan pembagian largest-remainder dan
peringatan cost-coverage, **plus per produk, per kasir, per jam, komposisi pembayaran, audit diskon/void**,
ekspor CSV/XLSX/PDF, kirim terjadwal) · Pengaturan (PB1/service charge, header-footer struk, timezone).

**Panel platform `/platform`** (guard terpisah, router terpisah, nama & path cookie terpisah,
**TOTP wajib**):

Login super-admin · Daftar perusahaan · **Buat perusahaan + Owner pertama** (menggantikan CLI
`tenant:create`) · Suspend/aktifkan kembali · Pemakaian lintas perusahaan (outlet, perangkat,
order/hari, terakhir terlihat) · **Impersonasi dengan banner permanen yang mencolok + baris audit** —
rancang sengaja, atau support akan mulai bertukar password · Log audit platform · Feature flag & limit
per tenant · Ops: dashboard River, status migrasi, health.

---

## Empat Area Fitur Baru

**Stok.** Tabel: `stock_movements` (id, tenant, outlet, product, variant, `delta_qty`, reason,
ref_type/ref_id, `occurred_at_ms`, source `device|backoffice`, device_id, created_by, `sync_seq`),
proyeksi `outlet_stock` (qty_on_hand, updated_seq), `stock_alerts`. Menumpang `/sync/pull` (dua entity,
outlet-scoped) dan `/sync/push` (hanya movements). Refresh proyeksi = River job yang di-enqueue di dalam
transaksi ingest, unik per `(outlet, product, variant)` dengan debounce pendek, plus recompute penuh
per outlet tiap malam sebagai self-heal.

**Admin platform.** `super_admins` + guard sudah ada, nol route. Tambah `platform_audit_log`,
`tenant_limits`, `tenant_feature_flags`, `impersonation_sessions`. Onboarding jadi satu alur
transaksional: buat tenant → buat Owner → seed kategori & tarif default → terbitkan tautan login pertama.
Tidak ada implikasi sisi perangkat.

**Modifier / promo / meja.** Modifier dan promo = entity pull-only company-shared dengan tombstone;
satu-satunya kehalusan adalah `apply:"upsert"` pada dua tabel join. Scoping promo jadi entity tersendiri
`promo_outlets` (bukan kolom array) supaya delta tetap berbentuk baris. Meja dipecah: **definisi**
(area, nomor, kursi, layout x/y) ditulis HQ dan di-pull; **status live** ditulis perangkat, di-push
sebagai `table_status_events` (ledger append-only untuk audit) dan ditarik kembali oleh till lain di
outlet yang sama sebagai proyeksi `table_status`. Konflik = last-writer-wins pada `(table_id, seq)`
dengan `occurred_at_ms` sebagai pemecah seri, dan aplikasi **menampilkan** meja yang diperebutkan
alih-alih diam-diam memilih. Poll 60 detik terlalu lambat untuk denah meja → tambahkan
`GET /outlets/stream` (SSE) yang mendorong nudge `{entity, hwm}`; 15.000 koneksi SSE idle = satu
goroutine + satu socket masing-masing, nyaman untuk Go di satu box dengan `nofile` disetel.
**Kirim polling dulu, SSE belakangan.**

**Rollup laporan + ekspor.** Tabel: `daily_sales_rollup`, `daily_category_rollup`, `daily_product_rollup`,
`daily_employee_rollup`, `daily_payment_rollup`, `hourly_sales_rollup`. Bukan materialized view — tidak
bisa di-refresh inkremental pada 30 juta baris/bulan. Sebagai gantinya: River job per
`(outlet, business_date)` **di-enqueue di dalam transaksi ingest order**, dideduplikasi dengan fitur
unique-job River + debounce 60 detik, jadi outlet ramai menghitung ulang maksimal sekali per menit.
Tiap run = satu `INSERT … SELECT … ON CONFLICT DO UPDATE` atas satu irisan partisi. Dua jaring pengaman:
recompute 3 hari terakhir tiap malam (menangkap push offline yang telat dan enqueue yang terlewat) dan
pemeriksaan konsistensi tersampel mingguan yang membandingkan rollup dengan order mentah lalu alert bila
tidak cocok. Pembagian kategori memport largest-remainder dari
`CategorySalesAggregator.php` — **port unit
test-nya lebih dulu**, termasuk dua bug Dart yang ia jaga. Laporan hanya membaca rollup dan menampilkan
"per <timestamp>"; jalur tabel mentah hanya ada di balik tombol "hitung ulang". Ekspor: baris
`report_exports` + River job; CSV via `encoding/csv`, XLSX via `excelize`, PDF dengan merender templ
laporan lewat gotenberg. `report_schedules` + River periodic job mengirim **tautan unduh
bertanda-tangan ber-TTL pendek** lewat email, bukan lampiran.

---

## Fase

Aturan urutan: **bekukan `api/openapi.yaml` di akhir Fase 2.** Artefak itulah yang membuka pekerjaan
Flutter secara paralel.

### Fase 0 — Fondasi (±1 minggu, seluruh tim)
Layout repo, config, slog, pool pgx, goose, kerangka chi, Docker Compose (Postgres 18, Redis, Caddy),
CI (`go vet`, `staticcheck`, `golangci-lint`, `-race`, cek kesegaran `templ generate`), harness test
template-DB, pemasangan RLS, `/health`.
- **Selesai bila:** `docker compose up` melayani `/health` di atas TLS lokal, dan ada test yang
  membuktikan query tanpa konteks tenant mengembalikan nol baris sementara penulisan error.
- **Verifikasi:** `go test ./... -race`; lalu di `psql` set `app.tenant_id` ke tenant lain dan pastikan
  barisnya menghilang.

### Fase 1 — Identitas & aktivasi perangkat v2 (±1,5 minggu; bisa dibelah: A = skema/domain, B = shell auth Backoffice + layar perangkat)
Tenant/outlet/register/device/employee dengan composite FK, aktivasi sebagai CAS, penerbitan token,
middleware perangkat dengan cache generation Redis, rate limiting.
- **Selesai bila:** test balapan dua-pool membuktikan tepat satu aktivasi menang; port Go dari
  `verify-device-activation.php` lulus terhadap server hidup termasuk 429 + `Retry-After`; p99 auth < 3ms saat warm.
- **Verifikasi:** jalankan skripnya; lalu `redis-cli FLUSHALL` di tengah run dan pastikan auth tetap
  berhasil lewat Postgres.

### Fase 2A — Sync v2 pull ∥ Fase 2B — CRUD Backoffice (±2 minggu, benar-benar paralel: B menghasilkan tulisan yang dipublikasikan A)
2A: `sync_counters` ter-shard, `AllocSeq` dengan penjaga transaksi, tombstone, manifest/changes/pull,
watermark Redis. 2B: katalog, staf, outlet, register, perangkat, modifier, promo dalam templ+HTMX.
- **Selesai bila:** test konkurensi mereproduksi skenario lost-update persis (penulis A lambat, B cepat,
  perangkat menarik di antaranya) dan menunjukkan tidak ada baris terlewat; katalog 5.000 produk tertarik
  penuh; p99 `/sync/changes` < 20ms pada 2.000 rps.
- **Verifikasi:** test balapan; `k6` terhadap `/sync/changes`; `EXPLAIN` setiap query pull dan pastikan
  Index Only Scan.
- **Lalu bekukan spesifikasi OpenAPI.**

### Fase 3 — Push v2: order & sesi (±2 minggu, satu orang senior, sendirian)
Partisi orders/order_items, `order_dedupe`, `ingest_log`, hasil per-baris 200, tanpa lock tenant di mana pun.
- **Selesai bila:** mem-push batch 200 baris yang sama tiga kali meninggalkan database identik; order
  yang sudah settled tidak pernah dinyatakan ulang; laci tertutup tidak pernah terbuka lagi; satu baris
  buruk tidak pernah menggagalkan batch; baris mendarat di partisi yang benar.
- **Verifikasi:** skrip idempotensi terhadap server hidup; `SELECT count(*) FROM orders_2026_09` per
  partisi; `pg_locks` menunjukkan **tidak ada** lock pada `tenants`.

### Fase 4 — Klien Flutter v2 (±2 minggu, bisa mulai begitu spesifikasi beku — paralel dengan Fase 3)
`/api/v2`, terima 200 pada activate, epoch-millis menyeluruh, abaikan key pull tak dikenal, push
ter-batch, hasil per-baris, tabel dead-letter, jalur cepat `changes`, jitter + connectivity listener +
sync manual + sebar startup.
- **Selesai bila:** 547 test yang ada tetap hijau, plus test baru untuk setiap jalur kehilangan yang
  dihapus — yang terpenting: body 2xx berisi `[]` **meninggalkan baris outbox tetap utuh**.
- **Verifikasi:** mock server yang membalas `[]`, `"ok"`, 422, dan 500 bergantian; pastikan penjualan
  yang mengantre selamat di keempatnya.

### → GERBANG PILOT
Fase 0–4 plus uji beban terskala = paritas penuh dengan sistem hari ini **minus setiap cacat skala**.
**Mulai pilot di sini** (puluhan outlet) dan jalankan Fase 5–8 bersamaan dengan umpan balik nyata.

### Fase 5 — Stok (±2 mgg) ∥ Fase 6 — Meja + pengkabelan modifier/promo di perangkat (±1,5 mgg) ∥ Fase 7 — Rollup laporan + ekspor (±2 mgg) ∥ Fase 8 — Admin platform (±1 mgg)
Empat jalur independen; dengan tiga orang, jalankan dua sekaligus dan sisipkan Fase 8 sebagai pengisi.
- **Fase 5 selesai bila:** dua till menjual barang yang sama secara offline selama satu jam konvergen
  ke kuantitas outlet yang benar setelah keduanya push; pusat melihat angka yang sama.
- **Fase 7 selesai bila:** laporan penjualan sebulan dari rollup sama persis dengan perhitungan tabel
  mentah pada dataset ter-seed 30 hari, dan kembali dalam < 200ms.

### Fase 9 — Uji beban & pengerasan (±1 minggu, sebelum rollout masal; versi 10% dijalankan sebelum pilot)
Harness Go yang mensimulasikan siklus hidup perangkat penuh. Target diturunkan dari 5.000 outlet × 3 till
= 15.000 perangkat:

| Skenario | Target |
|---|---|
| `/sync/changes` | 250 rps steady → **buktikan 2.000 rps pada p99 < 20ms** di satu instance |
| Order | 1 juta/hari, jam puncak ±15% → 42/s → **tahan 200 order/s pada p99 < 300ms** |
| Serbuan pagi | 15.000 perangkat dalam jendela 10 menit. Ukur dengan sebar-startup **dimatikan** untuk melihat kasus terburuk, lalu dinyalakan untuk membuktikan ia mendatar di bawah 50 rps |
| Fan-out katalog | Ubah satu produk, 15.000 perangkat menarik; kerja DB tambahan harus ±15.000 index-only scan (cek `pg_stat_statements`) |
| Skala data | Seed 30 juta order, pastikan laporan tidak pernah menyentuh tabel mentah dan autovacuum mengejar |

- **Verifikasi:** dashboard Grafana selama run; top-20 `pg_stat_statements` sebelum/sesudah; jalankan
  satu skenario dengan **Redis dimatikan** untuk mengetahui plafon terdegradasi.

### Fase 10 — Rollout masal bergelombang
5% → 25% → 100%, tiap gelombang digerbangi: rejection rate push < 0,1% · dead job River = 0 ·
kebasian rollup < 15 menit · tidak ada regresi p99.

---

## Deployment VPS

**Proses** (Docker Compose): `caddy` · `api` ×N · `backoffice` · `worker` (River) · `postgres` ·
`redis` · `gotenberg`. Image distroless, `CGO_ENABLED=0`.

**TLS.** Caddy dengan Let's Encrypt otomatis — klien Flutter menolak `http://` polos kecuali loopback
([device_activation_repository.dart](mobile/lib/data/device/device_activation_repository.dart)), jadi
ini wajib. HSTS aktif. Kalau nanti melakukan pinning, pin intermediate + satu backup key, atau
perpanjangan rutin akan mematikan 15.000 till sekaligus.

**Tuning Postgres** (box 32 GB): `shared_buffers` 8GB, `effective_cache_size` 22GB, `work_mem` 12MB,
`maintenance_work_mem` 2GB, `max_connections` 200, `random_page_cost` 1.1, `wal_compression=zstd`,
`max_wal_size=8GB`, `checkpoint_timeout=15min`, `autovacuum_vacuum_scale_factor=0.02` pada orders,
`pg_stat_statements` + `track_io_timing` aktif. **`synchronous_commit=on` — jangan pernah dilonggarkan;
ini uang.**

**Pooling.** `pgxpool` saja cukup di skala pilot; **jangan tambahkan pgbouncer sebelum terukur perlu.**
Saat nanti dipakai: transaction mode secara historis merusak cache prepared-statement implisit pgx.
Dua penyelesaian — (a) pgbouncer ≥ 1.21 dengan `max_prepared_statements > 0`, mendukung named prepared
statement di transaction pooling dan bekerja dengan pgx v5 tanpa perubahan (**disarankan**); atau
(b) `DefaultQueryExecMode: pgx.QueryExecModeExec`, yang kehilangan plan caching sisi server dan mengubah
inferensi tipe parameter (kode sqlc umumnya selamat tapi butuh cast eksplisit `$1::uuid`). Terpisah dari
itu: konteks RLS memakai `SET LOCAL` di dalam transaksi, aman untuk transaction pooling — `SET` telanjang
akan membocorkan konteks tenant antar klien, jadikan itu aturan lint.

**Backup.** `pgBackRest` — full tiap malam, arsip WAL kontinu ke object storage **penyedia berbeda**,
retensi 30 hari full + 7 hari PITR. Latihan restore otomatis bulanan (River periodic job me-restore ke
container scratch lalu memeriksa jumlah baris + checksum rollup kemarin). Backup yang belum pernah
di-restore bukan backup.

**Migrasi saat deploy.** goose sebagai container sekali-jalan sebelum API di-roll, dijaga advisory lock
Postgres supaya deploy bersamaan tidak balapan. **Expand/contract saja** — migrasi harus kompatibel
dengan binary *sebelumnya* sehingga rollback tidak butuh down migration. Jangan pernah men-drop kolom
di rilis yang sama dengan saat berhenti menulisinya.

**Zero-downtime.** Graceful shutdown pada SIGTERM dengan drain 30 detik di belakang Caddy. Perangkat
toleran-offline, jadi kedipan 30 detik bukan peristiwa — ini yang menyelamatkan Anda dari membangun
blue/green di skala pilot.

**Observability.** Prometheus + Grafana + Loki di Compose. Metrik yang benar-benar penting: rps push dan
**rejection rate per-baris per code** (lonjakan = bug klien yang sedang menghilangkan uang), p99
`/sync/changes`, rows/s pull, kedalaman antrean & dead job River, koneksi/lock Postgres, kebasian rollup,
hit ratio Redis, perangkat-terlihat-dalam-5-menit. Alert: rejection > 0,1% · dead job > 0 · kebasian
rollup > 15 mnt · disk > 75% · umur backup > 26 jam · sertifikat < 20 hari. Sentry untuk exception.

**Topologi.** *Pilot:* satu VPS, 8 vCPU / 32 GB / NVMe, semua di Compose. *5.000 outlet:* (1) box DB
16–32 vCPU / 64–128 GB / 2 TB NVMe **plus replika streaming khusus laporan & ekspor** — menjalankan
laporan di primary adalah yang akan membunuh hari puncak pertama Anda, sediakan sebelum dibutuhkan;
(2) dua box aplikasi stateless di belakang Caddy; (3) box worker (River + gotenberg); (4) Redis dengan
replika. Rencanakan ±300–600 GB/tahun data order, arsipkan partisi yang di-detach setelah 25 bulan.

---

## Register Risiko

| # | Risiko | Mitigasi |
|---|---|---|
| 1 | **Uang terduplikasi** — klien me-retry push yang responsnya hilang | Idempotensi UUID perangkat + `order_dedupe` (unik global, tidak pernah di-prune) + `xmax` yang membedakan insert vs retry. Jadikan "payload sama ×3 meninggalkan DB identik" test wajib untuk setiap endpoint tulis |
| 2 | **Uang hilang diam-diam** — jalur `malformed`/422 klien saat ini menghapus penjualan | Empat penghalang independen (Sync v2) + `ingest_log` sisi server. **Tulis test "server membalas `[]`" paling awal di Fase 4** |
| 3 | Rollup menyimpang dari order mentah | Recompute 3 hari terakhir tiap malam + cek konsistensi tersampel mingguan + timestamp "per …" di setiap laporan + tombol hitung-ulang manual |
| 4 | Regresi isolasi tenant (Go tidak punya global scope) | RLS ditegakkan database; pool `BYPASSRLS` hanya di satu paket; suite test isolasi per-entity jadi definition-of-done, seperti `TenantIsolationTest.php` sekarang |
| 5 | Celah partisi atau salah rute | Partisi dibuat 3 bulan di muka; partisi `DEFAULT` menangkap yang nyasar + alert bila terisi; `order_dedupe` membuat duplikat akibat pergeseran tanggal mustahil |
| 6 | Regresi alokasi diskon | Port test `CategorySalesAggregator` **sebelum** kodenya — table-driven, tanpa DB — termasuk dua bug Dart aslinya |
| 7 | Skew jam merusak hari bisnis | Endpoint `/time`; perangkat menyimpan `server_time_delta_ms` dan menstempelnya pada baris yang di-push; server menandai order dengan delta > 5 menit; Backoffice menampilkan peringatan jam perangkat |
| 8 | Tim baru di Go | Satu binary dengan subcommand ala artisan; sqlc (SQL yang sudah dikuasai, bukan DSL ORM); templ (model mental Blade); `-race` di CI; **jalur uang dikerjakan satu orang senior sendirian** |
| 9 | Pembekuan kontrak molor → paralelisme Flutter mati | Spesifikasi OpenAPI adalah deliverable Fase 2 dengan gerbangnya sendiri; `oapi-codegen` menjadikan drift sebagai compile error |
| 10 | Redis mati menjatuhkan auth | Jatuh ke Postgres, jangan pernah fail-open; uji beban dengan Redis dimatikan supaya plafon terdegradasi jadi angka yang diketahui |
| 11 | Gagal perpanjang sertifikat mematikan semua till | Caddy + cek sintetis eksternal umur sertifikat + prosedur darurat terdokumentasi |
| 12 | Perangkat offline seminggu mem-push 10.000 baris sekaligus | Push ter-batch dengan rate limit per perangkat + pacing sisi klien; `order_dedupe` disimpan selamanya sehingga tidak ada jendela offline yang bisa melampauinya |
| 13 | Stok negatif / menyimpang | Ledger delta membuat divergensi mustahil secara struktural; negatif diizinkan dan di-alert, tidak pernah diblokir |
| 14 | **`FOR UPDATE` pada `tenants` menyelinap kembali** | Grep di CI. Ini cacat yang menyebabkan rewrite ini; perlakukan sebagai build failure |

---

## Cara Verifikasi Keseluruhan

Tiap fase punya kriteria selesai + verifikasi sendiri di atas. Tiga pemeriksaan yang berlaku menyeluruh:

1. **Uang tidak pernah ganda atau hilang.** Untuk setiap endpoint tulis: kirim payload identik tiga kali
   → database identik dengan sekali kirim. Untuk klien: mock server membalas `[]`, `"ok"`, 422, 500 →
   baris outbox tetap utuh di keempatnya.
2. **Tidak ada kontensi global.** Selama uji beban order, `SELECT * FROM pg_locks WHERE relation = 'tenants'::regclass`
   harus selalu kosong.
3. **Isolasi tenant utuh.** Setiap entity baru menambah kasus di suite isolasi sebelum dianggap selesai —
   aturan yang sama dengan `tests/Feature/TenantIsolationTest.php` hari ini.
## File Rujukan Utama

Pohon Laravel **sudah dihapus** dari repositori. Bagian ini disimpan sebagai
catatan dari mana tiap invariant berasal, dan ke mana ia pindah — bukan lagi
daftar berkas untuk dibaca.

| Invariant asal (Laravel, sudah dihapus) | Sekarang hidup di |
|---|---|
| `SyncCursor.php` — bukti lost-update yang harus bertahan setelah counter di-shard | `backend-go/internal/domain/syncfeed/counters.go`, dijaga `TestTheCounterLockIsHeldUntilTheWriterCommits` |
| `OrderIngest.php` — tiga jaminan uang, **dan lock baris tenant yang menyebabkan rewrite ini** | `backend-go/internal/domain/ingest/orders.go`; ketiadaan lock dijaga job CI `no-tenant-lock` dan sampel `pg_locks` di `scripts/loadtest` |
| `SyncRegistry.php` — allow-list kolom + urutan aman-FK | `backend-go/internal/domain/syncfeed/registry.go` |
| `CategorySalesAggregator.php` — largest-remainder | `backend-go/internal/domain/reporting/allocate.go`, test-nya diport lebih dulu |
| `SalesReporter.php` — "jangan pernah join `order_items` dalam total" | `backend-go/internal/domain/reporting/report.go` |
| `backend/CLAUDE.md` — catatan invariant | `backend-go/CLAUDE.md`, penerusnya |

Dua berkas till yang melahirkan cacat #3 masih ada dan masih relevan:

- [mobile/lib/data/sync/sync_client.dart](mobile/lib/data/sync/sync_client.dart) — tempat `malformed` lahir
- [mobile/lib/data/sync/order_push.dart](mobile/lib/data/sync/order_push.dart) — tempat `malformed` dulu menghapus penjualan

## Cara Verifikasi Keseluruhan

Tiap fase punya kriteria selesai + verifikasi sendiri di atas. Tiga pemeriksaan yang berlaku menyeluruh:

1. **Uang tidak pernah ganda atau hilang.** Untuk setiap endpoint tulis: kirim payload identik tiga kali
   → database identik dengan sekali kirim. Untuk klien: mock server membalas `[]`, `"ok"`, 422, 500 →
   baris outbox tetap utuh di keempatnya.
2. **Tidak ada kontensi global.** Selama uji beban order, `SELECT * FROM pg_locks WHERE relation = 'tenants'::regclass`
   harus selalu kosong.
3. **Isolasi tenant utuh.** Setiap entity baru menambah kasus di suite isolasi sebelum dianggap selesai —
   aturan yang sama dengan `tests/Feature/TenantIsolationTest.php` hari ini.
