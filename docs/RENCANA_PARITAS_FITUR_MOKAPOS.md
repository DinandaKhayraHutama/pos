# Rencana Pengembangan JustClick POS Menuju Paritas Fitur MokaPOS

**Tanggal:** 22 September 2026  
**Dokumen:** `docs/RENCANA_PARITAS_FITUR_MOKAPOS.md`  
**Status:** Fase 0 sudah selesai. **Implementasi Fase 1 juga selesai seluruhnya
(F1.1–F1.6)** dan semua gate otomatis lokal yang dapat dijalankan telah lulus,
termasuk build Android. Build Windows release dan eksekusi workflow GitHub
masih menunggu lingkungan yang sesuai; rinciannya dicatat di
[FASE_1_VERIFICATION.md](FASE_1_VERIFICATION.md). **Implementasi Fase 2 juga
selesai**, dan seluruh gate otomatis lokal yang tersedia telah lulus berdasarkan
[RENCANA_IMPLEMENTASI_FASE_2.md](RENCANA_IMPLEMENTASI_FASE_2.md). Bukti serta
gate lingkungan dicatat di [FASE_2_VERIFICATION.md](FASE_2_VERIFICATION.md).
**Implementasi Fase 3 juga selesai**
([RENCANA_IMPLEMENTASI_FASE_3.md](RENCANA_IMPLEMENTASI_FASE_3.md)); gate otomatis
lokal lulus dan gate lingkungan dicatat di
[FASE_3_VERIFICATION.md](FASE_3_VERIFICATION.md).

## 1. Tujuan, acuan, dan keputusan produk

Mengembangkan fitur JustClick POS secara bertahap berdasarkan analisis MokaPOS, dengan mendahulukan kebutuhan restoran/kafe, manfaat operasional, dan kemudahan implementasi. Setiap fase harus mencakup perubahan kasir, Backoffice, backend, penyimpanan lokal, sinkronisasi, hak akses, stok, serta laporan yang terdampak.

Acuan kebutuhan:

- [Analisis Fitur Backoffice MokaPOS](<Analisis Fitur Backoffice MokaPos.md>).
- [Analisis Fitur Kasir MokaPOS](<Analisis Fitur Kasir MokaPos.md>).
- [Rencana Konsistensi Multi-device](RENCANA_KONSISTENSI_MULTI_DEVICE.md), sebagai pekerjaan fondasi yang harus dilanjutkan.

Status fitur ditentukan dari penelusuran kode dan dokumentasi proyek, bukan hanya daftar fitur dalam README atau laporan fase terdahulu. Analisis pengguna menjadi target pembanding; dokumen ini tidak mengklaim telah memverifikasi seluruh penawaran MokaPOS terbaru.

Audit ini bersifat statis. Suite pengujian belum dijalankan ulang. PDF ringkasan lama tidak berhasil diparsing; versi HTML-nya telah ditelaah.

### Keputusan yang sudah disepakati

| Aspek | Keputusan |
|---|---|
| Segmen awal | Restoran/kafe; kebutuhan retail tetap masuk roadmap. |
| Lingkungan | Development dan pengujian lokal. Deployment belum menjadi pekerjaan fase ini. |
| Platform utama | Windows dan Android. Regresi platform yang sudah didukung tetap dijaga. |
| Pembayaran | Pembayaran manual dahulu; integrasi penyedia pembayaran menyusul. |
| Saved bill | Satu perangkat editor. Pemilik boleh melanjutkan offline; perpindahan kepemilikan membutuhkan konfirmasi server. |
| Pengurangan stok | Saat pesanan dikonfirmasi untuk diproses/dikirim ke dapur. |
| HPP | Biaya standar yang disimpan sebagai snapshot; perubahan biaya tidak mengubah transaksi lama. |
| Printer | LAN dahulu; dialog cetak PDF tetap tersedia. |
| Invoice pelanggan/DP lintas hari | Coming soon, berbeda dari split payment saat checkout. |
| Integrasi rumit | Billing SaaS, QRIS otomatis, marketplace, OTP, dan pengiriman SMS/email eksternal tetap coming soon. |

**Sasaran keberhasilan:** seluruh fitur aktif dapat dibuktikan bekerja pada alur lokal dua perangkat, tanpa kehilangan transaksi, pembayaran, stok, atau jejak audit ketika terjadi restart, offline, retry, dan perubahan konfigurasi.

## 2. Perbandingan fitur dan kondisi proyek

Fondasi proyek sudah cukup luas: Flutter dengan SQLite dan outbox, backend Go, PostgreSQL, Backoffice, platform admin, pengelolaan perangkat, koordinasi sesi kasir, stok, laporan, dan ekspor. Pekerjaan selanjutnya terutama memperluas model bisnis dan menyelaraskan perilaku antarmodul.

Keterangan: **Ada** berarti implementasinya ditemukan, bukan jaminan pengujian ulang sudah lulus. **Sebagian** berarti cakupannya belum setara dengan target.

| Area | Kondisi kode saat ini | Kebutuhan berikutnya | Fase |
|---|---|---|---|
| Katalog, kategori, foto, varian, modifier | Ada | Pertahankan dan perluas secara kompatibel. | F2–F3 |
| Impor/ekspor katalog | Sebagian; impor hanya memperbarui harga berdasarkan SKU | Membuat/memperbarui produk melalui CSV, ekspor dan validasi referensi. | F2 |
| Brand | Belum ada | Master brand dan dimensi laporan. | F2 |
| Pelanggan | Baru berupa informasi nama pada transaksi; belum menjadi modul pelanggan | Master pelanggan, input POS, pencarian, impor/ekspor, riwayat pembelian. | F2 |
| Sales type | Tiga enum tetap | Master jenis penjualan dan harga berbeda menurut jenis penjualan/outlet. | F3 |
| Pajak dan layanan | Sebagian; konfigurasi utama masih lokal | Konfigurasi terpusat, include/exclude, aturan per jenis penjualan, snapshot. | F3 |
| Diskon manual | Diskon tingkat bill tersedia | Diskon per item, master diskon tetap/custom, otorisasi terpisah. | F3 |
| Custom amount | Belum tersedia sebagai alur kasir | Item nominal bebas dengan nama, alasan, pajak, dan izin yang jelas. | F3 |
| Pembayaran | Cash, card, QRIS sebagai pencatatan manual | Master metode, grup pembayaran dan penugasan per outlet. | F3 |
| Saved bill | Belum ada alur persisten lengkap | Simpan, buka kembali, tambah pesanan, kirim dapur, serah kepemilikan. | F4 |
| Status pesanan dan pembayaran | Masih bercampur | Pisahkan status bill, dapur, pembayaran, dan pengembalian. | F4 |
| Split payment dan split bill | Belum ada | Pembayaran campuran serta pemisahan item/kuantitas menjadi tagihan terpisah. | F5 |
| Void/refund | Sebagian; seluruh order dan seluruh stok dikembalikan | Void item, refund sebagian, alokasi nominal dan keputusan pengembalian stok. | F5 |
| Riwayat transaksi | Lokal dan cache server tersedia; remote hanya baca | Filter periode, pencarian struk, halaman detail Backoffice dan audit tindakan. | F1, F4–F5 |
| Shift | Modal awal, penutupan, hitung kas dan selisih tersedia | Kas masuk/keluar, cash drop, petty cash, Z-report dan rekonsiliasi pembayaran campuran. | F5 |
| Meja | Master, area, kapasitas, status dan grid tersedia | Denah visual, bentuk/posisi, timer, pindah/gabung, laporan penggunaan. | F4, F6 |
| Printer dan struk | PDF melalui dialog sistem; cetak ulang tersedia | Profil struk, logo/footer, preview, cetak LAN, routing dapur, antrean cetak. | F3, F6 |
| Barcode dan cash drawer | Belum ada dukungan operasional lengkap | Scanner HID, barcode produk/varian, perintah drawer berotorisasi. | F6 |
| Pegawai dan akses | Tiga role tetap, PIN dan permission tersedia | Role kustom, akses POS/Backoffice, penyegaran izin pengguna aktif. | F3 |
| Stok barang jadi | Ledger, penyesuaian, opname dan transfer sederhana tersedia | Batas minimum per barang/outlet, ringkasan pergerakan, dokumen pembelian/transfer. | F7 |
| Supplier dan PO | Belum ada | Supplier, penerimaan pembelian sederhana, lalu approval dan penerimaan bertahap. | F7, F10 |
| Transfer lanjutan | Belum ada; transfer sekarang langsung per produk | Dokumen banyak item, approval, pengiriman, barang dalam perjalanan dan penerimaan. | F7, F10 |
| Ingredients dan resep | Belum ada | Bahan mentah, satuan, resep berversi, bahan setengah jadi dan Produce. | F8 |
| Promo otomatis | Baru preset yang dipilih kasir | Syarat tanggal/jam/jenis penjualan, diskon otomatis, free item. | F9 |
| Bundle | Belum ada | Paket, harga menurut sales type, stok dan HPP komponen. | F9 |
| Dashboard/laporan | Banyak agregat tersedia | Koreksi definisi laba, waterfall, filter periode, perbandingan outlet dan dimensi tambahan. | F1 dan setiap fase terkait |
| Laporan Backoffice transaksi/shift | Belum ada halaman khusus yang lengkap | Penelusuran transaksi, pembatalan, void item dan pertanggungjawaban shift. | F1, F5 |
| Ekspor dan jadwal laporan | CSV/XLSX dan mekanisme jadwal tersedia; PDF juga sudah diimplementasikan | Verifikasi lokal; perluas kolom sesuai fitur. Pengiriman email nyata ditunda. | F1 dan fase terkait |
| Pengaturan bisnis dan akun | Sebagian dan tersebar | Pengaturan merchant/outlet terpusat, profil struk, checkout dan inventori. | F3, F10 |
| Invoice pelanggan | Belum ada | Unpaid, partial, overdue, DP dan pelunasan Backoffice. | Coming soon |
| Loyalty dan feedback | Belum ada | Poin, reward, OTP redeem, feedback dari struk digital/layar pelanggan. | Coming soon |
| Online order dan marketplace | Belum ada | Katalog online, QR meja, pickup, penerimaan pesanan dan sinkronisasi menu. | Coming soon |
| Billing dan settlement | Belum ada | Langganan per outlet, kupon, rekening pencairan dan integrasi penyedia. | Coming soon |

### Temuan yang memengaruhi urutan implementasi

1. **Checkout saat ini sudah mencatat pembayaran meskipun status order masih `preparing`.** Saved bill tidak boleh ditambahkan hanya dengan memakai status tersebut.
2. **Laba kotor backend menggunakan total penerimaan dikurangi HPP**, sehingga pajak dan layanan ikut masuk dasar laba. Definisi ini perlu diperbaiki.
3. **Refund sekarang mengembalikan seluruh stok.** Menambahkan input nominal refund saja belum menghasilkan partial refund yang benar.
4. **Riwayat remote sengaja dipisahkan dari order lokal.** Cache tersebut tidak boleh ikut menjadi sumber outbox, pengurangan stok, atau agregat outlet yang tidak lengkap.
5. **Dokumentasi tertinggal dari kode.** SQLite sudah versi 28, migrasi backend mencapai 020, sedangkan endpoint koordinasi `/till` belum seluruhnya tercantum dalam OpenAPI.
6. **Dukungan database Windows perlu dibereskan.** Inisialisasi database native masih tidak mengatur backend SQLite desktop, sementara FFI berada pada dependency pengujian.

## 3. Aturan desain dan perubahan kontrak

Aturan berikut berlaku untuk semua fase agar fitur baru tidak menghasilkan perilaku berbeda antara POS, backend, dan Backoffice.

### A. Kompatibilitas, konfigurasi, dan akses

- Pertahankan namespace `/api/v2`. Tambahkan kontrak secara terukur, dokumentasikan di OpenAPI, dan perbarui tipe Go/Dart serta schema sinkronisasi bersama.
- Master baru meliputi konfigurasi bisnis, jenis penjualan, metode/grup pembayaran, brand, pelanggan, dan role. Feed harus mengikuti scope tenant/outlet dan kebutuhan akses perangkat.
- Fitur yang memerlukan model baru hanya diaktifkan setelah perangkat outlet mendukung kontraknya. Jangan membiarkan client lama menafsirkan metode baru sebagai `cash` atau sales type baru sebagai `dineIn`.
- Pisahkan **dukungan versi fitur pada perangkat** dari entitlement Backoffice yang sekarang ada; jangan mengubah perilaku entitlement lama secara terselubung.
- Konfigurasi bisnis dimiliki server dan dicache untuk offline. Tema, bahasa antarmuka, serta koneksi printer tetap preferensi perangkat.
- Perubahan permission/pegawai aktif harus memperbarui konteks login setelah sinkronisasi. Revokasi instan ketika perangkat offline tidak dijanjikan.
- Migrasi role mempertahankan izin bawaan sekarang, termasuk bahwa owner/manager tidak otomatis memperoleh hak jual atau membuka shift.

### B. Bill, pembayaran, dapur, dan kepemilikan

Tambahkan model terpisah untuk **Bill/BillLine**, pengiriman dapur, pembayaran, refund, pergerakan kas, dan sesi meja.

- Menyimpan bill tidak menghasilkan penjualan, pembayaran, atau pengurangan stok.
- Mengirim baris pesanan ke dapur menghasilkan efek stok satu kali.
- Pelunasan menerbitkan struk penjualan tanpa mengurangi stok kedua kali.
- Penjualan langsung tetap didukung: konfirmasi pesanan dan pembayaran dapat terjadi dalam satu alur atomik.
- Status dapur berjalan sendiri dari status pembayaran. Perubahan `preparing → ready → served` tidak mengubah pendapatan.
- Setiap operasi membawa ID unik, revisi, dan identitas kepemilikan. Retry tidak boleh menghasilkan pembayaran, stok, atau struk tambahan.
- Satu bill memiliki satu perangkat editor. Handoff membutuhkan sinkronisasi perubahan pemilik lama, konfirmasi server, dan pergantian generasi kepemilikan.
- Tidak ada pengambilalihan otomatis akibat heartbeat hilang. Konflik atau perangkat hilang masuk alur pemulihan dengan audit.
- Pengikatan awal meja bersama, pindah/gabung meja, dan handoff membutuhkan koneksi server. Bill tanpa meja dapat dibuat offline pada sesi yang sah.
- Shift yang masih memiliki bill terbuka hanya dapat ditutup setelah bill diselesaikan atau diparkir/diserahterimakan secara online. Pembayaran tetap melekat pada shift penerimanya.

### C. Uang, diskon, dan laporan

- Nominal transaksi tetap integer rupiah. Gunakan perhitungan deterministik; hindari floating-point untuk hasil keuangan.
- Urutan dasar: harga beserta varian/modifier → diskon item → alokasi diskon bill → layanan/pajak → pembulatan akhir.
- Mode include/exclude harus memakai aturan yang sama di Flutter dan Go. `null` berarti mewarisi konfigurasi; nilai nol tetap merupakan override sah.
- Selisih pembulatan dialokasikan secara deterministik agar jumlah per item, split bill, pembayaran, refund, dan laporan selalu cocok.
- Simpan snapshot harga, tarif, diskon, HPP, sales type, identitas produk, dan konfigurasi yang dipakai. Perubahan master tidak menghitung ulang struk lama.
- Untuk fase aktif, penjualan diakui saat bill lunas. Uang yang diterima sebelum pelunasan dicatat terpisah sebagai pembayaran belum selesai; invoice/piutang lintas hari belum diaktifkan.
- Definisi laporan: **net sales = gross sales − discounts − refund penjualan**; pajak, layanan, dan pembulatan ditampilkan terpisah. **Gross profit = net sales − COGS**.
- HPP yang tidak diketahui tidak dianggap nol yang valid. Selaraskan peringatan cakupan HPP dengan ambang 90%, dan tampilkan bahwa laba berbasis biaya standar.
- Shift tertutup mempertahankan snapshot hasil penutupannya. Refund kemudian masuk periode dan shift pengembalian, bukan mengubah laci yang sudah ditutup.

### D. Stok dan resep

- Kembangkan ledger yang sudah ada; jangan membuat saldo stok kedua yang berdiri sendiri.
- Efek stok baru terkait sumber operasi dan baris pesanan, sehingga dapat mewakili barang jadi, komponen bundle, dan bahan resep.
- Pengiriman dapur tambahan hanya mengurangi kuantitas tambahan. Pembatalan setelah pengiriman meminta keputusan pengembalian fisik atau waste.
- Refund uang tidak otomatis mengembalikan bahan. Barang/bahan yang sudah dikonsumsi tetap mempunyai biaya; klasifikasi waste tidak boleh membebankan biaya yang sama dua kali.
- Resep, konversi satuan, dan HPP memakai versi yang disimpan pada operasi. Perangkat offline tidak dihitung ulang menggunakan resep terbaru saat melakukan sinkronisasi.
- Batas stok awal menggunakan saldo yang diketahui perangkat, dengan default peringatan. Sistem tidak menjanjikan pencegahan overselling global saat offline dan tidak menolak pencatatan penjualan nyata hanya karena stok server menjadi negatif.

### E. Histori, audit, dan migrasi

- Struk final tetap immutable; koreksi dilakukan melalui catatan pembayaran/refund/penyesuaian terkait.
- Cache riwayat perangkat lain tetap hanya baca. Mutasi lintas perangkat memerlukan serah hak yang dikonfirmasi, bukan menghapus atribut `readOnly`.
- Pertahankan tenant isolation, validasi actor di server, audit otorisasi, urutan penguncian stok, serta enqueue laporan dalam transaksi yang sama.
- Migrasi mempertahankan UUID, kepemilikan, nomor struk, snapshot, outbox, dan dead-letter. Tidak menggunakan penghapusan database sebagai strategi migrasi.
- Data historis yang tidak mempunyai rincian item/refund/actor tidak boleh diberi rincian buatan. Tampilkan keterbatasan data lama.
- Dashboard outlet menggunakan agregat server. Tampilan lokal/offline harus menyebut cakupan dan waktu pembaruan datanya.

## 4. Roadmap implementasi

**Prioritas:** P0 = fondasi wajib; P1 = operasi utama restoran; P2 = efisiensi dan kontrol; P3 = operasional lanjutan.  
**Ukuran:** kecil/sedang/besar merupakan kompleksitas relatif, bukan estimasi kalender.

Urutan default adalah **F0 → F1 → F2 → F3 → F4 → F5 → F6 → F7 → F8 → F9 → F10**. Fitur yang sederhana dan bernilai cepat didahulukan; pekerjaan besar mengikuti fondasi yang dibutuhkannya.

### F0 — Konsolidasi fondasi dan baseline lokal

**P0 · Sedang · Prasyarat seluruh fase**

Rincian implementasi: [RENCANA_IMPLEMENTASI_FASE_0.md](RENCANA_IMPLEMENTASI_FASE_0.md).

- Perbaiki inisialisasi SQLite Windows dan dependency runtime-nya; buktikan penyimpanan tetap ada setelah restart pada Windows dan Android.
- Lengkapi kontrak OpenAPI untuk endpoint till yang sudah ada, selaraskan versi dokumentasi, dan inventarisasi konflik sesi, outbox, dead-letter serta efek stok yatim.
- Lengkapi pemulihan koordinasi perangkat tanpa mengosongkan data; pertahankan aturan satu writer per register dan satu penugasan jual aktif per kasir.
- Siapkan baseline pengujian lokal yang dapat diulang dan CI Flutter untuk analisis, pengujian data, serta regresi yang sudah ada.

**Dampak:** database lokal, paket desktop, kontrak API, koordinasi sesi, sinkronisasi, CI dan dokumentasi.

**Kriteria lulus:** dua instalasi berbeda dapat diuji tanpa berbagi file database; restart/retry tidak menggandakan sesi atau order; transaksi tertahan terlihat dan dapat dipulihkan.

### F1 — Visibilitas transaksi dan koreksi laporan

Rincian implementasi: [RENCANA_IMPLEMENTASI_FASE_1.md](RENCANA_IMPLEMENTASI_FASE_1.md).
Bukti verifikasi: [FASE_1_VERIFICATION.md](FASE_1_VERIFICATION.md).

**P1 · Kecil–sedang · Bergantung F0 · Implementasi selesai, gate lokal lulus**

- Tambahkan halaman Backoffice transaksi dan shift dengan filter outlet, periode, kasir, nomor struk, serta detail pembatalan yang tersedia.
- Perluas penelusuran riwayat POS dengan periode dan pagination yang benar, tetap menjaga cache remote sebagai data baca.
- Perbaiki pemisahan net sales, pajak, layanan, penerimaan, HPP dan laba; tambahkan waterfall sesuai data yang tersedia.
- Lengkapi filter periode dashboard, hari dalam minggu, top item/kategori, serta perbandingan outlet menggunakan agregat yang sama.
- Sesuaikan CSV/XLSX dan verifikasi PDF lokal yang sudah ada. Jangan membangun ulang fasilitas ekspor yang sudah tersedia.

**Dampak:** query, rollup, worker laporan, dashboard, histori, ekspor dan label sumber data.

**Kriteria lulus:** detail transaksi, agregat dan ekspor cocok untuk fixture yang sama; pergantian periode tidak melewatkan/menggandakan baris; angka pajak/layanan tidak menaikkan laba penjualan.

### F2 — Kelengkapan katalog dan pelanggan dasar

Rincian implementasi: [RENCANA_IMPLEMENTASI_FASE_2.md](RENCANA_IMPLEMENTASI_FASE_2.md).
Bukti verifikasi: [FASE_2_VERIFICATION.md](FASE_2_VERIFICATION.md). **Status implementasi: selesai.**

**P1 · Sedang · Bergantung F0–F1**

- Tambahkan brand, kelengkapan profil pelanggan, pencarian/pembuatan pelanggan dari POS, dan hubungan pelanggan dengan transaksi.
- Aktifkan antarmuka nama pelanggan dan catatan item/pesanan yang saat ini belum tersambung lengkap ke alur kasir.
- Perluas impor produk menjadi create/update data produk; sediakan ekspor dengan ID stabil, preview, validasi referensi, dan pelaporan kesalahan per baris.
- Pertahankan impor atomik: SKU ambigu ditolak; baris yang tidak tercantum dalam CSV tidak berarti dihapus. Foto tetap dikelola melalui alur unggah gambar.
- Tambahkan impor/ekspor pelanggan. Duplikasi kontak ditandai; penggabungan pelanggan harus eksplisit dan tidak menghapus histori.

**Dampak:** master PostgreSQL/SQLite, feed, importer, katalog POS, snapshot pelanggan/brand dan laporan.

**Kriteria lulus:** ekspor–impor dapat dilakukan tanpa menggandakan entitas; pelanggan offline tersinkron dengan ID tetap; perubahan nama master tidak mengubah isi struk lama.

### F3 — Pengaturan bisnis, akses, dan mesin harga

Rincian implementasi: [RENCANA_IMPLEMENTASI_FASE_3.md](RENCANA_IMPLEMENTASI_FASE_3.md).
Bukti verifikasi: [FASE_3_VERIFICATION.md](FASE_3_VERIFICATION.md). **Status implementasi: selesai.**

**P1 · Besar · Bergantung F2**

Urutan pekerjaan di dalam fase: konfigurasi dan role → master penjualan/pembayaran → kalkulasi → antarmuka dan struk.

- Tambahkan pengaturan merchant/outlet terpusat, profil akun, penggantian password, timezone, profil struk, logo/footer dan preview.
- Tambahkan role kustom berbasis permission dengan akses POS/Backoffice, data kontak staf, dan penyegaran role/active pada sesi berjalan.
- Tambahkan master sales type serta harga dengan prioritas: override outlet+sales type → harga sales type bisnis → harga dasar. Varian dan modifier dihitung satu kali.
- Tambahkan profil pajak/layanan, include/exclude, pembulatan, diskon item/bill, diskon bernama dan custom amount berotorisasi.
- Tambahkan grup metode pembayaran per outlet. QRIS/EDC/e-wallet pada fase ini tetap pencatatan manual dengan label yang jelas.
- Tambahkan konfigurasi checkout, termasuk track server; pegawai pelayanan disimpan terpisah dari kasir penerima pembayaran dan pemberi otorisasi.

**Dampak:** permission Go/Dart, feed konfigurasi, model harga, kalkulasi, ingest, snapshot, struk, laporan dan invalidasi provider.

**Kriteria lulus:** dataset perhitungan yang sama menghasilkan nominal identik di Go dan Flutter; perubahan konfigurasi tidak mengubah bill/struk yang sudah dibekukan; role lama tidak mendapat akses tambahan tanpa penetapan.

### F4 — Saved bill dan siklus pesanan restoran

Rincian rencana implementasi: [RENCANA_IMPLEMENTASI_FASE_4.md](RENCANA_IMPLEMENTASI_FASE_4.md). **Status: perencanaan, belum diimplementasikan.**

**P1 · Besar · Bergantung F3**

- Implementasikan bill persisten, buka kembali, tambah item, catatan, pelanggan, pelayan, meja, dan pre-bill bertanda **BELUM LUNAS**.
- Pisahkan status bill, pembayaran dan dapur; tambahkan perintah kirim dapur beserta revisi baris yang sudah dikirim.
- Terapkan pengurangan stok saat pengiriman, termasuk penjualan langsung, tanpa pengurangan ulang saat pembayaran.
- Implementasikan kepemilikan bill, handoff online, pemulihan setelah restart, serta parkir bill saat pergantian shift.
- Tambahkan sesi penggunaan meja dengan waktu mulai/selesai. Pembayaran dan pelepasan meja merupakan tindakan berbeda agar meja belum langsung dianggap kosong saat tamu masih duduk.
- Perluas aktivitas menjadi bill terbuka, penjualan lunas dan pembatalan tanpa mencampur nilainya dalam pendapatan.

**Dampak:** model order, SQLite/PostgreSQL, outbox, ingest stok, koordinasi till, meja, histori dan laporan.

**Kriteria lulus:** bill tetap utuh setelah aplikasi dihentikan; simpan bill tidak menambah pendapatan; retry kirim dapur tidak menggandakan stok; perangkat kedua tidak bisa mengedit bill yang masih dimiliki perangkat pertama.

### F5 — Split, refund terperinci, dan pertanggungjawaban kas

**P1 · Besar · Bergantung F4**

- Implementasikan **split payment** untuk beberapa metode pada satu tagihan dan **split bill** berdasarkan item/kuantitas menjadi tagihan anak dengan hubungan ke bill asal.
- Alokasikan diskon, pajak, layanan dan pembulatan secara deterministik. Jumlah seluruh tagihan anak harus sama dengan tagihan asal.
- Bekukan komponen tagihan setelah pembayaran dimulai. Tambahan pesanan dibuat sebagai bill baru dalam sesi meja yang sama.
- Implementasikan void item sebelum pelunasan dan refund item/nominal setelah pelunasan; batasi refund sesuai saldo yang masih dapat dikembalikan.
- Pisahkan otorisasi refund uang dari keputusan restock/waste. Refund offline hanya dilakukan perangkat pemilik; perangkat lain memerlukan serah hak yang dikonfirmasi.
- Tambahkan cash in/out, cash drop, petty cash, alasan, actor, dan Z-report. Kas yang diharapkan menghitung pembayaran tunai bersih, refund tunai dan pergerakan kas.
- Lengkapi laporan void item, refund, pembayaran campuran dan shift.

**Dampak:** ledger pembayaran/kas, snapshot alokasi, refund, stok, otorisasi, laporan dan struk.

**Kriteria lulus:** pembayaran/refund berulang tidak berlipat; total split tepat sampai rupiah terakhir; refund makanan yang sudah dibuat tidak otomatis menambah stok bahan; shift tertutup tidak berubah akibat refund kemudian.

### F6 — Denah restoran dan perangkat kasir

**P1 · Sedang–besar · Bergantung F4–F5**

- Implementasikan editor area/denah, posisi dan bentuk meja, kapasitas, timer, pindah/gabung meja dan laporan omzet/durasi penggunaan.
- Pindah/gabung harus online dan memvalidasi kepemilikan semua bill terkait. Pembayaran atau histori tidak dihapus ketika meja digabung.
- Implementasikan adapter cetak LAN, konfigurasi printer kasir/dapur, routing kategori, tiket tambahan dan tiket pembatalan.
- Tambahkan antrean cetak persisten. Kegagalan printer tidak membatalkan pembayaran atau mengulangi efek stok.
- Jika hasil cetak tidak dapat dipastikan akibat koneksi putus, tampilkan status belum pasti dan sediakan cetak ulang bertanda salinan; jangan menjanjikan pencetakan fisik tepat satu kali.
- Tambahkan scanner HID dengan barcode produk/varian yang jelas, serta pembukaan cash drawer berotorisasi dan tercatat.

**Dampak:** UI denah, kontrak meja, konfigurasi perangkat, antrean lokal, format cetak dan audit.

**Kriteria lulus:** alur meja bekerja pada Windows/Android; printer mati lalu tersambung kembali tidak menggandakan transaksi; setidaknya satu model printer LAN nyata diuji sebelum dukungan perangkat dinyatakan lulus.

### F7 — Supplier, pembelian sederhana, dan kontrol stok

**P1 · Sedang · Bergantung F3–F5**

- Tambahkan supplier dan dokumen pembelian sederhana. Posting dokumen mencatat penerimaan stok satu kali; koreksi memakai pembalikan/penyesuaian berjejak.
- Tambahkan transfer sederhana banyak item, maksimal 50 baris per dokumen, dengan debit/kredit outlet atomik.
- Tambahkan batas minimum stok per barang/outlet dan status ketersediaan jual per outlet.
- Lengkapi laporan saldo awal, pembelian, pemakaian, transfer, koreksi dan saldo akhir beserta ekspor.
- Tambahkan nilai selisih opname berdasarkan biaya standar. Tampilkan sebagai informasi operasional persediaan, bukan klaim sudah memiliki general ledger.
- Siapkan identitas item inventori dan satuan dasar untuk perluasan bahan tanpa mengubah identitas produk atau menggandakan saldo.

**Dampak:** ledger stok, projection, master supplier, dokumen inventori, permission, feed dan laporan.

**Kriteria lulus:** posting/retry pembelian tidak menambah stok dua kali; transfer seimbang antar outlet; laporan pergerakan merekonsiliasi saldo akhir; transaksi lintas tenant ditolak.

### F8 — Ingredients, resep, dan produksi setengah jadi

**P1 · Besar · Bergantung F7**

Fase ini berprioritas tinggi untuk restoran, tetapi membutuhkan fondasi inventori F7.

- Tambahkan kategori bahan, raw ingredient, satuan g/ml/pcs, konversi satuan dalam dimensi yang sama, serta kuantitas fixed-point hingga tiga desimal.
- Tambahkan resep berversi untuk produk, varian dan modifier; tentukan apakah produk mengurangi stok barang jadi atau bahan resep.
- Snapshot komposisi dan biaya saat pesanan dikirim ke dapur. Pelunasan tidak mengonsumsi bahan kedua kali.
- Tambahkan bahan setengah jadi dan operasi Produce: konsumsi input, catat hasil aktual, tambah output, serta larang resep bersiklus.
- Gunakan HPP standar berversi. Harga pembelian disimpan sebagai informasi pembelian; perubahan biaya standar dipublikasikan secara eksplisit.
- Lengkapi laporan pemakaian bahan, produksi, waste, cakupan HPP dan estimasi laba.

**Dampak:** tipe kuantitas, ledger, recipe engine, operasi produksi, sinkronisasi offline, kalkulasi biaya dan laporan.

**Kriteria lulus:** contoh satu minuman mengurangi bahan dan kemasan yang tepat; modifier ikut mengurangi bahan; recipe lama tetap dipakai untuk operasi offline yang merekam versi lama; produk dan bahan tidak terpotong bersamaan secara tidak sengaja.

### F9 — Promo otomatis dan bundle

**P2 · Besar · Bergantung F3–F4 dan F8**

- Tambahkan rule promo berdasarkan produk, minimum pembelian, sales type, tanggal dan jam, termasuk free item.
- Untuk versi awal, gunakan maksimal satu promo otomatis per bill: pilih penghematan terbesar, lalu prioritas dan ID sebagai pemecah seri.
- Diskon manual bill menonaktifkan promo otomatis pada bill tersebut. Urutan diskon item lalu bill tetap konsisten; jangan menambahkan stacking tersembunyi.
- Evaluasi waktu menggunakan timezone outlet dan acuan waktu server yang dicache.
- Tambahkan bundle dengan komponen tetap, harga per sales type, serta versi isi paket. Isi bundle aktif harus dinonaktifkan sebelum diedit.
- Hitung stok/HPP dari komponen beserta resepnya, dan alokasikan nilai penjualan ke komponen untuk laporan dan refund tanpa hitung ganda.
- Tambahkan laporan efektivitas diskon, promo, modifier dan bundle.

**Dampak:** master promo/bundle, kalkulasi, stok bahan, snapshot, struk, refund dan laporan.

**Kriteria lulus:** promo tumpang tindih menghasilkan pilihan yang deterministik; free item tetap mempunyai efek stok/HPP; bundle tidak mengurangi stok parent sekaligus komponen; perubahan promo tidak mengubah struk lama.

### F10 — Approval pembelian dan transfer lanjutan

**P3 · Besar · Bergantung F7–F8**

- Tambahkan mode inventori simple/advanced per outlet dengan permission approval.
- Advanced PO mendukung pengajuan, persetujuan, penerimaan sebagian, penyelesaian dan pembatalan sisa yang belum diterima.
- Advanced transfer mendukung request, approval, shipment dan fulfillment.
- Saat shipment, stok sumber berpindah menjadi stok dalam perjalanan; stok tujuan bertambah saat diterima. Selisih/hilang dicatat melalui tindakan berotorisasi.
- Dokumen yang sudah diposting tidak diedit diam-diam; gunakan pembalikan atau koreksi dengan audit.
- Perubahan advanced → simple diblokir selama masih ada dokumen berjalan.
- Lengkapi laporan pembelian, outstanding, barang dalam perjalanan dan rekonsiliasi antar outlet.

**Dampak:** workflow, permission, ledger/projection, penguncian multi-outlet, dokumen dan laporan.

**Kriteria lulus:** approval/penerimaan bersamaan tidak menggandakan stok; penerimaan sebagian tidak melebihi pengiriman; pembatalan tidak menghapus pergerakan yang sudah terjadi.

### Fitur yang tetap coming soon

Coming soon harus terlihat sebagai kemampuan yang belum aktif. Jangan menampilkan tombol seolah layanan sudah bekerja.

| Fitur | Alasan ditunda | Syarat sebelum diaktifkan |
|---|---|---|
| Billing langganan SaaS, paket per outlet, kupon | Memerlukan siklus langganan, penagihan dan integrasi pembayaran | Model komersial disepakati, provider sandbox, webhook dan rekonsiliasi teruji. |
| Invoice pelanggan, DP dan piutang lintas hari | Menambah aturan piutang, jatuh tempo dan pengakuan pendapatan | Rancangan akuntansi transaksi dan rekonsiliasi ditetapkan setelah payment ledger stabil. |
| QRIS dinamis/e-wallet otomatis | Memerlukan provider, callback, kedaluwarsa dan status tidak pasti | Integrasi sandbox, verifikasi callback, idempotency, refund dan rekonsiliasi. |
| Rekening settlement | Bergantung layanan pembayaran | Proses perubahan rekening, verifikasi dan pencairan terdefinisi. |
| GoFood/GrabFood/ShopeeFood | Bergantung akses API dan hubungan mitra | API resmi tersedia; mapping menu, harga, OOS, order dan rekonsiliasi siap. |
| Website order, QR meja, pickup dan preorder | Membuka kanal publik serta memerlukan hosting | Core bill/dapur/stok stabil dan rancangan pemesanan publik selesai. |
| Struk email/SMS dan notifikasi eksternal | Memerlukan provider pengiriman | Provider, antrean, retry, preferensi penerima dan riwayat pengiriman siap. |
| Loyalty lengkap dengan OTP | Memerlukan saldo poin, reversal dan verifikasi redeem | Customer/payment ledger stabil dan provider OTP tersedia. |
| Feedback dari struk digital/layar pelanggan | Bergantung kanal pelanggan | Kanal digital atau perangkat pelanggan sudah ditentukan. |
| Bluetooth dan perangkat khusus | Memperluas variasi driver/platform | LAN stabil dan model perangkat sasaran tersedia untuk pengujian. |
| Jaminan stok global tanpa overselling | Tidak dapat dijamin oleh cache offline | Mode online dengan reservasi stok dan kebijakan kehilangan koneksi. |
| HPP aktual rata-rata/FIFO | Lebih kompleks daripada biaya standar | Aturan valuasi dan koreksi historis dirancang tersendiri. |

Ekspor yang sudah tersedia dan penjadwalan internal tetap dipertahankan. Yang ditunda adalah aktivasi layanan eksternal, bukan menghapus implementasi yang sudah ada.

## 5. Pengujian, gerbang fase, dan hasil akhir

### Skenario penerimaan wajib

| Skenario | Hasil yang harus dibuktikan |
|---|---|
| Upgrade database lama | UUID, nomor struk, saldo, snapshot, outbox dan dead-letter tetap dapat ditelusuri. |
| Respons server hilang lalu retry | Tepat satu efek bisnis untuk order, pembayaran, pengiriman dapur, refund dan pembelian. |
| Dua perangkat mengklaim register/bill | Hanya satu pemilik sah; perangkat kalah mendapat penjelasan, bukan melakukan overwrite. |
| Offline, restart, lalu tersambung | Bill dan antrean pulih; perubahan baru tidak terhapus oleh acknowledgement revisi lama. |
| Simpan → kirim dapur → tambah pesanan → bayar | Stok hanya berkurang untuk bagian yang dikirim; pendapatan muncul saat lunas; tidak terjadi pemotongan ganda. |
| Split dengan diskon/pajak/pembulatan | Jumlah seluruh bagian sama dengan total asal; tidak ada selisih rupiah atau pendapatan ganda. |
| Refund sebagian dan berulang | Batas refundable terjaga; uang, stok, HPP dan waste mengikuti tindakan sebenarnya. |
| Shift dengan campuran pembayaran | Kas tunai, kas masuk/keluar, refund dan Z-report cocok; shift lama tetap immutable. |
| Perubahan master ketika POS offline | Snapshot lama tetap valid; konfigurasi baru berlaku sesuai versi tanpa menghitung ulang histori. |
| Resep, modifier, bundle dan free item | Komponen yang benar dikonsumsi satu kali; biaya tidak dihitung ganda. |
| Pergantian hari/timezone dan banyak halaman histori | Periode konsisten; tidak ada transaksi hilang atau muncul dua kali. |
| Printer kehabisan kertas/koneksi putus | Transaksi tetap tersimpan; pekerjaan cetak terlihat; cetak ulang tidak mengulangi transaksi. |
| Manipulasi tenant/outlet/actor | Server menolak akses dan operasi di luar kewenangan. |
| Rekonsiliasi laporan | Detail, rollup, dashboard dan ekspor cocok dalam cakupan serta waktu pembaruan yang sama. |

### Metode pengujian

- Backend: pengujian domain, kontrak, migrasi, konkurensi dan isolasi pada PostgreSQL/Redis sesuai fondasi proyek; jalankan pemeriksaan build, vet, lint, race dan generated-code yang relevan.
- Flutter: pengujian model, repository, migrasi, sinkronisasi dan kalkulasi; pertahankan regresi yang sudah ada.
- UI: verifikasi langsung pada Windows, Android dan Backoffice browser dengan log/error serta bukti hasil. Ikuti kebijakan proyek untuk tidak otomatis membuat suite widget/E2E baru per fitur.
- Jalankan tooling Flutter dari `mobile/` dan Go dari `backend-go/`.
- Pengujian perangkat keras harus membedakan hasil simulasi dan hasil printer nyata. Jika perangkat belum tersedia, status penerimaan hardware tetap belum lulus.

### Gerbang penyelesaian setiap fase

Satu fase baru dinyatakan selesai setelah:

1. Migrasi baru dan upgrade data lama lulus pada salinan data lokal.
2. Kontrak API, sinkronisasi, permission dan penanganan kegagalan tersedia bersama fiturnya.
3. Skenario yang terdampak lulus pada Windows, Android dan Backoffice.
4. Rekonsiliasi uang/stok/laporan tidak memiliki selisih yang tidak dijelaskan.
5. OpenAPI, panduan uji lokal dan memory proyek diperbarui dengan bukti aktual.
6. Fitur baru diaktifkan hanya untuk konfigurasi/perangkat lokal yang kompatibel.

Urutan penerapan setiap fase: **backup terverifikasi → migrasi backend → aplikasi kasir kompatibel → rekonsiliasi antrean → aktivasi fitur → UAT lokal**. Pemulihan tidak dilakukan dengan menurunkan schema secara paksa atau menghapus antrean transaksi.

**Milestone F6:** operasional restoran dasar lengkap, termasuk saved bill, split, pertanggungjawaban kas, meja dan printer LAN.  
**Milestone F8:** pengendalian pembelian, bahan, resep, produksi dan biaya standar.  
**Milestone F10:** cakupan fitur internal lokal yang luas, termasuk promo, bundle dan inventori lanjutan.

Deployment dan aktivasi integrasi eksternal menjadi pekerjaan terpisah setelah milestone lokal yang dipilih benar-benar lulus.
