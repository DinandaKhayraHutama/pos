# Fase 9.5 — stabilisasi lokal & bug login panel platform

Tanggal: 21 September 2026. Fase 10 **ditunda** atas keputusan pemilik produk;
fase ini menjawab pertanyaan yang mendahuluinya: apakah aplikasinya benar-benar
jalan di lokal, dan apakah Backoffice, panel platform dan till benar-benar
terhubung satu sama lain.

## Bug yang dilaporkan: login super admin ditolak "Forbidden - origin invalid"

### Reproduksi

Matriks empat kombinasi terhadap stack hidup, tanpa perlu tahu kata sandi:
CSRF diperiksa **sebelum** kredensial, jadi kata sandi yang sengaja salah tetap
membedakan "CSRF lolos" (401, pesan kredensial) dari "CSRF ditolak" (403).

| Kombinasi | Hasil |
|---|---|
| Halaman HTTPS (Caddy), `Origin` HTTPS | 401 — CSRF lolos |
| Halaman HTTP (biner host), `Origin` HTTP | 401 — CSRF lolos |
| Token dari HTTPS, dikirim ke pintu HTTP | 401 — lolos (**cookie mengabaikan nomor port**) |
| Halaman HTTPS, `Origin` HTTP | **403 `Forbidden - origin invalid`** |
| HTTPS, tanpa `Origin` **dan** tanpa `Referer` | **403 `Forbidden - referer not supplied`** |

### Dua cacat, keduanya terbukti di kode

**1. Skema yang disimpulkan server bisa berbeda dari skema yang dipakai
browser.** `gorilla/csrf` menyusun URL acuan dari skema yang dideklarasikan
aplikasi (`internal/infra/web.DeclareRequestScheme`, yang membacanya dari
`X-Forwarded-Proto`) lalu membandingkannya dengan header `Origin`. Tapi
`internal/httpapi/router.go` **membuang** header itu bila `TRUST_PROXY` bukan
`true` — dan `TRUST_PROXY` tidak ada sama sekali di `.env` maupun
`.env.example`; hanya `docker-compose.yml` yang menyetelnya. Siapa pun yang
menjalankan `justclick serve` langsung — persis yang tertulis di bagian
"Jalankan ulang" setiap dokumen fase — lalu menaruh TLS di depannya, mendapat
browser ber-`Origin: https://…` dan server yang membandingkannya dengan
`http://…`. Setiap POST panel ditolak, termasuk login, tanpa satu baris log pun.

**2. Panel platform menyuruh browser menahan `Referer`-nya sendiri.**
`securityHeaders` memasang `Referrer-Policy: no-referrer` di seluruh
`/platform` — ditambahkan bersama panelnya (commit `0a1dfcf`, 15 September),
sehari sebelum akun super admin pertama dibuat. Saat sebuah browser tidak
mengirim `Origin` pada form POST — beberapa browser memang tidak, untuk POST
sesama origin — `gorilla/csrf` jatuh ke pemeriksaan `Referer`, yaitu header
yang baru saja kita larang sendiri. Panel menolak login-nya sendiri.

### Perbaikan

| Perubahan | Berkas |
|---|---|
| `Referrer-Policy` panel platform `no-referrer` → `same-origin`. Masih tidak bocor ke situs lain, tapi fallback CSRF hidup kembali | `internal/platform/handler.go` |
| Penanganan kegagalan CSRF bersama: **mencatat** alasan, `origin`, `referer`, `host`, `x_forwarded_proto` dan skema yang disimpulkan server, lalu menampilkan halaman 403 yang bisa dibaca orang — bukan satu baris telanjang | `internal/infra/web/csrf.go` (baru), dipasang di kedua panel |
| `TRUST_PROXY` didokumentasikan beserta akibat salah setelnya | `.env.example`, `.env` |
| `HTTP_ADDR` dan `METRICS_ADDR` default ke `127.0.0.1`, bukan semua antarmuka | `.env.example`, `.env` |

Sesudah perbaikan, penolakan yang sama menghasilkan baris log ini — setiap
angka yang menentukan vonisnya ada di dalamnya:

```
level=WARN msg="CSRF refused a request" path=/platform/login method=POST
  reason="referer not supplied" origin="" referer="" host=localhost:8443
  x_forwarded_proto=https server_read_it_as_https=true
```

### Uji mutasi

`OverTLS` dirusak (proxy diabaikan) → `TestAnHTTPSOriginIsAcceptedWhenTheProxySaysTheBrowserUsedHTTPS`
dan `TestARefusalIsLoggedWithWhatDecidedIt` **gagal**; dipulihkan (file identik
byte-per-byte) → lulus. Sembilan test baru di `internal/infra/web` dan
`internal/platform` mengunci kedua arah: `Origin` https di balik proxy
diterima, `Origin` lintas-situs tetap ditolak, browser yang hanya mengirim
`Referer` diterima, dan browser yang disuruh menahan keduanya ditolak.

## Temuan lain yang ikut diperbaiki

| Temuan | Perbaikan |
|---|---|
| **Port 9000 dan 9090 terbuka ke seluruh jaringan lokal.** `HTTP_ADDR=:9000` mengikat `::`, jadi `/backoffice`, `/platform` dan `/metrics` dapat dijangkau lewat HTTP polos dari perangkat lain — di sebelah pintu yang dikunci Caddy | Default loopback di `.env.example`; Compose tetap `:9000` karena di sana ikatannya jaringan Docker, bukan host |
| **Kontainer `api` di-SIGKILL pada 10 detik** padahal kodenya menunggu 30 detik untuk drain — setiap deploy memutus request yang sedang berjalan | `stop_grace_period: 35s` |
| **Tidak ada CORS di API**, sehingga till versi web tidak bisa memanggil API dari origin lain | Blok dev di `Caddyfile`: bundel web dan `/api/v2` disajikan dari satu origin (`http://localhost:8090`), tanpa menambah kode CORS ke produk |

## Bukti "ketiganya terhubung"

Dijalankan terhadap kontainer lewat Caddy HTTPS.

| Bukti | Skrip | Hasil |
|---|---|---|
| Kode aktivasi yang dicetak **di browser** mengaktifkan till lewat `POST /api/v2/devices/activate` | `verify-backoffice` | lulus |
| Baris yang dibuat di browser ditarik till yang diaktifkan dari browser yang sama; rename outlet sampai ke binding perangkat seketika | `verify-backoffice-crud` | lulus |
| Siklus hidup perangkat penuh: aktivasi lewat endpoint sungguhan, 240 baris tertarik dari semua feed, laci dibuka, 3 struk diterima, 1 gerakan stok, sinkron ulang melihat gerakannya sendiri | `loadtest smoke` | lulus |
| Uang: 200 baris ×3 idempoten, audit utuh, partisi benar | `verify-push` | lulus |
| Suspend menghentikan till seketika; reaktivasi memulihkan token yang sama | `verify-platform` | lulus |
| Laporan dari rollup, ekspor, jadwal | `verify-reports` | lulus |

Sepuluh verifier live lulus seluruhnya: activation, sync, push, stock, tables,
backoffice, backoffice-crud, platform, reports, dan `loadtest smoke`.

**Yang tetap harus dilakukan manusia**: mengetik kode aktivasi di layar till,
masuk dengan PIN, dan membuat penjualan lewat UI. Tidak ada alat pengendali
browser di lingkungan ini, dan Flutter menggambar ke kanvas sehingga tidak ada
elemen DOM untuk diklik. Langkahnya ada di `../../docs/MANUAL_TEST_LOKAL.md`,
dan stack-nya sudah disiapkan sampai tinggal klik: merchant `qa-lokal` sengaja
kosong, till versi web tersaji di `http://localhost:8090` dengan API di origin
yang sama.

## Sapuan regresi

| Pemeriksaan | Hasil |
|---|---|
| `go build ./...`, `go vet ./...` | Bersih |
| `go test ./... -count=1` (PostgreSQL 18 + Redis asli) | **27 paket lulus**, 0 gagal; **297 test top-level** (288 sebelumnya, 9 baru) |
| gofmt | Bersih kecuali tiga berkas `internal/infra/jobs` yang sudah bermasalah CRLF sejak Fase 8 dan tidak disentuh fase ini |
| Checkout bersih bisa dibangun | `git archive HEAD` ke direktori kosong → `go build ./...` dan `go vet ./...` lulus. Sebelum fase ini **tidak bisa**: `internal/infra/metrics/`, `ops/`, `scripts/loadtest/` dan migrasi 019 masih untracked padahal kode tracked meng-import-nya |
| `fvm flutter analyze` | 86 isu, **semuanya `info`**, 0 error, 0 warning |
| `fvm flutter test` | **663 lulus**, 2 di-skip (uji kontrak live yang butuh env var) |
| `-race` | Tidak dijalankan di mesin ini (butuh cgo); berjalan di CI Linux |

## Gerbang yang masih terbuka

- **Klik-tayang UI till belum dilakukan.** Semua yang ada di belakang layar
  sudah dibuktikan; layarnya sendiri menunggu satu orang dan sepuluh menit.
- **CI belum menjalankan konfigurasi ini** (belum di-push).
- Windows sebagai target till masih terblokir dua hal: toolchain Visual Studio,
  dan `sqflite` yang tidak punya implementasi Windows (`sqflite_common_ffi`
  hanya `dev_dependency`) sehingga build Windows gagal di panggilan database
  pertama. Belum pernah tercatat sebelum ini.
- Seluruh daftar prasyarat Fase 10 tetap terbuka: backup, TLS produksi,
  distribusi aplikasi, signing rilis, Alertmanager.
