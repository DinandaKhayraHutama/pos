# Gerbang sebelum Fase 3

Tanggal: 13 September 2026. Acuan: `../../plan.md`.

Fase 0, 1, 2A, dan 2B telah diverifikasi ulang secara lokal sebelum implementasi
push dimulai. Bukti ini melengkapi, bukan mengganti, catatan 2A/2B sebelumnya.
Ini bukan persetujuan produksi, UAT perangkat nyata, atau pembuktian kapasitas VPS.

## Bukti pengujian

| Gerbang | Hasil pada pemeriksaan ini |
|---|---|
| Suite seluruh paket Go | Lulus `go test ./... -count=1` |
| Linux race detector | Lulus `go test ./... -race -count=1`, Go 1.27 Alpine, PostgreSQL 18/Redis asli |
| Pemeriksaan statis | `go vet`, staticcheck v0.8.1, golangci-lint v2.13.2: 0 issues |
| Generator | templ v0.3.1020, oapi-codegen v2.8.0, sqlc v1.31.1: hash sebelum/sesudah identik |
| HTTPS lokal, API dibangun ulang | Aktivasi 17, Backoffice 21, CRUD 80, sync 53 pemeriksaan lulus |
| Auth hangat | 1.000 lookup berhasil; p50 1,05 ms, p99 1,53 ms (<3 ms) |
| Beban perubahan | Dua run 2.000 rps ×60s; masing-masing 120.001 iterasi; p99 2,35 ms dan 1,17 ms; HTTP failure=0, dropped=0, checks=100% |
| Pull | Seluruh 12 feed, masing-masing 5.000 baris, pagination lengkap dan Index Only Scan; PostgreSQL snapshot race test lulus |
| OpenAPI | Validasi dokumen, objek pada seluruh delapan respons sukses, allow-list seluruh feed, tipe baris nyata PostgreSQL cocok schema |
| Isolasi | RLS termasuk tabel `tenants`; tanpa konteks tidak membaca baris dan INSERT ditolak; context transaksi tidak bocor |

Uji beban memakai satu API pada Docker Desktop, jaringan internal HTTP,
2.000 token pada 667 outlet; limiter dan auth tetap aktif. Run kedua dilakukan
setelah suite race/verifier selesai. Verifikasi fungsional terpisah melewati
Caddy HTTPS. Tidak ada threshold yang dilonggarkan. Angka host lokal tidak
boleh dipromosikan menjadi jaminan untuk 15.000 perangkat produksi.

## Kekurangan yang ditutup

- Migration 011 melindungi root tenant dengan RLS dan menyimpan generasi auth
  di database. Binding dan generasi dibaca dalam snapshot yang sama; pengisian
  cache terlambat tidak dapat menghidupkan token yang sudah dicabut. TTL entri
  dibatasi umur snapshot dan kedaluwarsa token. Missing generation = cache miss.
- Penerbitan kode, aktivasi, dan revoke memakai urutan lock register lalu
  kode/device; tidak ada lock baris tenant. Test balapan penerbitan/aktivasi lulus.
- Gangguan database pada autentikasi menghasilkan 503 + Retry-After, bukan 401
  yang akan memaksa tablet aktivasi ulang. Redis tidak wajib tersedia saat boot.
- Proxy header tidak dipercaya secara default. Compose hanya membuka Caddy;
  Caddy menimpa header IP privat, sehingga IP palsu tidak melewati limiter.
- Watermark Redis membandingkan integer sebagai string desimal (tanpa rounding
  Lua di atas 2^53), dan publish nilai lama tidak memperpanjang TTL stale key.
- Counter SQL dipindah ke query sqlc, tetap menggunakan transaksi penulis.
  Migrasi CLI memakai session advisory lock goose. Nama database test mempertahankan
  suffix acak sekalipun nama test panjang.
- CI memeriksa generator API/SQL, lint, dan SQL lock multiline. Guard lock adalah
  pemeriksaan source tambahan, bukan pengganti pengujian konkurensi database.
- Verifier auth sebelumnya mengukur 200 request dengan bucket 120 dan tidak
  memeriksa status sampel. Kini HTTP memakai 80 request sukses dan SLO auth
  diukur terpisah dengan 1.000 lookup sukses, bukan respons 429.

## Batas cache keamanan

PostgreSQL tetap otoritas. Revoke langsung berlaku setelah invalidasi Redis
berhasil; kegagalan publikasi setelah commit dicatat sebagai error dan stale
cache dibatasi TTL maksimum lima menit. Jangan mengklaim pencabutan seketika
ketika invalidasi gagal. Redis yang tidak dapat dibaca selalu jatuh ke database.
Sebelum rollout besar, tambahkan outbox invalidasi jika SLA pencabutan menuntut
batas lebih ketat daripada TTL pada kegagalan parsial.

## Kontrak Fase 2

Baseline `api/openapi.yaml` v2.0.0 adalah acuan Flutter. Model respons dihasilkan,
bukan disalin manual. Kontrak push ditentukan sebelum implementasi Fase 3:

- Correlation berdasarkan `(batch_index, row_index)`, ditambah id/revision bila valid.
- Setiap revisi di-outbox harus immutable; ACK hanya mengakui revisi yang dikirim.
- Retry identik = accepted meskipun transaksi sudah final; perubahan setelah
  settled/closed = rejected. `retry` tidak boleh menghapus antrean.
- `changes` hanya petunjuk; cursor lokal hanya maju bersama apply halaman pull.
- Satu baris gagal tidak membatalkan uang pada baris lain. Payload invalid tetap
  harus dapat dipulihkan dari audit; audit percobaan boleh bertambah pada retry,
  sedangkan state bisnis harus identik.

Pernyataan plan bahwa `pg_locks` untuk `tenants` harus selalu kosong bukan gate
yang benar: SELECT dan FK boleh memegang relation lock. Yang dilarang adalah
serialisasi penjualan pada baris tenant, bukan semua lock PostgreSQL.
Lihat [PostgreSQL pg_locks](https://www.postgresql.org/docs/18/view-pg-locks.html).

## Ulangi

Dari `backend-go`, muat `.env` lokal tanpa mencetak secret, jalankan migrate up,
build Compose API, lalu suite/vet/lint/generator. Jalankan verifier satu per satu
(beberapa mengosongkan Redis development), baru `go run ./scripts/verify-sync-load`.
Untuk Linux race, gunakan image Go dengan gcc, kredensial test, dan host database
`postgres:5432`/Redis `redis:6379` di jaringan `justclick_default`.
