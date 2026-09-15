# Fase 7 — rollup laporan dan ekspor

Tanggal verifikasi: 15 September 2026. Acuan: `../../plan.md` (Rollup laporan +
ekspor, gerbang Fase 7). **Implementasi dan verifikasi otomatis selesai; PDF
lewat gotenberg dan pengiriman email lewat SMTP sungguhan belum diuji live
karena registry image tidak dapat dijangkau dari mesin ini.** Ini bukan
persetujuan pilot/rollout.

## Review Fase 6 (prasyarat)

- Diuji ulang: suite Go penuh, `go vet`, gofmt; suite Flutter dan analyzer.
- **Temuan (P2), sudah diperbaiki:** `client_seq` event meja dimulai dari 1 pada
  store SQLite kosong, padahal baris device dipakai ulang saat aktivasi ulang
  (`ON CONFLICT (tenant_id, device_uuid)`) dan installation id dapat bertahan
  setelah reinstall (keychain iOS). Event pertama store baru akan menabrak
  indeks unik server dan masuk dead-letter sebagai `duplicate`. Till kini
  menomori `max(sebelumnya + 1, jam dinding ms)`; test regresi
  `a store that starts empty numbers its changes above an earlier store`.
  Dicatat juga di `PHASE_6_VERIFICATION.md`, `mobile/CLAUDE.md` dan OpenAPI.
- Ditinjau dan dinilai aman: redirect router untuk editor saat connected, filter
  promo per outlet (tanpa outlet tidak ada promo), checkout + event meja dalam
  satu transaksi, overlay dead-letter, refresh `table_status` setelah ACK.

## Lingkup yang selesai

### Skema — `migrations/20260916000017_reporting.sql`

- `tenants.timezone` (default `Asia/Jakarta`, CHECK bentuk nama zona).
- Tujuh rollup per `(tenant, outlet, business_date)`: `daily_sales_rollup`,
  `daily_category_rollup`, `daily_product_rollup`, `daily_employee_rollup`,
  `daily_payment_rollup`, `hourly_sales_rollup`, dan tambahan
  `daily_adjustment_rollup` untuk audit diskon/void. Semua ber-RLS, composite FK
  ke outlet, indeks `(tenant_id, business_date)`.
- `report_schedules` dan `report_exports` (status, file, token hash, masa
  berlaku tautan, status pengiriman). Indeks unik `(schedule_id, date_from,
  date_to)` mencegah satu periode terkirim dua kali; FK ke jadwal
  `ON DELETE SET NULL (schedule_id)` (ditambahkan saat review, sebelumnya uuid
  menggantung).

### Domain — `internal/domain/reporting`

- **Alokasi kategori**: test `CategorySalesAggregator` diport **lebih dulu**
  (17 test tanpa DB, termasuk dua bug Dart yang dijaganya), lalu
  `AggregateCategories` (largest remainder per order, pemecah seri kunci terkecil,
  `big.Int` saat overflow).
- **Rollup**: satu slice dibangun ulang utuh (hapus + insert ketujuh tabel)
  dalam satu transaksi REPEATABLE READ. Marker `report_dirty_slices` hanya
  dihapus bila generasinya sama dengan yang dibaca pada snapshot; kalau berubah,
  job di-snooze 30 detik (tidak memakan attempt).
- **Laporan** hanya membaca rollup: ringkasan, harian, per outlet, per kategori
  (dengan peringatan cakupan HPP < 90%), per produk, per kasir, per jam (zona
  merchant), komposisi pembayaran, audit diskon & void, "Data per <waktu>" dan
  jumlah hari-outlet yang belum diperbarui.
- **Hitung ulang**: menandai slice kotor + enqueue job (maks 92 hari); halaman
  tidak membaca tabel mentah.
- **Jaring pengaman**: malam hari menandai 3 hari terakhir setiap outlet dan
  menghapus ekspor > 30 hari; mingguan menghitung ulang 20 slice acak dari 4
  minggu terakhir di transaksi yang selalu di-rollback, lalu mencatat tabel yang
  berbeda sebagai ERROR.
- **Ekspor**: CSV (`encoding/csv`, BOM UTF-8, pengaman formula injection), XLSX
  (ditulis manual dengan `archive/zip`), PDF (HTML templ yang sama dengan halaman
  → gotenberg). File ditulis atomik ke `REPORTS_DIR/<tenant>/<export>.<ext>`.
- **Jadwal harian/mingguan/bulanan** (06.00 waktu merchant): membuat ekspor,
  lalu mengirim **tautan** (bukan lampiran, bukan angka) berisi token acak 32
  byte; hanya SHA-256-nya disimpan, dibandingkan constant-time, berlaku 24 jam.
  Gagal kirim email tidak merender ulang; retry hanya mengirim ulang email.

### Worker, Backoffice, konfigurasi

- Satu klien River (`jobs.NewWorker`): antrean `maintenance` (1) dan `reporting`
  (4); job periodik ingest-partitions 1 jam, stock-reconcile 24 jam,
  report-nightly 24 jam, report-consistency 7 hari, report-schedules 15 menit.
- Backoffice: `/backoffice/dashboard` (omzet, order, rata-rata struk, outlet
  teratas; polling 30 detik hanya di widget; `viewDailySummary`) dan
  `/backoffice/reports` (laporan, hitung ulang, ekspor dengan polling status,
  jadwal; `viewFinancialReports`). Tautan email publik
  `/backoffice/report-links/{id}?token=…` menjawab 410 bila kedaluwarsa.
- Env baru: `REPORTS_DIR`, `PUBLIC_BASE_URL`, `GOTENBERG_URL`, `SMTP_*`,
  `MAIL_FROM`. Compose: volume `reports` dipakai bersama API dan worker;
  gotenberg dan mailpit ada di profile `reports`. CI menjalankan
  `verify-reports`.

## Penyimpangan dari draft plan (disengaja)

1. **Hapus + insert slice utuh, bukan `INSERT … ON CONFLICT DO UPDATE`.** Upsert
   meninggalkan baris produk/kasir/jam yang hilang dari hari itu (misalnya
   setelah refund). Slice kecil, jadi membangun ulang tetap murah.
2. **XLSX tanpa `excelize`.** Module proxy tidak dapat dijangkau; writer OOXML
   minimal (inline string, format angka ribuan/desimal, header tebal) cukup
   untuk tabel laporan dan tanpa dependensi baru.
3. **Tautan bertoken acak + hash, bukan URL bertanda tangan.** Setara untuk
   kebutuhan "tautan ber-TTL pendek", dan terputus ketika ekspor dihapus. TTL 24
   jam belum dapat diatur lewat env.
4. **Alert konsistensi = log ERROR.** Kanal alert (Sentry/metrics) milik fase
   pengerasan.
5. **Job periodik berbasis interval sejak worker start**, didedup per periode;
   restart worker dalam periode yang sama tidak menjalankan ulang job itu.

## Bug yang ditemukan saat verifikasi live

- **`backoffice.New` tidak menyalin `Deps.Reports`.** Semua rute laporan dan
  dashboard 404 di server sungguhan, sementara seluruh test lain lulus. Diperbaiki;
  `internal/backoffice/routes_test.go` menelusuri router. Uji mutasi: tanpa
  perbaikan test gagal (`GET /dashboard is not mounted`), dengan perbaikan lulus.

## Bukti verifikasi

| Pemeriksaan | Hasil |
|---|---|
| `go test ./... -count=1` (PostgreSQL 18 + Redis asli) | 21 paket lulus |
| Test integrasi reporting | Lulus: angka laporan fixture ingest (omzet 77.450, alokasi 42.000/22.500/5.000), laporan identik setelah semua order dihapus, zona waktu, race generasi via `SetAfterRollup`, hitung ulang + batas 92 hari, deteksi drift tanpa menyimpan hasil, isolasi tenant, ekspor CSV/XLSX/PDF (gotenberg palsu), PDF tanpa gotenberg gagal langsung, jadwal + email gagal lalu retry + token salah/kedaluwarsa, purge |
| Test worker | Lulus: job periodik berjalan saat start; slice tidak bersih di-snooze (state `scheduled`, attempt 0); cek konsistensi menghitung mismatch |
| Mailer | Lulus terhadap server SMTP palsu (STARTTLS, AUTH, header injection) |
| gofmt, `go vet`, templ | Bersih; `templ generate` tidak mengubah file hasil generate |
| staticcheck v0.8.1 | Lulus setelah memperbaiki satu ST1005 (pesan pengguna di string error pengiriman) |
| Flutter setelah koreksi `client_seq` Fase 6 | Suite **662 lulus, 2 dilewati**, 0 gagal (termasuk `a store that starts empty numbers its changes above an earlier store` dan `local event order survives a clock correction`); analyzer 0 error, 0 warning, 86 info yang sudah ada |
| Regresi HTTPS fase sebelumnya | `verify-activation`, `verify-backoffice`, `verify-backoffice-crud`, `verify-sync`, `verify-push`, `verify-stock`, `verify-tables` semua lulus, berurutan, terhadap build yang sama |
| Job worker di Compose | `report_nightly`, `report_schedules`, `report_slice` berstatus completed |
| HTTPS `verify-reports` (API + worker Compose) | **64 pemeriksaan lulus.** Seed 46.755 order / 116.825 baris, 30 hari × 6 outlet (termasuk batal, refund, status dapur, item tanpa produk/kategori, produk terhapus, kategori diganti nama). 180 slice dihitung dalam 3,6 detik (20,3 ms/slice). Laporan sebulan dari rollup **sama persis** dengan SQL mentah independen untuk semua angka dan semua rincian, baik gabungan maupun per outlet |
| Gerbang < 200 ms | Domain p50 17,4 ms / p95 19,7 ms / maks 20,2 ms (40 run); halaman Backoffice via HTTPS p50 17,8 ms / p95 18,8 ms / maks 19,1 ms (25 run) |
| Tidak membaca order | Semua 46.755 order tenant dihapus: laporan domain identik dan halaman menampilkan omzet yang sama |
| Ekspor via halaman + worker | CSV dan XLSX dirender worker, diunduh lewat Backoffice, berisi omzet yang sama. PDF: worker tanpa gotenberg → gagal langsung dengan pesan (dicatat, bukan klaim lulus) |
| Konsistensi | Sampel cocok; rollup yang diubah manual terdeteksi (`daily_sales_rollup`) dan diperbaiki oleh hitung ulang |
| Tombol hitung ulang | Menjawab di halaman dan mengantrekan tepat satu job slice |

## Jalankan ulang

Dari `backend-go/`, env lokal dimuat, Compose aktif:

```powershell
go run ./cmd/justclick migrate up
docker compose up -d --build api worker caddy
$env:VERIFY_BASE_URL='https://localhost:8443'
$env:VERIFY_INSECURE_TLS='1' # hanya CA development lokal
go run ./scripts/verify-reports
```

Tanpa worker, `verify-reports` mengambil job ekspor dari antrean dan merendernya
sendiri ke `REPORTS_DIR`, yang harus sama dengan milik API (seperti di CI).
Untuk PDF/email lokal: `docker compose --profile reports up -d`, lalu set
`GOTENBERG_URL=http://gotenberg:3000`, `SMTP_HOST=mailpit`, `SMTP_PORT=1025`,
`MAIL_FROM=laporan@localhost` dan rebuild API/worker.

## Gerbang yang masih terbuka

- **PDF (gotenberg) dan email (SMTP/mailpit) belum diuji live**: image tidak
  dapat ditarik. Keduanya diuji dengan server HTTP/SMTP palsu.
- Belum ada layar Pengaturan untuk timezone; mengubah timezone memerlukan hitung
  ulang riwayat.
- Latensi diukur di laptop development dengan satu merchant 30 hari × 6 outlet,
  bukan skala 5.000 outlet / 30 juta baris per bulan dan bukan uji beban. Replika
  khusus laporan belum ada. Metrik/alert kebasian rollup (< 15 menit) milik
  fase pengerasan.
- `-race` membutuhkan cgo; dijalankan di CI Linux, tidak di mesin ini.
