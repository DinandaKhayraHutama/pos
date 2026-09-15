# Panduan tes manual Fase 1–7

Panduan untuk Windows/PowerShell, berdasarkan commit `514f191`. Tujuannya memeriksa hasil yang terlihat oleh pengguna. Checklist di bawah adalah hasil yang **diharapkan**, bukan pernyataan bahwa pengujiannya sudah lulus.

Fase 1–4 mengalirkan data dari server ke perangkat (katalog, staf). Fase 5–7 membalik arahnya: sesi kas dan penjualan didorong naik, lalu dilaporkan lintas outlet. Bagian 9–11 menguji arah baru itu.

## 0. Kondisi awal dan batas pengujian

Pemeriksaan saat panduan dibuat:

- PHP 8.4, Composer, FVM, dan PostgreSQL 18 tersedia; layanan PostgreSQL berjalan.
- `backend/.env` dan `backend/vendor/` sudah ada. Database yang dikonfigurasi: `justclick_pos` di `127.0.0.1:5432`.
- `php artisan migrate:status` menunjukkan seluruh migration, termasuk katalog dan staf, sudah `Ran`.
- Flutter melalui FVM: **3.38.9 / Dart 3.10.8**. Emulator Android yang terdeteksi: **`emulator-5554`**.
- Belum ada aplikasi yang dijalankan atau tes fungsional yang dilakukan untuk penyusunan panduan ini.

Gunakan data bertanda `UAT` agar mudah dibedakan dari data sebelumnya. Jangan menjalankan `migrate:fresh`, menghapus data aplikasi, atau memilih **Reset demo data** untuk mengikuti panduan ini. `lib.zip` dan PDF blueprint tidak diperlukan untuk menjalankan aplikasi.

**Kendala yang sudah terlihat dari kode:**

| ID | Kondisi saat ini | Dampak pada tes |
|---|---|---|
| B1 | **Diperbaiki:** aktivasi dan sync memakai API root yang sama, tanpa `/api/v1` ganda. Cache tampilan diperbarui setelah resume; update kategori/produk mempertahankan relasi lokal. | Rebuild aplikasi dengan perintah bagian 4. Tidak perlu aktivasi ulang atau reset data. |
| B2 | Build flag yang dibaca kode adalah `API_BASE_URL`; dokumentasi lama menyebut `BACKEND_API_URL`. | Gunakan perintah dalam panduan ini. Flag lama dapat membuat aplikasi masuk mode demo. |
| B3 | Form staf menerima PIN 4–6 digit, tetapi layar login mobile memverifikasi setelah 4 digit. | Gunakan PIN **4 digit** untuk alur utama. Dukungan 5–6 digit masih merupakan temuan terbuka. |
| B4 | **Diperbaiki:** adopsi dihentikan. Store connected tidak lagi menyalin apa pun dari demo, dan migrasi v24 mengosongkan store yang sudah terlanjur berisi salinan. | Saat pertama membuka aplikasi setelah update, store connected dikosongkan lalu diisi ulang dari server. Daftar akun harus tepat satu baris per orang. **Transaksi uji lama di device connected ikut hilang** — lihat bagian 0.1. |
| B5 | Nomor struk kini per register (`K1-0001`), bukan `ORD-xxxx` global. Order lama tetap memakai nomor lamanya. | Nomor tidak lagi berurutan lintas till. Dua outlet berbeda boleh sama-sama mencetak `K1-0001`; yang membedakan adalah outlet/register pada barisnya. |
| B6 | Belum ada tombol "Sync sekarang" maupun indikator antrean di aplikasi. | Sync hanya berjalan saat aktivasi dan saat aplikasi kembali dari background. Untuk memicu manual: tekan Home lalu buka lagi. Tidak ada cara melihat berapa penjualan yang belum terkirim selain memeriksa backoffice. |

### 0.1 Yang berubah pada perangkat yang sudah aktif

Update ini menjalankan migrasi v24. Pada **store connected** (aplikasi yang dijalankan dengan `API_BASE_URL`):

- Seluruh tabel bisnis dikosongkan, lalu katalog dan staf ditarik ulang dari server.
- **Transaksi, sesi kas, dan meja hasil uji sebelumnya hilang.** Sampai update ini order memang belum bisa dikirim ke mana pun, jadi yang hilang hanyalah data uji lokal — tetapi lebih baik Anda tahu sebelum menjalankannya.

Pada **store demo** (dijalankan tanpa `API_BASE_URL`): tidak ada yang tersentuh. 26 produk, 4 staf, dan sebulan penjualan demo tetap utuh, termasuk **Reset demo data**.

Urutan praktis: **backend → login dan hak akses → siapkan outlet/register/katalog/staf → mobile → sync/offline → jual → periksa sesi & penjualan di backoffice → laporan → revoke → catat hasil**. Tes API pada bagian 8 tersedia untuk diagnosis tambahan.

## 1. Menjalankan backend

### Terminal A — backend

Buka terminal PowerShell di IDE:

```powershell
Set-Location 'D:\MobileDevelopment\Projects\nti_pos\backend'
php --version
php artisan migrate:status
```

Karena dependency, `.env`, dan database sudah tersedia, tidak perlu membuat project atau database baru. Jika ada migration `Pending`, jalankan:

```powershell
php artisan migrate
```

Siapkan akun demo lokal, kemudian jalankan server:

```powershell
php artisan db:seed
php artisan serve --host=127.0.0.1 --port=8000
```

Seeder melewati merchant `restoran-nti` jika sudah ada; **tidak mereset password akun yang sudah diubah**. Biarkan terminal server tetap terbuka. Untuk menghentikannya nanti, tekan `Ctrl+C`.

Jika dependency ternyata belum tersedia pada checkout lain, jalankan `composer install` terlebih dahulu. Jangan menimpa `.env` yang sudah ada. Pada instalasi baru saja, salin `.env.example`, isi koneksi PostgreSQL, buat database tujuan melalui pgAdmin, dan jalankan `php artisan key:generate` hanya jika `APP_KEY` belum diisi. Konfigurasi database Laravel dijelaskan dalam [dokumentasi instalasi Laravel 12](https://laravel.com/docs/12.x/installation); fungsi application key dijelaskan dalam [dokumentasi enkripsi Laravel](https://laravel.com/docs/12.x/encryption).

### Browser — pemeriksaan Fase 1

1. Buka `http://127.0.0.1:8000/api/v1/health`.
   - **Lulus:** muncul JSON dengan `status: "ok"`.
   - Ini pemeriksaan hidupnya API, bukan pemeriksaan koneksi database.
2. Buka `http://127.0.0.1:8000/backoffice`.
   - **Lulus:** muncul halaman login JustClick POS.
   - URL `/` masih halaman welcome Laravel. Itu normal; backoffice berada di `/backoffice`.
3. Login sebagai Owner:

   | Akun | Email | Password demo | PIN mobile |
   |---|---|---|---|
   | Farhan Sabili — Owner | `farhan@nti.test` | `password` | `9999` |
   | Siwi Wiyono Raharjo — Manager | `siwi@nti.test` | `password` | `1234` |
   | Siti Rahayu — Cashier | Tidak ada pada seed | Tidak ada | `2345` |
   | Dani Rycki Dinata — Cashier | Tidak ada pada seed | Tidak ada | `3456` |

4. Pastikan dashboard menampilkan merchant **Restoran NTI**, dan menu **Outlets**, **Pos Registers**, **Devices**, **Categories**, **Products**, serta **Staff** tersedia untuk Owner.
5. Logout, coba password salah: login harus ditolak. Login sebagai Manager: outlet/register/device boleh dikelola; kategori, produk, dan staf harus dibatasi.
6. Saat menjadi Manager, coba URL berikut secara langsung. Harus ditolak, misalnya dengan 403; menyembunyikan menu saja tidak cukup:
   - `http://127.0.0.1:8000/backoffice/products`
   - `http://127.0.0.1:8000/backoffice/categories`
   - `http://127.0.0.1:8000/backoffice/employees`
7. Login kembali sebagai Owner untuk langkah berikutnya.

Catatan perbaikan login: pesan `These credentials do not match our records.`
untuk kedua akun demo pernah disebabkan provider autentikasi ikut terkena filter
tenant sebelum identitas pengguna diketahui. Perbaikannya ada pada
`backend/app/Auth/EmployeeUserProvider.php`; password demo tidak direset.
Sesudah mengambil perubahan ini, refresh halaman login. Jika server masih
memakai konfigurasi lama, hentikan server, jalankan `php artisan config:clear`
dari `backend/`, lalu jalankan server kembali.

**Catat F1-01:** health, login Owner/Manager, password salah, dan pembatasan URL langsung.

## 2. Menyiapkan outlet dan register — Fase 2

Di backoffice sebagai Owner:

1. **Outlets → tombol Create/New**. Isi nama `UAT Outlet A`, alamat bebas, dan **Active** menyala. Simpan.
2. **Pos Registers → tombol Create/New**. Pilih `UAT Outlet A`, nama `UAT Kasir Android`, **Active** menyala. Matikan **Table service** untuk percobaan pertama agar penjualan tidak membutuhkan meja.
3. Buat satu register tambahan bernama `UAT API` pada outlet yang sama. Register ini khusus percobaan API PowerShell di bagian 8.
4. Pastikan pilihan outlet dan nama register tersimpan setelah halaman direfresh.
5. Jangan membuat activation code dulu; masa berlakunya **10 menit**. Buat ketika aplikasi siap menerima kode.

Seed backend membuat merchant dan staf; jangan mengharapkan produk, outlet, atau register demo Flutter otomatis tersedia di backoffice.

**Catat F2-01:** outlet/register berhasil dibuat dan relasinya benar.

## 3. Menyiapkan katalog dan staf di backoffice — Fase 3–4

Lakukan sebelum aktivasi agar tarikan pertama mempunyai data yang mudah dikenali.

### Katalog

1. **Categories → Create/New**: nama `UAT Minuman`, icon key `restaurant`, sort order `0`.
2. **Products → Create/New**:

   | Field | Nilai |
   |---|---|
   | Name | `UAT Es Teh` |
   | Category | `UAT Minuman` |
   | Price | `5000` |
   | Cost | `2000` |
   | SKU | `UAT-TEH-01` |
   | Tax rate | `0` |
   | Icon key | `restaurant` |
   | Available | Aktif |

3. Simpan dan catat angka **Rev**. Edit harga menjadi `6000`, simpan: angka Rev harus bertambah.
4. Buat produk kedua `UAT Hapus Saya`, harga `1000`, pada kategori yang sama. Biarkan dulu untuk tes penghapusan setelah sync.
5. Coba menyimpan produk dengan harga negatif atau kategori kosong: harus ada validasi.

Varian sudah masuk kontrak sync, tetapi form Products saat ini belum mempunyai editor varian. Jangan menganggap tes form produk ini juga membuktikan varian. Modifier belum termasuk feed yang tersedia.

### Staf

1. **Staff → Create/New**: nama `UAT Kasir`, role **Cashier**, PIN `4567`, Active menyala. Email/password boleh kosong untuk kasir.
2. Simpan: indikator **Till PIN** harus aktif. PIN tidak boleh ditampilkan sebagai teks di daftar staf.
3. Coba membuat kasir lain dengan PIN `4567`: harus ditolak sebagai duplikat dalam merchant yang sama.
4. Coba kasir baru tanpa PIN: harus ditolak. Batalkan form setelah pengujian validasi.
5. Edit `UAT Kasir`, ubah nama menjadi `UAT Kasir A`, biarkan PIN kosong, simpan. PIN lama seharusnya tetap berlaku dan Rev bertambah.

Untuk menguji bahwa kasir tidak bisa masuk backoffice, boleh buat akun khusus `UAT Login Cashier`, role Cashier, PIN `6789`, email `uat.cashier@nti.test`, dan password lokal pilihan Anda minimal 8 karakter. Coba login pada browser privat: akses backoffice harus ditolak walaupun password benar.

**Catat F3-01 dan F4-01:** CRUD/validasi katalog, perubahan Rev, pembuatan staf, PIN duplikat/kosong, dan akses kasir.

## 4. Menjalankan mobile dan aktivasi — Fase 2

### Terminal B — Flutter

Emulator `emulator-5554` sudah terdeteksi saat panduan dibuat. Jika sudah tertutup, buka Android Studio → Device Manager → tombol Play pada emulator, lalu periksa lagi:

```powershell
Set-Location 'D:\MobileDevelopment\Projects\nti_pos\mobile'
fvm flutter devices
fvm flutter pub get
fvm flutter run -d emulator-5554 --dart-define=API_BASE_URL=http://10.0.2.2:8000/api/v1
```

Ganti `emulator-5554` jika daftar perangkat menunjukkan ID lain. `10.0.2.2` adalah alamat khusus emulator Android untuk mengakses komputer host; `127.0.0.1` di emulator mengarah ke emulator sendiri. Lihat [dokumentasi jaringan Android Emulator](https://developer.android.com/studio/run/emulator-networking-address).

Jika FVM menampilkan `Invalid kernel binary format` tetapi kemudian versi/perangkat atau aplikasi tetap muncul, catat sebagai peringatan toolchain. Jika benar-benar berhenti, gunakan SDK yang sudah ditunjuk project:

```powershell
.\.fvm\flutter_sdk\bin\flutter.bat pub get
.\.fvm\flutter_sdk\bin\flutter.bat run -d emulator-5554 --dart-define=API_BASE_URL=http://10.0.2.2:8000/api/v1
```

Gunakan Android untuk panduan ini. Mode web membutuhkan pemeriksaan CORS/storage tersendiri, sedangkan koneksi HTTP ke IP LAN HP fisik ditolak oleh validasi URL aplikasi saat ini. Jangan mengganti alamat contoh dengan IP Wi-Fi komputer tanpa menyesuaikan pendekatan koneksinya.

### Di aplikasi

**Jika layar menjadi hitam setelah splash:** pada pengujian 9 September 2026,
widget aktivasi sudah terbentuk tanpa error Dart, tetapi emulator Pixel_8 tidak
menampilkan frame. Mengganti renderer tidak mengatasi masalah; cold boot emulator
memulihkan layar dengan perintah Flutter asli dan Impeller tetap aktif.

AVD Pixel_8 pada komputer ini kini memakai **Cold boot** (`fastboot.forceColdBoot=yes`,
`fastboot.forceFastBoot=no`). Konfigurasi sebelumnya dicadangkan di
`C:\Users\dinan\.android\avd\Pixel_8.avd\config.ini.before-coldboot-fix`.
Data aplikasi tetap dipertahankan; startup emulator dapat lebih lama dibanding
Quick Boot. Jika masalah berulang, tutup emulator lalu pilih **Cold Boot** melalui
Android Studio → Device Manager → menu perangkat Pixel_8. Jangan pilih Wipe Data.
Cold boot melewati state Quick Boot sebelumnya; lihat
[dokumentasi snapshot Android Emulator](https://developer.android.com/studio/run/emulator-snapshots).

1. **Harus muncul layar aktivasi**, bukan langsung daftar akun demo. Jika langsung masuk demo, pastikan flag `API_BASE_URL` benar dan hentikan/jalankan kembali Flutter; perubahan build flag memerlukan restart penuh.
2. Di browser emulator, buka `http://10.0.2.2:8000/api/v1/health` untuk memastikan backend dapat dijangkau.
3. Di browser komputer: **Pos Registers → UAT Kasir Android → Activation code → konfirmasi**. Salin kode yang ditampilkan; kode hanya ditampilkan pada penerbitan itu.
4. Masukkan kode pada mobile, tekan aktivasi.
5. **Lulus Fase 2:** layar konfirmasi menampilkan **Restoran NTI / UAT Outlet A / UAT Kasir Android**. Di backoffice **Devices**, ada perangkat dengan outlet/register yang sama dan platform Android.
6. Tekan **Lanjut ke login**. Teks layar konfirmasi yang mengatakan sync tersedia pada fase berikutnya masih merupakan teks lama; gunakan data yang benar-benar masuk sebagai bukti.
7. Tutup aplikasi, buka kembali. Identitas perangkat harus tetap dikenali tanpa memasukkan kode baru. Layar konfirmasi sebelum login dapat muncul lagi; itu tidak sama dengan kehilangan aktivasi.

**Setelah perbaikan B1:** akun dan katalog server ditarik saat startup/aktivasi serta ketika aplikasi kembali dari background. Sesudah menyimpan perubahan di backoffice, tekan Home Android lalu buka aplikasi kembali dan tunggu sync selesai. Rebuild diperlukan sekali untuk memasang perbaikan kode ini; perubahan katalog berikutnya tidak memerlukan `flutter run` ulang.

Jangan menjalankan mode demo pada perangkat ini hanya untuk mengisi layar yang kosong: itu dapat menutupi kegagalan sync dengan data lokal.

**Catat F2-02:** identitas aktivasi, baris Devices, persistensi setelah restart, serta ada/tidaknya akun UAT.

## 5. Menguji perubahan katalog pada mobile

Prasyarat: `UAT Kasir A` benar-benar muncul dari server dan produk UAT sudah ditarik. Tetap gunakan kontrak base URL yang disepakati pada perbaikan tersebut.

1. Pilih **UAT Kasir A**, masukkan PIN `4567`.
2. Buka sesi kasir pada **UAT Kasir Android**, isi kas awal `100000`. Hanya akun Cashier yang menjalankan penjualan; Owner/Manager membuka fungsi pengelolaan.
3. Cari **UAT Es Teh** di POS. Harga harus `6000`.
4. Di backoffice, ubah harga menjadi `7000`.
5. Di emulator, tekan Home Android, lalu kembali ke aplikasi. Ini memicu sync. Tunggu request backend selesai, lalu periksa harga untuk item yang baru ditambahkan ke keranjang kosong.
6. **Lulus:** harga baru `7000` terlihat tanpa perlu aktivasi ulang. Jika baru terlihat setelah menutup dan membuka aplikasi sepenuhnya, catat masalah pembaruan layar; jangan tandai tes resume lulus.
7. Di backoffice, hapus **UAT Hapus Saya**. Ulangi langkah resume. Produk tersebut harus hilang dari katalog mobile.
8. Ulangi resume dua kali lagi: produk tidak boleh berlipat.
9. Matikan backend dengan `Ctrl+C` di Terminal A. Tambahkan produk yang sudah tersimpan, lakukan pembayaran tunai, dan pastikan struk serta order lokal terbentuk.
10. Hidupkan kembali backend menggunakan perintah serve bagian 1.

Sync katalog dipicu saat pemuatan/aktivasi dan resume. Timer 30 detik pada kode memverifikasi identitas perangkat; jangan mengandalkannya sebagai timer pembaruan katalog.

Harga pada order lama adalah snapshot transaksi. Harga lama pada struk yang sudah selesai bukan kegagalan sync. Order yang Anda buat di langkah 9 memang akan naik ke backend saat koneksi kembali — itu Fase 6, dan diuji tersendiri di bagian 10. Di sini yang dinilai hanya arah tarik.

**Catat F3-02:** tarikan pertama, perubahan harga, penghapusan, tidak duplikat, dan transaksi lokal tanpa backend.

## 6. Menguji PIN offline dan perubahan staf

Selesaikan/tutup sesi kasir sebelum logout; aplikasi menolak logout selama sesi kasir masih terbuka. Saat penutupan sesi, gunakan PIN kasir yang sedang login.

1. Saat backend hidup, pastikan `UAT Kasir A` sudah tersinkron. Logout sampai kembali ke pilihan akun.
2. Matikan backend melalui `Ctrl+C`. Untuk uji tanpa jaringan sama sekali, matikan Wi-Fi/data emulator juga.
3. Tutup dan buka aplikasi kembali. Pilih `UAT Kasir A`, masukkan `4567`.
   - **Lulus:** tetap bisa login dari identitas tersimpan dan data staf lokal.
4. Logout, pilih akun yang sama, masukkan PIN salah. Harus ditolak. PIN milik akun lain juga harus ditolak untuk akun ini.
5. Hidupkan backend/jaringan. Di **Staff**, ubah PIN `UAT Kasir A` menjadi `5678`.
6. Resume aplikasi agar menerima perubahan. Kembali ke login: `4567` harus ditolak, `5678` diterima. Ulangi saat backend dimatikan setelah sync: hasil harus tetap sama.
7. Hidupkan backend. Deactivate **UAT Kasir A** di backoffice, resume aplikasi, lalu coba login lagi. Akun tidak boleh bisa login; dapat hilang dari pilihan akun.
8. Aktifkan kembali akun melalui Edit bila ingin melanjutkan tes. Sync kembali.
9. Pemeriksaan tambahan: buat staf uji terpisah dengan PIN 5–6 digit. Backend saat ini mengizinkan, sedangkan login mobile berhenti di 4 digit. Catat `FAIL B3` bila belum diperbaiki; jangan mengganti PIN akun utama untuk tes ini.
10. Jika perangkat pernah memakai demo, cek apakah ada nama ganda atau akun demo tetap bisa login setelah staf server dinonaktifkan. Catat identitas akun yang dipilih; baris dengan nama sama dapat memiliki ID berbeda.

Perubahan PIN atau status staf di server baru bisa diketahui perangkat setelah berhasil sync. Uji deactivation harus dilakukan setelah sync, bukan ketika perangkat masih terputus. Tes ini memeriksa login baru; pencabutan sesi staf yang sudah login perlu dinilai tersendiri.

**Catat F4-02:** login offline setelah restart, PIN salah/akun lain, rotasi PIN, deactivation, dan temuan legacy.

## 7. Menguji pencabutan device dan isolasi merchant

### Revoke — lakukan setelah tes mobile lainnya

1. Pastikan backend hidup dan emulator terhubung. Tutup sesi kasir dan simpan pekerjaan terlebih dahulu.
2. Di **Devices**, pilih perangkat Android UAT → **Revoke access** → konfirmasi.
3. Kembali ke aplikasi atau tunggu pemeriksaan sekitar 30 detik.
4. **Lulus:** aplikasi kembali meminta aktivasi, akses API perangkat ditolak, dan baris perangkat tetap terlihat sebagai revoked di backoffice.
5. Terbitkan kode baru untuk register yang sama, aktifkan kembali instalasi yang sama. Kode lama tidak boleh menjadi jalan masuk kembali.

Revoke berlaku pada request yang mencapai server. Perangkat yang sedang offline tidak menerima pemberitahuan pencabutan secara instan.

### Isolasi merchant — backoffice

Buka Terminal C, tanpa menghentikan server:

```powershell
Set-Location 'D:\MobileDevelopment\Projects\nti_pos\backend'
php artisan tenant:create
```

Isi prompt dengan business `UAT Merchant B`, owner `Owner UAT B`, email `owner.b@uat.test`, dan password pilihan Anda minimal 8 karakter. Gunakan email berbeda jika sudah pernah membuat akun tersebut.

1. Login akun merchant B di jendela privat atau browser berbeda.
2. **Lulus:** outlet, register, produk, dan staf Restoran NTI tidak terlihat.
3. Buat kategori `UAT Khusus B` dan outlet `UAT Outlet B`.
4. Kembali ke browser Restoran NTI: kedua data B tersebut tidak boleh terlihat, termasuk dalam pilihan outlet/kategori pada form.

Tes tampilan ini adalah pemeriksaan awal isolasi. Race condition kode sekali pakai dan jaminan constraint database membutuhkan pengujian otomatis/concurrency; jangan menandai keduanya terbukti hanya dari klik manual.

**Catat F2-03 dan F1-02:** revoke/reactivate serta isolasi dua merchant.

## 8. Tes API langsung ketika sync mobile terhalang

Bagian ini memeriksa API backend tanpa bergantung pada pembentukan URL Flutter. Gunakan register **UAT API**, sehingga percobaan tidak mencabut atau merotasi identitas Android.

### Aktivasi dan identitas

1. Di backoffice Restoran NTI, terbitkan **Activation code** untuk **UAT API**.
2. Pada Terminal C, jalankan:

```powershell
$uatApi = 'http://127.0.0.1:8000/api/v1'
$uatCode = Read-Host 'Masukkan activation code UAT API'
$uatDeviceId = [guid]::NewGuid().ToString()
$uatBody = @{
    code = $uatCode.Trim().ToUpperInvariant()
    device_uuid = $uatDeviceId
    label = 'UAT PowerShell'
    platform = 'windows'
} | ConvertTo-Json
$uatActivation = Invoke-RestMethod -Method Post -Uri "$uatApi/devices/activate" -ContentType 'application/json' -Headers @{ Accept = 'application/json' } -Body $uatBody
$uatHeaders = @{ Authorization = "Bearer $($uatActivation.token)"; Accept = 'application/json' }
Invoke-RestMethod -Uri "$uatApi/devices/me" -Headers $uatHeaders
```

**Lulus:** respons `/devices/me` menampilkan tenant, outlet, dan register UAT API yang benar. Token disimpan pada variabel sesi terminal; tidak perlu mencetak atau menyalinnya ke laporan.

### Manifest, katalog, dan staf

```powershell
Invoke-RestMethod -Uri "$uatApi/sync/manifest" -Headers $uatHeaders
$uatProducts = Invoke-RestMethod -Uri "$uatApi/sync/pull?entity=products&after_seq=0&limit=500" -Headers $uatHeaders
$uatProducts.rows | Select-Object id,name,price,sync_seq,deleted_at
$uatProducts | Select-Object next_seq,has_more
$uatStaff = Invoke-RestMethod -Uri "$uatApi/sync/pull?entity=employees&after_seq=0&limit=500" -Headers $uatHeaders
$uatStaff.rows | Select-Object name,role,active,sync_seq
```

**Lulus:** manifest berisi `employees`, `categories`, `products`, `product_variants`; produk/staf UAT merchant A muncul; data merchant B tidak muncul. Jika `has_more` bernilai `True`, tarik halaman berikutnya menggunakan `after_seq` dari `next_seq` sampai `False` sebelum menyimpulkan data lengkap.

Untuk memeriksa bentuk credential tanpa mencetak hash:

```powershell
$uatStaff.rows | Select-Object name,@{Name='HasPinHash';Expression={ -not [string]::IsNullOrEmpty($_.pin_hash) }}
if ($uatStaff.rows.Count -gt 0) { $uatStaff.rows[0].PSObject.Properties.Name }
```

Nama field harus mencakup `pin_hash`, tetapi tidak `pin`, `password`, atau `email`.

### Delta dan penghapusan

1. Setelah halaman produk terakhir, simpan cursor:

```powershell
$uatCursor = $uatProducts.next_seq
```

2. Di backoffice, ubah harga produk UAT. Lalu:

```powershell
$uatDelta = Invoke-RestMethod -Uri "$uatApi/sync/pull?entity=products&after_seq=$uatCursor&limit=500" -Headers $uatHeaders
$uatDelta.rows | Select-Object id,name,price,sync_seq,deleted_at
```

3. **Lulus:** perubahan muncul dengan `sync_seq > $uatCursor`. Request ulang dengan cursor lama boleh mengembalikan perubahan yang sama; itu normal karena cursor dikelola client.
4. Setelah seluruh halaman delta diterima, simpan `next_seq` sebagai cursor baru dan tarik lagi tanpa mengedit produk: `rows` harus kosong, cursor tidak mundur.
5. Hapus sebuah produk UAT yang dibuat khusus untuk tes. Tarik dari cursor terakhir: harus ada baris produk itu dengan `deleted_at` terisi. Itulah pemberitahuan penghapusan ke perangkat.

### Penolakan akses dan kode

Lakukan percobaan berikut satu per satu. PowerShell menampilkan error merah untuk HTTP yang ditolak; pada langkah ini itu hasil yang diharapkan, selama status sesuai.

| Percobaan | Cara | Hasil yang diharapkan |
|---|---|---|
| Tanpa token | Panggil `/devices/me` memakai hanya header `Accept: application/json` | 401 |
| Kode terpakai | Jalankan ulang POST aktivasi di atas dengan `$uatBody` yang sama | 422 |
| Kode lama dibatalkan | Terbitkan kode A lalu kode B untuk UAT API; coba aktivasi dengan A | 422 |
| Kode kedaluwarsa | Terbitkan kode baru, tunggu lebih dari 10 menit, lalu pakai kode itu | 422 |
| Batas percobaan | Di akhir tes, kirim 6 POST berkode tidak valid dalam satu menit | 429 setelah batas 5 per menit; lihat `Retry-After` pada respons melalui Postman bila diperlukan |
| Entity tidak diizinkan | Pull dengan `entity=super_admins` | 422 |
| Token dicabut | Revoke **UAT PowerShell** di Devices, lalu jalankan `/devices/me` dengan `$uatHeaders` lama | 401 |

Rate limit dihitung per IP, sehingga dapat memengaruhi aktivasi Android dari host yang sama. Lakukan terakhir dan tunggu sesuai `Retry-After`; ada juga batas 30 percobaan per jam. Jangan mengirim request berulang saat menunggu kode expired.

**Catat API-01:** identitas, manifest, delta, tombstone, field staf, penolakan akses, dan revoke. Lulus pada bagian ini belum membuktikan Flutter menyimpan dan menampilkan data dengan benar.

## 9. Menguji sesi kas tersinkron — Fase 5

Sesi kas kini didorong ke server. Yang diperiksa: laci yang dibuka di till muncul di backoffice, penutupannya menyusul, dan tidak ada laci ganda.

1. Di aplikasi (mode connected), login sebagai kasir dan **buka sesi** dengan kas awal, misalnya `200000`.
2. Tekan Home lalu buka lagi supaya sync berjalan.
3. Di backoffice buka **Cash sessions**.

**Yang diharapkan:**

- Baris baru muncul dengan outlet, register, nama kasir, dan Float `Rp 200.000`.
- Kolom penutupan berbunyi **Still open** — bukan kosong. Laci yang masih berjalan berbeda dari data yang hilang.
- Filter **Still open** menampilkannya.

4. Kembali ke aplikasi, **tutup sesi** dengan jumlah hitungan yang **sengaja berbeda** dari yang diharapkan (misalnya kurangi 5000). Tekan Home lalu buka lagi.

**Yang diharapkan:**

- Baris yang **sama** kini terisi waktu tutup, jumlah hitungan, dan **Over / short** berwarna merah. Tidak muncul baris kedua.
- Filter **Drawer did not balance** menampilkannya.
- Halaman ini tidak punya tombol edit atau hapus sama sekali. Selisih kas tidak boleh bisa dihapus dari browser.

5. **Uji satu laci per register.** Ada dua penjaga di sini, dan keduanya perlu dicoba karena letaknya berbeda:

   a. *Di perangkat:* buka sesi lagi di aplikasi yang sama tanpa menutup yang sedang berjalan. Aplikasi harus menolak — ini penjaga lokal yang sudah ada sejak awal.

   b. *Di server:* aktivasi **perangkat kedua** ke register yang sama (backoffice mengizinkannya — satu register boleh punya beberapa instalasi), lalu buka sesi di sana selagi sesi perangkat pertama masih berjalan. Push-nya harus ditolak dengan menyebut siapa yang sedang memegang laci itu. Inilah penjaga yang baru: dua tablet pada satu laci fisik tidak boleh menghasilkan dua sesi terbuka.

   Kalau hanya (a) yang dicoba, penjaga server belum teruji sama sekali.

## 10. Menguji penjualan tersinkron — Fase 6

Ini bagian paling kritis: uang yang sudah diterima pelanggan.

1. Login sebagai kasir, buka sesi, lalu **buat satu penjualan**. Catat nomor struknya.

**Yang diharapkan:** nomor berformat **`K1-0001`** (huruf pertama nama register + angkanya), bukan `ORD-0001`.

2. Tekan Home lalu buka lagi. Di backoffice buka **Sales**.

**Yang diharapkan:**

- Penjualan muncul dengan nomor struk, waktu, nama kasir, total, dan metode pembayaran.
- Kolom waktu adalah **waktu di till**, bukan waktu server menerimanya.

3. **Uji tidak dobel:** tekan Home dan buka lagi beberapa kali. Jumlah baris di Sales tidak boleh bertambah.

4. **Uji offline:** matikan internet emulator (mode pesawat), buat **dua** penjualan, lalu nyalakan lagi dan tekan Home → buka.

**Yang diharapkan:** kedua penjualan menyusul ke backoffice. Saat offline, penjualan tetap bisa diselesaikan dan struk tetap tercetak — itu inti offline-first.

5. **Uji void:** void satu penjualan dari aplikasi dengan PIN manager dan alasan. Sync.

**Yang diharapkan:**

- Status di Sales berubah menjadi `cancelled`, dan kolom **Voided by** menampilkan nama penyetuju beserta alasannya.
- Baris itu **hilang dari perhitungan pendapatan** (lihat bagian 11), tetapi tetap tampil di daftar.

6. **Uji dua till:** aktifkan register kedua, buat penjualan di masing-masing.

**Yang diharapkan:** nomornya berbeda prefiks, misalnya `K1-0001` dan `TA-0001`. Sebelum perbaikan ini keduanya akan bernomor sama.

## 11. Menguji laporan lintas outlet — Fase 7

1. Login backoffice sebagai **Owner**. Dashboard harus menampilkan **Takings today** dengan jumlah penjualan dan item.
2. Buka **Sales report**. Rentang awal adalah 7 hari terakhir.

**Yang diharapkan:**

- Revenue cocok dengan jumlah penjualan yang belum di-void.
- Penjualan yang di-void muncul di bagian **Voided and refunded**, dengan catatan bahwa ia dikecualikan dari angka di atas.
- **By outlet** menampilkan setiap cabang. Filter Outlet kosong berarti seluruh chain.
- **By category** punya catatan bahwa angkanya sebelum pajak dan service charge — jadi jangan kaget kalau jumlahnya tidak sama dengan Revenue. Itu memang disengaja.

3. Jika sebagian produk belum diisi harga modal, akan muncul peringatan kuning tentang cakupan biaya. Gross profit di bawah 66% cakupan adalah perkiraan, bukan angka final.

4. **Uji batas permission:** login sebagai **Manager**.

**Yang diharapkan:** menu Sales report tidak tersedia; membukanya langsung lewat URL menghasilkan 403. Manager tetap bisa membuka Cash sessions dan Sales.

## 12. Opsional: memastikan mode demo tetap terpisah

Adopsi sudah dihentikan, jadi yang diperiksa di sini kebalikannya: **mode demo tidak boleh terpengaruh sama sekali** oleh semua perubahan di atas.

1. Jalankan **tanpa** build flag, pada emulator mana pun:

   ```powershell
   Set-Location 'D:\MobileDevelopment\Projects\nti_pos\mobile'
   fvm flutter run -d ID_EMULATOR
   ```

**Yang diharapkan:**

- Muncul layar **login PIN**, bukan layar aktivasi.
- Katalog demo lengkap (26 produk, 5 kategori), 4 staf demo, dan Dashboard menampilkan sebulan penjualan.
- **Settings → Reset demo data** tetap berfungsi.

2. Jalankan lagi **dengan** `API_BASE_URL`. Store connected harus terpisah: katalog dan staf hanya yang dari backoffice, dan tidak ada satu pun produk demo yang bocor ke sana.

3. Bolak-balik beberapa kali antara kedua mode. Tidak ada data yang berpindah ke arah mana pun.

## 13. Jika menemui masalah

| Gejala | Langkah pemeriksaan |
|---|---|
| `/` hanya welcome Laravel | Buka `/backoffice`. |
| `could not find driver` | Periksa `php -m`; driver `pdo_pgsql` harus aktif pada PHP CLI yang dipakai. |
| Koneksi PostgreSQL ditolak | Cek layanan PostgreSQL, host/port, serta credential pada `.env`. Jangan kirim password DB dalam laporan. |
| Akun demo tidak bisa login | Pastikan database yang digunakan benar. Seeder tidak mengganti akun merchant yang sudah ada. Catat masalah, jangan reset database. |
| Create mendapat 403 atau dashboard berubah menjadi `No merchant resolved` saat polling | Perbaikan konteks tenant Livewire sudah ditambahkan. Refresh penuh halaman untuk mendapatkan snapshot baru. Konteks tenant kini bertahan sampai aksi/render selesai; autentikasi dan policy tetap diperiksa. |
| Staff gagal karena ekstensi `intl` | Periksa `php -m` dan `php --ini`. Pastikan `extension=intl` aktif pada php.ini yang dipakai. Setelah perubahan konfigurasi PHP, restart server; refresh browser saja tidak memuat ulang ekstensi pada proses server lama. |
| Port 8000 sudah dipakai | Cek apakah backend sudah berjalan. Jika memilih port lain, ubah seluruh URL contoh secara konsisten. |
| Mobile langsung masuk demo | Cek `API_BASE_URL`, lalu stop dan run ulang. |
| Aktivasi gagal karena jaringan | Coba health dari browser emulator; cek server tetap hidup dan URL `10.0.2.2`. Jika log menyebut cleartext HTTP ditolak, catat pesan tersebut untuk perbaikan konfigurasi debug. |
| Aktivasi berhasil tetapi akun/produk UAT tidak muncul | Pastikan build terbaru memakai `API_BASE_URL`, backend hidup, dan device terikat ke tenant yang sama. Request harus menuju `/api/v1/sync/...`, tanpa prefix ganda. Log `Device sync failed` menunjukkan kategori kegagalan. |
| Kode ditolak | Bisa terpakai, expired, atau dibatalkan kode baru. Terbitkan kode baru setelah aplikasi siap. |
| Tidak bisa logout | Tutup sesi kasir terlebih dahulu menggunakan PIN kasir yang sedang login. |
| Owner/Manager tidak bisa menjual | Sesuai pembagian role sekarang; gunakan Cashier untuk transaksi. |
| Perubahan belum tampil saat aplikasi tetap terbuka | Sync dipicu saat startup/resume. Tekan Home Android lalu kembali, tunggu jaringan selesai. Versi perbaikan memperbarui cache tampilan tanpa restart. |
| Penjualan tidak muncul di backoffice | Push hanya berjalan saat aktivasi dan resume (B6). Tekan Home lalu buka lagi. Kalau tetap tidak muncul, cek terminal Flutter untuk `Device sync failed` — kategorinya menunjukkan jaringan, otorisasi, atau penolakan server. |
| Data uji lama hilang setelah update | Migrasi v24 mengosongkan store connected (bagian 0.1). Ini disengaja: order hasil salinan demo akan mencemari pembukuan begitu Fase 6 mengirim penjualan ke server. Store demo tidak tersentuh. |
| Nomor struk tidak berlanjut dari yang lama | Nomor kini per register dan dimulai ulang dari `0001` untuk register itu. Order lama tetap memakai `ORD-xxxx` — struk yang sudah dipegang pelanggan tidak boleh berubah nomornya. |
| Dua outlet mencetak nomor yang sama | Diharapkan. Prefiks berasal dari nama register, dan dua cabang boleh sama-sama punya "Kasir 1". Yang membedakan barisnya adalah outlet dan register, bukan nomornya. |
| Sesi kedua di register yang sama ditolak | Diharapkan — satu laci fisik hanya boleh punya satu sesi terbuka. Tutup sesi yang sedang berjalan lebih dulu. Pesannya menyebut siapa yang memegangnya. |
| Angka By category tidak sama dengan Revenue | Diharapkan. Kategori dihitung sebelum PB1 dan service charge, yang punya barisnya sendiri. Jumlah kategori sama dengan subtotal dikurangi diskon. |
| Manager tidak bisa membuka Sales report | Diharapkan — laporan berentang dengan profit adalah milik Owner, sama seperti di aplikasi. Manager tetap bisa membuka Cash sessions dan Sales. |

Untuk log backend setelah error, buka Terminal C:

```powershell
Set-Location 'D:\MobileDevelopment\Projects\nti_pos\backend'
Get-Content storage/logs/laravel.log -Tail 80
```

Catat juga pesan terminal Flutter. Bagikan bagian error yang relevan saja; samarkan token, activation code yang masih berlaku, dan credential.

## 14. Lembar hasil

Isi status dengan `PASS`, `FAIL`, atau `BLOCKED`; jangan menganggap langkah yang belum dicoba sebagai lulus.

| ID | Pemeriksaan | Bagian | Status | Catatan |
|---|---|---|---|---|
| F1-01 | Health, login dan hak akses Owner/Manager/Cashier | 1 | Belum diuji | |
| F1-02 | Isolasi dua merchant | 7 | Belum diuji | |
| F2-01 | Outlet dan register | 2 | Belum diuji | |
| F2-02 | Aktivasi, identitas, persistensi setelah restart | 4 | Belum diuji | |
| F2-03 | Revoke dan aktivasi ulang | 7 | Belum diuji | |
| F3-01 | Katalog backoffice dan validasi | 3 | Belum diuji | |
| F3-02 | Sync awal/delta/delete, UI resume, penggunaan offline | 5 | Belum diuji | B1 diperbaiki |
| F4-01 | Staf backoffice dan validasi credential | 3 | Belum diuji | |
| F4-02 | PIN offline, rotasi PIN, deactivation | 6 | Belum diuji | B3 masih terbuka |
| **BUG-01** | **Daftar akun tepat satu baris per orang; katalog tidak berlipat** | 4 | Belum diuji | Inti perbaikan B4 |
| **F5-01** | Sesi kas terbuka muncul di backoffice sebagai "Still open" | 9 | Belum diuji | |
| **F5-02** | Penutupan mengisi baris yang sama, selisih tampil, tidak ada baris kedua | 9 | Belum diuji | |
| **F5-03** | Sesi kedua pada register yang sama ditolak — penjaga perangkat (a) dan penjaga server dua-tablet (b) | 9 | Belum diuji | (b) yang paling penting |
| **F6-01** | Nomor struk berformat `K1-0001`, berbeda prefiks antar till | 10 | Belum diuji | B5 |
| **F6-02** | Penjualan muncul di backoffice; sync berulang tidak menggandakan | 10 | Belum diuji | |
| **F6-03** | Penjualan offline menyusul setelah koneksi kembali | 10 | Belum diuji | |
| **F6-04** | Void tercatat dengan penyetuju dan alasan, keluar dari pendapatan | 10 | Belum diuji | |
| **F7-01** | Dashboard menampilkan takings hari ini | 11 | Belum diuji | |
| **F7-02** | Sales report: revenue, per outlet, per kategori, voided terpisah | 11 | Belum diuji | |
| **F7-03** | Manager ditolak membuka Sales report (403) | 11 | Belum diuji | |
| **DEMO-01** | Mode demo utuh: 26 produk, 4 staf, sebulan penjualan, reset berfungsi | 12 | Belum diuji | Wajib — jaminan bahwa v24 tidak menyentuh demo |
| API-01 | API device/sync dan respons penolakan | 8 | Belum diuji | |

Format laporan per temuan:

```text
ID tes:
Langkah terakhir:
Akun/role dan perangkat:
Hasil yang diharapkan:
Hasil aktual:
Pesan error / screenshot:
Terulang setelah restart penuh: ya / tidak / belum dicoba
```

Checklist manual ini tidak menggantikan suite otomatis. Saat panduan diperbarui, kondisi otomatisnya: backend **200 tes**, Flutter **547 tes**, `pint` bersih, `composer audit` tanpa advisory — termasuk uji balapan dua koneksi PostgreSQL untuk "satu laci per register", dan uji idempotensi push order lewat HTTP nyata.

Yang **belum** diverifikasi oleh siapa pun, dan itulah alasan lembar ini ada: rantai lengkap tablet → server pada perangkat sungguhan. Sisi perangkat terbukti lewat tes terhadap SQLite asli, sisi server lewat HTTP nyata, tetapi keduanya belum pernah diamati langsung berjalan bersama.

Prioritas pemeriksaan: **BUG-01** dan **DEMO-01** lebih dulu — keduanya menjawab laporan bug Anda dan menjaga aset demo. Setelah itu F6 (uang), lalu F5 dan F7.

## Verifikasi teknis perbaikan sync Android — 9 September 2026

- B1 diperbaiki: request sync memakai API root yang sama dengan aktivasi. Tidak perlu mengubah `API_BASE_URL` atau aktivasi ulang.
- Database Android dan layar Produk akun Farhan menampilkan `Bala Bala` (2000), `Es Teh Aneh` (1000), serta `Es Teh Susu` (6000). Kategori `Makanan Sunda` dan `Minuman` juga tampil.
- Data uji sementara dibuat melalui model backend dengan mekanisme sequence yang sama dengan backoffice. Setelah Home → kembali, kategori dan produk muncul pada halaman yang masih terbuka. Perubahan nama kategori serta harga 1234 → 5678 tampil tanpa restart; penghapusan juga tersinkron. Data uji telah dibersihkan melalui tombstone, tanpa menghapus data pengguna.
- Update sync kini memakai UPDATE/INSERT, sehingga rename kategori tidak menghapus produk dan update produk tidak menghapus varian yang tidak berubah. Cache katalog/staf dibaca ulang setelah sync tanpa mereset router, sesi, atau keranjang.
- `flutter test`: **537 tes lulus**, termasuk 11 tes sync. Analisis empat file Dart yang berubah bersih; analisis seluruh proyek masih melaporkan 85 lint tingkat info pada file lain, tanpa error/warning.
- Bukti lokal tersedia di `mobile/build/diagnostics/`: `sync-categories.png`, `sync-delta.png`, `sync-products.png`, `flutter-sync-tests.log`, dan `flutter-sync-analyze.log`.

Verifikasi ini tidak menggantikan checklist UAT Anda atau menyatakan seluruh skenario PIN offline/revoke sudah diuji ulang. Fase 5 belum dimulai.
