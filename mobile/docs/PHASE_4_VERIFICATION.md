# Fase 4 — klien Flutter v2

Tanggal: 14 September 2026. Acuan: `../../plan.md` (Fase 4), kontrak beku
`../../backend-go/api/openapi.yaml` v2.0.0, dan `../../backend-go/CLAUDE.md`.

Status: implementasi selesai dan diverifikasi lokal, termasuk terhadap server Go
yang hidup lewat Caddy HTTPS. Ini **bukan** UAT perangkat nyata dan bukan uji
beban armada; gerbang pilot tetap membutuhkan keduanya.

## Gerbang sebelum mulai

Fase 0–3 diperiksa ulang pada tanggal yang sama, sebelum satu baris Flutter
diubah:

| Pemeriksaan | Hasil |
|---|---|
| `go build ./...`, `go vet ./...` | Lulus |
| `go test ./... -count=1` (PostgreSQL 18 + Redis asli) | Semua paket lulus |
| API + worker dibangun ulang, `go run ./scripts/verify-push` via `https://localhost:8443` | Semua pemeriksaan lulus: 200 baris ×3 tetap 200 struk, total tepat, settle-once, laci tertutup tidak dibuka, baris buruk tidak memblok tetangga, 611 percobaan tersimpan di audit, partisi bulanan |
| `flutter test` baseline | 547 test lulus |
| `flutter analyze` baseline | 85 issue, seluruhnya `info` (0 error, 0 warning) |

Race suite Linux dan k6 tidak dijalankan ulang di sini; buktinya ada di
`PHASE_0_2_VERIFICATION.md` dan `PHASE_3_VERIFICATION.md`.

## Butir Fase 4 dan tempatnya

| Butir plan | Implementasi |
|---|---|
| `/api/v2` | `API_BASE_URL` sekarang root v2, mis. `https://…/api/v2` |
| Terima 200 pada activate | `DeviceActivationRepository`: hanya 200 + amplop `data`; 201 (v1) diperlakukan sebagai belum aktif |
| Epoch-millis menyeluruh | `token_expires_at_ms`, `deleted_at_ms`, `placed_at_ms`, `opened_at_ms`/`closed_at_ms`; binding v1 (ISO) masih bisa dibaca |
| Abaikan key pull tak dikenal | `CatalogueSync` menyaring kolom lewat `PRAGMA table_info`; upsert memakai `key` dari manifest, bukan `id` tetap |
| Push ter-batch | `OutboxPush`: ≤200 baris/request, batch sesi sebelum order, batas 3 MiB, byte identik saat retry |
| Hasil per-baris | Hanya `accepted` (dengan id + revisi yang cocok) menghapus; `rejected` dengan kode tertutup → dead-letter; sisanya tetap antre |
| Tabel dead-letter | `_dead_letter` (v25) + `DeadLetterStore`; jumlahnya tampil di Settings dan bisa dikirim ulang |
| Jalur cepat `changes` | `DeviceSyncRunner`: satu request `/sync/changes` per poll; pull hanya feed yang kursornya maju; hint tidak pernah disimpan sebagai kursor |
| Jitter + connectivity listener + sync manual + sebar startup | `SyncScheduler` + `DeviceSyncController`: poll `next_poll_ms` × [0,8; 1,2], nudge 5 s/≥30 s, backoff 2 s→5 m full jitter + `Retry-After`, `hash(device_id) mod 300` s, tombol "Sinkronkan sekarang" |
| Header skema | `X-Schema-Version: 1` di setiap panggilan sync; 409 `device_schema_outdated` menghentikan sync dan meminta update |

Tambahan yang diperlukan agar kontrak benar-benar diterima server:

- **Outbox menyimpan snapshot + revisi** (`_outbox.revision`, `_outbox.payload`,
  `_push_revisions`). ACK hanya menghapus revisi yang dikirim; edit selama HTTP
  tetap antre. Entri v24 (hanya identitas) di-snapshot sebelum kiriman v2 pertama.
- **`orders.business_date` dan `orders.server_time_delta_ms`** dipilih sekali saat
  checkout (v25); order pra-v25 dibekukan dari `created_at` saat snapshot pertama.
- **`setStatus` sekarang meng-enqueue.** Sebelumnya perubahan status dapur tidak
  pernah naik ke server.
- **Referensi opsional non-UUID dikirim null.** Layar lokal masih membuat id
  `table_<ms>`/`emp_<ms>`/`p_<ms>`; server menolak referensi non-UUID, sehingga
  setiap penjualan dine-in dengan meja lokal akan ditolak. Snapshot nama tetap
  dikirim.
- **Override manajer memilih akun dulu.** `backend-go/CLAUDE.md` mencatat ini
  sebagai kewajiban Fase 4: sejak PIN tidak unik (2026-09-13), `byPin` bisa
  menyetujui seorang kasir sebagai manajer yang kebetulan ber-PIN sama. Sheet kini
  hanya menampilkan akun yang memegang izin dan memverifikasi PIN terhadap akun
  itu; jalur `byPin` di sheet dihapus.
- **`/devices/me` tidak lagi dipoll tiap 30 detik.** Revokasi terdeteksi dari 401
  pada sync mana pun; perubahan binding dari `device_revision`.

## Bukti

| Kasus | Hasil |
|---|---|
| `flutter analyze` | 85 issue, identik dengan baseline; tidak ada issue dari file yang diubah/ditambah |
| `flutter test` | **609 test lulus** (baseline 547) |
| Server membalas `[]`, `"ok"`, `null`, body kosong, 422, 500 | Seluruh antrean (sesi + 2 order) identik sebelum/sesudah: entity, id, revisi, payload; dead-letter 0 |
| Hasil yang tidak menamai baris (tanpa id/revisi, revisi/id lain, entity lain, status/kode tak dikenal, tanpa `results`, posisi ganda) | Tidak ada yang dihapus |
| Order di-void saat push pertamanya sedang di jalan | Revisi 1 di-ACK, revisi 2 (`cancelled`) tetap antre lalu terkirim |
| `rejected` | Payload yang persis dikirim pindah ke `_dead_letter`; `register_busy` menyimpan nama pemegang laci |
| 1 sesi + 205 order | 2 request, masing-masing ≤200 baris, sesi di batch pertama, semua diterima |
| Retry setelah 503 | Body request kedua identik byte-per-byte |
| 401 / 409 schema | Run berhenti, antrean utuh |
| Payload vs skema OpenAPI | Key order/item/modifier/sesi ⊆ skema, required lengkap, total = subtotal − diskon + pajak + service, Σ unit_price×qty = subtotal, field immutable identik antar revisi |
| Migrasi v24 → v25 | Entri outbox v24 (attempts=4) tetap ada; kolom dan tabel v25 terbentuk |
| Scheduler | Sebar startup deterministik < 300 s; jitter ±20%; backoff 2,4,8,16 s … cap 5 m, floor 1 s; `Retry-After` menang; baris tertahan tidak lebih lambat dari poll; nudge 5 s dan dibatasi 30 s |

### Kontrak live terhadap server Go

`test/contract/live_sync_contract_test.dart` (di-skip tanpa env) dijalankan
terhadap API yang baru dibangun ulang via `https://localhost:8443/api/v2`, dengan
tenant sekali pakai. Skenario: buka laci + 3 penjualan (modifier, service charge,
PB1, meja lokal non-UUID) → sync penuh → penjualan ke-4 → status dapur, void,
refund, tutup laci → sync jalur cepat → kirim ulang snapshot yang sudah
diterima (respons "hilang"). Lulus tanpa dead-letter di ketiga langkah.

Diperiksa langsung di PostgreSQL untuk tenant tersebut sebelum dihapus:

| Tabel | Isi |
|---|---|
| `orders` | 4 baris: `served` r2, `cancelled` r2, `refunded` r2, `preparing` r1 |
| `order_items` / `order_item_modifiers` / `order_dedupe` | 8 / 4 / 4 — retry identik tidak menggandakan apa pun |
| Total | Rp212.520 = 4 × Rp53.130, tepat |
| `server_time_delta_ms` | Ada tepat pada 1 order (yang dibuat setelah sync pertama) |
| `table_id` | null pada ke-4 order |
| `pos_sessions` | 1 sesi, revisi 2, tertutup |
| `ingest_log` | 13 percobaan = 4 + 5 + 4 kiriman |

## Perubahan pada test yang sudah ada

Tidak ada test yang dihapus. Tiga file mengunci kontrak v1 dan diubah ke v2:

- `catalogue_sync_test.dart`: path `/api/v2`, manifest berupa objek, `deleted_at_ms`;
  ditambah key tak dikenal, feed yang belum didukung, hint `changes`, dan halaman
  yang tidak sesuai kontrak.
- `device_activation_repository_test.dart`: 200 + amplop `data`, epoch-millis;
  201 kini termasuk status yang ditolak; binding v1 tersimpan tetap terbaca.
- `outbox_test.dart`: `resolve` diganti `acknowledge(revision)`; "antre dua kali"
  sekarang memeriksa revisi yang naik (enqueue untuk baris yang tidak ada tidak
  lagi membuat entri kosong).

## Batas yang tetap berlaku

- **Belum UAT perangkat.** 23 baris `docs/MANUAL_TEST_FASE_1_7.md` masih harus
  dijalankan di tablet nyata (online, offline seminggu, ganti jaringan, jam salah).
- **Aktivasi tidak diuji live.** Kode aktivasi di-HMAC dengan `APP_KEY`; parser
  diuji terhadap bentuk `wire.ActivateResponse` hasil generate, dan
  `verify-backoffice` sudah membuktikan sisi server. Satu aktivasi dari build
  Flutter terhadap server nyata tetap perlu dilakukan saat UAT.
- **Pull live hanya dengan katalog kosong.** Pengisian katalog lewat Backoffice
  ke till dibuktikan di sisi server oleh `verify-backoffice-crud`; unit test
  Flutter memakai halaman palsu.
- **Feed modifier dan promo tidak ditarik** sampai Fase 6 (lihat alasan
  `promo_outlets` di atas). Till connected tetap tanpa modifier/promo server,
  seperti sebelumnya.
- **Ganti `API_BASE_URL` = namespace penyimpanan baru.** Scope toko connected
  adalah `sha256(baseUrl)`; perangkat yang pernah diaktifkan ke `/api/v1` akan
  membuka toko kosong dan harus diaktivasi ulang. Antrean v1 di toko lama tidak
  dikirim. Aman hari ini karena belum ada produksi, tetapi jangan pernah
  mengganti root API pada perangkat yang masih punya antrean.
- **Plugin baru `connectivity_plus`.** Untuk web, jalankan `flutter clean` sebelum
  `flutter build web` (lihat catatan registrant di `CLAUDE.md`). Di platform tanpa
  plugin, sinyal konektivitas diabaikan; poll dan resume tetap berjalan.
- **Serbuan pagi, 15.000 perangkat, dan Redis mati** adalah Fase 9, bukan hasil
  verifikasi ini.

## Adendum — perbaikan blocker review Fase 4

Review sebelum Fase 5 menemukan empat blocker. Semuanya diperbaiki dan
diverifikasi ulang pada 14 September 2026, sebelum pekerjaan stok dimulai.

| Blocker | Perbaikan |
|---|---|
| [P1] Till R1 masih bisa memilih R2 | `TillBinding` (outlet + register dari aktivasi) ditegakkan di tiga lapis: pilihan UI (`registerSlotsProvider`, outlet, settings) hanya menampilkan binding; `ShiftRepository.open` dan `OrderRepository.create` menolak outlet/register/sesi lain di dalam transaksi (`TillBindingException`, pesan `tillBindingMismatch`); `OutboxPush` memindahkan baris sesi/order/stok milik register lain ke dead-letter `register_mismatch` tanpa mengirimnya |
| [P1] Hasil `verify(binding)` dibuang, binding lama menimpa register baru | Tidak ada `verify` saat launch/resume. Binding hasil `/devices/me` disimpan ke secure storage dan dipakai; `seedBindingRows` hanya menyisipkan outlet/register yang belum ada (`ConflictAlgorithm.ignore`) sehingga baris hasil feed tidak pernah ditimpa |
| [P2] `Retry-After` bisa dilewati | `RetryGate` satu per perangkat: 429 (dan 503 ber-`Retry-After`) memasang larangan, default 30 s, maks 1 jam, tidak pernah diperpendek. `SyncClient` dan `verify` menolak mengirim selama larangan berlaku; scheduler menjepit setiap jadwal, nudge, dan tombol manual ke akhir larangan; runner berhenti tanpa push setelah `/sync/changes` mendapat 429 |
| [P2] Sebar startup bisa dilewati | `/devices/me` hanya dipanggil saat `device_revision` (tersimpan di `_sync_meta`) berubah, lewat scheduler yang sama; laporan konektivitas pertama diabaikan dan nudge di dalam jendela startup tidak memperpendeknya |

Bukti:

| Kasus | Hasil |
|---|---|
| `test/sync/till_binding_test.dart` | Register/outlet lain tidak tampil, tidak bisa dibuka shift-nya, tidak bisa checkout, tidak dikirim |
| `test/sync/sync_gate_test.dart` | 429 dengan `Retry-After: 120` menahan poll, nudge, dan sync manual 120 s; tidak ada push setelah 429 di `/sync/changes`; startup tidak dipercepat konektivitas |
| `test/repositories/device_verify_test.dart` | Binding baru dari `/devices/me` dipakai dan disimpan; larangan aktif = tidak ada request |
| Kontrak live (`live_sync_contract_test.dart`) | Binding diambil dari `/devices/me`; 4 order, total Rp212.520, sesi pada register terikat; register lain ditolak lokal |
| `flutter test` setelah perbaikan | 630 lulus, 1 dilewati (kontrak live tanpa env) |

Setelah Fase 5 (klien stok) suite menjadi **643 lulus, 1 dilewati**; analyzer
tetap 85 `info`. Kontrak OpenAPI naik ke 2.1.0 secara aditif (skema
`StockMovement`, `stock_seq`/`balance_after` pada hasil push); klien Fase 4
tetap valid karena key yang tidak dikenal diabaikan. Rincian stok ada di
`../../backend-go/docs/PHASE_5_VERIFICATION.md`.

## Jalankan ulang

Dari `mobile/` (PowerShell; `fvm` adalah `.bat` dan tidak jalan dari Git Bash):

```powershell
fvm flutter analyze
fvm flutter test
```

Kontrak live, dari `backend-go/` dengan Compose menyala. Buat tenant sekali pakai
(pola yang sama dengan `scripts/verify-push`), jalankan test, lalu hapus:

```powershell
$t=[guid]::NewGuid(); $o=[guid]::NewGuid(); $r=[guid]::NewGuid(); $d=[guid]::NewGuid()
$b=New-Object byte[] 32; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
$token=-join ($b | % { $_.ToString('x2') })
@"
INSERT INTO tenants(id,name,slug) VALUES ('$t','Flutter v2 contract','$t');
INSERT INTO outlets(id,tenant_id,name) VALUES ('$o','$t','Outlet');
INSERT INTO pos_registers(id,tenant_id,outlet_id,name) VALUES ('$r','$t','$o','Kasir 1');
INSERT INTO devices(id,tenant_id,outlet_id,pos_register_id,device_uuid,token_sha256,token_expires_at)
  VALUES ('$d','$t','$o','$r','$d',sha256(convert_to('$token','UTF8')),now()+interval '1 hour');
"@ | docker compose exec -T postgres sh -c 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"'

cd ..\mobile
$env:JUSTCLICK_LIVE_BASE_URL='https://localhost:8443/api/v2'; $env:JUSTCLICK_LIVE_TOKEN=$token
fvm flutter test test/contract/live_sync_contract_test.dart

cd ..\backend-go
"DELETE FROM jobs.river_job WHERE args->>'tenant_id'='$t'; DELETE FROM tenants WHERE id='$t';" |
  docker compose exec -T postgres sh -c 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
```
