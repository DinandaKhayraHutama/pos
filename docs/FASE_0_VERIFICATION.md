# Fase 0 — bukti verifikasi

**Tanggal:** 22 September 2026
**Acuan rencana:** [RENCANA_IMPLEMENTASI_FASE_0.md](RENCANA_IMPLEMENTASI_FASE_0.md)
**Panduan klik manual:** [MANUAL_TEST_LOKAL.md](MANUAL_TEST_LOKAL.md) bagian F dan G

Dokumen ini mencatat apa yang benar-benar dijalankan, dengan perintahnya, dan —
sama pentingnya — **apa yang belum bisa dibuktikan di mesin ini**. Bagian
"Belum lulus" adalah bagian yang menentukan apakah Fase 0 boleh dianggap
selesai untuk tujuan tertentu.

## Ringkasan per workstream

| # | Workstream | Bukti | Status |
|---|---|---|---|
| F0.1 | Baseline diagnostik | `DiagnoseTill` + `justclick diagnostics till`; `RecoveryInspector` + Recovery Center POS; kartu "Diagnostik sinkronisasi" di Backoffice | Lulus otomatis |
| F0.2 | SQLite native Windows/Linux | `db_platform_io.dart` memasang factory FFI; `native_file_persistence_test` menulis, menutup, membuka ulang **berkas sungguhan di Windows** | Lulus sebagian — lihat "Belum lulus" |
| F0.3 | Kontrak till di OpenAPI | 6 endpoint `/till/*` + skema recovery; `contract_test` mencocokkan tipe Go yang dibangkitkan terhadap spesifikasi | Lulus otomatis |
| F0.4 | Model recovery | Migrasi `20260922000021_till_recovery`; RLS per tenant; turun-naik bersih | Lulus otomatis |
| F0.5 | Takeover Backoffice | `verify-recovery` mengemudikan form takeover di browser, termasuk penolakannya | Lulus otomatis |
| F0.6 | Recovery Center | `verify-recovery` untuk sisi Backoffice; `recovery_inspector_test` + `outbox_push_test` untuk sisi POS | Lulus otomatis; UI POS belum diklik manual |
| F0.7 | Gerbang verifikasi | Gate di bawah; CI Flutter dan langkah roll-down ditambahkan ke workflow | Lulus sebagian — workflow belum pernah berjalan |

## Gate yang dijalankan

Lingkungan: Windows 11, PostgreSQL 18 dan Redis dari `docker compose`,
**API dijalankan sebagai proses host** `go run ./cmd/justclick serve` pada
`127.0.0.1:9000` (alasannya di "Belum lulus"). Flutter 3.38.9 lewat FVM.

### Backend

```powershell
cd backend-go
go build ./... ; go vet ./...
templ generate                       # 0 pembaruan: kode templ yang di-commit sudah segar
go run ./cmd/justclick migrate down ; go run ./cmd/justclick migrate up
go test ./... -count=1
go run ./scripts/verify-till
go run ./scripts/verify-recovery
```

| Gate | Hasil |
|---|---|
| `go build ./...`, `go vet ./...` | lulus |
| `templ generate` | 0 pembaruan — `devices_templ.go` yang di-commit cocok dengan `.templ`-nya |
| Migrasi 021 turun lalu naik | lulus; `till_recoveries` kembali kosong, `pos_sessions.close_kind` kembali `normal` |
| `go test ./... -count=1` | **314 test tingkat atas pada 28 paket, 0 gagal** |
| `verify-till` | **31/31 lulus** |
| `verify-recovery` | **48/48 lulus** |
| Seluruh verifier lain, dijalankan dalam urutan CI | lulus — tidak ada regresi dari perubahan Fase 0 |

Hitungan per skrip pada sapuan terakhir, dalam urutan yang dipakai CI:

| Skrip | Lulus |
|---|---|
| `verify-activation` | 17 |
| `verify-backoffice` | 21 |
| `verify-backoffice-crud` | 103 |
| `verify-sync` | 61 |
| `verify-push` | 8 |
| `verify-stock` | 12 |
| `verify-tables` | 20 |
| `verify-till` | 31 |
| `verify-recovery` | **48** |
| `verify-reports` | seluruhnya lulus |
| `verify-platform` | 60 |

`verify-recovery` adalah skrip baru Fase 0. Yang dibuktikannya, lewat HTTP dan
bukan lewat pemanggilan domain:

- halaman Perangkat menyebut siapa memegang tiap laci, dan menawarkan takeover
  hanya untuk register yang punya laci terbuka;
- takeover ditolak bila nama till yang diketik tidak cocok, bila alasannya
  kosong, dan bila kas terhitung bukan rupiah — **laci tetap terbuka** setelah
  penolakan;
- takeover yang dikonfirmasi menutup laci sebagai `forced`, mencabut perangkat,
  melepas kasir aktif, dan membatalkan kode aktivasi yang masih hidup, **dalam
  satu transaksi**; snapshot kasnya `modal awal + penjualan tunai` dan kas
  hitungan manager disimpan **di sebelahnya**, bukan menggantinya;
- instalasi yang sama dapat diaktifkan ulang ke **baris perangkat yang sama**,
  sehingga kasus recovery masih mengenalinya;
- tiga retry identik + satu penjualan kedua = **dua** item karantina, dan
  tidak satu pun menyentuh `orders`, `stock_movements`, atau antrean laporan;
- kasus tidak bisa ditutup selama ada item pending; penolakan butuh alasan;
- penerimaan menulis **tepat satu** order, satu efek stok, satu `report_dirty_slices`;
  menerima dua kali dan retry till sesudahnya tidak menambah apa pun;
- jejak audit lengkap dan berurutan:
  `takeover,item_found,item_found,item_discarded,item_accepted,reconciled`;
- kas laci pengganti tidak tersentuh oleh semua itu.

Diagnostik CLI dijalankan terhadap tenant `QA Lokal` yang sudah ada dan
menemukan konflik nyata, bukan hasil buatan:

```json
{ "status": "conflict", "findings": [ { "classification": "conflict",
  "code": "open_session_without_claim", "entity": "pos_session",
  "entity_id": "7c2e1ca1-e040-4921-8db7-5837658441bf",
  "action": "Inspect the register and create a controlled recovery before assigning another device." } ] }
```

### Till

```powershell
cd mobile
fvm flutter analyze --no-fatal-infos
fvm flutter test
fvm flutter build apk --debug
```

| Gate | Hasil |
|---|---|
| `flutter analyze` | 83 temuan, **semuanya `info`** — tidak ada error atau warning. Sebagian besar `avoid_print` di `integration_test/`, yang memang disengaja |
| `flutter test` | **689 lulus, 2 dilewati, 0 gagal** |
| `native_file_persistence_test` (Windows) | berkas sungguhan ditulis, ditutup, dibuka ulang; `categories`, `_outbox` dan `_dead_letter` utuh; `PRAGMA user_version` = 29; `PRAGMA foreign_keys` = 1 |
| `recovery_migration_test` | database v28 berisi antrean dan state till naik ke v29 **tanpa kehilangan baris**; kolom `recovery_id` / `recovery_detected_at` bertambah |
| `flutter build apk --debug` | lulus, 220 MB. APK-nya **tidak** memuat `libsqlite3.so` — Android tetap memakai plugin platform `sqflite`, jadi memindahkan `sqflite_common_ffi` ke dependency utama tidak menambah beban native di Android |
| `build/native_assets/windows/sqlite3.dll` | ada — pipeline native assets menyelesaikan pustaka SQLite untuk Windows di host ini |

Audit lanjutan memasang ulang APK debug pada Android emulator, menghentikan
paksa aplikasi, mengambil snapshot connected store, membuka aplikasi kembali,
dan menghentikannya lagi. Kedua snapshot identik: `PRAGMA user_version = 29`,
satu shift yang sudah ada tetap tersimpan, dan hash SHA-256 berkas database tidak
berubah. Ini membuktikan reopen/force-stop mempertahankan connected store;
skenario transaksi yang masih berada di outbox tetap menjadi bagian UAT F dan G.

## Cacat yang ditemukan selama UAT dan audit lanjutan

Sebagian alur eksplorasi di bagian F dijalankan manual oleh pemilik produk pada
22 September 2026 dan menemukan lima hal yang lolos dari baseline 314 test Go
dan 668 test Flutter. Skenario F dan G secara lengkap belum dijalankan dari awal
sampai akhir; status itu dicatat di bagian "Belum lulus".

1. **Laci yang tidak bisa dilanjutkan maupun ditutup dari till — tombol mati.**
   Picker till membaca tabel `shifts`, sedangkan `_resolvePosContext` membaca
   `_till_sessions`. Sebuah sesi terbuka tanpa izin server ditawarkan sebagai
   **"Lanjutkan"**, lalu ketukannya diselesaikan kembali menjadi "tidak ada
   sesi": tidak ada yang terjadi, tidak ada pesan, dan kasir tidak bisa keluar
   dari layar itu. Keadaan ini nyata — sesi yang sampai ke server lewat jalur
   push legacy tidak punya baris `till_claims`. **Perbaikan:**
   `TillCoordinator.holdsPermit` menjadi satu-satunya definisi "boleh jual ke
   laci ini", dipakai resolver maupun picker; picker menampilkan keadaan
   keempat ("perlu manager") dan menjelaskannya saat diketuk; `_resume`
   memeriksa hasilnya sendiri. Regresi:
   `mobile/test/repositories/till_permit_test.dart`.

2. **Revoke yang terlihat tidak berlaku — loop aktivasi.** `BackendApp._revoked`
   hanya membersihkan state di memori. Binding tetap di secure storage, jadi
   peluncuran berikutnya mengadopsinya secara offline-first, kasir masuk, dan
   till baru kembali ke layar aktivasi ketika sinkron pertama 401 — yang
   menunggu `startupSpreadFor(deviceId)`, sampai lima menit. Berulang pada
   setiap peluncuran. **Perbaikan:** `DeviceActivationRepository.forget()`
   menghapus binding (dan **mempertahankan** uuid instalasi, agar aktivasi
   ulang tetap mendarat di baris `devices` yang sama dan kasus recovery masih
   mengenalinya). Regresi: `device_verify_test.dart`.

3. **`recovery_required` tanpa kasus — state yang tidak bisa diputuskan siapa
   pun.** `TillCoordinator.recover` menulis `recovery_required` setiap kali
   server tidak memegang klaim, termasuk ketika `recovery` null, sehingga
   Recovery Center menunjuk kasus yang tidak ada dan tidak ada yang bisa
   diterima atau ditolak di Backoffice. **Perbaikan:** tanpa id kasus,
   state-nya `conflict`.

4. **Perangkat tercabut tetap menampilkan till yang tampak berfungsi —
   selamanya, kalau dimuat ulang cukup cepat.** Startup spread
   (`hash(device_id) mod 300` detik) dimaksudkan meratakan lalu lintas **pull**
   satu fleet, tetapi ia juga menahan satu-satunya permintaan yang dapat
   menemukan pencabutan. Perangkat uji mengukur **186 detik**: setiap
   peluncuran memberi jendela 3 menit, dan memuat ulang lebih cepat dari itu
   membuat jendelanya tidak pernah habis. Ini di luar janji yang
   didokumentasikan ("revokasi instan ketika perangkat offline tidak
   dijanjikan") — di sini perangkatnya online dan aplikasinya yang memilih
   tidak bertanya. **Perbaikan:** `_accept` mengonfirmasi kredensial sekali per
   peluncuran lewat `_verify()`, di luar spread. Spread tetap berlaku untuk
   pull. Ini bukan menghidupkan kembali desain yang ditolak dulu — yang ditolak
   adalah poll `/devices/me` **periodik** tiap 30 detik dari 15.000 till, bukan
   satu pemeriksaan per peluncuran. Offline-first tidak berubah: `_verify`
   mempertahankan data merchant pada kegagalan jaringan dan hanya 401/403 yang
   mencabut. Bagian repository sudah dipin oleh
   `device_activation_repository_test.dart`; **wiring-nya sendiri belum punya
   test** (tidak ada harness widget untuk `BackendApp`), jadi langkah F6a dan
   F6b di panduan manual yang menutupinya.

5. **"Cannot be resumed" tidak pernah hilang, bahkan setelah takeover,
   rekonsiliasi, dan aktivasi ulang perangkat.** Dugaan pemilik produk benar:
   sesinya dibuat build lama, sebelum till terkoordinasi ada, jadi keluar lewat
   push outbox legacy dan `_save` tidak pernah menulis baris `_till_sessions`.
   `recover()` memilih kandidatnya dengan
   `FROM _till_sessions t JOIN shifts s` — **inner join**, sehingga laci tanpa
   baris izin tidak pernah terlihat: `recover()` langsung `return` dan lacinya
   tetap terbuka selamanya, tidak bisa dilanjutkan (tanpa izin) dan tidak bisa
   ditutup (tak ada yang merekonsiliasi). Aktivasi ulang tidak menolong karena
   query yang sama berjalan lagi. Cacat kedua di tempat yang sama:
   `tx.update('_till_sessions', …)` pada baris yang tidak ada mengubah **0
   baris**, jadi state-nya tak pernah tercatat. **Perbaikan:** query
   diekstrak menjadi `TillCoordinator.pendingDrawer` dengan **LEFT join** yang
   juga melihat laci tanpa izin (tetapi tidak menyentuh laci yang izinnya
   menyebut kasir lain), dan penulisannya menjadi upsert. `RecoveryInspector`
   juga menamai keadaannya sebagai `shift_without_till_permit`.

   Satu celah terakhir ikut ditutup: `recover()` hanya dipanggil dari `signIn`,
   jadi kasir yang sesi login-nya masih diingat dari peluncuran sebelumnya
   tidak pernah memicunya — satu-satunya jalan keluar adalah sign-out lalu
   sign-in, yang tidak akan ditebak siapa pun. **Mengetuk tile yang menolak
   sekarang menanyakannya ke server** dan mencerminkan jawabannya. Till tetap
   tidak memutuskan apa pun sendiri. Regresi:
   grup `pendingDrawer` di `till_permit_test.dart`, dan sisi server dipin oleh
   `TestTakeoverClosesADrawerThatHasNoClaim` — sesi tanpa klaim tetap
   menghasilkan pointer recovery, dan `CurrentTill` melaporkan "tidak ada
   klaim" **tanpa error**, sehingga till membaca `data: null` di samping
   pointer itu, bukan permintaan yang gagal.

Satu kode mati juga ditemukan dan dihapus dari `ForceTakeover`: sebuah
`tx.Exec("SELECT … FOR UPDATE")` atas `till_claims` yang dimaksudkan mewajibkan
adanya klaim. `Exec` membuang baris, jadi nol baris bukan error dan cabang
`ErrNoRows`-nya tidak pernah berjalan. Kebetulan itulah perilaku yang benar —
sesi tanpa klaim adalah kasus yang paling butuh takeover dan tidak punya jalan
keluar lain — jadi penjaga itu dihapus dengan alasannya dicatat, agar tidak ada
yang "memperbaikinya" menjadi syarat nyata dan mengunci merchant dari register
mereka sendiri. Regresi: `TestTakeoverClosesADrawerThatHasNoClaim`.

Audit lanjutan setelah lima perbaikan tersebut menemukan empat celah lagi dan
menutupnya sebelum pekerjaan Fase 1 dimulai:

1. State lokal `conflict` sebelumnya tidak dipilih lagi oleh `pendingDrawer`.
   Jika kasir memeriksa laci sebelum takeover, lalu manager baru melakukan
   takeover, POS berhenti mengirim `local_session_id` dan shift lokal dapat
   tertahan selamanya. State `conflict` dan `recovery_required` sekarang tetap
   diperiksa tanpa memberinya izin jual. Regresi:
   `till_permit_test.dart`.
2. Callback 401 menampilkan aktivasi sebelum penghapusan binding selesai, dan
   `forget()` menyembunyikan kegagalan secure storage. Callback sekarang
   asynchronous dan ditunggu oleh sync runner; aktivasi diblokir selama delete,
   kegagalan storage dilaporkan, serta sinyal revokasi tetap sampai ke aplikasi
   bila percobaan delete pertama gagal. Regresi: `device_verify_test.dart` dan
   `device_sync_runner_test.dart`.
3. Payload order lama tanpa `pos_session_id` menjalankan query SQLite dengan
   argumen null. Library saat ini hanya memperingatkan, tetapi versi berikutnya
   akan melempar exception. Jalur tanpa sesi sekarang melewati lookup permit dan
   tidak mengarang efek stok. Regresi: `outbox_snapshot_test.dart`.
4. Ketukan rekonsiliasi selalu menampilkan pesan error, termasuk ketika server
   berhasil memulihkan atau menutup sesi. `TillCoordinator.recover` sekarang
   mengembalikan hasil bertipe; UI membedakan sesi aktif, konflik, dan sesi yang
   ditutup untuk recovery dengan pesan lokal yang sesuai.

Hitungan setelah audit lanjutan: **689 test Flutter** (dari 668) dan **315 test
Go** tingkat atas (dari 314), semuanya lolos. Analyzer menghasilkan 83 temuan
level `info`, tanpa error atau warning.

## Belum lulus

Empat hal, dan tidak ada yang bisa diselesaikan dengan menulis kode:

1. **Build rilis Windows belum pernah dibuat.** `flutter build windows --release`
   berhenti dengan `Unable to find suitable Visual Studio toolchain`; Visual
   Studio tidak terpasang di mesin ini. Artinya bukti F0.2 berhenti pada
   "factory FFI bekerja terhadap berkas sungguhan di Windows di bawah
   `flutter test`" dan **belum** mencapai "`Runner.exe` yang dipaketkan
   menemukan `sqlite3.dll` saat dijalankan pengguna". `build/native_assets/windows/sqlite3.dll`
   membuat itu sangat mungkin berhasil, tetapi kemungkinan bukan bukti.
   Job `windows` pada workflow Flutter yang baru menjalankan build itu di
   `windows-latest`, jadi CI akan menutup celah ini begitu dijalankan.

2. **UAT manual bagian F dan G belum diselesaikan secara penuh.** Seluruh perilaku
   till Windows dan Android pada takeover — antrean yang tertahan saat offline,
   401 setelah pencabutan, Recovery Center POS, dan persistensi setelah
   aplikasi ditutup — baru dibuktikan oleh unit test dan oleh sisi server.
   Skenarionya sudah tertulis lengkap dan dapat diulang di
   [MANUAL_TEST_LOKAL.md](MANUAL_TEST_LOKAL.md) bagian F dan G. Ini
   memerlukan mesin dengan Visual Studio.

3. **Kedua workflow CI belum pernah berjalan.** `.github/workflows/flutter.yml`
   baru dibuat, dan langkah roll-down migrasi serta `verify-recovery` baru
   ditambahkan ke `backend-go.yml`. Keduanya sudah diverifikasi secara lokal
   dengan perintah yang sama, tetapi belum di runner GitHub.

4. **Sapuan seluruh verifier belum diulang dari container yang sama.** Sapuan
   awal seluruh skrip memakai proses API host karena build image saat itu gagal
   me-resolve `gcr.io/distroless/static-debian12`. Audit lanjutan berhasil
   menjalankan `verify-recovery` melalui API container di Caddy HTTPS dan lulus
   48/48. Verifier lain sudah lulus pada proses host; untuk angka beban, tetap
   ikuti aturan proyek dan ukur seluruh komponen melalui container.

## Catatan kejujuran

- **`golangci-lint` tidak dijalankan** — tidak terpasang di mesin ini. Job
  `lint` di CI menjalankannya.
- **`verify-activation` gagal satu check kalau dijalankan tepat setelah
  `verify-till`**, dan lulus 17/17 kalau dijalankan lebih dahulu — seperti dalam
  urutan CI. Penyebabnya state rate limiter di Redis yang dibawa skrip
  sebelumnya, bukan regresi. Jalankan `verify-activation` pertama, atau
  bersihkan kunci `rl:act:*`.
- **`verify-reports` gagal dua check bila worker berjalan di container
  sementara API berjalan di host.** Job ekspor diambil worker container dan
  ditulis ke `/var/lib/justclick/reports` di dalam container, lalu API host
  menyajikan `REPORTS_DIR`-nya sendiri dan menjawab 404 pada unduhan. Jalankan
  keduanya di sisi yang sama: `docker compose stop worker`, lalu
  `go run ./cmd/justclick worker` dengan `REPORTS_DIR` yang sama seperti server.
  Sesudah itu skripnya lulus seluruhnya. Bukan regresi Fase 0, tetapi mudah
  disalahartikan sebagai regresi.
- **Satu pemeriksaan diagnostik tidak dapat menyala.**
  `cashier_has_multiple_claims` mencari satu kasir yang memegang lebih dari satu
  claim, tetapi indeks unik `till_one_active_cashier` membuat keadaan itu tidak
  mungkin ada selama indeksnya berdiri. Pemeriksaan itu dibiarkan sebagai
  pertahanan berlapis, bukan karena sudah terbukti pernah menyala — jangan
  membacanya sebagai cakupan uji.
- **`gofmt -l` menandai tiga berkas** di `internal/infra/jobs/`. Ketiganya sudah
  begitu sebelum Fase 0 dan tidak tersentuh pekerjaan ini.
- Angka 314 test Go dan 668 test Flutter adalah baseline sebelum perbaikan UAT;
  kondisi kode sekarang adalah 315 test Go dan 689 test Flutter.
- **Satu berkas dihapus dari pekerjaan Fase 0:**
  `mobile/integration_test/_f0_android_sell_uat_test.dart` adalah salinan
  `sell_flow_test.dart` yang hanya berbeda pada pemanggilan
  `convertFlutterSurfaceToImage()` — pendekatan yang justru sengaja tidak
  dipakai repo ini, karena `screenshots_test.dart` menulis PNG-nya sendiri ke
  `build/screenshots/`. Suite E2E kembar yang akan menyimpang dari saudaranya
  bukan cakupan tambahan, dan kebijakan proyek melarang membuat suite E2E baru
  per fitur. UAT Android Fase 0 adalah bagian F di
  [MANUAL_TEST_LOKAL.md](MANUAL_TEST_LOKAL.md), bukan suite otomatis.
- **Recovery Center POS ditulis ulang untuk melewati `context.l10n`.** Versi
  pertamanya memakai string Bahasa Indonesia literal, termasuk teks tindakan
  yang dibuat di lapisan data (`RecoveryInspector`), padahal konvensi proyek
  melarang string user-facing literal. `LocalDiagnostic.action` kini berupa
  `enum RecoveryAction` dan teksnya dipilih di UI; 31 kunci baru ditambahkan ke
  `app_en.arb` dan `app_id.arb`.
