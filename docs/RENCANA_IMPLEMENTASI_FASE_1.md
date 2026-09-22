# Rencana Implementasi Fase 1 — Visibilitas Transaksi dan Koreksi Laporan

## 1. Ringkasan dan keputusan

F1 membuat histori transaksi dapat ditelusuri, laporan penjualan memiliki rumus yang konsisten, dan angka POS, Backoffice, serta ekspor dapat dicocokkan untuk periode dan cakupan yang sama.

Berdasarkan pemeriksaan kode, fondasi laporan, rollup, ekspor, dan cache histori sudah tersedia. Implementasi akan memperluas fasilitas tersebut.

Keputusan yang sudah disetujui:

- **POS terhubung menggunakan agregat server**, mencakup seluruh register pada outlet yang dipilih.
- **Manager boleh melihat ringkasan penjualan lintas periode**, tetapi HPP, laba, margin, dan ekspor keuangan tetap khusus owner.
- Mode demo tetap memakai perhitungan lokal dengan rumus yang sama.
- Implementasi dan pengujian tetap lokal; tidak mencakup deployment.

Setelah rencana disetujui, simpan sebagai `docs/RENCANA_IMPLEMENTASI_FASE_1.md` dan tautkan dari roadmap utama. Bukti implementasi nantinya dicatat terpisah dalam `docs/FASE_1_VERIFICATION.md`.

## 2. Definisi angka dan batas akses

### Perhitungan penjualan

Semua nominal menggunakan integer rupiah dan snapshot transaksi, bukan harga atau HPP katalog saat ini.

| Metrik | Definisi F1 |
|---|---|
| Penjualan kotor | Subtotal seluruh transaksi selain transaksi dibatalkan, termasuk transaksi yang kemudian direfund |
| Diskon | Diskon dari kelompok transaksi yang sama |
| Retur penjualan | `subtotal − diskon` dari transaksi berstatus refunded |
| Penjualan bersih | Penjualan kotor − diskon − retur penjualan |
| Pajak dan layanan | Nilai tersimpan pada transaksi selain cancelled/refunded |
| Total penerimaan penjualan | Penjualan bersih + pajak + layanan; harus cocok dengan total transaksi yang masih diperhitungkan |
| HPP | Snapshot biaya item pada transaksi selain cancelled/refunded |
| Laba kotor | Penjualan bersih − HPP |
| Margin kotor | Laba kotor ÷ penjualan bersih; tampilkan “—” bila pembagi nol |
| Rata-rata penjualan | Penjualan bersih ÷ jumlah transaksi selain cancelled/refunded |
| Nilai refund uang | Nominal refund tersimpan, ditampilkan terpisah dari retur penjualan |

Aturan tambahan:

- Status dapur seperti `preparing` tetap mengikuti aturan penjualan sekarang. F1 tidak mengubah siklus pembayaran.
- Pembatalan ditampilkan terpisah dan tidak dikurangkan lagi dari waterfall.
- Refund dan recovery tetap memengaruhi **tanggal bisnis transaksi asli**. Waktu keputusan ditampilkan dalam detail audit.
- `amount_paid` yang mencakup uang kembalian bukan pendapatan.
- Gratuity dan pembulatan belum ditambahkan karena belum memiliki sumber data tersendiri.
- Data lama yang tidak konsisten ditandai sebagai anomali. F1 tidak merekonstruksi refund parsial atau mengubah transaksi historis.
- HPP yang tidak tersedia tidak dianggap diketahui bernilai nol. Tampilkan cakupan HPP; laba diberi penanda sementara bila cakupannya di bawah 90%.
- Field internal lama `revenue` dipertahankan dengan arti penerimaan untuk kompatibilitas. Model dan tampilan baru memakai nama metrik yang eksplisit.

### Akses

- **Cashier:** histori sendiri untuk hari bisnis berjalan, pada register perangkat; pembatasan berlaku pada server dan cache lokal.
- **Manager:** transaksi dan shift sesuai permission yang sudah ada; ringkasan penjualan lintas periode tanpa informasi biaya/laba.
- **Owner:** seluruh ringkasan dan laporan keuangan.
- Pemilihan outlet laporan tidak mengubah outlet aktivasi perangkat atau sesi kasir.
- Data keuangan yang tidak diizinkan harus dihilangkan dari respons server, bukan hanya disembunyikan oleh UI.

## 3. Urutan implementasi

### F1.1 — Baseline dan fixture rekonsiliasi

**Prioritas P0 · Ukuran kecil**

- Rekam baseline pengujian dan pertahankan perubahan F0 yang sudah ada.
- Buat fixture bersama untuk Go dan Dart: beberapa outlet/register/kasir, diskon, pajak, layanan, refund penuh, pembatalan, HPP kosong, dan transaksi recovery.
- Tetapkan hasil angka yang diharapkan secara eksplisit agar pengujian tidak sekadar membandingkan dua implementasi rumus yang sama.
- Inventarisasi data historis yang tidak memenuhi persamaan nominal secara read-only.

Sisa verifikasi F0—Windows release, UAT dua instalasi, dan workflow CI aktual—tetap dicatat sebagai prasyarat penutupan fondasi. Pekerjaan F1 dapat dikembangkan tanpa menyatakan gate tersebut sudah lulus.

### F1.2 — Koreksi agregat dan perhitungan ulang histori

**Prioritas P0 · Ukuran sedang**

- Tambahkan metrik waterfall dan koreksi laba pada model laporan Go serta Dart.
- Pertahankan arsitektur laporan berbasis rollup. Query transaksi mentah digunakan untuk detail dan pekerjaan recompute.
- Seluruh query pembentuk satu laporan membaca snapshot database yang konsisten.
- Perluas rollup untuk penjualan bersih per produk, kategori, kasir, outlet, dan waktu. Gunakan alokasi diskon largest remainder yang sudah ada.
- Alokasi produk dan kategori harus merekonsiliasi jumlah rupiah yang sama tanpa menambahkan modifier dua kali.
- Tambahkan agregat produk per kategori untuk tampilan top item dalam kategori.
- Hari dalam minggu diturunkan dari tanggal bisnis; jam memakai timezone tenant yang sudah tersedia.

Migrasi PostgreSQL bersifat aditif:

- Tambahkan kolom/tabel agregat yang diperlukan dan versi perhitungan.
- Tandai seluruh slice historis terdampak untuk dihitung ulang, termasuk outlet yang sudah dinonaktifkan.
- Jalankan backfill bertahap melalui worker dengan mekanisme generation yang sudah ada; proses dapat diulang setelah terputus.
- Selama backfill, tandai laporan belum lengkap dan jangan menampilkan kolom baru bernilai nol sebagai hasil final.
- Jangan mengubah payload order, efek stok, atau snapshot penutupan sesi.

### F1.3 — Histori transaksi dan shift Backoffice

**Prioritas P1 · Ukuran sedang**

Tambahkan halaman baca:

- `/backoffice/transactions` dan detail transaksi.
- `/backoffice/shifts` dan detail shift.

Transaksi menyediakan:

- Filter outlet, periode, kasir, register, nomor struk, dan status.
- Kelompok penjualan, dibatalkan, dan refund sesuai data yang tersedia.
- Detail item, modifier, nominal, pembayaran, kasir, register, sesi, serta alasan/pemberi otorisasi pembatalan atau refund.
- Tautan recovery ketika relevan. Waktu atau pelaku yang tidak direkam ditampilkan sebagai tidak tersedia.
- Struk memakai nama snapshot; perubahan master tidak mengubah detail struk lama.

Shift menyediakan:

- Filter outlet, periode pembukaan, register, kasir, serta status terbuka/tertutup.
- Waktu buka/tutup, modal awal, expected cash, counted cash, selisih, jenis penutupan normal/forced, dan transaksi terkait.
- Filter kasir mencakup kasir pembuka maupun kasir yang memiliki transaksi dalam sesi.
- Detail sesi mencakup seluruh transaksi sesi, termasuk sesi yang melewati tengah malam.
- Snapshot penutupan dan dampak recovery setelah penutupan ditampilkan terpisah.

Daftar menggunakan pagination keyset, maksimal 100 baris per halaman. Tidak ada aksi void/refund baru dari Backoffice dalam F1.

### F1.4 — Histori POS dengan periode dan pagination

**Prioritas P1 · Ukuran sedang**

Perluas `GET /api/v2/till/orders` secara aditif:

- Parameter baru `from`, `to`, `status`, `receipt_number`, `cashier_id`, dan `scope=register|outlet`.
- Parameter lama `day` dan `before` tetap didukung. Kombinasi `day` dengan rentang tanggal ditolak sebagai input ambigu.
- Default scope tetap register. Scope outlet dan filter kasir lain memerlukan `viewAllOrders`.
- Rentang maksimal 366 hari; cashier tetap dibatasi pada hari berjalan.

Perubahan aplikasi:

- Muat satu halaman per permintaan, menggantikan loop yang mengunduh seluruh halaman sekaligus.
- Tambahkan filter periode dan pencarian struk untuk pengguna berizin.
- Urutan stabil memakai waktu transaksi dan UUID; cursor terikat pada filter serta cakupan pengguna.
- Gabungkan sumber lokal dan remote dengan cursor masing-masing dan deduplikasi UUID; baris lokal tetap menjadi sumber untuk transaksi milik perangkat.
- Reset pagination saat filter, akun, atau outlet berubah; abaikan respons lama yang datang terlambat.
- Refresh memulai penelusuran ulang untuk mengambil transaksi terlambat dan perubahan status.

Cache remote tetap terpisah dari transaksi lokal:

- Tidak menghasilkan outbox, stok, total shift, atau total laporan.
- Simpan tanggal bisnis dari payload.
- Pisahkan cache berdasarkan pengguna dan scope, dengan metadata waktu serta kelengkapan pengambilan.
- Bedakan “tidak ada transaksi” dari “data belum tersedia offline”.
- Migrasi SQLite dari versi sekarang bersifat aditif dan mempertahankan seluruh antrean F0.

### F1.5 — API laporan dan dashboard POS/Backoffice

**Prioritas P1 · Ukuran sedang**

Tambahkan:

- `GET /api/v2/till/reports/summary` untuk `viewDailySummary`.
- `GET /api/v2/till/reports/sales` untuk `viewFinancialReports`.

Keduanya menggunakan bearer device dan `X-Cashier-Token`, serta service agregat yang sama dengan Backoffice.

Kontrak:

- Filter `from`, `to`, dan `outlet_id`; default outlet perangkat.
- Cakupan semua outlet hanya untuk pengguna dengan izin melihat ringkasan dan mengelola outlet.
- Respons object berisi periode, scope, timezone, versi perhitungan, waktu komputasi, jumlah slice tertunda, dan metrik sesuai permission.
- Dokumentasikan validasi serta respons 400/401/403/429/503 dan `Cache-Control: no-store`.
- Naikkan Device API dari 2.4.0 menjadi 2.5.0; master-data feed tetap versi 1.

Dashboard POS dan Backoffice menyediakan:

- Hari ini, kemarin, 7 hari, bulan berjalan, dan rentang khusus.
- Pembanding periode sebelumnya dengan jumlah hari yang sama.
- Waterfall penjualan, grafik harian/per jam/hari dalam minggu, top item, kategori berdasarkan volume/penjualan, dan top item per kategori.
- Perbandingan outlet pada periode yang sama.
- Nilai pembanding nol ditampilkan sebagai “—”, bukan persentase tak terhingga.

Mode offline POS:

- Gunakan cache laporan server untuk filter dan permission yang sama.
- Tampilkan label cache serta waktu pembaruan.
- Tampilkan transaksi lokal belum tersinkron sebagai informasi terpisah, tanpa menambahkannya ke agregat server.
- Jika cache tidak tersedia, tampilkan keadaan belum tersedia; jangan mengganti angka outlet dengan total perangkat secara diam-diam.

### F1.6 — Ekspor dan konsistensi tampilan

**Prioritas P1 · Ukuran kecil–sedang**

- Perbarui generator CSV/XLSX, template PDF Backoffice, serta ekspor CSV POS yang sudah tersedia.
- Gunakan metrik, filter, urutan waterfall, dan label yang sama dengan laporan.
- Cantumkan cakupan outlet, periode, timezone, waktu komputasi, versi perhitungan, dan status kelengkapan data.
- Pertahankan perlindungan formula injection, tipe angka XLSX, otorisasi unduhan, serta penyimpanan file privat.
- Ekspor baru memakai rumus F1. File lama tetap disimpan sebagai artefak historis dan dibedakan dari ekspor baru.
- Verifikasi PDF memakai Gotenberg lokal yang sudah tersedia di Compose; jangan membangun layanan PDF baru.
- Sesuaikan lokalisasi Indonesia/Inggris dan panduan penggunaan.

## 4. Pengujian dan kriteria selesai

### Keuangan dan agregat

- Fixture menghasilkan nominal yang diharapkan pada Go, Dart, Backoffice, POS, CSV, XLSX, dan PDF.
- Pajak/layanan meningkatkan penerimaan, tetapi tidak meningkatkan laba penjualan.
- Total kategori/produk cocok dengan penjualan bersih setelah alokasi diskon.
- Refund dan pembatalan tidak dikurangkan dua kali.
- HPP kosong, kategori terhapus, perubahan nama master, periode kosong, dan transaksi bernilai nol ditangani eksplisit.
- Recompute berulang tidak menggandakan angka; concurrent ingest mempertahankan dirty marker.
- Recovery accepted memperbarui tanggal bisnis asli; discarded tidak memengaruhi laporan.

### Histori, sesi, dan akses

- Lebih dari dua halaman, timestamp sama, batas tengah malam/bulan/tahun, dan pergantian filter tidak menggandakan atau melewatkan baris pada dataset tetap.
- Transaksi terlambat ditemukan setelah refresh.
- Pergantian akun dan respons jaringan terlambat tidak membocorkan cache pengguna sebelumnya.
- Manipulasi outlet, cursor, cashier ID, atau detail UUID lintas tenant ditolak.
- Manager tidak menerima HPP/laba melalui API, HTML, cache, atau unduhan.
- Shift lintas hari dan forced-close tetap menampilkan snapshot yang benar.

### Migrasi dan verifikasi lokal

- Uji migrasi kosong dan upgrade berisi data; pastikan order, outbox, dead-letter, recovery, dan stock movements tidak berubah.
- Uji backfill terputus lalu dilanjutkan.
- Jalankan suite backend/Flutter yang ada, contract freshness, serta perluasan `verify-reports`.
- Ukur ulang gate laporan yang sudah ada dengan fixture dan lingkungan pembanding yang sama.
- UAT dua register dalam satu outlet dan satu outlet pembanding: transaksi lokal, sinkronisasi, laporan outlet, offline cache, refund, recovery, serta ekspor.
- Build Android dan Windows serta verifikasi workflow aktual sesuai gate lingkungan yang tersedia.

F1 dinyatakan selesai setelah bukti pengujian dicatat dan seluruh kriteria yang relevan lulus. Pengujian yang belum dapat dijalankan ditulis sebagai tertunda, bukan dianggap berhasil.

## 5. Batas fase dan asumsi

- F1 tidak menambahkan saved bill, split payment, refund parsial, void per item, invoice/cicilan, role kustom, atau konfigurasi timezone baru.
- Riwayat transaksi merupakan tampilan keadaan transaksi terkini beserta audit yang tersedia; F1 tidak menciptakan audit historis yang belum pernah direkam.
- Total penerimaan dalam laporan penjualan bukan laporan arus kas berdasarkan tanggal refund.
- Pagination tidak menjanjikan snapshot beku selama transaksi terus berubah; refresh adalah mekanisme pembaruan.
- Implementasi dilakukan berurutan F1.1–F1.6, dengan pengujian pada setiap bagian dan verifikasi gabungan sebelum penutupan fase.
