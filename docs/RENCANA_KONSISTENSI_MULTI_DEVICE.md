# Rencana konsistensi multi-device, riwayat order, dan sesi kasir

Tanggal: 21 September 2026.
Status: **tahap B–F terimplementasi dan terverifikasi** (21 September 2026).
Koordinasi till online, pengikatan efek stok ke struk, riwayat server, penugasan
kasir dan rentang nomor struk sudah ada dan dibuktikan `scripts/verify-till`
(23 check lewat HTTP) serta empat test konkurensi di `internal/domain/ingest`.
Yang belum: tahap A (inventaris konflik pada data yang sudah terlanjur) dan
tahap G (pemulihan data + gerbang sebelum Fase 10). Lihat
`backend-go/CLAUDE.md`, bagian "Coordinated tills".
Posisi: stabilisasi tambahan setelah Fase 9/9.5; Fase 10 tetap ditunda.

## 1. Kesimpulan

Gejala yang dilaporkan cocok dengan implementasi saat ini. Aktivasi dua perangkat
pada till yang sama tidak membuat keduanya berbagi database lokal. Order dan sesi
hanya diunggah; server belum menyediakan jalur penarikan keduanya ke till lain.
Login PIN juga lokal, sehingga login akun yang sama tidak mengambil sesi global.

Server **sudah** memiliki unique index satu sesi terbuka per register. Celahnya:
aplikasi menganggap sesi lokal berhasil sebelum server mengesahkannya. Karena itu
dua layar yang sama-sama menunjukkan sesi terbuka belum berarti PostgreSQL
menyimpan dua sesi terbuka pada register yang sama.

Perbaikannya memerlukan pemisahan tiga hal: identitas perangkat, hak menjalankan
till, dan hak membaca riwayat. Menambah order ke daftar pull saja tidak cukup.

Analisis ini berdasarkan kode, migrasi, kontrak API, plan.md, dokumentasi proyek,
dan laporan pengguna. Tidak ada reproduksi dua perangkat, pengujian otomatis baru,
atau pemeriksaan isi database merchant pada analisis ini. Risiko turunan di bawah
adalah jalur yang ditemukan dalam kode, bukan klaim transaksi pengguna sudah hilang.

## 2. Temuan dan bukti

Path berikut relatif terhadap root repository.

| Prioritas | Temuan | Bukti kode | Dampak |
|---|---|---|---|
| P1 | Order dan sesi push-only | `backend-go/internal/domain/syncfeed/pull.go`, `Manifest()`: `pos_sessions` dan `orders` memiliki `Pull: false`; `mobile/lib/data/sync/catalogue_sync.dart`, `supportedEntities` | Perangkat baru tidak dapat memulihkan riwayat meskipun semua order sudah masuk server. |
| P0 | Pembukaan sesi hanya dikunci lokal | `mobile/lib/data/repositories/shift_repository.dart`, `open()` melakukan query, insert, dan enqueue di SQLite; `settings_provider.dart`, `openPosSession()` langsung mengadopsinya | Dua database perangkat bisa sama-sama mengizinkan transaksi pada till yang sama. |
| P0 | Penolakan server tidak mencabut sesi lokal | Unique index `pos_sessions_one_open_register` di `backend-go/migrations/20260913000012_financial_ingest.sql`; pemetaan `register_busy` di `internal/domain/ingest/ingest.go`; `mobile/lib/data/sync/dead_letter_store.dart`, `moveFromOutbox()` | Payload sesi masuk dead-letter, tetapi baris `shifts` tetap terbuka. Tidak ada transisi khusus untuk menghentikan checkout sesi yang ditolak. |
| P0 | Order dapat menunggu sesi yang tidak diterima | `backend-go/internal/domain/ingest/orders.go`: sesi tidak ada menghasilkan `dependency_pending`; outbox memproses sesi sebelum order | Retry order tidak akan selesai hanya dengan menunggu jika sesi induk sudah masuk dead-letter. Perlu pemulihan ketergantungan. |
| P0 | Efek stok tidak bergantung pada penerimaan order | `mobile/lib/data/sync/stock_movement_push.dart` tidak mengirim order/session ID; `backend-go/internal/domain/stock/stock.go`, `RecordFromDevice()`; `ingest.go` memakai transaksi per baris | Gerakan stok dapat diterima saat order belum diterima atau ditolak. Angka stok dan laporan penjualan dapat berbeda tanpa jejak hubungan order yang kuat. |
| P1 | Banyak perangkat boleh terikat satu till | `backend-go/internal/domain/devices/devices.go`, `Activate()`: upsert berdasarkan `(tenant_id, device_uuid)`; tidak mengganti perangkat lain pada register | Kode baru untuk instalasi baru menambah perangkat, bukan otomatis memindahkan kepemilikan till. |
| P1 | Tidak ada eksklusivitas kasir lintas perangkat | `mobile/lib/data/repositories/employee_repository.dart`, `verify()` memeriksa PIN lokal; `pos_sessions` menyimpan employee ID dalam payload, tanpa constraint sesi per kasir | Akun yang sama bisa dipakai bersamaan; server mengunci register, bukan penugasan kasir. |
| P1 | Nomor struk bisa berulang sesudah ganti perangkat | `mobile/lib/data/repositories/order_repository.dart`, `_nextNumber()` memakai MAX lokal; komentar kode mengakui batas dua perangkat | UUID tetap berbeda, tetapi dua struk dapat memiliki label sama. Reinstall/replacement juga relevan walau perangkat tidak berjualan bersamaan. |
| P1 | Pengaturan bisnis belum menjadi feed bersama | `mobile/lib/data/preferences/app_preferences.dart` menyimpan PB1/service charge/alamat lokal; feed registry tidak memiliki business settings; `connected_storage.dart` hanya menyiapkan binding dan nama toko | Dua instalasi bisa menghitung total atau mencetak identitas toko berbeda. Nilai default bukan konfigurasi merchant yang telah disahkan. |
| P1 | Konteks aktif tidak seluruhnya diperbarui setelah pull | `mobile/lib/providers/synced_data.dart` menyegarkan katalog/staf/meja, tetapi tidak settings/POS context; role aktif disalin saat `SettingsNotifier.signIn()` | Perlu regression test perubahan role/active staf dan `table_service` saat aplikasi sudah login; refresh daftar staf saja tidak membuktikan izin sesi aktif berubah. |
| P2 | Hari bisnis dan cakupan history berbeda dari ekspektasi pengguna | `mobile/lib/providers/order_provider.dart`: kasir melihat miliknya hari ini; `OrderRepository.recent()` default 50 baris; `wire_values.dart`, `businessDateFor()` memakai tanggal perangkat | Riwayat lengkap memerlukan pagination dan kebijakan tanggal. Zona waktu perangkat berbeda dapat memisahkan transaksi pada hari berbeda. |

P0 = konsistensi operasional/keuangan, perlu diselesaikan sebelum uji multi-device
dianggap lulus. P1 = fungsi inti atau integritas integrasi; P2 = kejelasan cakupan.

### Mengapa riwayat kosong

`DeviceRegistration.storageScope` menghitung hash dari API URL, tenant ID,
device ID, dan register ID. `prepareConnectedStorage()` membuka store terpisah
dan tidak menyalin transaksi dari store lain. `OrderRepository.recent()` hanya
membaca SQLite pada store tersebut. Tidak ada request server pada pencarian history.

Browser context yang meminta aktivasi baru dapat merepresentasikan instalasi baru;
URL/origin berbeda atau storage yang hilang juga perlu diperiksa. Tidak cukup
menyimpulkan bahwa sekadar membuka tab baru selalu menciptakan device baru.
Riwayat kosong pada device B sendiri tidak membuktikan order device A gagal upload.

### Skenario kegagalan sesi

1. A dan B teraktivasi pada register R, masing-masing punya database lokal kosong.
2. A membuat sesi SA, B membuat SB. Keduanya lolos pengecekan lokal.
3. SA diunggah lebih dulu dan diterima; SB ditolak `register_busy`.
4. SB disimpan di dead-letter, tetapi aplikasi B masih memiliki sesi lokal terbuka.
5. Order B yang merujuk SB mendapat `dependency_pending`; gerakan stoknya dapat
   diproses sendiri. Ini perlu reproduction test, bukan diasumsikan telah terjadi.

Unique index server melindungi dua baris yang saat ini sama-sama terbuka. Ia tidak
melarang interval historis yang tumpang tindih: sesi kedua yang pertama kali
diunggah dalam keadaan sudah tertutup tidak masuk predicate unique index.
`DeadLetterStore.requeueAll()` juga dapat mengirim ulang snapshot terkini sesudah
till bebas. Karena itu, generic retry tidak boleh dianggap penyelesaian konflik laci.

## 3. Perilaku produk yang direkomendasikan

Ini usulan default untuk implementasi berikutnya, bukan keputusan produk yang
sudah disetujui atau fitur yang sudah ada.

| Konsep | Aturan yang disarankan |
|---|---|
| Perangkat | Instalasi yang memiliki credential, cache, dan outbox sendiri. Aktivasi tidak otomatis memberikan hak berjualan pada till yang sedang dipakai. |
| Till/register | Satu titik transaksi/laci; maksimal satu perangkat pemegang hak berjualan aktif. Perangkat lain boleh menjadi pembaca sesuai izin. |
| Sesi POS | Masa tanggung jawab atas laci. Harus disahkan server sebelum checkout pertama. Menutup lokal belum berarti till telah bebas di server. |
| Kasir | Maksimal satu penugasan berjualan aktif per tenant. Login untuk membaca riwayat tidak perlu dihitung sebagai penugasan berjualan. |
| Handover kasir | Dapat mempertahankan sesi/laci yang sama. Penanggung jawab awal, kasir saat ini, dan pembuat tiap order harus tetap terpisah dalam audit. |
| Ganti perangkat normal | Perangkat lama drain outbox dan selesaikan sesi; server melepas hak; perangkat baru mengambil hak dan membuka sesi baru. History lama tetap dapat dibaca. |
| Dua perangkat ingin berjualan bersamaan | Gunakan dua till terpisah dan penugasan kasir yang sesuai. Dukungan beberapa writer dalam satu till adalah fitur lain yang perlu desain khusus. |

Jangan menambahkan unique index berdasarkan *pembuka sesi* sebagai satu-satunya
pengaman kasir. Handover yang sudah ada membolehkan kasir lain berjualan dalam
sesi yang sama: eksklusivitas harus mengikuti penugasan aktif, bukan nama opener.

### Batas offline yang harus dinyatakan

- Membuka sesi baru, berpindah perangkat, atau mengambil penugasan kasir baru
  membutuhkan konfirmasi server. Login offline untuk melanjutkan penugasan yang
  sudah tersimpan masih dapat disediakan.
- Sesi yang telah disahkan boleh melanjutkan penjualan saat jaringan putus.
  Server tetap memegang reservasi till dan kasir sampai pelepasan eksplisit.
- Tidak memakai timeout heartbeat untuk otomatis memberikan till ke perangkat
  kedua. Perangkat pertama bisa masih menjual saat offline.
- Penutupan offline masuk `closing_pending`; checkout lokal berhenti, tetapi
  reservasi server baru dilepas setelah penutupan dan antrean terkait terkonfirmasi.
- Darurat perangkat rusak/hilang memerlukan alur manager dengan audit dan rekonsiliasi.
  Server tidak dapat seketika menghentikan aplikasi lain yang sedang offline.
  Hak lama diberi generation berbeda; upload tertunda masuk jalur recovery yang
  mempertahankan bukti, bukan dibuang sebagai transaksi tidak sah.
- Riwayat hanya bisa sama untuk transaksi yang sudah mencapai server. Transaksi
  yang hanya ada pada perangkat offline tidak dapat diketahui perangkat baru.

## 4. Rencana implementasi berurutan

### A. Reproduksi dan inventaris konflik (P0)

Gunakan tenant uji khusus; jangan reset data merchant yang sedang diperiksa.
Siapkan dua instalasi independen, satu register, satu kasir. Catat session UUID,
order UUID, device UUID, status outbox/dead-letter, sesi server, ledger stok, dan
laporan. Uji urutan push A/B, kedua perangkat offline, close sebelum push pertama,
serta retry setelah sesi pemenang ditutup. Pisahkan bukti lokal, respons HTTP,
baris server, dan rollup yang memang dapat tertunda.

Deliverable: regression test pada Go ingest dan Flutter sync, fixture dua device
pada till yang sama, serta daftar data konflik yang perlu dipulihkan. Test stok
dua till yang sudah ada tetap berguna, tetapi tidak menggantikan skenario ini.

### B. Bekukan kontrak sesi dan penugasan server (P0)

- Tambahkan operasi idempoten untuk claim/open, current status, handover, close,
  dan release. Request ID dipersist sebelum dikirim; respons hilang dipulihkan
  lewat query/retry ID sama, tanpa membuat sesi kedua.
- Modelkan pemegang till dan penugasan kasir aktif beserta generation. Lock hanya
  register/assignment terkait, dengan urutan lock tetap; jangan lock tenant.
- Validasi identitas kasir, status aktif, izin dan scope tenant/outlet pada server.
  Jangan mempercayai employee ID yang sekadar dikirim perangkat. Definisikan
  autentikasi kasir untuk operasi online tersebut, rate limit PIN, dan capability
  yang mengikat tenant/register/device/session/employee/generation.
- Pertahankan constraint satu sesi terbuka per register. Tambahkan pengaman
  penugasan kasir aktif; opening snapshot dan handover dicatat terpisah.
- Normal replacement hanya setelah drain dan close terkonfirmasi. Forced takeover
  adalah operasi terpisah; credential recovery tidak memberi hak membuat order baru.
- Penutupan membutuhkan high-water mark operasi lokal/acknowledged outbox agar
  order atau gerakan stok yang belum tiba tidak tertinggal diam-diam. Penghitungan
  kas server dan selisihnya harus bisa diaudit; jangan otomatis menimpa hitungan fisik.
- Pada ingest, validasi bukti session/device/generation. Tetap terima retry valid
  dan transaksi offline sah yang terlambat setelah close; pisahkan dari checkout
  baru sesudah close. Waktu perangkat saja tidak cukup membuktikan kewenangan.
- Skema baru lewat migrasi aditif dan version/capability gate; legacy client tidak
  boleh terus membuka sesi melalui push lama setelah aturan ketat diaktifkan.

Deliverable: OpenAPI, state transition, skema dan test konkurensi dua request/two
pool. Gate: tepat satu claim berhasil, retry claim menghasilkan sesi yang sama,
dan sesi gagal tidak dapat menjadi dasar penjualan baru.

### C. Terapkan state sesi di Flutter (P0)

- Bedakan `opening_pending`, `active_confirmed`, `closing_pending`, `closed`,
  `conflict`, dan `recovery_required`; konektivitas adalah status terpisah.
- Checkout memeriksa sesi terbuka yang disahkan, pemegang perangkat, dan penugasan
  kasir di repository dalam transaksi. Saat ini `OrderRepository.create()` hanya
  memeriksa register pada sesi, bahkan tidak memeriksa `closed_at` pada query itu.
- Simpan capability/identitas sesi secara tahan crash; startup memulihkan status
  dengan aman, tanpa mengandalkan sukses navigasi UI.
- `register_busy` atau penolakan otoritas memblokir checkout berikutnya dan menampilkan
  sesi/perangkat pemegang serta tindakan penyelesaian. Tetap simpan order lama.
- Dependency order yang induknya ditolak masuk alur konflik yang terlihat, bukan
  retry tanpa akhir. Generic requeue tidak boleh diam-diam mengesahkan konflik laci.
- Handover, logout, restart, dan penyegaran staf/role harus mengikuti aturan sesi
  yang sama. Dua tab yang berbagi device credential juga perlu single-writer guard
  lokal agar tidak dianggap dua POS aktif yang sah.

### D. Ikat efek penjualan ke order (P0)

- Tambahkan referensi stabil `order_id`, operation ID, dan konteks sesi pada efek
  stok sale/void/refund. `note` nomor struk tidak memadai sebagai foreign identity.
- Usulan awal: kumpulan efek stok satu operasi divalidasi lengkap dan di-commit
  atomik bersama operasi order terkait. Pertahankan ledger movement UUID dan
  deduplikasi; jangan mengurangi stok sekali dari payload lama dan sekali dari
  mekanisme baru. Gerakan manual/opname tetap memiliki otoritas tersendiri.
- Urutan batch saja tidak memberi atomicity. Tentukan envelope/capability baru,
  aturan incomplete group, retry, dan batas ukuran transaksi pada kontrak.
- Penolakan order mempertahankan seluruh bukti operasi untuk recovery. Tidak ada
  stock return dari refund yang gagal disahkan. Nilai refund parsial dan kuantitas
  barang yang benar-benar kembali adalah data berbeda.
- Audit efek status meja bersama checkout/void; status meja boleh eventual, tetapi
  konflik/penolakan order tidak boleh tersembunyi di balik meja yang tampak normal.
- Rekonsiliasi ledger lama vs order dengan audit; jangan menganggap seluruh movement
  lama dapat dipasangkan otomatis dari label struk yang mungkin berulang.

### E. Sediakan riwayat server dan cache perangkat (P1)

- Tambahkan API baca daftar/detail order dan sesi, dengan pagination cursor stabil,
  snapshot/anchor untuk paging, filter rentang tanggal/till/kasir, serta update cursor
  untuk perubahan status. Jangan full-download seluruh histori tenant setiap startup.
- Default usulan: perangkat pengganti mengambil hari bisnis berjalan dan sesi terkait;
  riwayat lama diminta per halaman. Retensi cache diatur terpisah dari retensi server.
- Server menegakkan tenant/outlet/register dan akses kasir. Device token hanya
  membuktikan perangkat; query `cashier_id` tanpa otorisasi kasir tidak cukup untuk
  menjamin privasi transaksi rekan kerja. Manager mendapat scope sesuai permission.
- Gunakan cache baca server terpisah dari data yang boleh diunggah, atau metadata
  origin/ownership yang eksplisit. Gabungkan order lokal dan server berdasarkan UUID;
  revision/cursor mencegah duplikasi dan snapshot lama menimpa perubahan pending.
- Pull tidak boleh membuat outbox, mengulang pengurangan stok, mengubah nomor struk,
  atau membuat sesi historis bisa dipakai checkout. Cache satu sesi server pada
  device B tidak membuat B menjadi pemegang hak sesi itu.
- History menampilkan status tersinkron/pending/conflict dan waktu pembaruan. Sesudah
  restart, data cache tetap dapat dibaca offline sesuai scope pengguna.
- Untuk tahap pertama, order dari perangkat lain read-only. Void/refund lintas
  perangkat baru diaktifkan lewat command server berizin dan idempoten dengan
  expected revision. Backend sekarang menolak update order milik device lain.
  Jangan mencabut pengaman itu hanya agar hasil pull dapat diedit.
- Dashboard/laporan Flutter harus menyatakan apakah angka lokal, cached, atau agregat
  server. Histori yang hanya memuat beberapa halaman tidak boleh dihitung sebagai
  total outlet lengkap; gunakan agregat server untuk pertanyaan seluruh outlet.

### F. Konsistensi konfigurasi dan identitas struk (P1)

- Tambahkan konfigurasi bisnis server-owned: PB1, service charge, identitas/alamat
  struk, mata uang dan timezone. Lengkapi pengelolaan Backoffice bila belum tersedia.
  Tema, bahasa UI, dan printer tetap preferensi perangkat.
- Versioning konfigurasi; setiap order menyimpan snapshot tarif/konfigurasi yang
  benar-benar dipakai. Perubahan tarif tidak menghitung ulang struk lama.
- Gunakan timezone merchant/outlet yang disepakati untuk business date dan filter
  hari ini. Pertahankan tanggal historis; koreksi historis melalui audit tersendiri.
- Alokasikan rentang nomor struk per register secara atomik dari server untuk
  pemakaian offline, disimpan sebelum digunakan; rentang instalasi yang hilang
  tidak didaur ulang. Saat habis offline, gunakan fallback unik yang ditetapkan
  dalam kontrak. UUID tetap identitas utama, struk lama tidak dinomori ulang.
- Pull perubahan role/active staf dan konfigurasi register harus memperbarui context
  login/POS yang sedang aktif. Definisikan keterlambatan revokasi saat offline;
  jangan menjanjikan perubahan izin real-time pada perangkat terputus.

### G. Pemulihan data dan gerbang verifikasi (sebelum Fase 10)

- Inventaris session/order/dead-letter yang sudah konflik sebelum memasang constraint
  baru. Jangan menghapus SQLite, mengosongkan outbox, atau menyalin file database antar
  device sebagai migrasi. Preserve UUID, revision, kepemilikan asal, dan payload audit.
- Buat alur manager untuk sesi konflik, order dependen, perangkat hilang, dan stock
  effects yang belum terpasangkan. Tidak otomatis menggabungkan dua laci atau mengubah
  `pos_session_id` order yang sudah diterima server.
- Version gate diuji pada client lama/baru. Rollback aplikasi tidak boleh membuka
  kembali jalur claim lama atau menggandakan efek stock.
- Tambahkan indikator jumlah konflik/dependency tertahan, ownership mismatch, dan
  reconciliation gap; antrean kosong saja bukan bukti tidak ada dead-letter.
- Perbarui manual test dan memory proyek setelah implementasi; catat bukti lulus
  aktual. Dokumen fase lama tetap bukti untuk cakupan lama, bukan bukti fitur baru.

## 5. Acceptance test wajib

| Skenario | Hasil yang harus dibuktikan |
|---|---|
| A menjual, push selesai; B aktivasi pada till/kasir sama | B melihat order server sesuai izin tanpa duplikasi; B tidak memperoleh hak jual selama A masih memegang till. |
| A dan B bersamaan open pada till sama | Tepat satu claim sah. Yang kalah tidak bisa checkout, identitas pemegang jelas. |
| Kasir sama pada dua till berbeda | Penugasan jual kedua ditolak; login baca riwayat tetap sesuai kebijakan. |
| A offline dengan sesi sah; B mencoba mengambil till | B tidak otomatis mendapat hak karena heartbeat A hilang. Penjualan offline A tetap tersimpan. |
| Respons open/close hilang, restart, retry | Tidak membuat sesi ganda; status dapat dipulihkan berdasarkan operation ID. |
| Close offline, lalu perangkat lain mencoba open | Till belum dilepas sebelum finalisasi server; checkout lokal pada sesi closing berhenti. |
| Dua sesi lama tumpang tindih, termasuk pertama kali push sudah closed | Terdeteksi sebagai konflik/recovery; tidak lolos hanya karena unique partial index tidak terpicu. |
| Session rejected, order dependen, stock sale | Semua bukti dipertahankan; tidak ada retry tersembunyi atau efek stok yatim pada protokol baru. |
| Push diterima tetapi respons hilang; retry x3 | Satu order, satu set movement; ledger dan laporan tidak berlipat. |
| B membaca/pull order A lalu sync | Tidak mengunggah ulang order A dan tidak mengurangi stok lagi. |
| Remote order dibatalkan/refund | Versi cache berubah, efek hanya sekali; writer usang ditolak; refund serentak diuji sebelum mutasi remote dibuka. |
| Normal replacement A ke B | Outbox A drain, sesi ditutup dan hak dilepas, B membuka sesi baru dengan history dan nomor struk tidak berulang. |
| Forced replacement saat A hilang/offline | Audit takeover dan recovery transaksi terlambat tersedia; tidak menjanjikan remote stop instan. |
| Tenant/outlet/kasir lain meminta history/detail/session | Server menolak sesuai scope, termasuk ID yang ditebak dan filter yang dimanipulasi. |
| Role/active staf dan table_service berubah saat login | Context/permission aktif menyusul perubahan setelah sync; operasi baru mengikuti konfigurasi terbaru. |
| Tarif/zona waktu berubah, perangkat melintasi tengah malam | Struk lama tetap sama; business date, history dan laporan baru konsisten pada policy yang sama. |
| Banyak halaman history dan koneksi putus saat pull | Tidak ada baris terlewat/ganda; cursor hanya maju bersama cache yang berhasil commit; resume aman. |
| Browser dua tab, reinstall, storage baru, device ID berubah | Tidak ada silent multi-writer; recovery/claim eksplisit, nomor tidak didaur ulang. |

Gerbang akhir: backend test konkurensi/isolation dan migrasi, Flutter repository/
state/widget test, kontrak live dua instalasi, UAT browser + emulator, serta uji
beban pada endpoint claim/history dan ingest setelah perubahan atomicity stok.
Keberhasilan A → Backoffice tidak menggantikan bukti A → server → B.

## 6. Batas dan urutan pengerjaan

Urutan: **A → B → C → D → E → F → G**. Rancangan E dan F perlu diketahui saat
membekukan kontrak B; tahap implementasi dapat dipecah menjadi PR kecil dengan
feature gate, tanpa mengaktifkan setengah kontrak untuk pengguna.

Keputusan yang perlu dipastikan ketika implementasi dimulai: scope penugasan kasir
(usulan per tenant), kebutuhan pindah perangkat di tengah sesi (usulan awal close
lalu open baru), rentang history default, dan prosedur darurat perangkat hilang.
Default yang direkomendasikan sudah dijelaskan agar tahap analisis tidak menunggu
keputusan tersebut.

Untuk uji lokal sebelum perbaikan: pakai satu perangkat aktif per till, sinkronkan
dan tutup sesi sebelum pindah, periksa pending **dan** rejected, dan gunakan
Backoffice untuk melihat transaksi server. Jangan hapus storage perangkat yang
masih memiliki transaksi pending/conflict. Langkah ini mengurangi risiko pengujian;
belum menyediakan history lintas perangkat yang memang belum diimplementasikan.
