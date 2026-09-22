# Rencana Implementasi Fase 0 — Konsolidasi Fondasi dan Baseline Lokal

**Status:** kode selesai; gate otomatis lokal lulus. Exit gate lingkungan yang
tersisa adalah build rilis Windows, UAT manual dua instalasi, dan eksekusi
workflow GitHub. Build serta UAT Windows membutuhkan Visual Studio Build Tools.
Bukti dan daftar lengkap yang belum lulus ada di
[FASE_0_VERIFICATION.md](FASE_0_VERIFICATION.md).  
**Acuan:** [RENCANA_PARITAS_FITUR_MOKAPOS.md](RENCANA_PARITAS_FITUR_MOKAPOS.md)

Fase 0 menyelesaikan fondasi SQLite Windows, kontrak till, diagnosis konflik,
takeover perangkat, rekonsiliasi transaksi terlambat, CI Flutter, dan UAT lokal.
Implementasi dibagi menjadi tujuh workstream berikut.

1. **F0.1 — Baseline diagnostik:** pemeriksa read-only untuk outbox, dead-letter,
   sesi, order, dan efek stok pada perangkat maupun server.
2. **F0.2 — SQLite native:** gunakan `sqflite_common_ffi` pada Windows/Linux dan
   buktikan file database tetap utuh setelah koneksi ditutup lalu dibuka kembali.
3. **F0.3 — Kontrak till:** dokumentasikan seluruh endpoint till di OpenAPI,
   termasuk status recovery dan seluruh respons kegagalan.
4. **F0.4 — Model recovery:** simpan kasus takeover, payload terlambat, dan event
   audit secara tenant-scoped tanpa menghapus bukti.
5. **F0.5 — Takeover Backoffice:** manager/owner dapat menutup paksa sesi,
   mencabut perangkat lama, dan membuka jalan bagi aktivasi perangkat pengganti.
6. **F0.6 — Recovery Center:** tampilkan antrean dan penolakan secara terarah;
   transaksi terlambat diterima atau ditolak oleh manager dengan jejak audit.
7. **F0.7 — Gerbang verifikasi:** CI Flutter Linux/Windows, perluasan verifier
   backend, serta UAT Windows dan Android dengan dua instalasi.

Aturan utamanya: tidak ada reset database, retry massal untuk konflik, takeover
otomatis berdasarkan heartbeat, atau penerimaan transaksi terlambat tanpa
keputusan manusia. Recovery hanya melewati larangan sesi yang sudah ditutup;
validasi tenant, actor, nominal, idempotency, dan stok tetap berlaku.

Kriteria akhir F0 adalah database persisten pada Windows/Android, tepat satu
sesi aktif per register di server, takeover yang teraudit, late order yang
masuk karantina satu kali, rekonsiliasi yang tidak menggandakan order/stok, dan
baseline CI serta panduan uji lokal yang dapat diulang.

## Di mana masing-masing mendarat

| # | Yang mendarat |
|---|---|
| F0.1 | `ingest.DiagnoseTill` (delapan pemeriksaan read-only) · CLI `justclick diagnostics till --tenant` · kartu "Diagnostik sinkronisasi" di `/backoffice/devices` · `mobile/lib/data/recovery/recovery_inspector.dart` |
| F0.2 | `mobile/lib/data/database/db_platform_io.dart` memasang `databaseFactoryFfi` pada Windows/Linux · `sqflite_common_ffi` pindah dari `dev_dependencies` ke dependency utama · SQLite lokal v29 |
| F0.3 | Enam operasi `/till/*` di `api/openapi.yaml` (versi 2.4.0) beserta seluruh respons kegagalan · `wire` yang dibangkitkan · `contract_test` mengunci permukaan dan skemanya |
| F0.4 | Migrasi `20260922000021_till_recovery`: `till_recoveries`, `till_recovery_items`, `till_recovery_events`, `pos_sessions.close_kind` / `forced_recovery_id`, RLS per tenant, dan `Down` yang bersih |
| F0.5 | `ingest.ForceTakeover` · form takeover berkonfirmasi nama till di `views/devices.templ` · `Handler.takeoverTill` · `CachedAuthenticator.InvalidateRevoked` |
| F0.6 | Kartu Recovery Center di `/backoffice/devices` dengan terima/tolak/tutup · `ingest.AcceptRecoveryItem` / `DiscardRecoveryItem` / `ReconcileRecovery` · `mobile/lib/features/recovery/recovery_center_page.dart` · `DeadLetterStore.requeue` menggantikan `requeueAll` |
| F0.7 | `.github/workflows/flutter.yml` (Linux + Windows) · langkah roll-down migrasi dan `verify-recovery` pada `backend-go.yml` · `scripts/verify-recovery` · bagian F dan G di `MANUAL_TEST_LOKAL.md` |

Dua keputusan desain yang tidak terlihat dari daftar di atas dan mudah
dirusak tanpa sengaja:

- **Baris `till_claims` sesi yang ditutup paksa sengaja tidak dihapus.**
  `ingestSale` hanya memberlakukan penjagaan sesi ketika sesinya *claimed*;
  menghapus claim-nya akan membuat penjualan terlambat lolos tanpa penjagaan
  apa pun, bukan tertahan. Yang dikosongkan hanya `active_employee_id`, karena
  indeks unik `till_one_active_cashier` melarang satu kasir memegang dua claim
  dan kasir itu harus bisa membuka laci pengganti.
- **`recovery_id` yang dipegang manager adalah satu-satunya kunci yang
  melewati larangan `session_closed`.** `ingestSaleForRecovery` melewatkan
  penjagaan itu saja; validasi tenant, pemilik perangkat, penugasan kasir,
  nominal, idempotency dan stok tetap berjalan pada jalur yang sama dengan
  penjualan normal.
