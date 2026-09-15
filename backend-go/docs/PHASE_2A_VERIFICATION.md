# Verifikasi dan handoff Fase 2A

Tanggal pemeriksaan: 10 September 2026. Acuan: `../../plan.md`.

Pembaruan 13 September 2026: Fase 0–2 telah diverifikasi ulang dan kontrak
OpenAPI dibekukan. Lihat [gerbang akhir Fase 0–2](PHASE_0_2_VERIFICATION.md)
dan [hasil Fase 3](PHASE_3_VERIFICATION.md). Catatan di bawah adalah hasil
pemeriksaan historis 10 September.

**Status: gerbang Fase 2A di environment lokal lulus; siap lanjut Fase 2B.**

## Batas pekerjaan

Fase 2A mencakup counter sync ter-shard, alokasi dalam transaksi, tombstone,
manifest/changes/pull, watermark Redis, dan gerbang verifikasinya. Perbaikan
ini juga menegakkan aturan respons JSON objek dan pemeriksaan versi schema
pada endpoint sync yang sudah ada.

CRUD Backoffice adalah Fase 2B. OpenAPI dibekukan pada akhir Fase 2. Push order/
sesi adalah Fase 3; Flutter v2 adalah Fase 4; stok, meja, laporan, platform dan
River tetap pada fase berikutnya. Tidak ada implementasi fitur-fitur itu di sini.

## Bukti perbaikan

| Pemeriksaan | Hasil |
|---|---|
| Reproduksi cursor melewatkan commit di antara dua SELECT | Test lama gagal: halaman kosong mengakui seq 1 dan halaman sebagian mengakui seq 2 tanpa row-nya. Setelah `REPEATABLE READ READ ONLY`, keduanya lulus dan pull berikutnya menerima row yang baru commit. |
| Lock counter hingga commit, isolasi tenant, tombstone dan pagination | Lulus suite PostgreSQL/Redis asli. |
| `go vet ./...`, build, `go test ./... -count=1` | Lulus; 72 fungsi test tingkat atas, ditambah subtest. |
| `go test ./... -race -count=1` | Lulus di container Linux, Go 1.27 Alpine + gcc/musl-dev. |
| `verify-sync` melalui Caddy HTTPS | 53 check lulus: 5.000 row untuk masing-masing 12 feed, zero duplicate, cursor konvergen, cold Redis fallback, izin/schema/JSON, dan seluruh covering index. |
| `verify-backoffice`, `verify-activation` melalui HTTPS | Keduanya lulus, termasuk aktivasi dari kode panel, revoke, CSRF, 429 dan Retry-After. |
| Source terbaru di Compose | API di-rebuild; endpoint sync kini tersedia pada container yang dilayani Caddy. |

Test snapshot menggunakan tracer pgx untuk commit writer pada koneksi kedua
tepat sebelum query counter. Ini deterministik, tanpa sleep atau hook produksi.
Transaksi write tidak dinaikkan isolation level-nya. Referensi semantik:
[PostgreSQL 18 transaction isolation](https://www.postgresql.org/docs/18/transaction-iso.html).

`X-Schema-Version` wajib pada manifest/changes/pull: hilang atau terlalu lama
→ 409 `device_schema_outdated`; bukan angka → 400 `malformed_request`.
`render.JSON` menolak encoded array/scalar/null dan kegagalan encoding sebelum
menulis status sukses, lalu mengirim objek error 500. OpenAPI contract test
tetap pada akhir Fase 2.

EXPLAIN memeriksa setiap feed setelah VACUUM ANALYZE pada 5.000 row, mengambil
500 row setelah seq 4500. Planner tetap bebas memilih rencana. Pada dataset
kecil yang membaca sebagian besar tabel, Seq Scan dapat menjadi pilihan wajar;
nama Index Only Scan juga tidak menjamin nol heap fetch pada halaman yang baru
berubah. Fixture tidak mengubah setting planner untuk membuat test hijau.

## Uji beban k6

Runner: `go run ./scripts/verify-sync-load`. k6 1.8.0 dalam Docker, executor
`constant-arrival-rate`, 2.000 iterasi/detik selama 60 detik setelah warmup.
Satu iterasi = satu GET `/api/v2/sync/changes`. Menggunakan 2.000 token unik,
satu tenant, 667 outlet beban, sekitar tiga register per outlet; autentikasi
dan limiter produksi tetap aktif. Data diterbitkan pada setiap feed untuk
memastikan payload cursor benar. Fixture lookup tambahan berisi satu outlet/
register untuk seed katalog. Tenant dan file token sementara dibersihkan
otomatis setelah run, termasuk jika threshold gagal; cache uji akan kedaluwarsa.

Mesin: Intel Core i7-13650HX; Docker Desktop melihat 20 CPU logis dan sekitar
11,5 GiB RAM. Satu container API, Postgres, Redis, dan generator berbagi host.
Target beban default `http://api:9000` di jaringan Compose; uji fungsional
terpisah menggunakan `https://localhost:8443`. Ini bukti lokal untuk gate
pengembangan, bukan ukuran kapasitas VPS produksi atau pengganti Fase 9/UAT.

Threshold: p99 <20ms, HTTP failure=0, seluruh check respons benar,
`dropped_iterations=0`. Referensi:
[k6 constant arrival rate](https://grafana.com/docs/k6/latest/using-k6/scenarios/executors/constant-arrival-rate/).

Run awal dengan 100 VU preallocated: p99 1,23ms, respons benar 100%, tetapi
97 dropped iterations; **gagal gate**. Runner diperbaiki untuk menyiapkan 400
VU sebelum pengukuran sehingga tidak perlu alokasi VU saat ada jeda scheduler.
Threshold tidak dilonggarkan.

Run final, 400 VU preallocated, **exit code 0**:

| Metrik skenario `changes` | Hasil |
|---|---|
| Arrival rate / durasi | 2.000 request/detik / 60 detik |
| Request terukur | 120.001 |
| p50 / p95 / p99 | 0,477 ms / 0,702 ms / **1,10 ms** |
| Respons HTTP gagal | 0 |
| Check objek, cursor dan metadata | 120.001 dari 120.001 lulus |
| Dropped iterations | **0** |

Request warmup sebanyak 2.000 tidak termasuk metrik skenario tersebut. Angka
request/s ringkasan global k6 memasukkan waktu setup, sehingga gunakan rate
skenario, jumlah iterasi dan dropped iterations untuk menilai target arrival
rate. Image `grafana/k6:1.8.0` pada run ini ber-digest
`sha256:b992f241070f3f3a7d78096fa6020db1edcda49297ee8ed9eb0ab847ef3dcb32`.

## Langkah cek manual di Windows

Gunakan PowerShell dari `backend-go/`. `.env` harus menunjuk database/Redis
pengembangan lokal. Verifier membuat lalu menghapus tenant uji dan mengosongkan
Redis untuk menguji fallback; jalankan secara berurutan di environment dev.

1. Muat environment tanpa mencetak rahasia:

   ```powershell
   Get-Content .env | ForEach-Object {
     if ($_ -match '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
       [Environment]::SetEnvironmentVariable($matches[1], $matches[2], 'Process')
     }
   }
   ```

2. Siapkan database dan build API terbaru:

   ```powershell
   docker compose up -d postgres redis
   go run ./cmd/justclick migrate up
   go run ./cmd/justclick roles set-password
   docker compose up -d --build api
   docker compose up -d caddy
   docker compose ps
   curl.exe -k --fail https://localhost:8443/health
   ```

   Harapan: Postgres/Redis healthy dan health berisi objek JSON `status: ok`.
   Opsi `-k` khusus sertifikat CA lokal Caddy. Perbaikan ini tidak menambah
   migration; database harus sudah memiliki migration 001–008.

3. Jalankan suite otomatis dan perhatikan exit code nol:

   ```powershell
   go vet ./...
   go build ./...
   go test ./... -count=1
   go test ./internal/domain/syncfeed -run TestPullDoesNotSkipACommitBetweenRowsAndCounter -v -count=1
   ```

   Harapan: 72 test tingkat atas lulus; dua subtest snapshot (`empty_page`,
   `partial_page`) lulus. `-race` dijalankan oleh CI Linux; bukti lokal Linux
   juga telah diperiksa pada closeout ini.

4. Verifikasi API yang benar-benar hidup melalui HTTPS:

   ```powershell
   $env:VERIFY_BASE_URL = 'https://localhost:8443'
   $env:VERIFY_INSECURE_TLS = '1'
   go run ./scripts/verify-activation
   go run ./scripts/verify-backoffice
   go run ./scripts/verify-sync
   ```

   Harapan: ketiganya `all checks passed`. Verifier sync menampilkan 53 PASS,
   termasuk fixture lengkap setiap entity dan 12 Index Only Scan. Jika route
   sync 404, pastikan langkah `--build api` sukses; menjalankan `up -d` saja
   tidak memperbarui binary dari source yang berubah.

5. Uji endpoint secara langsung menggunakan token perangkat dev milik Anda:

   ```powershell
   # $deviceToken berisi token dev dari hasil aktivasi Anda; jangan commit token.
   curl.exe -k -i -H "Authorization: Bearer $deviceToken" https://localhost:8443/api/v2/sync/manifest
   curl.exe -k -i -H "Authorization: Bearer $deviceToken" -H 'X-Schema-Version: 0' https://localhost:8443/api/v2/sync/manifest
   curl.exe -k -i -H "Authorization: Bearer $deviceToken" -H 'X-Schema-Version: 1' https://localhost:8443/api/v2/sync/manifest
   curl.exe -k -i -H "Authorization: Bearer $deviceToken" -H 'X-Schema-Version: 1' 'https://localhost:8443/api/v2/sync/pull?entity=products&after_seq=0&limit=500'
   ```

   Harapan: dua request pertama 409, berikutnya 200 berupa objek. Pull boleh
   kosong bila tenant dev belum mempunyai katalog yang diterbitkan. Layar CRUD
   untuk mengisinya baru dibangun pada Fase 2B; gunakan verifier untuk fixture.

6. Jalankan gate beban saat suite/verifier lain sudah selesai:

   ```powershell
   go run ./scripts/verify-sync-load
   ```

   Harapan: seluruh threshold hijau dan exit code nol. Runner memakai Docker
   sehingga tidak perlu memasang k6 ke Windows. `LOAD_BASE_URL`, `LOAD_NETWORK`,
   `LOAD_RATE`, `LOAD_DURATION` dapat diubah untuk diagnosis; hasil dengan rate
   <2000 atau durasi <60s tidak menutup gate standar. Jangan mematikan limiter
   atau menghapus threshold untuk meluluskan run.

## Checklist pekerjaan berikutnya: Fase 2B

- Buat CRUD merchant yang tercantum dalam plan, memakai domain write API.
- Setiap create/edit/delete yang dipublikasikan menggunakan `syncfeed.Write`,
  seq dalam transaksi yang sama, dan watermark setelah commit.
- Jangan biarkan initial row pada seq 0; pastikan outlet/register baru dan
  rename-nya dapat ditarik. Owner provisioning sudah mengalokasikan seq.
- Periksa data seed dev lama yang masih seq 0 ketika menyiapkan CRUD.
- Tambah test create/edit/tombstone dari domain penulis sampai feed, termasuk
  perubahan child/join. Pertahankan registry allow-list, RLS dan urutan FK.
- Bekukan OpenAPI serta contract test object-2xx pada akhir Fase 2. Flutter,
  push, stok/meja, laporan dan platform tetap menunggu fasenya.
