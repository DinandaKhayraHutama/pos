# Fase 1 — Bukti Verifikasi

**Tanggal:** 23 September 2026  
**Acuan:** [RENCANA_IMPLEMENTASI_FASE_1.md](RENCANA_IMPLEMENTASI_FASE_1.md)  
**Status:** implementasi F1.1–F1.6 selesai dan seluruh gate otomatis lokal yang dapat dijalankan telah lulus.

Dokumen ini mencatat hasil yang benar-benar dijalankan pada kode akhir. Fase 1
tetap berfokus pada pengembangan lokal dan tidak mencakup deployment.

## Hasil per workstream

| Workstream | Hasil | Status |
|---|---|---|
| F1.1 Baseline dan fixture | Fixture Go/Dart mencakup dua outlet, dua register, refund, pembatalan, HPP kosong, dan recovery. Angka harapan ditulis eksplisit. Diagnostik read-only dijalankan pada seluruh tenant lokal. | Lulus |
| F1.2 Agregat dan recompute | Waterfall, net per dimensi, top item per kategori, versi kalkulasi, dirty slice, dan backfill tersedia. Pembacaan laporan dibatch dalam satu snapshot database. | Lulus |
| F1.3 Histori Backoffice | Daftar/detail transaksi dan shift, filter, keyset pagination, forced close, dan akses manager/owner diverifikasi melalui HTTP/HTML. | Lulus |
| F1.4 Histori POS | Rentang tanggal, status, pencarian struk, scope register/outlet, cursor terikat filter, cache per pengguna, dan pembatasan kasir diverifikasi. | Lulus |
| F1.5 API dan dashboard | Device API 2.5.0, permission summary/sales, waterfall, pembanding periode, outlet, kategori, item, jam, dan hari dalam minggu tersedia. | Lulus |
| F1.6 Ekspor | CSV, XLSX, PDF, dan CSV POS memakai definisi serta metadata F1 yang sama. | Lulus |

## Angka kanonis

Fixture utama memakai empat struk:

```text
paid      55.000 - 5.500 + 4.950 PB1            = 54.450
paid      20.000 - 0     + 2.000 PB1 + 1.000 SC = 23.000
cancelled 30.000                                  tidak masuk penjualan
refunded  15.000                                  retur penjualan 15.000
```

| Metrik | Nilai |
|---|---:|
| Penjualan kotor | 90.000 |
| Diskon | 5.500 |
| Retur penjualan | 15.000 |
| Penjualan bersih | 69.500 |
| Pajak + layanan | 7.950 |
| Total penerimaan | 77.450 |
| HPP | 15.000 |
| Laba kotor | 54.500 |
| Rata-rata penjualan | 34.750 |
| Nilai refund uang | 12.000 |

Go dan Dart menguji angka tersebut secara mandiri. `verify-reports` kemudian
mencocokkan rollup dengan SQL mentah pada 46.755 order dan 116.825 baris item.

## Backend

Perintah utama yang dijalankan dari `backend-go/`:

```bash
go build ./...
go vet ./...
templ generate
go generate ./api ./internal/store
go test ./... -count=1
go run ./scripts/verify-history
go run ./scripts/verify-reports
go run ./scripts/verify-till
go run ./scripts/verify-recovery
```

| Gate | Hasil |
|---|---|
| Build dan vet | Lulus |
| Templ | Segar, 0 pembaruan |
| OpenAPI 2.5.0 | Segar, model hasil generate tidak berubah |
| SQLC | Diregenerasi; `models.go` kini memuat kolom dan tabel F1 |
| Suite Go penuh | Seluruh paket lulus, 0 gagal |
| `verify-history` | Seluruh pemeriksaan histori POS, Backoffice, permission, filter, cursor, dan dashboard lulus |
| `verify-reports` | Seluruh rekonsiliasi, ekspor, drift/recompute, dan gate performa lulus |
| `verify-till` dan `verify-recovery` | Lulus; koordinasi register dan recovery F0 tidak mengalami regresi |

`verify-reports` dijalankan pada image API dan worker yang dibangun ulang dari
worktree akhir. Hasil performa untuk laporan 30 hari × 6 outlet:

| Jalur | p50 | p95 | Batas |
|---|---:|---:|---:|
| Domain laporan | 103,2 ms | 154,9 ms | 200 ms |
| Halaman Backoffice | 95,9 ms | 105,9 ms | 200 ms |

Sebelum koreksi akhir, pembacaan setiap dimensi melakukan perjalanan database
terpisah dan p95 sempat melebihi 300 ms. Query rollup sekarang memakai
`pgx.Batch` di dalam transaksi read-only yang sama. Konsistensi snapshot tetap
terjaga dan biaya lintas proses turun tanpa mengubah rumus laporan.

Migrasi `20260922000022_reporting_f1` diuji `down` lalu `up` pada database lokal
berisi data. Jumlah sebelum dan sesudah tetap sama:

| Entitas | Jumlah |
|---|---:|
| orders | 17 |
| order_items | 18 |
| pos_sessions | 13 |
| stock_movements | 6 |
| till_recoveries | 1 |
| till_recovery_items | 0 |

Schema kembali ke versi `20260922000022`. Diagnostik laporan dijalankan pada
10 tenant lokal untuk rentang satu tahun dan menemukan 0 anomali nominal.

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
| Lokalisasi | Segar, tidak menghasilkan drift |
| Analyzer | 0 error, 0 warning; 83 info lama tetap terlihat sesuai konfigurasi CI |
| Suite Flutter penuh | 697 lulus, 2 live test di-skip, 0 gagal |
| Migrasi SQLite/history | Termasuk dalam suite penuh dan lulus |
| Waterfall Dart | Termasuk dalam suite penuh dan lulus |
| APK debug | Berhasil: `mobile/build/app/outputs/flutter-apk/app-debug.apk` |

## CI dan gate lingkungan

- Workflow backend sekarang menjalankan API dan worker, lalu memasukkan
  `verify-history` setelah `verify-reports`.
- Workflow Flutter menjalankan analyzer, suite penuh, build APK, repository
  test Windows, persistence test berbasis file, dan build Windows release.
- Build Windows release tidak dapat dijalankan pada host ini karena Visual
  Studio dengan workload **Desktop development with C++** belum terpasang.
  Repository/database test Windows sudah tercakup dalam suite Flutter yang
  lulus; kompilasi Windows tetap harus dibuktikan oleh runner Windows CI.
- Workflow GitHub aktual belum dijalankan karena perubahan masih berada di
  worktree lokal dan belum dipush.

Keterbatasan lingkungan tersebut tidak meninggalkan pekerjaan implementasi F1
di dalam kode. Ia tetap menjadi bukti platform yang harus diperoleh ketika
branch dipush atau toolchain Windows tersedia.
