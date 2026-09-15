# Verifikasi dan handoff Fase 2B

Tanggal pemeriksaan: 11 September 2026. Acuan: `../../plan.md` (Fase 2B — CRUD
Backoffice: katalog, staf, outlet, register, perangkat, modifier, promo dalam
templ + HTMX).

Pembaruan 13 September 2026: gerbang k6 sudah lulus pada pemeriksaan ulang,
OpenAPI telah dibekukan, dan Fase 3 telah diimplementasikan. Lihat
[gerbang akhir Fase 0–2](PHASE_0_2_VERIFICATION.md) dan
[hasil Fase 3](PHASE_3_VERIFICATION.md). Status di bawah adalah catatan
historis 11 September, bukan blocker yang masih terbuka.

**Status: gerbang fungsional Fase 2B lulus di environment lokal. Gerbang beban
k6 (milik Fase 2A) tidak stabil di host ini sore ini untuk build lama maupun
baru — lihat bagian k6. Langkah berikutnya: pembekuan OpenAPI akhir Fase 2.**

## Sebelum mulai: verifikasi ulang Fase 2A

Semua klaim di `PHASE_2A_VERIFICATION.md` direproduksi secara independen sebelum
2B dikerjakan: build/vet, suite penuh, `-race` di container Linux, tiga verifier
live lewat Caddy HTTPS pada container yang di-rebuild (16/20/53 PASS), dan gate
k6 pagi hari (p99 1,33 ms, 0 dropped). Test snapshot diuji mutasi: dengan `Pull`
dikembalikan ke `InTenantTx` (READ COMMITTED), kedua subtest gagal dengan pesan
"never acknowledge a row absent from this snapshot".

## Yang dibangun

| Area | Layar | Domain writer |
|---|---|---|
| Kategori | list + tambah inline, ubah, hapus (ditolak bila masih berisi produk) | `catalogue` |
| Produk | list dengan cari/filter/halaman, saklar habis per baris, tambah, ubah, hapus | `catalogue` |
| Varian | tambah/ubah/hapus inline di halaman produk | `catalogue` |
| Modifier | grup + opsi inline; konfigurasi per produk (grup, opsi, default) | `catalogue` |
| Impor harga | unggah CSV `sku,harga` (koma atau titik koma), semua-atau-tidak-sama-sekali | `catalogue` |
| Promo | persen/nominal, min. belanja, berlaku di semua outlet atau outlet terpilih | `promos` (baru) |
| Karyawan | profil, peran, email, PIN, kata sandi Backoffice, aktif/nonaktif | `staff` |
| Outlet & till | outlet + till di dalamnya, aktif/nonaktif, layanan meja per till | `outlets` (baru) |
| Perangkat | sudah ada sejak Fase 1B; kini terhubung ke till yang dibuat dari panel | `devices` |

Migrasi baru: `20260911000009_backoffice_writes.sql` (`promos.all_outlets` dan
`products.image_key`; versi awalnya berisi fingerprint PIN + unique index, dicabut
pada 13 September — lihat "Keputusan") dan
`20260911000010_publish_unnumbered_rows.sql` (backfill baris `sync_seq = 0`;
di DB dev satu employee lama kini bernomor, nol baris tersisa di 0).

## Masalah yang ditemukan dan diperbaiki selama pengerjaan

Semua ditemukan sebelum rilis. Empat yang pertama dibuktikan dengan uji mutasi
(test gagal tanpa perbaikannya). Perbaikan filter pencarian hanya dibuktikan
*bekerja* di Chrome headless — browser tidak dijalankan terhadap trigger lama.
Temuan `SaveVariant` ditangkap analyzer statis dan belum punya test khusus.

| Masalah | Dampak bila lolos | Bukti |
|---|---|---|
| Dua owner saling menurunkan peran bersamaan → **deadlock** (target dikunci sebelum baris owner) | Salah satu dapat 500 alih-alih pesan "harus ada satu owner" | Mutasi urutan kunci lama: `40P01 deadlock detected` di round 1 pada 3/3 run; setelah perbaikan lulus, termasuk di bawah `-race` |
| Parser rupiah yang membuang titik secara buta | `25000.50` terbaca **2.500.050** — harga naik 100× tanpa pesan | `TestRupiahIsReadOnlyWhenItIsUnambiguous`; verifier live menolak `25000.50` |
| `retireScope` dengan slice `nil` → `NULL`, dan `cardinality(NULL) = 0` bernilai NULL | Menghapus promo meninggalkan scoping outlet hidup di feed | Mutasi tanpa lengan `IS NULL`: `TestDeletingAPromoRetiresItsScoping` gagal |
| Upsert dengan ID milik merchant lain → `42501 new row violates row-level security policy` | Tidak ada data yang bocor, tapi 500 alih-alih 404, dan membocorkan bahwa ID itu ada | Test terkonfirmasi gagal dulu dengan 42501; kini `ErrNotFound` di catalogue, promos, outlets |
| Filter pencarian produk: `hx-trigger` `changed` dipasang di form (form tidak punya value) | Cari-sambil-mengetik bisa tidak pernah terpicu | Diganti pola "active search" HTMX; dibuktikan di Chrome headless |
| `SaveVariant` mengembalikan `Scan` langsung sehingga cek `ErrNoRows` jadi dead code | Varian yang dipindah antar produk jadi 500, bukan 404 | Ditangkap analyzer, diperbaiki sebelum test |

Mutasi juga dijalankan untuk penutupan outlet: tanpa `Bump` cache auth,
`TestClosingAnOutletSignsItsTillsOutNow` gagal (cache masih melayani binding
cabang yang sudah ditutup).

## Bukti verifikasi (kode final)

| Pemeriksaan | Hasil |
|---|---|
| `go build`, `go vet`, `gofmt` | Bersih (`gofmt` hanya menandai `scripts/verify-activation`, sudah begitu sebelum 2B) |
| `templ generate` | Hash output identik sebelum/sesudah generate ulang — view yang di-commit mutakhir |
| `go test ./... -count=1` | 11 paket lulus; **124** fungsi test tingkat atas (72 sesudah 2A) |
| `go test ./... -race -count=1` | Lulus di container Linux (Go 1.27 Alpine + gcc/musl-dev), 11 paket |
| `verify-backoffice-crud` (baru) lewat Caddy HTTPS | **67 PASS**, diulang dua kali pada tenant baru |
| `verify-activation` / `verify-backoffice` / `verify-sync` | 16 / 20 / 53 PASS pada build final |
| Chrome headless (puppeteer-core di scratchpad, bukan di repo) | **19/19**: swap HTMX, toast, redirect setelah create, pesan per field, cari-sambil-mengetik + URL, saklar habis, penolakan hapus, 0 respons ≥ 400, 0 error JS |
| Log API selama run | Nol baris ERROR/WARN (handler mencatat setiap 500 di level ERROR) |

`verify-backoffice-crud` membuktikan hal yang tidak bisa dibuktikan unit test:
outlet, till, kategori, produk, varian, grup/opsi modifier, konfigurasi produk,
promo terscope, dan kasir yang dibuat **di browser** tiba di feed pull **till**
dengan nilai yang diketik — tanpa `email` maupun `password`.
Rename till di panel langsung terlihat di `/devices/me` tablet; menutup outlet
(oleh manajer) langsung membuat till 401; manajer mendapat 403 di katalog dan
nav hanya menampilkan yang boleh dibukanya. Skrip ini ditambahkan ke langkah
verifier live di CI.

## Uji beban k6 — gerbang Fase 2A, diukur ulang pada build 2B

Jalur panas `/sync/changes` (cache auth, rate limiter, `Cursors`) tidak diubah
oleh 2B. Tetap diukur ulang, dan hasilnya **tidak stabil di host ini sore ini**:

| Kondisi | Build | p99 | dropped | gate |
|---|---|---|---|---|
| pagi (sebelum 2B) | 2A + perbaikan review | 1,33 ms | 0 | lulus |
| sore, run 1–2 | 2B | 12,47 / 12,16 ms | 0 / 0 | lulus |
| setelah restart `api` + `redis` | 2B | 23,97 ms | 12 | **gagal** |
| setelah restart Docker Desktop | 2B | 14,97 / 12,95 ms | 0 / 0 | lulus |
| A/B berselang-seling, run 1 | lama (`b6b13ef`) | 73,5 ms (max **5j58m**) | 0 | **gagal** |
| A/B run 2 | 2B | 2,54 ms | 0 | lulus |
| A/B run 3 | lama (`b6b13ef`) | 1,55 ms | 0 | lulus |
| A/B run 4 | 2B | 1,94 ms | 47 | **gagal** |

Kesimpulan yang didukung data:

- **Tidak ada regresi yang bisa diatribusikan ke 2B.** Pada run bersebelahan,
  build lama dan baru punya median yang sama (~0,5 ms) dan p99 sebanding.
- **Gerbang lokal tidak andal di host ini sekarang, untuk kedua build.**
  Kegagalannya berupa jeda sesaat (max 80–230 ms; satu `5h58m` yang mustahil
  sebagai latensi dan menunjuk ke lompatan jam VM), bukan latensi server yang
  merata. Restart Docker Desktop tidak memulihkan angka pagi.
- Penyebab pasti belum diisolasi. Generator k6, API, Postgres dan Redis berbagi
  satu VM Docker Desktop di Windows yang sama dengan IDE dan browser. Ini
  memperkuat catatan di dokumen 2A: angka lokal bukan ukuran kapasitas, dan
  gerbang ini sebaiknya dijalankan di host Linux yang tenang, dengan generator
  terpisah dari server, sebelum dianggap mengikat. Itu bagian Fase 9.

Container dan image A/B sudah dihapus; hanya dua merchant asli di DB dev yang
tersisa.

## Keputusan yang diambil (13 September 2026)

1. **PIN tidak perlu unik.** Unique index parsial, kolom
   `employees.pin_fingerprint`, dan semua pesan "PIN sudah dipakai" dihapus.
   Aman untuk login: layar login till memilih akun dulu lalu memverifikasi PIN
   (`EmployeeRepository.verify(id, pin)`). **Satu jalur till perlu diubah di
   Fase 4:** `authorize_sheet.dart` (otorisasi void/refund) memakai `byPin`
   saat belum ada akun yang dipilih, dan `byPin` mengambil karyawan aktif
   *pertama* yang cocok — dengan PIN kembar, otorisasi bisa tercatat atas nama
   orang yang salah. `TestStaffMayShareAPIN` mengunci keputusan ini.

   Migrasi 009 diubah di tempat, bukan ditambah migrasi penghapus: 009 belum
   pernah di-commit dan hanya diterapkan di DB dev ini. DB dev di-rollback ke
   008 (tidak ada data promo, gambar, atau fingerprint yang hilang — dicek
   dulu) lalu dinaikkan lagi ke 010.

2. **Upload gambar produk — disimpan di volume disk, disajikan di `/media/`.**
   - Pilihan pertama adalah object storage S3 lewat MinIO di Compose, tetapi
     `docker pull minio/minio` kini ditolak (`pull access denied`). Untuk
     pilot satu VPS, volume Docker yang dibaca Caddy adalah pilihan paling
     sederhana yang benar.
   - URL publik = `MEDIA_PUBLIC_BASE_URL` + key. Itulah yang disimpan setiap
     till, jadi itu yang dijaga stabil: pindah ke object storage/CDN nanti cukup
     menyalin folder dan mengarahkan host itu, tanpa menulis ulang baris produk
     (yang akan membangunkan seluruh till).
   - Key berbasis hash isi: `products/{tenant}/{sha256}.{jpg|png}`. Ditulis
     atomik, tidak pernah diubah, cache 1 tahun `immutable`. File disimpan
     **sebelum** baris yang menyebutnya dipublikasikan. File lama tidak dihapus
     saat diganti, karena till yang belum sinkron masih menampilkannya.
   - Setiap upload **di-decode dan di-encode ulang**, tidak pernah disimpan
     apa adanya: EXIF (termasuk lokasi foto) terbuang, file HTML/script yang
     menyamar tidak mungkin tersimpan, sisi terpanjang maks. 1024 px. Tag
     orientasi EXIF diterapkan dulu — tanpa itu setiap foto portrait dari HP
     tampil miring di semua tablet. JPEG kecuali ada transparansi (PNG).
     JPG/PNG/WebP, maks. 10 MB, maks. 50 MP dicek dari header sebelum decode,
     maks. 2 decode bersamaan per proses.
   - `SaveProduct` tidak lagi menyentuh gambar, sehingga menyimpan form produk
     tidak bisa menghapus foto. Field "Alamat gambar" diganti kartu upload.
   - Volume `media` **tidak** tercakup pgBackRest; harus di-backup terpisah.

3. **`APP_KEY`: tidak ada data tahan lama yang diturunkan darinya.** Dengan
   fingerprint PIN hilang, rotasi `APP_KEY` hanya membatalkan kode aktivasi
   10 menit dan form yang sedang terbuka. Aturan ini dicatat di `config.go` dan
   `CLAUDE.md`, dan URL gambar sengaja tidak ditandatangani dengan kunci itu.

## Bukti untuk perubahan 13 September

| Pemeriksaan | Hasil |
|---|---|
| `go build`, `go vet`, `templ generate` | Bersih; hash view identik sebelum/sesudah generate |
| `go test ./... -count=1` | 12 paket lulus; **142** fungsi test tingkat atas (124 sebelumnya) |
| `go test ./... -race -count=1` (container Linux) | 12 paket lulus |
| Guard CI | Tidak ada `FOR UPDATE` pada `tenants`; nol referensi `pin_fingerprint` tersisa |
| `verify-backoffice-crud` lewat Caddy HTTPS | **80 PASS** (termasuk 12 check gambar) |
| `verify-backoffice-crud` lewat API langsung, tanpa Caddy (jalur CI) | **80 PASS**, 1 file tertulis, nol ERROR/WARN di log |
| `verify-activation` / `verify-backoffice` / `verify-sync` | 16 / 20 / 53 PASS |
| Chrome headless | **25/25**: upload lewat input file, gambar benar-benar termuat dari `/media` (900×600 PNG, transparansi dipertahankan), tetap ada setelah form produk disimpan, bisa dihapus; 0 error JS, 0 respons ≥ 400 |

Check gambar di verifier live memakai foto "portrait HP" buatan: 1600×1200
dengan tag EXIF orientation 6 dan penanda merah di pojok kiri atas. Hasilnya
768×1024, penanda di kanan atas, tanpa byte `Exif`, `Content-Type: image/jpeg`,
`Cache-Control: public, max-age=31536000, immutable`, `nosniff`. SVG ditolak di
samping field; file yang tidak ada → 404 **tanpa** header cache; direktori tidak
bisa di-list. Menghapus gambar membuat till menarik `image_url: null`.

Uji mutasi (test harus gagal tanpa kodenya):

- Tag orientasi diabaikan → `TestAPortraitPhonePhotoArrivesUprightAndScaled`
  gagal ("turned upright: the long side is now vertical"). Percobaan pertama
  mutasi ini gagal compile (variabel tak terpakai) sehingga belum membuktikan
  apa pun; diulang dengan mutasi yang tetap compile.
- Batas 50 MP dihapus → `TestWhatIsNotAnImageIsRefused` gagal. Versi awal test
  ini **vakum**: header PNG diubah tanpa menghitung ulang CRC, jadi file ditolak
  karena "rusak", bukan karena ukurannya. CRC kini dihitung ulang dan pesannya
  ditegaskan menyebut megapiksel.

Dua kegagalan di Chrome yang sempat muncul adalah masalah script, bukan
aplikasi. Diagnostik terpisah dengan urutan persis yang sama (upload → simpan
form → hapus gambar → ditolak → simpan ulang) menunjukkan server membalas
`{"toast":"Produk disimpan."}` dan notifikasi tampil. Penyebabnya script
mengetik ke form yang sedang di-*settle* HTMX, lalu membaca notifikasi lama.

Catatan: file gambar dari tenant uji yang dihapus tetap ada di volume `media`,
sesuai desain (belum ada sweep).

## Keterbatasan yang sudah ada sebelumnya (tidak diubah)

Cache auth membaca generation **setelah** membaca database. Request yang membaca
DB tepat sebelum commit sebuah revoke/penutupan cabang, lalu membaca generation
tepat sesudah bump-nya, bisa menyimpan binding lama dengan generation baru.
Jendelanya milidetik dan dibatasi TTL 5 menit. Tidak diubah di 2B karena
perbaikan yang benar mengubah desain cache Fase 1; dicatat di sini agar tidak
hilang.

## Langkah cek manual (Windows, dari `backend-go/`)

Muat `.env` seperti di dokumen 2A, lalu:

```powershell
# caddy ikut dibuat ulang: Caddyfile berubah dan kini me-mount volume media
docker compose up -d --build api caddy
go run ./cmd/justclick migrate up
go test ./... -count=1
$env:VERIFY_BASE_URL = 'https://localhost:8443'; $env:VERIFY_INSECURE_TLS = '1'
go run ./scripts/verify-activation
go run ./scripts/verify-backoffice
go run ./scripts/verify-backoffice-crud
go run ./scripts/verify-sync
```

Untuk mencoba upload secara manual: buka produk mana pun di
`https://localhost:8443/backoffice/catalogue/products`, pilih foto di kartu
**Gambar**, lalu buka URL gambarnya di tab baru.

Harapan: semua `all checks passed`. Untuk mencoba layar secara manual, masuk
sebagai Owner di `https://localhost:8443/backoffice`: buat outlet dan till,
terbitkan kode di **Perangkat**, aktivasi tablet, lalu buat kategori → produk →
varian → grup modifier → konfigurasi produk → promo → kasir, dan tarik feed dari
tablet. Masuk sebagai Manajer untuk melihat 403 di katalog.

## Berikutnya

Pembekuan `api/openapi.yaml` dan contract test objek-2xx di akhir Fase 2, sesuai
`plan.md`. Putuskan butir 1 di atas sebelum atau saat membekukan. Flutter v2
(Fase 4) menunggu spesifikasi beku; push order/sesi (Fase 3) tidak bergantung
pada 2B.
