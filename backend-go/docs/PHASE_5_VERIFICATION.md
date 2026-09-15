# Fase 5 — stok

Tanggal: 14 September 2026. Acuan: `../../plan.md` (Fase 5), kontrak
`../api/openapi.yaml` v2.1.0, dan bagian "The stock ledger (Fase 5)" di
`../CLAUDE.md`.

Kriteria plan: *dua till menjual barang yang sama secara offline selama satu jam
konvergen ke kuantitas outlet yang benar setelah keduanya push; pusat melihat
angka yang sama.*

Status: implementasi server, Backoffice, dan klien Flutter selesai dan
diverifikasi lokal, termasuk lewat Caddy HTTPS terhadap API yang dibangun ulang.
Ini **bukan** UAT perangkat nyata; batasnya dicatat di bawah.

## Gerbang sebelum mulai

Empat blocker review Fase 4 diperbaiki dan diverifikasi lebih dahulu; lihat
adendum di `../../mobile/docs/PHASE_4_VERIFICATION.md`.

## Implementasi

### Server

- **Ledger append-only + proyeksi.** Migrasi `20260914000015_stock.sql`:
  `stock_movements` (tidak pernah diubah/dihapus) dan `outlet_stock`
  (`qty_on_hand` per outlet × produk). Setiap movement dan proyeksinya commit
  dalam satu transaksi. FK komposit per tenant, CHECK alasan/panjang teks,
  FORCE RLS, grant sama dengan tabel tenant lain.
- **Stok negatif diizinkan.** Kekurangan adalah fakta yang harus tercatat;
  till offline tidak bisa tahu pengiriman yang dibukukan Backoffice.
- **Opname = server menang.** Till mengirim `counted_qty` dan `basis_seq`;
  saat ingest server mengganti delta menjadi `counted − qty_on_hand` saat itu.
  `basis_seq` disimpan untuk audit.
- **Aturan tanda per alasan.** Dari till: `sale`/`waste` wajib negatif,
  `voidReturn`/`received` wajib positif, `correction`/`opening` tidak nol,
  `count` wajib membawa `counted_qty` ≥ 0 (dan hanya `count` yang boleh).
  `transferIn`/`transferOut` tidak bisa ditulis perangkat, hanya lewat transfer
  Backoffice. Pelanggaran ditolak per baris (`schema_rejected`), bukan per
  request.
- **Idempoten.** Advisory lock per UUID movement; retry identik (revisi boleh
  berbeda) dijawab dengan `stock_seq` dan `balance_after` yang pertama kali
  tercatat, tanpa movement baru. UUID sama dengan isi berbeda, atau dari
  perangkat lain, ditolak `duplicate`.
- **Urutan lock tetap.** Baris proyeksi dalam urutan (outlet, product), lalu
  counter per outlet (movements, lalu stock). Tidak ada lock baris tenant.
- **Feed per outlet.** Counter sync `t:{tenant}/o:{outlet}/e:{entity}`;
  `outlet_stock` (pull) dan `stock_movements` (pull + push) masuk manifest
  dengan scope outlet. `/sync/changes` dan pull memakai outlet dari token, jadi
  till di outlet lain tidak menarik apa pun.
- **Push.** `stock_movements` lewat `/sync/push` yang sama dengan order/sesi.
  Hasil `accepted` membawa `stock_seq` (sequence proyeksi setelah apply) dan
  `balance_after`.
- **Backoffice** `/backoffice/stock` (izin `AdjustStock`, manajer ke atas):
  daftar stok per outlet dengan penanda stok rendah (≤5), halaman ledger per
  produk, form terima/buang/koreksi, opname, dan transfer antar outlet (dua
  movement dalam satu transaksi).
- **Rekonsiliasi malam.** Job River `stock_reconcile` (periodik 24 jam di worker
  maintenance) membandingkan proyeksi dengan jumlah ledger per tenant dan hanya
  memperbaiki baris yang menyimpang, dengan log.

### Klien Flutter (skema lokal v26)

- `outlet_stock` menyimpan `server_qty`/`server_seq`; `stock_movements` menyimpan
  `counted_qty`, `basis_seq`, `server_seq`, `origin`.
- Angka yang tampil = `server_qty`, lalu movement till ini yang belum termasuk
  snapshot diputar ulang dari yang tertua: opname **menetapkan** nilai, movement
  lain menambah delta. Snapshot lama yang datang terlambat diabaikan.
- Movement di-enqueue dalam transaksi yang menulisnya, hanya pada till aktif.
  Antrean stok dikirim tertua dulu, agar penjualan sebelum opname tiba lebih
  dulu.
- Acceptance stok tanpa `stock_seq` tidak menghapus antrean; `server_seq` dicatat
  sebelum entri dihapus.
- Tanpa lantai nol pada till aktif; mode demo tetap seperti sebelumnya.
- Movement dari till lain/Backoffice disimpan sebagai riwayat (`origin=server`).
- Inventori menampilkan alasan baru dan opname; l10n en/id ditambah.

## Bukti

| Kasus | Hasil |
|---|---|
| `go build ./...`, `go vet ./...` | Lulus |
| `go test ./... -count=1` (PostgreSQL + Redis asli) | 17 paket ber-test lulus, 0 gagal; 182 fungsi test tingkat atas |
| Generator (OpenAPI, sqlc, templ) | Hash 17 file output sebelum/sesudah generate identik |
| `gofmt -l` pada file yang berubah | Kosong |
| `flutter test` | **643 lulus, 1 dilewati** (kontrak live tanpa env), 0 gagal |
| `flutter analyze` | 85 `info`, 0 error, 0 warning (sama dengan baseline) |

Test Go khusus stok (`internal/domain/stock`, `internal/domain/ingest`,
`internal/infra/jobs`):

| Test | Yang dibuktikan |
|---|---|
| `TestTwoTillsSellingOfflineConvergeOnTheOutletQuantity` | Dua till, penjualan offline barang sama, push bergantian: proyeksi = jumlah ledger = kuantitas yang benar |
| `TestAnExactRetryIsAcceptedWithWhatWasFirstRecorded` | Retry identik tidak membuat movement; hasil sama dengan yang pertama |
| `TestACountBecomesADeltaAgainstTheServersQuantity` | Opname menjadi delta terhadap kuantitas server saat tiba |
| `TestMovementsThatContradictTheirReasonAreRefused` | Tanda salah ditolak per baris |
| `TestATransferMovesStockBetweenBranchesInOneStep` | Transfer atomik, dua outlet, dua movement |
| `TestABackofficeCountAndAdjustmentsValidateBeforeWriting` | Validasi sebelum menulis |
| `TestStockIsInvisibleToAnotherMerchant` | RLS: tenant lain tidak membaca stok/ledger |
| `TestOutletFeedsPageAndCountOneBranchOnly` | Feed outlet mem-page dan menghitung satu cabang saja |
| `TestReconcileRepairsOnlyARowThatDrifted` | Rekonsiliasi hanya menyentuh baris yang menyimpang |
| `TestConcurrentWritersAcrossBranchesNeitherDeadlockNorDrift` | Penulis paralel lintas cabang: tanpa deadlock, tanpa selisih |
| `TestStockMovementsPushThroughTheSameContract` | Push stok lewat ingest yang sama, hasil per baris |
| `TestStockReconcileVisitsEveryActiveMerchant` | Job River mengunjungi setiap tenant aktif |

Test Flutter khusus stok:

| Test | Yang dibuktikan |
|---|---|
| `two offline tills converge on the outlet quantity` | Dua till berbasis file, stok 20, masing-masing 15 penjualan offline; respons push till A hilang; setelah sync bergantian keduanya dan server = −10, antrean kosong, 31 movement (retry tidak menambah) |
| `a count taken on one till converges on both` | Till B menjual 2, till A opname 12 terhadap snapshot lama; penjualan B tiba lebih dulu; server, A, dan B = 12 |
| `stock_sync_test.dart` (10 test) | Rumus angka tampil, snapshot terlambat, riwayat dari server, settle lewat pull, payload opname, acceptance tanpa `stock_seq`, register lain → dead-letter, demo tetap lantai nol, opname tertunda menetapkan nilai |
| `migration_test.dart` v25 → v26 | Kolom baru terbentuk, data lama utuh |

### Verifikasi live lewat `https://localhost:8443`

API dan worker dibangun ulang dari kode ini. Hasil run terakhir:

| Verifier | Hasil |
|---|---|
| `verify-stock` | 12 PASS, lalu "all stock checks passed" |
| `verify-sync` | 57 PASS, termasuk pull `outlet_stock` dan `stock_movements` sebagai Index Only Scan dan fixture lengkap |
| `verify-backoffice-crud` | 93 PASS, termasuk langkah stok |
| `verify-activation`, `verify-backoffice`, `verify-push` | Lulus pada build Fase 5 |

Isi `verify-stock` (tiga till, dua di outlet yang sama, satu di outlet lain):

- Manifest menerbitkan `stock_movements` (outlet, pull + push) dan
  `outlet_stock` (outlet, pull saja).
- Pengiriman barang dari till diterima dengan sequence proyeksi.
- Dua till mem-push barang sama secara paralel, tiga kali masing-masing: semua
  diterima, outlet mendarat di 20 − 30 = −10 (kekurangan tercatat, tidak
  ditolak).
- Proyeksi = ledger; retry tidak membuat movement.
- Kedua till di outlet itu menarik angka yang sama dengan server; till di outlet
  lain tidak menarik stok outlet itu.
- `/sync/changes` menamai kursor feed outlet.
- Opname menjadi kuantitas server dan retry-nya mengulang hasil; penjualan yang
  menambah stok ditolak per baris.
- Lock baris pada `tenants` setelah run: 0.

Langkah stok di `verify-backoffice-crud` ("pusat melihat angka yang sama"):
validasi form, terima 12 di Backoffice, till menarik 12, opname 7, ledger
mencatat delta −5, menu stok tampil untuk manajer, halaman daftar/filter/ledger
ter-render.

## Penyesuaian terhadap plan

1. **"Satu jam offline" diuji sebagai urutan, bukan waktu dinding.** Konvergensi
   tidak bergantung pada durasi: tidak ada TTL pada antrean, snapshot, atau
   movement, dan token perangkat berlaku jauh lebih lama. Yang diuji adalah
   urutan terburuk: penjualan saling tumpang, respons hilang, retry, opname
   dengan snapshot lama.
2. **Opname server-wins, bukan "last write wins" lokal.** Delta opname dihitung
   saat tiba di server. Konsekuensinya ada di klien: opname tertunda menetapkan
   nilai, dan antrean stok dikirim FIFO. Bug ini ditemukan oleh test dua till
   dan diperbaiki sebelum verifikasi akhir.
3. **Stok negatif, bukan penolakan.** Menolak penjualan yang sudah terjadi di
   kasir hanya menghilangkan data; angka negatif adalah sinyal untuk opname.

## Batas yang tetap berlaku

- **Belum UAT perangkat.** Tidak ada tablet nyata; dua till Flutter diuji
  terhadap server ledger palsu dengan semantik yang sama, dan server asli diuji
  lewat verifier HTTP. Build Flutter belum mem-push stok ke server Go hidup;
  `live_sync_contract_test.dart` belum mencakup stok.
- **Race suite Linux dan k6 tidak dijalankan ulang.** Host ini Windows tanpa gcc.
  Konkurensi dibuktikan oleh test paralel pada PostgreSQL asli dan push paralel
  `verify-stock`, bukan `-race`.
- **Tidak ada pemesanan ulang/purchase order, HPP, atau stok varian.** Stok per
  produk per outlet saja, sesuai lingkup Fase 5.
- **Ambang stok rendah tetap 5** (`stock.LowStockThreshold`), belum bisa diatur
  per produk.
- **Rekonsiliasi memperbaiki proyeksi, bukan ledger.** Jika job menemukan
  penyimpangan, itu bug; log-nya harus diperiksa, bukan diabaikan.
- **Fase 6–9** (meja/modifier/promo di perangkat, rollup laporan, admin
  platform, uji beban) bukan hasil verifikasi ini.

## Jalankan ulang

Dari `backend-go`, muat `.env` development (jangan cetak secret):

```powershell
go run ./cmd/justclick migrate up
docker compose up -d --build api worker
go build ./...; go vet ./...
go test ./... -count=1
go generate ./api ./internal/store
go run github.com/a-h/templ/cmd/templ@v0.3.1020 generate
$env:VERIFY_BASE_URL = 'https://localhost:8443'
$env:VERIFY_INSECURE_TLS = '1'
go run ./scripts/verify-stock
go run ./scripts/verify-sync
go run ./scripts/verify-backoffice-crud
```

`verify-sync` mengosongkan Redis; jalankan verifier berurutan. Dari `mobile/`
(PowerShell):

```powershell
fvm flutter analyze
fvm flutter test
```
