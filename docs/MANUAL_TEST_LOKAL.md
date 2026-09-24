# Uji lokal: membuktikan Backoffice ⇄ Platform ⇄ Till terhubung

Pengganti `MANUAL_TEST_FASE_1_7.md` yang dihapus. Bedanya: dokumen ini
dijalankan di mesin lokal terhadap stack yang benar-benar hidup, dan setiap
baris punya cara memeriksanya — bukan kolom "Belum diuji".

Yang dibuktikan dokumen ini adalah satu kalimat: **apa yang terjadi di
Backoffice sampai ke till, apa yang terjadi di till sampai ke Backoffice, dan
till bisa aktif memakai kode yang dicetak dari Backoffice.**

## Menyiapkan stack

Dari `backend-go/`:

```powershell
docker compose up -d --build api worker caddy
go run ./cmd/justclick migrate up
```

Bangun till sebagai aplikasi web. **URL API ikut di-compile ke bundel**, dan
URL itu juga yang menamai store lokal (`sha256(baseUrl)`), jadi ia harus sama
persis dengan alamat yang nanti dibuka:

```powershell
cd ..\mobile
fvm flutter build web --dart-define=API_BASE_URL=http://localhost:8090/api/v2
```

| Permukaan | Alamat |
|---|---|
| Backoffice (pemilik/kasir) | `https://localhost:8443/backoffice` |
| Panel platform (super admin) | `https://localhost:8443/platform` |
| Till (aplikasi web) | `http://localhost:8090` |

### Till Windows desktop

Sejak Fase 0 till berjalan sebagai aplikasi Windows dengan SQLite native,
bukan hanya sebagai aplikasi web. Ini jalur yang dipakai bagian F dan G.

```powershell
cd ..\mobile
fvm flutter run -d windows --dart-define=API_BASE_URL=http://localhost:8090/api/v2
```

**Prasyarat: Visual Studio dengan beban kerja "Desktop development with C++".**
Tanpa itu `flutter build windows` dan `flutter run -d windows` berhenti dengan
`Unable to find suitable Visual Studio toolchain`, dan seluruh bagian F tidak
dapat dijalankan di mesin tersebut. Periksa dengan `fvm flutter doctor -v`;
baris `[√] Visual Studio` harus hijau.

Database-nya adalah berkas sungguhan di
`%USERPROFILE%\Documents\connected_<scope>.db`, dengan `scope` =
`sha256(baseUrl/tenantId/deviceId/registerId)`. Nama itu penting untuk bagian G:
**dua instalasi yang teraktivasi sebagai perangkat berbeda memakai berkas
berbeda**, sehingga tidak ada satu pun berkas yang dibagi.

`nti_pos.db` (tanpa awalan `connected_`) adalah store demo dan tidak pernah
dipakai till yang terhubung.

### Till Android emulator

`localhost` di emulator adalah emulator itu sendiri, bukan Windows host. Jalankan
build debug berikut dari `mobile/` (bukan `flutter build web`), setelah stack di
atas hidup:

```powershell
fvm flutter run -d emulator-5554 --dart-define=API_BASE_URL=http://10.0.2.2:8090/api/v2
```

`10.0.2.2` adalah alias khusus Android Emulator ke loopback komputer host.
Portnya **8090**, karena Caddy meneruskan `/api/v2/*` pada port itu; port API
internal `9000` tidak dipublikasikan Docker. HTTP hanya diizinkan oleh
`android/app/src/debug/AndroidManifest.xml`, jadi tidak ikut build rilis.
Perangkat fisik sengaja tidak memakai jalur ini: gunakan hostname HTTPS yang
dapat dijangkau perangkat pada jaringan tersebut.

**Satu pintu per permukaan.** Panel juga bisa dijangkau lewat pintu lain
(misalnya proses `justclick serve` yang berjalan di host), dan membuka panel
yang sama dari dua alamat berbeda adalah cara memicu penolakan CSRF: cookie
browser mengabaikan nomor port, jadi token yang diterbitkan di balik HTTPS ikut
terkirim ke pintu HTTP dan skemanya tidak lagi cocok. Kalau sebuah formulir
ditolak, baca `docker compose logs api | grep CSRF` — baris itu menyebut
`origin`, `referer`, `host`, `x_forwarded_proto` dan skema yang disimpulkan
server.

Merchant uji yang sudah disiapkan (sengaja kosong — outlet, till, katalog dan
kasirnya dibuat sendiri lewat UI, karena itulah yang sedang diuji):

| | |
|---|---|
| Merchant | QA Lokal (`qa-lokal`) |
| Owner | `qa@lokal.test` |
| Kata sandi | `qa-lokal-2026x` |

Membuat yang baru:
`docker compose exec api /justclick tenant create --name ... --slug ... --owner-name ... --owner-email ... --password ...`

---

## A. Backoffice berdiri sendiri

| # | Langkah | Lulus bila |
|---|---|---|
| A1 | Buka `/backoffice`, masuk sebagai owner | Masuk ke dashboard, bukan 403 |
| A2 | Buat outlet | Muncul di daftar outlet |
| A3 | Buat till (register) di outlet itu | Muncul di bawah outletnya |
| A4 | Buat kategori, lalu produk berharga di kategori itu | Produk tampil dengan harganya |
| A5 | Buat kasir dengan PIN 4 digit | Muncul di daftar staf, peran kasir |
| A6 | Terbitkan kode aktivasi untuk till itu | Kode 12 karakter tampil **sekali**, dengan keterangan tidak disimpan |

Catatan A6: kode hidup **10 menit**, dan menerbitkan kode baru membatalkan yang
lama. Terbitkan tepat sebelum langkah B1.

## B. Till menyala dengan kode dari Backoffice

| # | Langkah | Lulus bila |
|---|---|---|
| B1 | Buka `http://localhost:8090`, masukkan kode dari A6 | Aktivasi berhasil, layar pindah dari layar aktivasi |
| B2 | Tunggu sinkron pertama | Katalog dari A4 muncul di till |
| B3 | Masuk sebagai kasir dengan PIN dari A5 | Masuk ke layar kasir |
| B4 | Buat satu penjualan, selesaikan pembayaran | Struk keluar, penjualan tercatat lokal |
| B5 | Tekan "Sync now" di Pengaturan | Antrean kosong, tidak ada kegagalan |

## C. Apa yang terjadi di till sampai ke Backoffice

| # | Langkah | Lulus bila |
|---|---|---|
| C1 | Backoffice - Laporan / Dashboard | Penjualan B4 muncul dengan nilainya |
| C2 | Backoffice - Perangkat | Till menunjukkan "terakhir terlihat" beberapa menit terakhir |
| C3 | Backoffice - Stok | Kuantitas produk berkurang sesuai yang terjual |

## D. Apa yang terjadi di Backoffice sampai ke till

| # | Langkah | Lulus bila |
|---|---|---|
| D1 | Ubah harga produk di Backoffice | Setelah poll (maksimal 60 detik) atau "Sync now", harga baru muncul di till |
| D2 | Setel produk jadi habis | Produk tidak lagi bisa dijual di till |
| D3 | Tambah produk baru | Muncul di till tanpa perlu aktivasi ulang |

## E. Panel platform mengendalikan keduanya

| # | Langkah | Lulus bila |
|---|---|---|
| E1 | `docker compose exec api /justclick platform admin create --name ... --email ...` | Kata sandi tercetak **sekali** |
| E2 | Masuk ke `/platform` dengan kata sandi itu | Diminta enrol TOTP - **bukan** "Forbidden" |
| E3 | Selesaikan enrolment TOTP, simpan kode pemulihan | Masuk ke daftar merchant |
| E4 | Suspend merchant QA (ketik slug untuk konfirmasi) | Till menjawab 401 dan kembali ke layar aktivasi; antrean penjualan **tetap utuh** |
| E5 | Reaktivasi merchant | Till hidup lagi dengan token yang sama, tanpa aktivasi ulang |

## F. Fase 0 — takeover terkendali dan transaksi terlambat

Bagian ini membuktikan satu kalimat: **laci yang perangkatnya hilang bisa
ditutup manusia tanpa membuang bukti, dan transaksi yang telat sampai hanya
masuk setelah seorang manager memutuskannya.**

Butuh dua till: satu Windows (F.Setup) dan satu Android emulator, keduanya
teraktivasi pada **register yang sama**. Buat juga satu staf berperan
**manager** dengan kata sandi Backoffice — takeover memerlukan izin
`manageOutlets`, yang dimiliki manager dan owner, bukan kasir.

| # | Langkah | Lulus bila |
|---|---|---|
| F1 | Till Windows: aktivasi, masuk sebagai kasir, buka laci dengan modal awal | Laci terbuka; Backoffice → Perangkat, kolom "Sesi aktif" menyebut nama kasir, label perangkat, dan waktu buka |
| F2 | Jual satu transaksi tunai, tekan "Sync now" | Antrean kosong; Backoffice → Laporan memuat penjualan itu |
| F3 | **Matikan jaringan till** (cabut Wi-Fi / matikan Caddy), lalu jual satu transaksi lagi | Struk tetap keluar; kartu status sinkron menunjukkan "Menunggu diunggah" = 1 |
| F4 | Backoffice sebagai manager → Perangkat → buka `Takeover` pada register itu, ketik nama till **yang salah**, kirim | Ditolak dengan "Takeover ditolak…"; laci **masih terbuka** |
| F5 | Ulangi dengan nama till yang benar, isi alasan, dan kas terhitung | Kembali ke halaman Perangkat; "Sesi aktif" jadi "Tidak ada"; kartu Recovery Center memuat kasus baru dengan alasan, snapshot jumlah order dan ekspektasi kas |
| F6 | Backoffice → Perangkat, lihat baris perangkat lama | Perangkat tercabut (revoked) |
| F6a | Till lama: tutup aplikasi sepenuhnya, buka lagi | Layar aktivasi meminta kode — **bukan** pemilihan user/PIN. Binding yang dicabut harus ikut terhapus, bukan hanya disembunyikan sampai sinkron berikutnya gagal |
| F6b | Till lama: muat ulang **berulang kali dengan cepat**, jangan tunggu | Tetap layar aktivasi setiap kali. Kredensial dikonfirmasi sekali per peluncuran, **di luar** startup spread; kalau pemeriksaan itu ikut menunggu spread, memuat ulang lebih cepat dari spread membuat perangkat tercabut tetap bisa dipakai tanpa batas |
| F7 | Terbitkan kode aktivasi baru, aktivasi till Android sebagai perangkat pengganti, buka laci dengan kasir yang sama | Laci baru terbuka; kas laci baru tidak terpengaruh takeover |
| F8 | **Hidupkan kembali jaringan till Windows**, tekan "Sync now" | Till menjawab 401 dan kembali ke layar aktivasi; **antrean penjualan F3 tetap utuh** |
| F9 | Terbitkan kode aktivasi lagi, aktivasi ulang till Windows **pada instalasi yang sama** (jangan hapus data aplikasi), masuk sebagai kasir | Aktivasi berhasil ke baris perangkat yang sama; till tidak mengklaim laci mana pun |
| F10 | Tekan "Sync now" | Penjualan F3 **ditolak** dengan kode `recovery_required`; kartu status sinkron menunjukkan baris ditolak |
| F11 | Till → Pengaturan → tekan kartu status sinkron | Recovery Center POS terbuka: penjualan itu ada di "Menunggu tindakan manager", dengan id recovery-nya, dan **tanpa tombol coba ulang** |
| F12 | Tekan "Sync now" dua kali lagi | Tetap satu baris ditolak; Backoffice → Recovery Center tetap **satu** item, bukan tiga |
| F13 | Backoffice → Recovery Center: coba "Tutup recovery" sekarang | Ditolak dengan "Keputusan ditolak…" — kasus tidak bisa ditutup selama masih ada item pending |
| F14 | Tolak item itu dengan alasan kosong | Ditolak |
| F15 | Tekan "Terima" pada item itu | Item jadi `accepted`; Backoffice → Laporan memuat penjualan F3; Backoffice → Stok berkurang **satu kali** |
| F16 | Till Windows: tekan "Sync now" | Antrean dan daftar ditolak kosong; laporan dan stok **tidak berubah lagi** — tidak ada order atau efek stok kedua |
| F17 | Backoffice → Recovery Center → "Tutup recovery", pilih basis dan isi catatan | Kasus jadi `reconciled` dengan basis yang dipilih |
| F18 | Backoffice → Perangkat → kartu "Diagnostik sinkronisasi" | Tidak lagi memuat `open_recovery` untuk kasus itu |
| F19 | Till lama: aktivasi ulang, masuk, buka pemilih till, **ketuk tile yang bertanda "Tidak bisa dilanjutkan"** | Till menanyakan status ke server; karena lacinya sudah ditutup paksa, shift lokal ikut tertutup dan register kembali bebas untuk membuka laci baru. Tidak perlu sign-out dahulu |

Regresi yang wajib diperiksa pada F19: ketuk tile terlantar **sebelum** takeover
agar POS mencatat state `conflict`, lalu lakukan takeover dan ketuk tile yang
sama sekali lagi. Pemeriksaan kedua harus tetap mengirim session ID lokal,
menemukan recovery yang baru dibuat, menutup shift lokal, dan membebaskan
register. Kasir lain juga boleh memicu pemeriksaan state konflik karena tindakan
ini hanya mencerminkan keputusan server dan tidak memberinya izin berjualan pada
laci tersebut.

Kalau langkah F15 diganti "Tolak" dengan alasan, hasil yang harus terlihat
adalah kebalikannya: penjualan itu **tidak pernah** menjadi order, stok tidak
bergerak, tetapi baris buktinya tetap ada di Recovery Center dengan alasan
penolakannya. Payload aslinya tidak pernah dihapus.

Diagnostik yang sama dapat dibaca dari command line, tanpa mengubah apa pun:

```powershell
cd ..\backend-go
go run ./cmd/justclick diagnostics till --tenant <TENANT_UUID>
```

### Laci yang tidak bisa dilanjutkan maupun ditutup dari till

Keadaan ini nyata dan ditemukan saat uji manual: sebuah sesi terbuka di server
**tanpa baris `till_claims`**. Diagnostik menyebutnya
`open_session_without_claim`. Penyebab paling umum adalah sesi yang sampai ke
server lewat jalur push legacy, jadi register-nya bahkan belum
`coordinated_sessions`.

Yang terlihat di till: kasir yang membuka laci itu melihat tilenya bertanda
**"Tidak bisa dilanjutkan — perlu manager"**. **Mengetuk tile itu menanyakan
statusnya ke server** dan mencerminkan jawabannya — kalau laci sudah ditutup
paksa lewat takeover, laci lokal ikut tertutup dan register bebas kembali.
Till memang **tidak boleh** menutup laci itu sendiri kalau server tidak
mengatakannya; keputusannya milik manager.

Ini juga berlaku untuk laci yang dibuat build lama (sebelum till terkoordinasi
ada): laci seperti itu tidak punya baris izin lokal sama sekali, dan sebelum
diperbaiki tidak bisa dilanjutkan **maupun** ditutup — aktivasi ulang perangkat
pun tidak menolong.

Jalan keluarnya satu: **Backoffice → Perangkat → Takeover** pada register itu.
Server mengizinkan takeover atas sesi tanpa klaim justru karena inilah kasus
yang tidak punya jalan keluar lain. Mencabut (revoke) perangkat **tidak**
menutup sesinya — revoke hanya mematikan token, laci tetap terbuka.

Memeriksa keadaan ini langsung di database:

```powershell
psql $env:MIGRATE_DATABASE_URL -x -c "SELECT p.id, r.name AS register, p.employee_name, p.close_kind, (SELECT count(*) FROM till_claims c WHERE c.session_id=p.id) AS claims FROM pos_sessions p JOIN pos_registers r ON r.id=p.pos_register_id WHERE p.closed_at_ms IS NULL"
```

`claims = 0` pada sesi terbuka berarti gunakan takeover, bukan revoke.

## G. Fase 0 — dua instalasi tanpa berbagi database

| # | Langkah | Lulus bila |
|---|---|---|
| G1 | Setelah F7, cek `%USERPROFILE%\Documents` di host | Ada berkas `connected_<scope>.db` untuk till Windows; nama scope-nya **berbeda** dari scope till Android (Android menyimpan di sandbox aplikasinya sendiri) |
| G2 | Tutup till Windows sepenuhnya, buka lagi | Kasir, laci, katalog, antrean dan daftar ditolak masih ada — tidak ada layar aktivasi, tidak ada database kosong |
| G3 | Jual di till Android, sinkronkan, lalu sinkronkan till Windows | Riwayat till Android terlihat di till Windows sebagai riwayat **baca saja**, bukan sebagai order lokal yang bisa diubah |
| G4 | Backoffice → Perangkat | Kedua perangkat terdaftar pada register yang sama; hanya satu yang memegang laci |

G2 adalah kriteria F0.2. Kalau till kembali ke layar aktivasi setelah
dijalankan ulang, `configureDatabaseFactory()` tidak memasang factory FFI dan
database ditulis ke tempat yang salah — bukan masalah data, tetapi masalah
platform.

## H. Fase 1 — histori, laporan, cache offline, dan ekspor

Siapkan dua register pada outlet A dan satu register pada outlet B. Gunakan
dua instalasi till yang berbeda untuk outlet A. Buat akun cashier, manager, dan
owner agar pembatasan data diuji dari server, bukan hanya dari tampilan.

| # | Langkah | Lulus bila |
|---|---|---|
| H1 | Till A1 dan A2: buka laci masing-masing, buat penjualan dengan diskon, PB1, service charge, metode bayar, produk, dan kasir berbeda; sinkronkan | Backoffice → Transaksi memuat setiap UUID/nomor struk tepat satu kali |
| H2 | Till B1: buat dan sinkronkan satu penjualan pembanding | Laporan outlet A tidak memuat transaksi B; cakupan semua outlet memuat keduanya |
| H3 | Backoffice → Transaksi: filter outlet, tanggal, kasir, register, nomor struk, dan status | Setiap filter mempersempit hasil dengan benar; membersihkan filter mengembalikan daftar lengkap |
| H4 | Buka detail salah satu transaksi | Item, modifier, pembayaran, kasir, register, sesi, dan nama snapshot cocok dengan struk asli |
| H5 | Backoffice → Shift: cari kedua sesi outlet A lalu buka detailnya | Modal, expected/count cash, jenis penutupan, dan seluruh transaksi sesi tampil; sesi tidak dipotong hanya karena melewati tengah malam |
| H6 | POS sebagai cashier: buka Histori | Hanya transaksi cashier pada register dan hari bisnis berjalan yang dapat dibaca |
| H7 | POS sebagai manager: pilih 7 hari, outlet, status, dan cari awalan nomor struk; lanjutkan lebih dari satu halaman bila tersedia | Scope outlet bekerja, urutan stabil, dan tidak ada UUID yang hilang atau muncul dua kali |
| H8 | Ubah filter ketika halaman berikutnya masih dimuat | Respons lama tidak menimpa hasil filter baru dan pagination kembali ke halaman pertama |
| H9 | POS sebagai manager: buka Laporan untuk hari ini, kemarin, 7 hari, bulan berjalan, dan rentang khusus | Waterfall, grafik hari/jam, outlet, kategori, top item, dan pembanding periode muncul tanpa HPP/laba |
| H10 | Periksa response/cache manager melalui DevTools atau log jaringan | Tidak ada `cost_of_goods`, `gross_profit`, atau margin pada payload summary |
| H11 | POS sebagai owner: buka laporan yang sama | HPP, laba, margin, dan cakupan HPP tersedia; angka penjualan lainnya sama dengan manager |
| H12 | Cocokkan Backoffice dan POS pada periode serta outlet yang sama | Penjualan kotor − diskon − retur = penjualan bersih; penerimaan = penjualan bersih + pajak + layanan |
| H13 | Saat online, buka laporan dan histori sampai selesai; putus jaringan lalu buka filter yang sama | POS menampilkan data cache beserta waktu pembaruan, bukan total lokal yang diberi label outlet |
| H14 | Masih offline, buat satu penjualan lokal lalu buka laporan | Jumlah antrean lokal ditampilkan terpisah dan tidak ditambahkan ke agregat server |
| H15 | Saat offline, pilih periode yang belum pernah diunduh | Tampil “data belum tersedia offline”, bukan keadaan kosong yang seolah pasti tidak ada transaksi |
| H16 | Sambungkan kembali, sinkronkan, lalu refresh | Transaksi terlambat muncul satu kali dan agregat server berubah setelah dirty slice selesai dihitung |
| H17 | Refund satu transaksi, lalu ulangi pembandingan | Retur mengurangi penjualan bersih satu kali; nilai uang refund tampil terpisah; pajak/layanan tidak menaikkan laba |
| H18 | Backoffice: ekspor CSV, XLSX, dan PDF; POS: ekspor CSV | File menyebut outlet/periode/timezone/waktu/versi kalkulasi; waterfall sama dengan layar dan XLSX menyimpan nominal sebagai angka |

Gunakan alur recovery pada bagian F untuk transaksi terlambat. Setelah item
diterima, ulangi H12 pada tanggal bisnis transaksi asli; setelah item ditolak,
pastikan laporan dan stok tidak berubah.

Catat untuk setiap bukti: outlet/register, device UUID, session UUID, order
UUID, periode, scope akun, status outbox/dead-letter, waktu cache, recovery ID
bila ada, total order server, movement stok, dan nama file ekspor.

## I. Fase 2 — katalog, brand, dan pelanggan

| # | Langkah | Lulus bila |
|---|---|---|
| I1 | Backoffice: buat brand, pasang pada produk, lalu sinkronkan dua till | Kedua till menerima satu brand dan produk membawa UUID brand yang sama |
| I2 | Ekspor produk, unggah kembali tanpa perubahan | Preview dan commit tidak membuat produk baru serta tidak menaikkan feed untuk baris yang sama |
| I3 | Unggah CSV multi-kolom berisi satu perubahan dan satu produk baru | Preview menyebut jumlah tepat; commit atomik dan referensi kategori/brand yang salah menolak seluruh berkas |
| I4 | Unggah format lama `sku;harga` | Harga langsung berubah dengan perilaku dan pesan lama |
| I5 | Till A offline: buat pelanggan, tutup/buka aplikasi, pilih pelanggan pada cart, dan jual | UUID pelanggan tetap sama pada tabel pelanggan, outbox pelanggan, dan order |
| I6 | Sambungkan A, sinkronkan dua kali untuk mensimulasikan retry, lalu sinkronkan B | Server dan B hanya memiliki satu pelanggan; tidak ada dead-letter |
| I7 | Backoffice: ubah nama pelanggan dan brand setelah transaksi | Struk serta detail transaksi lama tetap memakai snapshot nama saat transaksi |
| I8 | Backoffice: buat kontak duplikat lalu gabungkan loser ke winner | Badge duplikat muncul, loser hilang dari pilihan till, riwayat winner memuat order kedua identitas, dan order lokal tidak terhapus |
| I9 | Ekspor pelanggan lalu impor file yang sama | ID stabil, nol pelanggan baru, dan teks yang berawalan `=`, `+`, `-`, atau `@` aman saat dibuka di spreadsheet |
| I10 | Buka laporan pada periode sesudah dan sebelum F2 | Jumlah penjualan per brand merekonsiliasi penjualan bersih; data lama masuk “Tanpa brand” |

Catat UUID brand, produk, pelanggan, order, nilai `sync_seq`, isi outbox/dead-letter,
dan total penjualan bersih per brand sebagai bukti Fase 2.

## J. Fase 3 — pengaturan bisnis, peran, dan mesin harga

Persiapan: dua till (A dan B) aktif di outlet yang sama dengan build Fase 3,
ditambah satu instalasi build **lama** (sebelum Fase 3) bila tersedia untuk J3
dan J6. Semua nominal di bawah adalah rupiah bulat.

| # | Langkah | Lulus bila |
|---|---|---|
| J1 | Sebelum owner menyimpan apa pun di Backoffice › Pengaturan, buka Pengaturan di till A | Bagian Bisnis masih bisa diubah dan bertanda "hanya perangkat ini"; keranjang memakai PB1/layanan dari preferensi till |
| J2 | Backoffice › Pengaturan › Bisnis: PB1 10% **termasuk harga**, layanan 5%, pembulatan 100 terdekat; simpan, lalu sinkronkan A | Bagian Bisnis di till menjadi read-only dengan nilai server. Outlet masih `legacy`: tidak ada pembulatan, tidak ada tombol nominal bebas |
| J3 | Pengaturan outlet › aktifkan harga v2 selagi till build lama masih aktif di outlet itu | Ditolak dengan jumlah perangkat yang belum siap; halaman Perangkat menandai till itu "perlu update". Setelah till lama dicabut: diizinkan |
| J4 | Di A, keranjang Kopi Susu 2× (diskon item 10%) + Nasi Goreng, diskon bill Rp 1.000, bayar tunai | Ringkasan keranjang, layar checkout, struk, dan detail transaksi Backoffice menunjukkan subtotal, diskon, layanan, PB1 yang ditambahkan, pembulatan, dan "PB1 termasuk harga" yang sama persis; `go run ./scripts/verify-pricing` menghitung angka yang sama untuk keranjang yang sama |
| J5 | Bayar tunai kurang dari total; bayar dengan metode yang mewajibkan referensi tanpa mengisinya | Keduanya ditolak dengan pesan; tidak ada order yang tercatat |
| J6 | Backoffice › Staf › Peran: buat peran "Gudang" (stok + ringkasan harian, akses POS); tugaskan ke kasir yang sedang login di A | Ditolak selama ada till build lama; setelah dicabut: diterima. Setelah sinkron, sesi kasir di A pindah ke Dashboard tanpa keluar, laci tetap terbuka untuk pemiliknya, outbox utuh |
| J7 | Nonaktifkan pegawai yang sedang login di B, sinkronkan, lalu tutup dan buka B | B keluar ke layar PIN — **tidak pernah** masuk sebagai owner |
| J8 | Owner: Pengaturan › zona waktu Asia/Jayapura, sinkronkan, jual di A | `business_date` dan jam di laporan mengikuti WIT; slice hari sebelumnya tidak berubah setelah recompute |
| J9 | Sales type kustom "GoFood" dengan harga outlet Kopi Susu Rp 23.000 | Chip GoFood muncul di keranjang, harga baris Rp 23.000 + delta varian, dan laporan menampilkan "GoFood" per jenis penjualan |
| J10 | Nominal bebas "Ongkos titip" Rp 7.300 oleh kasir tanpa izin `enterCustomAmount` | Meminta PIN owner; baris terjual tanpa efek stok dan tanpa `product_id` di server |
| J11 | Diskon manual oleh manajer | Struk mencetak nama diskon atau "Diskon", bukan nama manajer; laporan adjustment tetap mengatribusikannya |
| J12 | Cetak ulang struk J4 setelah owner mengubah footer dan menyembunyikan alamat | Cetak ulang sama dengan struk asli (snapshot), bukan pengaturan baru |
| J13 | Matikan jaringan B, owner ubah PB1, B tetap berjualan, lalu sambungkan lagi | Order B membawa snapshot lama, diterima, dan **tidak** ditandai `pricing_mismatch` |

Catat UUID order, isi `orders.pricing`, `tax_included`, `rounding_amount`,
`pricing_mismatch`, `devices.capabilities`, dan angka waterfall laporan sebagai
bukti Fase 3.

---

## Yang sudah dibuktikan otomatis (tidak perlu diulang manual)

Dijalankan terhadap stack yang sama; hasil terbaru ada di
`backend-go/docs/PHASE_9_5_VERIFICATION.md` dan, untuk Fase 0 paritas, di
[FASE_0_VERIFICATION.md](FASE_0_VERIFICATION.md).

| Bukti | Skrip |
|---|---|
| Kode yang dicetak **di browser** mengaktifkan till lewat `POST /api/v2/devices/activate` | `verify-backoffice` |
| Baris yang dibuat di browser ditarik oleh till yang diaktifkan dari browser yang sama | `verify-backoffice-crud` |
| Siklus hidup perangkat penuh: aktivasi, tarik semua feed, buka laci, 3 struk, gerakan stok, sinkron ulang | `loadtest smoke` |
| Push uang idempoten, tidak ada yang hilang, tidak ada lock baris tenant | `verify-push` |
| Suspend menghentikan till seketika, reaktivasi memulihkan token yang sama | `verify-platform` |
| Koordinasi laci: satu pemenang, handover, close menunggu seluruh struk, dan jalur recovery domain | `verify-till` |
| Seluruh jalur manager di browser: takeover terkonfirmasi, karantina sekali, terima/tolak, tutup kasus, jejak audit | `verify-recovery` |
| Header kapabilitas tercatat, gate harga v2 menolak lalu mengizinkan, struk v2 diterima/ditandai/ditolak, waterfall dengan pajak termasuk dan pembulatan menutup | `verify-pricing` |
| Peran kustom ditolak selama ada till tanpa `roles-v1`, pengaturan bisnis sampai ke till, zona waktu, ganti kata sandi akun | `verify-backoffice-crud` |

Bagian F dan G di atas **tidak** digantikan oleh `verify-recovery`: skrip itu
membuktikan server dan Backoffice, sedangkan F3, F8–F12, G1 dan G2 adalah
perilaku till Windows/Android yang hanya terlihat pada perangkat sungguhan.

## Kalau ada yang gagal

1. `docker compose logs api --since 5m` - penolakan CSRF, kegagalan ingest dan
   error render semuanya muncul di sini dengan konteksnya.
2. Till: buka Pengaturan, lihat kartu status sinkron. "Menunggu diunggah" yang
   naik berarti antrean belum terkirim; **tidak ada satu pun hasil transport
   yang menghapus penjualan**, jadi datanya masih ada.
3. Aktivasi ditolak: kode kedaluwarsa (10 menit), sudah dipakai, atau till
   sudah terikat register lain. Terbitkan ulang dari Backoffice.
