# Fase 2 — Bukti Verifikasi

**Tanggal:** 23 September 2026  
**Acuan:** [RENCANA_IMPLEMENTASI_FASE_2.md](RENCANA_IMPLEMENTASI_FASE_2.md)  
**Status:** implementasi F2 selesai; seluruh gate otomatis lokal yang tersedia
lulus. Gate Windows release, workflow GitHub aktual, dan UAT bisnis interaktif
dua perangkat tetap dicatat sebagai tertunda sampai lingkungannya tersedia.

Dokumen ini mencatat hasil yang benar-benar dijalankan terhadap kode akhir.
Fase 2 masih berada dalam lingkup pengembangan lokal dan tidak mencakup
deployment.

## Hasil per workstream

| Workstream | Hasil | Status |
|---|---|---|
| F2.1 Brand | Master brand tenant-scoped, RLS, CRUD Backoffice, feed sebelum produk, brand produk, tombstone, dan snapshot brand item tersedia. | Lulus |
| F2.2 Pelanggan | Master pelanggan, normalisasi kontak, badge duplikat, izin `manageCustomers`, feed pull, dan push create-only idempoten tersedia. | Lulus |
| F2.3 Transaksi pelanggan | `customer_id` tersimpan pada order tanpa FK yang dapat menghapus histori; detail pelanggan menampilkan pembelian 12 bulan dan menggabungkan histori hasil merge saat membaca. | Lulus |
| F2.4 UI kasir | Kasir dapat mencari/membuat pelanggan, mengisi nama pelanggan, catatan order, dan catatan item. Snapshot tampil pada detail dan struk. | Lulus |
| F2.5 Katalog CSV | Ekspor ber-ID stabil, preview create/update/no-op, hash berkas konfirmasi, validasi referensi, advisory lock, dan kompatibilitas impor `sku;harga` tersedia. | Lulus |
| F2.6 Pelanggan CSV dan merge | Impor/ekspor all-or-nothing, audit ekspor data pribadi, duplicate badge, deactivate, serta merge dengan path compression dan tombstone tersedia. | Lulus |
| F2.7 Laporan brand | Rollup brand, dirty slice historis, Backoffice/POS/API, serta CSV/XLSX/PDF memakai alokasi net yang sama. | Lulus |
| F2.8 Dokumentasi | OpenAPI, memori proyek, panduan UAT, roadmap, dan dokumen bukti diperbarui. | Lulus |

## Backend

Perintah utama dijalankan dari `backend-go/` dengan PostgreSQL dan Redis nyata:

```bash
templ generate
go generate ./api ./internal/store
go build ./...
go vet ./...
go test ./... -count=1
go run ./cmd/justclick migrate down
go run ./cmd/justclick migrate up
go run ./scripts/verify-backoffice-crud
go run ./scripts/verify-reports
```

| Gate | Hasil |
|---|---|
| Build dan vet | Lulus |
| Templ, OpenAPI, SQLC | Diregenerasi dan stabil pada generasi berikutnya |
| Device API | Versi 2.7.0; schema brand, pelanggan, `customer_id`, `brand_id`, dan laporan brand tersedia |
| Suite Go penuh | Seluruh paket lulus, 0 gagal |
| Test pascaperbaikan terakhir | Ingest, syncfeed, RLS, Backoffice, dan template lulus |
| Migrasi | Migrasi 23–27 terpasang; migrasi audit 27 diuji down/up; migrasi brand rollup 26 diuji ulang down/up dengan FK cascade |
| Verifikasi Backoffice | Seluruh pemeriksaan brand, produk, katalog CSV, pelanggan, audit ekspor, duplikat, merge, permission, feed, dan render halaman lulus |
| Verifikasi laporan | Rekonsiliasi rollup/raw, brand, ekspor CSV/XLSX/PDF, drift/recompute, dan performa lulus |

`verify-reports` memakai 46.755 order dan 116.825 baris item pada 30 hari dan
6 outlet. Seluruh breakdown brand menjumlah tepat ke penjualan bersih. Karena
fixture dibuat tanpa snapshot brand, seluruh nilai masuk ke **Tanpa brand**, yang
membuktikan perilaku histori sebelum F2.

Skenario yang semula direncanakan sebagai `verify-catalog-io` dan
`verify-customers` digabung ke `verify-backoffice-crud`. Dengan begitu satu
fixture HTTP membuktikan form Backoffice, impor/ekspor, feed perangkat, audit,
permission, dan tombstone tanpa menggandakan provisioning tenant di CI.

| Jalur laporan | p50 | p95 | Batas |
|---|---:|---:|---:|
| Domain | 94,5 ms | 104,3 ms | 200 ms |
| Halaman Backoffice | 103,3 ms | 112,7 ms | 200 ms |

Verifikasi HTTP juga membuktikan pelanggan baru mencapai feed till, customer
hasil merge mencapai till sebagai tombstone, dan satu ekspor pelanggan menulis
tepat satu baris `customer_export_events`.

## Flutter

Perintah utama dijalankan dari `mobile/` dengan Flutter 3.38.9:

```bash
fvm flutter gen-l10n
fvm flutter analyze --no-fatal-infos
fvm flutter test
fvm flutter build apk --debug
```

| Gate | Hasil |
|---|---|
| Lokalisasi | Model hasil generate diperbarui untuk label pelanggan dan laporan brand |
| Analyzer | 0 error; 86 temuan level info dari baseline tetap terlihat |
| Suite Flutter penuh | 710 lulus, 2 live contract test di-skip, 0 gagal |
| Migrasi SQLite v31 | Fresh install, upgrade, fixture parsial lama, outbox, dead-letter, dan histori keuangan lulus |
| Repository pelanggan | UUID lokal, payload create-only, pencarian aktif, dan larangan cascade ke order lulus |
| Gate server lama | `customer_id` dan `brand_id` hanya dikirim bila manifest mengiklankan feed terkait |
| APK debug | Berhasil: `mobile/build/app/outputs/flutter-apk/app-debug.apk` |
| Smoke Android | APK dipasang pada emulator, aplikasi hidup kembali setelah `force-stop`, tanpa fatal exception pada log yang diperiksa |

Kegagalan yang ditemukan oleh suite penuh ada pada upgrade fixture SQLite yang
sengaja hanya memiliki sebagian tabel. `_addColumnIfMissing` kini memeriksa
keberadaan tabel sebelum `ALTER TABLE`; tiga regression test yang sebelumnya
gagal kemudian lulus, diikuti suite penuh tanpa kegagalan.

## Keamanan dan integritas data

- Brand dan pelanggan memakai RLS tenant; referensi lintas tenant ditolak oleh
  validasi atau foreign key komposit.
- Retry exact customer create diterima tanpa membuat baris atau sequence baru.
  Benturan UUID milik tenant lain tidak lagi dapat dibalas sebagai accepted.
- Merge tidak menulis ulang order. Resolusi winner dilakukan saat membaca dan
  tombstone pelanggan tidak dapat menghapus transaksi lokal.
- Preview impor katalog diikat ke SHA-256 berkas yang dikonfirmasi.
- CSV melindungi formula injection; ekspor pelanggan dicatat tanpa menyimpan
  salinan kedua isi berkas.
- Rollup brand memakai snapshot `order_items.brand_id`, sehingga rename master
  tidak merekonstruksi transaksi lama.

## Gate lingkungan yang masih tertunda

| Gate | Status | Alasan |
|---|---|---|
| Windows release | Tertunda | Visual Studio dan workload Desktop development with C++ tidak terpasang pada host ini. |
| Workflow GitHub aktual | Tertunda | Perubahan masih berada di worktree lokal dan belum dipush. |
| UAT interaktif dua instalasi | Tertunda | Emulator Android tersedia, tetapi skenario operator lengkap (aktivasi dua register, transaksi offline, ACK hilang, merge saat offline, dan pemeriksaan layar) memerlukan sesi UAT interaktif. Langkah dan bukti yang harus dicatat tersedia di [MANUAL_TEST_LOKAL.md](MANUAL_TEST_LOKAL.md). |

Keterbatasan tersebut tidak menyisakan implementasi F2 yang belum ditulis.
Hasil UAT harus ditambahkan ke dokumen ini ketika dijalankan dan tidak boleh
dianggap lulus sebelum ada bukti perangkatnya.
