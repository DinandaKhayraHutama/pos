# Fase 8 — admin platform

Tanggal verifikasi: 15 September 2026. Acuan: `../../plan.md` (Admin platform,
Fase 8) dan rencana kerja Fase 8 yang disetujui. Ini bukan persetujuan
pilot/rollout.

## Keputusan produk (15 September 2026)

| Pertanyaan | Keputusan |
|---|---|
| Impersonasi | Boleh menulis; setiap request non-GET diaudit sebelum dijalankan |
| Efek suspend | Memblok Backoffice **dan** till (401 → layar aktivasi; outbox tetap) |
| Flag & limit | Ditegakkan di server; tidak menyentuh feed/till |
| TOTP | RFC 6238 dengan stdlib, tanpa QR, dengan kode pemulihan |

## Lingkup yang selesai

### Skema — `migrations/20260917000018_platform.sql`

- `tenants`: CHECK `status IN ('active','suspended')`, `suspended_at`,
  `suspended_reason`.
- `super_admins` (bcrypt, secret TOTP, `totp_last_step`),
  `super_admin_recovery_codes` (SHA-256), `platform_sessions` (skema scs,
  terpisah dari `sessions`), `platform_audit_log` (append-only),
  `tenant_limits`, `tenant_feature_flags`, `impersonation_sessions`,
  `password_setup_tokens`.
- **Grant sebagai batas keamanan.** Default privileges migrasi 001 memberi
  setiap tabel baru ke `justclick_app`; migrasi 018 me-revoke tabel platform
  darinya dan memberi ke `justclick_unscoped`. Audit log hanya `SELECT, INSERT`.
  Limit, flag dan impersonasi dapat dibaca merchant-nya sendiri (RLS
  `FOR SELECT`), ditulis hanya oleh platform.

### Domain

- `internal/domain/entitlements` (paket daun): registry flag (default aktif),
  `Enforce`/`EnforceDevices` dengan advisory lock transaksi hanya untuk merchant
  yang dibatasi. Ditegakkan di pembuatan/pengaktifan outlet dan till,
  penerbitan kode (pra-cek) dan aktivasi (otoritatif, kode tidak terpakai bila
  ditolak, reinstall `device_uuid` yang sama tidak dihitung).
- `internal/domain/platform`: TOTP, admin (enrolment, anti-replay CAS, kode
  pemulihan, CLI), audit, onboarding satu transaksi, suspend/reaktivasi dengan
  bump cache auth setelah commit, limit/flag teraudit hanya bila berubah,
  tautan setel kata sandi, impersonasi (handoff sekali pakai 60 detik, 60 menit,
  berakhir saat kedaluwarsa/suspend/admin nonaktif), pemakaian dari perangkat +
  `daily_sales_rollup`, laporan ops.
- `tenancy.ProvisionTx`; `tenancy.ValidSlug`.
- `devices.CachedAuthenticator.Touch`: `last_seen_at` maksimal sekali per 5
  menit per perangkat, tanpa menyentuh `updated_at`.

### HTTP

- Panel `/platform` (`internal/platform`): login bertahap password → TOTP /
  kode pemulihan / enrolment wajib, rate limit, sesi 8 jam dengan idle 30
  menit, CSRF sendiri, header anti-frame/no-store; daftar & detail perusahaan,
  onboarding, suspend (ketik slug), limit, modul, tautan setup, impersonasi,
  audit, ops.
- Backoffice: `POST /backoffice/impersonate` (di luar CSRF, cek Origin),
  `requireEmployee` memvalidasi impersonasi tiap request,
  `auditImpersonatedWrites` fail-closed (503), banner permanen, ganti
  password/PIN ditolak saat impersonasi, `/backoffice/welcome/{id}`,
  `requireFeature` (404) pada stok, meja, promo, ekspor/jadwal; nav mengikuti
  flag yang sama; polling ekspor disembunyikan bersama modulnya.
- API: aktivasi menjawab `422 device_limit_reached` (OpenAPI 2.3.0, aditif).
- CLI `justclick platform admin create|reset-totp|deactivate|activate`.
- Guard arsitektur `TestUnscopedImportersAreCountable`.

## Penyimpangan dari rencana (disengaja)

1. **Tidak ada seed tarif default** saat onboarding: server belum punya tabel
   pengaturan PB1/service charge.
2. **Tanpa QR** saat enrolment; secret diketik (dan URI otpauth ditampilkan).
3. **Manajemen super admin hanya lewat CLI**, bukan layar panel.
4. **Pembatasan IP `/platform` di Caddy** belum dibangun.
5. **Flag tidak menyentuh feed till**: promo, denah dan stok yang sudah ada di
   tablet tetap berlaku.
6. **Halaman ops** berupa ringkasan read-only (state/queue River, job
   discarded, migrasi, slice laporan tertunda, partisi DEFAULT), bukan riverui.
7. **Pesan limit perangkat di till** memakai pemetaan 422 yang sudah ada
   ("kode tidak valid"); pesan yang jelas hanya di Backoffice.

## Bug yang ditemukan selama pengerjaan

- **Penutupan impersonasi kedaluwarsa ter-rollback.** `ActiveImpersonation`
  menutup baris dan menulis audit di dalam transaksi lalu mengembalikan error;
  `pgx.BeginFunc` me-rollback keduanya. Tertangkap oleh
  `TestAnImpersonationEndsWhenItExpiresTheMerchantIsSuspendedOrTheAdminLeaves`;
  kini transaksi commit dan error dilaporkan setelahnya.
- **Test sendiri keliru** (`TestSwitchingAnOutletBackOnCountsAgainstTheLimit`
  sempat membuat outlet ketiga di batas 1); diperbaiki sebelum dijalankan.
- **Drift yang sudah ada:** `internal/httpapi/wire/models.gen.go` belum
  digenerate ulang setelah komentar `client_seq` di OpenAPI Fase 7; `go generate
  ./api` kini hanya mengubah komentar itu (tanpa perubahan tipe).

## Insiden lingkungan

Run `go test ./...` pertama terputus karena drive C: tersisa 0,08 GB: linker
gagal, Docker Desktop mengalami `input/output error`, dan PostgreSQL crash di
tengah suite (`pg_filenode.map: I/O error`, recovery mode). Hasil run itu tidak
dipakai sebagai bukti. Setelah C: dikosongkan (49,9 GB) dan Docker Desktop
di-restart, PostgreSQL kembali sehat (`pg_is_in_recovery() = false`, migrasi
018 tercatat) dan suite dijalankan ulang.

## Bukti verifikasi

### Otomatis

| Pemeriksaan | Hasil |
|---|---|
| `go test ./... -count=1` (PostgreSQL 18 + Redis asli, setelah Docker pulih) | **23 paket lulus**, 0 gagal. Modul kini 271 test top-level; 39 baru di Fase 8 |
| Test Fase 8 | `platform` (TOTP vektor RFC 6238, enrolment, replay paralel tepat satu menang, kode pemulihan paralel, onboarding atomik, tautan setup sekali pakai paralel, suspend lewat cache hangat → 401 lalu token yang sama pulih, handoff paralel, impersonasi berakhir karena kedaluwarsa/suspend/admin nonaktif, audit limit/flag hanya saat berubah, pemakaian dari rollup, ops), `entitlements` (10 outlet paralel pada batas 3 → tepat 3, tanpa lock untuk merchant tanpa batas, aktivasi di batas meninggalkan kode dapat dipakai, reinstall tetap lolos), grant (`justclick_app` ditolak 42501 pada tabel platform; audit log tidak bisa diubah/dihapus), middleware Backoffice, `Touch`, guard pengimpor `unscoped`, rute |
| gofmt, `go build ./...`, `go vet ./...` | Bersih. gofmt menandai tiga file `internal/infra/jobs` yang tidak disentuh Fase 8 (line ending CRLF di working copy; versi HEAD bersih) |
| `templ generate` | Tidak menghasilkan perubahan |
| staticcheck v0.8.1 | Lulus setelah dua helper view yang tidak terpakai dihapus |
| `go generate ./api` | Hanya komentar `TableStatusEvent` (drift Fase 7), tanpa perubahan tipe |
| `-race` | Tidak dijalankan di mesin ini (butuh cgo); berjalan di CI Linux |

### Uji mutasi

Setiap guard dirusak sementara dari cadangan, test pengawalnya dijalankan, file
dipulihkan (dicek identik byte-per-byte) dan test dijalankan ulang.

| Guard | Mutasi | Tanpa guard | Setelah dipulihkan |
|---|---|---|---|
| Anti-replay TOTP | hapus `AND totp_last_step < $2` | `TestTheSameCodeSignsInExactlyOnceUnderConcurrency` dan `TestTheEnrolmentCodeCannotBeReplayedToSignIn` **gagal** | lulus |
| Lock batas paket | `pg_advisory_xact_lock(…)` → query tanpa lock | `TestConcurrentOutletCreatesStopExactlyAtTheLimit` **gagal 3/3** | lulus 3/3 |
| Audit impersonasi fail-closed | kondisi error → `&& false` | `TestAnImpersonatedChangeIsRefusedWhenItsAuditRowCannotBeWritten` **gagal** (diharapkan 503, dapat 200) | lulus |

Percobaan M3 pertama salah sasaran: penanda yang dipakai muncul dua kali di
`auth.go` dan perl mengganti kemunculan pertama (di `logout`), sehingga test
wajar lulus. Diulang dengan penanda yang dipastikan unik; hasil di atas dari
percobaan kedua.

### Live via HTTPS (Caddy, build API + worker yang sama)

Dijalankan berurutan setelah `docker compose up -d --build api worker caddy`.

| Verifier | Hasil |
|---|---|
| `verify-activation` | Run pertama **berhenti fatal** setelah 7 PASS: `flush redis: i/o timeout`, beberapa menit setelah restart Docker Desktop. Redis kemudian `loading:0`; run ulang sendirian **19 PASS**, warm auth p99 1,75 ms |
| `verify-backoffice` | 21 PASS |
| `verify-backoffice-crud` | 103 PASS |
| `verify-sync` | 61 PASS |
| `verify-push` | 8 PASS (200 baris ×3, 611 percobaan tercatat di audit) |
| `verify-stock` | 12 PASS |
| `verify-tables` | 20 PASS |
| `verify-reports` | 64 PASS. Laporan sebulan dari rollup sama persis dengan SQL mentah; domain p95 **39,4 ms**, halaman p95 **37 ms** (gerbang < 200 ms). Lebih lambat dari Fase 7 (19,7 / 18,8 ms) pada host yang baru di-restart; seed 46.755 order butuh 4 m 56 s. Tidak dianggap regresi tanpa A/B |
| **`verify-platform`** | **60 PASS**, 0 FAIL |

`verify-platform` membuktikan dari luar: panel tertutup tanpa sesi dan POST
tanpa CSRF ditolak; password saja tidak membuka panel; enrolment lewat browser
dan 10 kode pemulihan; kode enrolment tidak bisa di-replay; login dengan kode
pemulihan; cookie platform tidak dikirim ke `/backoffice`; slug salah ditolak;
perusahaan dibuat dengan 3 kategori bernomor; Owner menyetel kata sandi lewat
tautan lalu masuk; tautan terpakai menjawab 410; outlet kedua ditolak pada
`max_outlets=1`; till diaktifkan dengan kode dari Backoffice; penerbitan kode di
batas perangkat ditolak dan kode lama menjawab `422 device_limit_reached`; modul
stok mati → 404 dan hilang dari nav; impersonasi perlu alasan, handoff dari
origin lain ditolak, handoff hanya sekali, banner tampil, perubahan kategori
tercatat di audit, ganti kata sandi Owner ditolak, akhiri kembali ke platform
dan sesi Backoffice hilang; suspend perlu slug, till langsung 401 dan Owner
keluar, reaktivasi memulihkan token yang sama; halaman audit memuat delapan jenis
aksi; ops melihat semua migrasi terpasang; kredensial merchant ditolak membaca
`super_admins`.

## Jalankan ulang

Dari `backend-go/`, env lokal dimuat, Compose aktif, C: punya ruang cukup:

```powershell
go run ./cmd/justclick migrate up
docker compose up -d --build api worker caddy
$env:VERIFY_BASE_URL='https://localhost:8443'
$env:VERIFY_INSECURE_TLS='1' # hanya CA development lokal
go run ./scripts/verify-platform
```

Admin sungguhan: `go run ./cmd/justclick platform admin create --name … --email …`,
lalu masuk ke `https://localhost:8443/platform/login`.

## Gerbang yang masih terbuka

- **Email tautan setup lewat SMTP sungguhan** belum diuji live; diuji dengan
  mailer palsu (terkirim, tidak terkonfigurasi, gagal kirim).
- **Pemeriksaan manual di browser** (tampilan banner, form panel, auto-submit
  handoff dengan JavaScript) belum dilakukan; `verify-platform` memeriksa lewat
  HTTP, bukan rendering.
- **CI** belum menjalankan perubahan ini (belum di-push), termasuk `-race` dan
  `verify-platform` di pipeline.
- Tidak dibangun: QR enrolment, manajemen admin di panel, pembatasan IP
  `/platform`, seed tarif default, flag yang menyentuh feed till.
- Latensi laporan diukur di laptop development yang baru pulih dari disk penuh,
  bukan uji beban.
