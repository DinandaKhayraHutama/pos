# Fase 3 — Bukti Verifikasi

**Tanggal:** 24 September 2026  
**Acuan:** [RENCANA_IMPLEMENTASI_FASE_3.md](RENCANA_IMPLEMENTASI_FASE_3.md)  
**Status:** implementasi F3 selesai; seluruh gate otomatis lokal yang tersedia
lulus terhadap kode akhir. Build Windows release, eksekusi workflow GitHub
aktual, dan UAT bisnis interaktif dua perangkat (bagian J di
[MANUAL_TEST_LOKAL.md](MANUAL_TEST_LOKAL.md)) dicatat **tertunda**, bukan
lulus, sampai lingkungannya tersedia.

Dokumen ini mencatat hasil yang benar-benar dijalankan. Fase 3 masih dalam
lingkup pengembangan lokal dan tidak mencakup deployment.

## Hasil per workstream

| Workstream | Hasil | Status |
|---|---|---|
| F3.0 Sesi till | `refreshSignedInEmployee` dipanggil setiap selesai pull: pegawai dihapus/nonaktif/tanpa akses POS keluar, **tidak pernah** jatuh ke owner; cold start dengan identitas seperti itu mulai keluar; kehilangan `viewAllOrders` melupakan cache order. Rute `/employees`, `/outlets`, `/registers` dialihkan di till terhubung; tunai < total ditolak. | Lulus |
| F3.C0 Kontrak 2.8.0 | OpenAPI 2.8.0, migrasi 028, persamaan header baru, validasi baris v2, `pricing_mismatch` saat insert. Payload lama tetap diterima apa adanya. | Lulus |
| F3.1 Kapabilitas | `X-Device-Capabilities` dicatat hanya bila berubah tanpa menyentuh `updated_at`; header kosong di `/sync/*` = build lama; gate v2 per outlet dan peran kustom se-tenant; halaman Perangkat menandai "perlu update". | Lulus |
| F3.2 Peran kustom | Tabel `roles` + seed trigger, `employees.role_id` + trigger derivasi, aturan tanpa eskalasi, CRUD Backoffice, resolver akses Dart dengan fallback terkunci, `homeRouteForAccess` tanpa loop. | Lulus |
| F3.3 Pengaturan | `business_settings`/`outlet_settings`, timezone WIB/WITA/WIT dengan `legacy_timezone`, logo struk, halaman akun (profil + ganti kata sandi), preview struk; D8 di till (editable sampai owner menyimpan, lalu read-only). | Lulus |
| F3.4 Sales type & harga | Master + harga bisnis/outlet per sales type, grid harga di form produk, resolusi outlet → bisnis → produk + delta sekali. | Lulus |
| F3.5 Pembayaran | Metode + grup, `payment_method` wire tetap KIND, nama/id/referensi ikut order, fallback `other`, label laporan memakai nama. | Lulus |
| F3.6 Diskon | Master diskon bill/item, diskon bernama di till, approver tercatat terpisah dari `promo_name`. | Lulus |
| F3.7 Mesin harga | Go + Dart, 36 golden vector bersama (29 harga + 7 alokasi) lulus identik di kedua sisi; recompute server → flag, bukan tolak. | Lulus |
| F3.8 SQLite v32 | 9 tabel baru, kolom order/item, migrasi berkas nyata v31 → v32 mempertahankan outbox dan order legacy. | Lulus |
| F3.9 Integrasi till | Satu `cartQuoteProvider` dibaca keranjang, bar keranjang, checkout, order, dan push; sales type, diskon item, nominal bebas, diskon bernama, metode per grup + referensi, pemilih pelayan. | Lulus |
| F3.10 Struk | Logo/header/footer/telepon dari snapshot, sales type, pelayan, diskon baris, PB1 dengan tarif, "PB1 termasuk harga", pembulatan, "(manual)" untuk non-tunai; cetak ulang memakai snapshot. | Lulus |
| F3.11 Laporan | Rollup `tax_included`/`rounding`, rollup sales type & metode bayar, net baris v2 dari `net_amount` (kategori, produk, brand), waterfall menutup; laporan lokal dan `ServerReport` ikut. | Lulus |
| F3.12 Verifikasi & dokumentasi | `verify-pricing` baru dan terdaftar di CI, `verify-backoffice-crud` diperluas, CLAUDE.md kedua proyek, panduan UAT bagian J, dokumen ini. | Lulus |

## Backend

Dari `backend-go/`, PostgreSQL dan Redis nyata (Docker):

```bash
templ generate && go generate ./api ./internal/store   # dijalankan dua kali: 0 diff
go build ./... && go vet ./...                          # bersih
gofmt -l <semua berkas yang disentuh>                   # kosong
go test ./... -count=1                                  # 30 paket ok, exit 0
justclick migrate down   (8×: 035 → 027)                # roles/business_settings hilang
justclick migrate up                                    # kembali ke 035; 33 peran sistem ter-backfill (11 tenant × 3)
```

Verifier live terhadap `justclick serve` + `justclick worker` dari kode akhir
(Gotenberg lokal di `127.0.0.1:3000` untuk ekspor PDF):

| Skrip | Hasil |
|---|---|
| `verify-activation` (pertama, sebelum yang lain) | all checks passed |
| `verify-backoffice` | all checks passed |
| `verify-backoffice-crud` (termasuk cek Fase 3: peran kustom ditolak selama ada till tanpa `roles-v1`, izin asing tidak tersimpan, pengaturan bisnis sampai ke till, timezone WIT diterima / zona asing ditolak, kata sandi akun lama salah ditolak lalu diganti) | all checks passed |
| `verify-sync` | all checks passed |
| `verify-push` | all push checks passed |
| `verify-stock` | all stock checks passed |
| `verify-tables` | all table checks passed |
| `verify-till` | all till checks passed |
| `verify-recovery` | all recovery checks passed |
| `verify-reports` | all report checks passed — 180 slice di-rollup 6,8 s; laporan sebulan × 6 outlet p95 72,7 ms (domain) dan 83,2 ms (halaman Backoffice) |
| `verify-history` | all history checks passed |
| **`verify-pricing`** (baru) | all pricing checks passed — 26 cek |
| `verify-platform` | all checks passed |
| `loadtest smoke` | all gates met (3 struk dengan `type: "dineIn"` diterima) |

`verify-pricing` membuktikan lewat HTTP nyata: header kapabilitas tercatat dan
token asing dibuang; header kosong tidak mencatat apa pun; manifest menawarkan
enam feed Fase 3; owner menyimpan pengaturan bisnis; aktivasi v2 **ditolak**
selama till build lama aktif lalu **diizinkan** setelah dicabut; struk v2 hasil
engine diterima dengan `tax_included`/`rounding_amount` benar dan tidak
ditandai; struk yang snapshot-nya tidak mereproduksi angkanya **diterima dan
ditandai**; baris yang tidak menutup dan struk legacy berisi pajak termasuk
**ditolak** `schema_rejected`; laporan owner membaca pajak termasuk dan
pembulatan, waterfall `gross − diskon − retur − pajak termasuk = net`, revenue
`= net + pajak + layanan + pembulatan`, net = Σ `net_amount` baris, anomali
terhitung, dan pengelompokan per sales type.

## Mobile

Dari `mobile/` (PowerShell, `fvm`):

```text
fvm flutter gen-l10n                       # 32 kunci baru di app_en.arb dan app_id.arb
fvm flutter analyze --no-fatal-infos       # 0 error, 0 warning (86 info lama, tak satu pun dari berkas F3)
fvm flutter test                           # 774 passed, 2 skipped, 0 failed
fvm flutter build apk --debug              # √ build\app\outputs\flutter-apk\app-debug.apk
```

Test unit baru (kebijakan: model/repo/kalkulasi, tanpa widget test baru):

| Berkas | Membuktikan |
|---|---|
| `test/pricing/vectors_test.dart` | 36 vector bersama identik dengan Go |
| `test/providers/cart_quote_test.dart` | Till tak terkonfigurasi = matematika lama persis; outlet legacy mengabaikan harga sales type, diskon item, include, pembulatan; outlet v2 memakai harga outlet → bisnis, delta sekali, diskon item, snapshot dengan diskon bill; nominal bebas; pembuangan baris khusus v2 |
| `test/sync/order_push_pricing_test.dart` | Server 2.7.0 tidak menerima satu pun kunci F3; struk legacy mengirim nama tanpa istilah v2; struk v2 menutup persis seperti `validatePricing`; setiap revisi identik byte |
| `test/repositories/f3_migration_test.dart` | Berkas v31 nyata → v32: tabel/kolom F3 ada, outbox dan order legacy utuh |
| `test/providers/session_refresh_test.dart` | Perubahan peran berlaku di sesi hidup; nonaktif/dihapus/tanpa POS keluar, tidak pernah owner; peran yang barisnya belum tiba tidak memberi apa pun |
| `test/auth/permissions_test.dart` (+4) | Rute awal peran kustom tanpa loop; izin asing dibuang; peran asing terkunci; `enterCustomAmount` hanya lewat derivasi owner |
| `test/sync/business_timezone_test.dart` | 15.30 UTC bertanggal 23/09 di WIB/WITA dan 24/09 di WIT; zona asing = jam perangkat |
| `test/print/receipt_document_test.dart` (+1) | Struk v2 lengkap (pajak termasuk, pembulatan negatif, diskon baris, nominal bebas, pelayan, "(manual)", snapshot) menghasilkan PDF valid |

Backend test baru utama: `pricing/vectors_test.go`, `ingest/pricing_ingest_test.go`,
`ingest/till_roles_test.go`, `staff/roles_test.go`, `devices/capabilities_test.go`,
`settings/settings_test.go`, `catalogue/salestypes_test.go`,
`reporting/pricing_v2_test.go` (dengan uji mutasi: mengembalikan perhitungan brand
lama membuat test gagal), `backoffice/employees_form_test.go`.

## Audit kontribusi Codex

Sebagian F3 dikerjakan asisten lain saat sesi terputus. Seluruhnya ditelusuri;
cacat berikut ditemukan dari kode dan diperbaiki (tidak ada yang ditemukan
hanya dari test yang kebetulan hijau):

| # | Cacat | Dampak bila lolos | Perbaikan |
|---|---|---|---|
| 1 | Nama header kapabilitas salah di klien sync dan aktivasi | Server tidak pernah melihat kapabilitas → v2 dan peran kustom tak pernah bisa diaktifkan | `X-Device-Capabilities` |
| 2 | Order legacy disimpan `pricing_version = 1` + snapshot, dan `order_push` mengirim snapshot/rincian untuk versi apa pun | **Setiap** penjualan legacy di server 2.8.0 ditolak `schema_rejected` | Istilah v2 hanya untuk `pricing_version == 2`, diputuskan dari baris tersimpan |
| 3 | Snapshot tanpa `bill_discount` | Setiap bill berdiskon v2 ditandai `pricing_mismatch` | `CartQuote.pricingSnapshot` memuat diskon bill |
| 4 | `service_enabled = false` diabaikan | Layanan tetap ditagihkan saat dimatikan | Tarif 0 bila nonaktif |
| 5 | Sales type kustom dan metode ewallet/transfer/other ditawarkan di outlet legacy | Melanggar D1; dua till di satu toko menagih berbeda | Disaring di `SalesConfigRepository.context` |
| 6 | Pelayan selalu kasir; `promo_name` berisi nama approver | Bug yang justru ingin ditutup F3 (#6 di rencana) muncul lagi | Pemilih pelayan; approver ke `discount_authorized_by_*` |
| 7 | Rollup brand memakai alokasi, bukan `net_amount` v2 | Σ brand ≠ penjualan bersih | `brand.go` membaca `net_amount` bila semua baris membawanya |
| 8 | String UI literal di 6 berkas | Melanggar checklist l10n | 32 kunci ARB |
| 9 | Fallback enum: jenis order → `dineIn`, peran asing → `cashier` | Peran asing menjadi kasir yang boleh jual | → `custom` (peran: terkunci) |
| 10 | `homeRouteForAccess` ke `/dashboard` untuk peran tanpa `viewDailySummary` | Loop redirect | `/settings` sebagai fallback |
| 11 | Halaman Pengaturan menyembunyikan bagian Bisnis di till terhubung | Melanggar D8: merchant yang belum mengonfigurasi kehilangan tarifnya | Editable sampai owner menyimpan, lalu read-only |
| 12 | Argumen `style:` ganda di struk; provider yang sudah dihapus masih dipakai UI | Tidak terkompilasi | Diperbaiki saat konsolidasi quote |
| 13 | `internal/store/models.go` basi (belum diregenerasi setelah 031–035) | Gate "generator 0 diff" di CI gagal | Diregenerasi; dua kali berturut-turut 0 diff |
| 14 | Form staf Backoffice tidak lagi menerima kunci peran sistem | `verify-backoffice-crud` dan `verify-recovery` gagal (regresi) | Handler menerima id peran atau kunci sistem; test unit |
| 15 | Laporan lokal dan `ServerReport` mengabaikan `tax_included`/`rounding`/`by_sales_type` | Dashboard till menampilkan net yang masih berisi pajak | Net lokal − `tax_included`, net baris v2, parsing field baru |
| 16 | Cold start dengan peran kustom terkunci tetap `loggedIn` | Sesi tanpa izin apa pun terbuka | `loggedIn` mensyaratkan akses POS |

Temuan dari verifikasi saya sendiri: skenario mismatch di `verify-pricing` versi
pertama salah desain (pembulatan ke 1000 kebetulan menghasilkan total yang
sama dengan ke 100), diganti klaim mode `up`; dan ekspor PDF gagal karena
Gotenberg tidak berjalan (lingkungan, bukan kode) — lulus setelah dinyalakan.

## Gate lingkungan yang tertunda

| Gate | Status | Alasan |
|---|---|---|
| Build Windows release | Tertunda | Visual Studio belum terpasang di mesin ini |
| Eksekusi workflow GitHub (`backend-go.yml` dengan `verify-pricing`, `flutter.yml` dengan `testdata/**`) | Tertunda | Belum di-push; tidak dijalankan dari sini |
| UAT interaktif dua perangkat (J1–J13) | Tertunda | Membutuhkan dua till fisik/emulator dan build lama untuk J3/J6 |
| Build iOS | Tidak dicakup | Tidak ada mesin macOS |

## Keterbatasan yang diketahui

- Logo struk diambil saat mencetak; tanpa jaringan struk dicetak tanpa logo
  (tidak gagal). Cache logo lokal ditunda.
- Till build lama tetap memberi tanggal dari jam perangkat (tidak tahu zona
  merchant).
- Order pra-F3 tidak punya rincian baris; laporan memakai alokasi lama untuk
  mereka dan tidak mengarang rincian.
- Revokasi peran/izin saat till offline berlaku pada sinkron berikutnya, bukan
  seketika.
