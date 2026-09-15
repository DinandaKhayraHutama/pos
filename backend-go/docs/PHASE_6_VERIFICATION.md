# Fase 6 — meja, modifier, dan promo di perangkat

Tanggal verifikasi: 14–15 September 2026. Acuan: `../../plan.md`, OpenAPI
2.2.0, SQLite v27. **Implementasi dan verifikasi otomatis selesai; build serta
UAT tampilan Windows belum lulus karena lingkungan, bukan diklaim selesai.**
Ini bukan persetujuan rollout/pilot produksi.

## Review prasyarat

- Empat blocker Fase 4 sudah diperbaiki: binding outlet/register diperiksa saat
  menulis dan mengirim; bootstrap tidak menimpa hasil pull; verifikasi binding
  tidak melakukan request awal di luar jadwal; Retry-After/startup gate dipakai
  bersama. Test regresinya tetap ikut suite Flutter.
- Fase 5 ledger/proyeksi, ACK `stock_seq`, dua till offline, opname, transfer,
  dan isolasi outlet tetap lulus suite dan verifier stok terhadap server hidup.
  Opname tetap mengikuti keputusan Fase 5 (server-wins saat ingest, bukan
  rekonstruksi waktu hitung fisik). Varian stok bukan tambahan lingkup Fase 6.
- Fase 0–3 diuji ulang secara fungsional melalui suite Go/RLS/konkurensi dan
  verifier HTTPS aktivasi, Backoffice, CRUD, sync, serta push. Uji beban
  2.000 rps sebelumnya tidak diulang dalam run ini; hasil historis bukan
  jaminan performa deployment baru.

## Lingkup yang selesai

### Backend

- Migrasi `20260915000016_tables.sql`: definisi `tables`, proyeksi `table_status`,
  riwayat `table_status_events`, composite FK, RLS, covering indexes.
- Definisi/status merupakan feed per outlet. Event status push-only, memakai
  endpoint batch, hasil per baris dan ingest audit yang sama dengan order.
- CRUD Backoffice di `/backoffice/outlets/{id}/tables`: nama, area, kapasitas,
  koordinat opsional, urutan, aktif/nonaktif, tombstone. Board status read-only
  dipoll setiap 15 detik, menampilkan konflik dan pelaku/waktu event.
- Identitas tenant/outlet/device berasal dari token. Meja tidak dapat dipindah
  outlet lewat edit URL atau payload. Meja nonaktif tetap dapat dikosongkan;
  meja bertombstone menolak event baru, tetapi retry yang telah diterima aman.

### Flutter

- Migrasi v26 → v27 mempertahankan transaksi, antrean, promo, dan meja lama.
  Tambahan `all_outlets`, `promo_outlets`, proyeksi meja dan ledger event lokal.
- Semua 16 feed dikonsumsi; modifier dan join diterapkan dengan upsert, bukan
  replace. Promo hanya ditawarkan pada outlet yang berhak, dan tanpa outlet
  aktif tidak ada promo yang ditawarkan. Tombstone join tidak memperluas scope.
- Connected: editor master katalog/modifier/promo/denah ditutup; repository
  modifier/promo/denah juga menolak penulisan lokal. Demo tetap dapat diedit.
- Checkout, stok dan event meja masuk satu transaksi SQLite. Kegagalan membuat
  event membatalkan checkout seluruhnya, bukan menyisakan order tanpa event.
- Status lokal adalah snapshot server dengan overlay event lokal terbaru yang
  belum tercakup. ACK harus memiliki `status_seq` positif dan `outcome` dikenal;
  ACK tidak lengkap mempertahankan antrean. Event ditolak tetap di dead-letter
  dan tidak terus menutupi status server; recovery mempertahankan fakta event.
- Setelah ACK meja, runner menarik **hanya** feed status yang berubah, memakai
  gate Retry-After yang sama. Ini memperbarui pemenang/indikator konflik tanpa
  menunggu seluruh katalog atau mengirim ulang event.
- Board Flutter menampilkan ikon/peringatan konflik (l10n Indonesia/Inggris).
  Provider di-refresh setelah pull maupun perubahan akibat ACK.

## Penyempurnaan atas draft

1. **Urutan event, bukan jam perangkat saja.** `client_seq` tersimpan monoton
   per device/table. Event lama yang tiba belakangan dicatat sebagai superseded,
   tidak dapat membatalkan tindakan lebih baru dari perangkat yang sama.
   `basis_seq` yang melebihi sequence proyeksi server ditolak. Counter lokal tidak
   boleh di-reset/prune bersama riwayat tanpa pengganti yang persisten.
   **Koreksi review (15 September 2026):** till menomori `max(sebelumnya + 1,
   jam dinding ms)`. Sebelumnya nomor dimulai dari 1 pada store kosong. Karena
   `installation` di secure storage bisa bertahan lebih lama dari database lokal
   (misalnya keychain iOS setelah reinstall) dan aktivasi ulang memakai baris
   device yang sama, event meja pertama store baru akan menabrak indeks unik
   server dan masuk dead-letter sebagai `duplicate`. Test regresi:
   `a store that starts empty numbers its changes above an earlier store`.
2. **Konflik antar perangkat tetap terlihat.** Jika basis cocok dengan snapshot
   saat ini, tindakan diterapkan dan konflik dibersihkan. Jika mengikuti event
   sendiri, flag dipertahankan. Perubahan antar perangkat yang tidak saling
   melihat memakai `(occurred_at_ms, UUID)` dan memublikasikan `contested=true`.
   Jam salah tetap dapat menentukan pemenang konflik: petugas harus memeriksa
   fisik lalu memilih status setelah melihat snapshot terbaru. Ini bukan
   jaminan reservasi eksklusif ketika perangkat offline.
3. **ACK bukan proyeksi lengkap.** Status dibaca kembali setelah push; hasil
   superseded sendiri tidak cukup untuk menebak status pemenang.
4. Verifier lama memakai kunci generik yang tidak memasukkan `table_id`.
   Diperbaiki beserta regresinya; duplikasi yang dilaporkan verifier tersebut
   bukan duplikasi data server.

## Bukti verifikasi

| Pemeriksaan | Hasil |
|---|---|
| `go test ./... -count=1` | Seluruh paket lulus, PostgreSQL 18 + Redis asli |
| Linux `go test -race -p 4 ./... -count=1` | Seluruh paket lulus; 193 fungsi test tingkat atas termasuk verifier key |
| `go vet`, staticcheck, golangci-lint v2.13.2 | Lulus; lint akhir 0 issues |
| OpenAPI, sqlc, templ | 18 hash output identik sebelum/sesudah generate ulang |
| Flutter analyzer | 0 error, 0 warning; 85 info yang sudah ada |
| Suite Flutter akhir | **661 lulus, 2 dilewati**, 0 gagal; dua kontrak live dijalankan terpisah dengan fixture nyata |
| Tes checkout atomik, rejected/recovery, ACK tak lengkap, clock mundur | Lulus |
| Migrasi SQLite v26 → v27 dan rantai migrasi lama | Lulus, antrean lama tetap utuh |
| Dua file SQLite kasir offline, konflik/penyelesaian | Lulus |
| HTTPS `verify-tables` | Lulus: isolasi outlet, retry, konflik, 50 perubahan konkuren, rename/tombstone |
| HTTPS `verify-stock`, `verify-push` | Lulus; 200 order ×3, uang tepat, audit lengkap, partisi benar |
| HTTPS `verify-sync` | Semua 16 feed lengkap; masing-masing Index Only Scan; warm HTTP p99 2,87 ms (bukan tes beban) |
| HTTPS `verify-backoffice-crud` | Lulus termasuk form meja, validasi kursi, edit, board, retire dan dua tombstone |
| HTTPS `verify-backoffice`, `verify-activation` | Lulus; warm auth p99 2,14 ms, flush Redis, revoke, 429 + Retry-After |
| `verify-flutter` (Go API + Flutter asli, bukan mock) | Dua kontrak lulus; 5 receipt dan 3 event meja di PostgreSQL, tanpa duplikasi/dead-letter |

`verify-flutter` mengisi katalog/modifier/promo/stock/meja, lalu dua database
kasir terpisah menariknya, melakukan checkout offline dan reservasi bersaing,
konvergen pada status konflik dan stok 0, menyelesaikan konflik, lalu mengirim
ulang event yang ACK-nya dianggap hilang. Token hanya melalui environment child
process. Tenant fixture dan job-nya dihapus setelah verifikasi, bukan data user.

Run awal mengalami Docker berhenti dan satu timeout Redis; setelah layanan
lokal kembali, kontrak live dan verifier aktivasi lulus tanpa melonggarkan test.

## Jalankan ulang

Dari `backend-go/`, dengan env lokal dimuat dan Compose aktif:

```powershell
go run ./cmd/justclick migrate up
docker compose up -d --build api worker caddy
$env:VERIFY_BASE_URL='https://localhost:8443'
$env:VERIFY_INSECURE_TLS='1' # hanya CA development lokal
go run ./scripts/verify-tables
go run ./scripts/verify-backoffice-crud
go run ./scripts/verify-flutter
```

`verify-flutter` mengharapkan `fvm` di PATH, dijalankan dari `backend-go/`, dan
menjalankan test dari `mobile/`. Jangan jalankan verifier yang mengosongkan
Redis bersamaan dengan test lain atau load test. CI backend menjalankan suite
race serta `verify-tables` dan CRUD yang kini mencakup meja.

## Gerbang yang masih terbuka

- **Windows desktop diprioritaskan sesuai permintaan, tetapi belum terverifikasi.**
  Build berhenti pada `Unable to find suitable Visual Studio toolchain`.
  Perlu workload Visual Studio *Desktop development with C++* + Windows SDK.
  Flutter Windows sempat diaktifkan untuk mencoba build lalu dikembalikan ke
  pengaturan semula (nonaktif). Registrant plugin Windows diregenerasi agar
  connectivity dan secure storage ikut terdaftar.
- Pemeriksaan visual via skill Computer Use gagal bahkan sesudah reset:
  `failed to write kernel assets ... (os error 3)`. Belum ada klaim bahwa UI
  Windows benar-benar dilihat/dioperasikan. Sesudah lingkungan siap, periksa
  board, konflik, penyelesaiannya, modifier, promo outlet, dan connected editor
  yang tidak tersedia. UAT hardware tetap wajib sebelum pilot.
- **Polling dulu, SSE kemudian**, sesuai instruksi eksplisit plan. Kasir lain
  masih menunggu poll server-controlled (default 60 detik) atau Sync now.
  Koordinat disimpan; board saat ini berupa daftar/grid per area, bukan editor
  denah drag-and-drop. Jangan menjualnya sebagai reservasi real-time eksklusif.
- Beban armada 15.000 perangkat, UAT tablet/printer dan gate rollout tetap di
  fase pengerasan/pilot. Fase 7/8 tidak dikerjakan dalam perubahan ini.
