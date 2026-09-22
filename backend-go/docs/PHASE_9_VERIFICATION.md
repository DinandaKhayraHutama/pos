# Fase 9 — uji beban & pengerasan

Tanggal verifikasi: 21 September 2026. Acuan: [`../../plan.md`](../../plan.md)
(Fase 9). **Ini bukan persetujuan pilot/rollout**, dan angka di bawah diukur di
laptop pengembangan (Windows 11, 20 vCPU, 23,7 GB RAM, Docker Desktop), bukan di
VPS pilot.

## Yang dibangun

### 1. Harness Go — `scripts/loadtest`

Satu perintah, enam skenario, semuanya bergerbang (exit code 1 kalau gerbangnya
tidak terpenuhi):

```bash
go run ./scripts/loadtest changes   --rate 2000 --duration 60s
go run ./scripts/loadtest orders    --orders-per-second 200 --duration 60s
go run ./scripts/loadtest rush      --devices 15000 --spread both
go run ./scripts/loadtest fanout    --devices 15000
go run ./scripts/loadtest datascale --orders 2000000 --days 30
go run ./scripts/loadtest smoke     # siklus hidup penuh, detik-detikan; dipakai CI
```

Keputusan desain yang menentukan arti angkanya:

- **Model terbuka (open model), bukan closed loop.** Kedatangan dijadwalkan pada
  waktunya sendiri; kalau semua worker sibuk, kedatangan itu **dicatat sebagai
  dropped**, tidak ditunda diam-diam. Closed loop akan melaporkan latensi sehat
  untuk server yang sebenarnya tidak sanggup dipakai. `fanout` sengaja closed
  loop — di sana pertanyaannya "apa yang dikerjakan database", jadi setiap till
  wajib menarik tepat sekali.
- **Tidak ada jalur produksi yang dilewati.** Setiap request terukur membawa
  bearer token asli dan melewati middleware, cache auth dan rate limiter yang
  sama dengan tablet. Yang disederhanakan hanya *provisioning*: baris `devices`
  ditulis langsung, karena mengaktifkan 15.000 tablet lewat limiter aktivasi
  akan mengukur limiter, bukan yang sedang diuji. Aktivasi sungguhan tetap
  diuji di skenario `smoke` dan di `verify-activation`.
- **Harness membaca `/metrics` server sendiri**, sebelum dan sesudah tiap fase,
  sehingga "server lambat" dan "generator tidak sanggup" jadi dua temuan
  berbeda, bukan satu perdebatan. Juga membaca counter cache auth — itulah yang
  menjelaskan temuan serbuan pagi di bawah.
- **Sebar-startup diport persis dari Flutter.** `startupSpread` di harness =
  `startupSpreadFor` di `mobile/lib/data/sync/sync_scheduler.dart`, dikunci
  vektor bersama di `TestTheStartupSpreadMatchesTheFlutterTill` (Go) dan
  `'startup spread matches the load harness on fixed vectors'` (Dart). Kalau
  salah satu bergeser, salah satu suite gagal — tanpa itu, skenario serbuan pagi
  mengukur armada yang tidak ada.
- **Tenant sekali pakai.** Setiap run membuat merchant-nya sendiri dan
  menghapusnya lewat satu `DELETE FROM tenants`, termasuk saat di-Ctrl-C.

### 2. Metrik Prometheus — `internal/infra/metrics`

Listener terpisah (`METRICS_ADDR`, default `:9090`), **bukan** route di server
publik: `/metrics` menyebut setiap antrean internal dan tidak boleh berjarak
satu aturan proxy dari internet. Compose tidak mem-publish port-nya.

| Metrik | Kenapa ada |
|---|---|
| `justclick_push_rows_total{entity,status,code}` | Rejection rate per kode — tanda paling awal build klien yang sedang menghilangkan uang |
| `justclick_http_request_duration_seconds{surface,route,method}` | p99 per route; label pakai **pola routing** chi, bukan URL (kardinalitas) |
| `justclick_sync_pull_rows_total{entity}` | rows/s jalur pull |
| `justclick_device_auth_cache_total{result}` | hit / miss / stale / error — hit ratio cache auth |
| `justclick_pgxpool_*` | Saturasi pool: kalau semua koneksi sibuk, request mengantre dan itu **tidak terlihat di metrik lain** |
| `justclick_river_jobs{queue,state}`, `justclick_report_dirty_slices`, `justclick_report_rollup_staleness_seconds`, `justclick_devices_seen_5m`, `justclick_default_partition_occupied` | Gauge lintas-merchant, dipublikasikan **worker** (satu instance, sudah di allow-list `unscoped`) |

Guard: `TestRequestsAreLabelledByRoutePatternNotByURL` (kardinalitas),
`TestANilMetricsInstrumentsNothingAndPanicsAtNothing` (nil aman, supaya tiap
test/skrip tidak perlu memasang registry), `TestTwoRegistriesDoNotShareState`
(registry privat, bukan default).

### 3. Stack observability — `docker compose --profile observability`

Prometheus v3.14 + Grafana 12.4 (dashboard & datasource ter-provision dari
repo, `allowUiUpdates: false`) + postgres_exporter + redis_exporter +
node_exporter. Hanya Grafana yang dipublish, ke loopback.

- Aturan alert: `ops/prometheus/alerts.yml` — rejection > 0,1%, retry persisten,
  dead job River > 0, kebasian rollup > 15 menit, baris di partisi DEFAULT,
  p99 `/sync/changes` > 20 ms, p99 `/sync/push` > 300 ms, hit ratio cache auth
  < 80%, pool mengantre, tidak ada perangkat terlihat, disk > 75%, Postgres/Redis
  tak terjangkau.
- **Dua alert dari rencana sengaja tidak ada**, dengan alasan tertulis di file
  itu: umur backup > 26 jam (pgBackRest belum ada) dan sertifikat < 20 hari
  (Caddy tidak mengekspor metrik; butuh blackbox_exporter). Aturan yang tidak
  mungkin menyala lebih buruk daripada aturan yang tidak ada — ia terlihat
  seperti perlindungan.

### 4. Pengerasan

| Perubahan | Alasan |
|---|---|
| `PG_MAX_CONNS` / `PG_UNSCOPED_MAX_CONNS` / `PG_MIN_CONNS` (`pg.Limits`) | pgx default `max(4, NumCPU)` — properti jatah CPU kontainer, bukan properti database. Di box 2 vCPU itu 4 koneksi untuk seluruh API, dan gejalanya latensi tanpa query lambat |
| Tuning Postgres di Compose | `shared_buffers`, `effective_cache_size`, `work_mem`, `random_page_cost=1.1`, `wal_compression=zstd`, `autovacuum_vacuum_scale_factor=0.02`, `autovacuum_analyze_scale_factor=0.01`. **`synchronous_commit=on` ditulis eksplisit dan tidak dibuat konfigurabel — itu uang** |
| Migrasi 019: role `justclick_metrics` | Exporter tidak boleh memegang kredensial owner. `pg_monitor` saja, tanpa satu pun grant tabel; dijaga `TestTheMetricsCredentialCanReadStatisticsAndNoMerchantData` |
| postgres_exporter: `--no-collector.stat_user_tables`, `--no-collector.statio_user_tables`, scrape 30s | Diukur: query per-tabelnya ~78–100 ms per scrape dan tumbuh mengikuti jumlah relasi (skema ini menambah partisi tiap bulan) |
| `TestTheOpsReportSeesThisSchemaAsCurrent` tidak lagi menulis versi migrasi literal | Literal itu membuat setiap migrasi baru menggagalkan test tentang halaman ops, yang mengajari orang mengedit assertion alih-alih membacanya |

---

## Hasil terukur

Lingkungan: PostgreSQL 18 + Redis 8 di Docker Desktop, API dan generator di host
yang sama. **Semua angka di bawah ditandai jalur mana yang diukur**, karena
perbedaannya ternyata besar (lihat "Batas pengukuran").

### Skenario 1 — `/sync/changes`

Gerbang rencana: 2.000 rps di satu instance, p99 < 20 ms.

| Run | Jalur | rps | p50 | p99 | max | dropped | gagal |
|---|---|---|---|---|---|---|---|
| Awal sesi | API host | 2.000 | 2,61 ms | **5,89 ms** | 17,0 ms | 0 | 0 |
| Kontainer #1 | Caddy → API kontainer | 1.995 | 5,04 ms | 30,2 ms | 420 ms | 280 | 0 |
| Kontainer #2 | Caddy → API kontainer | 1.999 | 5,10 ms | **17,0 ms** | 232 ms | 77 | 0 |

120.000 request per run, semuanya HTTP 200 objek JSON. **p50 stabil 2,6–5,1 ms
di seluruh run**; yang bergerak adalah ekor, karena stall singkat di host
(max 232–420 ms) — perilaku host yang sudah tercatat sejak Fase 2B.

Bukti struktural yang lebih penting daripada angka latensi: dengan `--pgstat`,
**120.000 request menghasilkan nol statement aplikasi di `pg_stat_statements`** —
yang tercatat hanya job latar River. Jalur cepat itu memang dilayani Redis
sepenuhnya saat cache hangat, dan itulah alasan armada 15.000 perangkat bisa
polling tanpa menyentuh database.

### Skenario 2 — order push

Gerbang rencana: 200 order/s, p99 < 300 ms, tanpa lock baris tenant, tidak ada
yang hilang.

| Bentuk armada | order/push | order/s | p50 | p99 | mean server | ditolak | hilang |
|---|---|---|---|---|---|---|---|
| 600 till / 200 outlet | 1 | **199,8** | 42,3 ms | **265,9 ms** | 54,7 ms | 0 | 0 |
| 600 till / 200 outlet | 5 | **199,6** | 159,9 ms | **295,5 ms** | 157,8 ms | 0 | 0 |
| 60 till / 20 outlet | 1 | **199,9** | 34,4 ms | **100,9 ms** | 36,9 ms | 0 | 0 |

Ketiganya lulus. Yang diperiksa selain latensi:

- **12.000 diterima → 12.000 baris `orders` → 12.000 reservasi `order_dedupe`.**
  Tidak ada yang hilang, tidak ada yang ganda.
- **Nol baris di `orders_default`** — semua mendarat di partisi bertanggal.
- **Nol transaksi menunggu di baris tenant**, dari 300 sampel `pg_locks` per run.
- Mean sisi-server (54,7 ms) praktis sama dengan mean sisi-klien (55,4 ms):
  yang diukur memang server, bukan generator.

### Skenario 3 — serbuan pagi, 15.000 perangkat

Model: pembukaan till mengelompok dalam 60 detik pertama (`--launch burst`),
lalu sebar-startup `hash(device_id) mod 300s` ditambahkan di atasnya. Till yang
sudah mutakhir saat tutup kemarin melakukan **tepat satu** request — itulah yang
membuat pagi hari bisa dilalui sama sekali.

| Fase | rps tertahan | detik tersibuk | p50 | p99 | hit ratio cache auth |
|---|---|---|---|---|---|
| Sebar **mati** (kasus terburuk) | 250 | **288** | 8,24 ms | 21,4 ms | **1,00** (0 miss) |
| Sebar **nyala** | **42,0** | **73** | 10,2 ms | 96,9 ms | **0,66** (5.034 miss) |

15.000 dari 15.000 till terlayani di kedua fase, nol kegagalan. Sebar-startup
meratakan puncak **3,9×** (288 → 73 rps).

**Gerbang "di bawah 50 rps" diukur sebagai laju tertahan, bukan detik
tersibuk.** `hash mod 300` adalah undian seragam ke 300 ember satu detik: dengan
15.000 till rata-rata ember berisi 50, dan ember tersibuk dari beberapa ratus
ember berada ~3σ di atasnya secara konstruksi. Menuntut puncak detik < 50 sama
dengan menuntut keacakan berhenti acak. Yang dijanjikan sebar-startup — dan yang
layak dipegang — adalah pagi datang sebagai dataran, bukan paku.

**Temuan: TTL cache auth (5 menit) sama panjang dengan jendela sebar (300 s),
jadi sepertiga armada selalu membayar jalur dingin.** Fase sebar-nyala berjalan
357 detik; entri yang dihangatkan sebelum run kedaluwarsa di tengahnya, dan
5.034 request membaca ulang seluruh rantai perangkat dari PostgreSQL. Itulah
kenapa fase yang **lebih sepi** (42 rps) punya ekor lebih buruk daripada fase
250 rps. Ini bukan masalah beban; ini dua konstanta yang kebetulan sama.
Pilihannya — menaikkan TTL cache (mis. 15 menit) atau memendekkan jendela sebar
— **tidak diambil di Fase 9**: TTL itu adalah jaring pengaman terakhir kalau
publikasi generasi revoke gagal, jadi memperpanjangnya adalah keputusan keamanan,
bukan keputusan performa. Angkanya sekarang ada; keputusannya milik pemilik
produk.

### Skenario 4 — fan-out katalog

Satu produk diubah lewat writer sungguhan (`catalogue.SaveProduct`), lalu seluruh
armada menarik.

| Armada | pull `products` | baris dikembalikan | blok dibaca dari disk | rencana |
|---|---|---|---|---|
| 2.000 till | **2.000** | **2.000** (1/panggilan) | **0** | Index Only Scan `products_sync_feed_idx` |
| 15.000 till | **15.000** | **15.000** (1/panggilan) | **0** | Index Only Scan `products_sync_feed_idx` |

Persis klaim rencana: mengubah satu produk membebani database **tepat satu
index-only scan per till dan tidak lebih**. 15.000 till selesai dalam 17,8 detik
pada 841 rps, nol kegagalan.

Catatan jujur: satu pull adalah tiga statement (konteks tenant transaksi, scan
feed, baca counter). Yang digerbangi adalah scan — satu-satunya yang tumbuh
mengikuti ukuran katalog.

### Skenario 5 — skala data

| Ukuran | Seed | Rollup | Laporan sebulan p50 / p95 | Statement yang menyentuh tabel mentah |
|---|---|---|---|---|
| 99.900 order | 96,8 s | 10,7 s (180 slice) | 62,7 / **92,5 ms** | **0** |
| 1.999.980 order | 276,6 s | 58,6 s (180 slice) | 80,0 / **100,9 ms** | **0** |

**Data 20× lipat menambah 9% latensi laporan.** Itu klaim strukturalnya,
terbukti: laporan membaca rollup, jadi ia tumbuh mengikuti jumlah slice (181),
bukan jumlah order. Buktinya bukan opini — `pg_stat_statements` direset tepat
sebelum 20 laporan dijalankan, lalu dicari statement mana pun yang menyebut
`orders`/`order_items`: nol.

Pada 2 juta order: `orders_2026_09` 1,6 GiB (1.333.230 baris, autovacuum 19×),
`orders_2026_08` 800 MiB (666.688 baris, autovacuum 4×), rasio dead/live 0,000
di semua partisi, nol baris di `orders_default`.

**30 juta order tidak dijalankan di sini, dan tidak boleh dijalankan di sini.**
Ekstrapolasi dari run 2 juta: ±69 menit seed, ±15 menit rollup, dan **±36 GB**
tabel+index — sementara C: hanya punya 34 GB kosong. Fase 8 sudah pernah
kehilangan satu run karena disk penuh (PostgreSQL masuk recovery mode di tengah
suite). Perintahnya untuk dijalankan di VPS pilot:
`go run ./scripts/loadtest datascale --orders 30000000 --days 30 --json var/loadtest/datascale-30m.json`.

### Plafon terdegradasi — Redis dimatikan

Diminta eksplisit oleh rencana. `docker compose stop redis`, lalu `changes`:

| rps | p50 | p99 | mean | gagal |
|---|---|---|---|---|
| 250 (laju armada sebenarnya) | 13,1 ms | **31,2 ms** | 14,1 ms | 0 |
| 500 | 11,1 ms | **33,7 ms** | 12,7 ms | 0 |
| 1.000 | 96,5 ms | **340,8 ms** | 120,2 ms | 0 |

Tanpa Redis, satu instance melayani **±500 rps dengan nyaman dan patah di antara
500 dan 1.000** — dua kali lipat kebutuhan tertahan armada 15.000 perangkat
(250 rps). Nol request gagal di ketiga laju: auth jatuh ke PostgreSQL dan rate
limiter mengizinkan, persis seperti yang dirancang. Setiap hasil run mencatat
status Redis di `environment.redis`, supaya run dengan cache mati tidak pernah
terbaca sebagai regresi.

---

## Temuan

### 1. `report_dirty_slices` adalah statement termahal di jalur uang

Di setiap run order, upsert penanda slice kotor adalah statement dengan total
waktu eksekusi tertinggi — dan biayanya mengikuti **laju order per outlet**,
karena semua till di satu cabang memperebutkan satu baris `(tenant, outlet,
tanggal)` yang sama:

| Bentuk armada | order/s per outlet | mean upsert penanda |
|---|---|---|
| 60 till / 20 outlet, batch 5 | 10 | **5,56 ms** |
| 600 till / 200 outlet, batch 5 | 1 | **1,06 ms** |

Insert lain di transaksi yang sama berada di 0,25–0,5 ms. Jadi selisihnya adalah
tunggu lock baris, bukan kerja.

**Bukan masalah pada skala rencana**: 1 juta order/hari ÷ 5.000 outlet ≈ 0,04
order/s per outlet, ribuan kali lebih rendah dari yang diuji di sini. Yang akan
menabraknya adalah **satu outlet yang sangat sibuk** (food court, stadion) di
atas ±5 order/s. Bentuk perbaikannya, kalau nanti perlu: ganti penanda yang
di-upsert dengan **log kotor append-only** yang dikuras job rollup — tidak ada
baris yang diperebutkan. Itu mendesain ulang invariant generasi milik Fase 7,
jadi **sengaja tidak dikerjakan di Fase 9**; angkanya dicatat di sini.

### 2. Tidak ada partisi bulan lampau, dan seed historis akan mendarat di DEFAULT

`app.ensure_ingest_partitions()` membuat bulan berjalan + 3 bulan ke depan. Itu
**benar untuk lalu lintas hidup** — perangkat tidak bisa push ke bulan yang sudah
lewat tanpa partisinya masih ada. Tapi backfill/seed historis bisa, dan
`orders_default` adalah tempat yang tidak dilihat job laporan maupun retensi.
Skenario `datascale` membuat partisi lampau yang dibutuhkannya sendiri (dan
menghapusnya lagi kalau kosong), dan mencatat catatan yang menjelaskannya.
Kalau nanti ada impor data historis sungguhan, ini yang harus diingat.

### 3. Exporter per-tabel postgres_exporter membebani database yang berpartisi

Query `pg_stat_user_tables`/`statio_user_tables` miliknya: **78–100 ms per
scrape** pada 86 relasi, dan skema ini menambah partisi setiap bulan. Dimatikan
(lihat Pengerasan). Dashboard tidak memakainya; harness membacanya langsung saat
sebuah run memang membutuhkannya.

### 4. Backlog listener: 300 dial serentak dijawab RST di Windows

Fase pemanasan harness sempat membuka koneksi sebanyak `--workers` sekaligus;
di atas ±200 koneksi serentak, Windows menjawab SYN dengan RST ketika antrean
accept penuh, dan Go melaporkannya sebagai *"connection refused"* — persis
seperti server yang tidak berjalan. Pemanasan sekarang dibatasi 64 koneksi
serentak, dengan komentarnya di kode.

### 5. Gerbang p99 lokal tidak stabil, dan sekarang ada mekanismenya

Run yang sama berayun dari p99 5,89 ms ke 227 ms dalam satu sesi. A/B-nya
menunjuk satu arah: proses API **di host** mencapai Redis/Postgres lewat proxy
port Docker Desktop, dan jalur itu melambat setelah berjam-jam beban; API **di
kontainer** (Redis/Postgres lewat jaringan internal), diukur lewat Caddy, tetap
di mean 5,5–6,0 ms pada 2.000 rps di sesi yang sama.

| Jalur (2.000 rps, sesi yang sama) | mean | p99 | dropped |
|---|---|---|---|
| API host, profil observability **nyala** | 46,0–56,3 ms | 320–394 ms | 5.065–6.988 |
| API host, profil observability **mati** | 15,5–31,6 ms | 55,5–227,7 ms | 1.844–1.857 |
| Caddy → API kontainer, observability nyala | **5,5–6,0 ms** | 17,0–30,2 ms | 77–280 |

Dua efek, keduanya lingkungan: scrape observability mengambil CPU yang sama
(host: p99 320 → 227 ms saat dimatikan), dan proxy port Docker Desktop jauh
lebih mahal daripada jaringan internal kontainer (227 → 17–30 ms).

Artinya: **ukur lewat kontainer, jangan lewat API host**, dan perlakukan gerbang
p99 lokal sebagai indikatif — seperti yang sudah ditulis sejak Fase 2B. Gerbang
sungguhannya adalah VPS pilot dengan generator di box terpisah.

---

## Bukti verifikasi

### Otomatis

| Pemeriksaan | Hasil |
|---|---|
| `go test ./... -count=1` (PostgreSQL 18 + Redis asli) | **25 paket lulus**, 0 gagal. Modul kini **288 test top-level** (271 di Fase 8) |
| Test baru | `metrics` (kardinalitas label, nil aman, registry terpisah, hitung push/pull/cache), `loadtest` (paritas sebar-startup dengan Dart, model terbuka menjatuhkan kedatangan alih-alih menundanya, persentil, penuduh tabel mentah, aritmetika struk), `pg` (batas kredensial metrik) |
| `gofmt`, `go build ./...`, `go vet ./...`, staticcheck v0.8.1 | Bersih. gofmt masih menandai tiga file `internal/infra/jobs` yang tidak disentuh Fase 9 (CRLF di working copy sejak Fase 8) |
| `templ generate` | Tidak menghasilkan perubahan |
| `-race` | Tidak dijalankan di mesin ini (butuh cgo); berjalan di CI Linux |

### Live

Dijalankan berurutan terhadap **API host** (`http://127.0.0.1:9000`, build yang
sama dengan kontainer), kecuali dua baris terakhir yang ditandai.

| Verifier | Hasil |
|---|---|
| `verify-activation` | Lulus (termasuk 429 + `Retry-After`, perangkat dicabut ditolak seketika) |
| `verify-sync` | Lulus; Index Only Scan untuk semua feed; p50 2,64 ms / p99 4,28 ms |
| `verify-push` | Lulus (200 baris ×3, 611 percobaan di audit, partisi `orders_2026_09`) |
| `verify-stock` | Lulus; lock baris pada `tenants` setelah run: 0 |
| `verify-tables` | Lulus; lock baris pada `tenants` setelah run: 0 |
| `verify-backoffice`, `verify-backoffice-crud` | Lulus |
| `verify-platform` | Lulus |
| `verify-reports` | Lulus **lewat API kontainer (Caddy HTTPS)**. Lewat API host dua check gagal (404 unduhan ekspor) karena API host dan worker kontainer tidak berbagi `REPORTS_DIR` — artefak setup terpisah, bukan regresi; pesan check-nya sendiri sudah menyebut penyebabnya |
| `loadtest smoke` | Lulus di kedua jalur (host dan **API kontainer**): aktivasi lewat endpoint sungguhan, tarik semua feed, buka laci, 3 struk, 1 gerakan stok, sinkron ulang |

### Stack observability

Dijalankan penuh dan diperiksa lewat API Prometheus/Grafana:

- 6 target scrape, **semuanya `up`** (api, worker, postgres, redis, node, prometheus).
- 14 aturan alert termuat.
- Setiap seri yang dipakai dashboard mengembalikan data nyata:
  `justclick_fleet_scrape_ok=1`, `justclick_river_jobs` (22 job),
  `justclick_report_rollup_staleness_seconds=0`,
  `justclick_default_partition_occupied=0`, `pg_up=1`, `redis_up=1`,
  `node_filesystem_avail_bytes` (37 filesystem), `pg_stat_activity_count`,
  `pg_locks_count`, `redis_keyspace_hits_total`.
- Grafana mem-provision datasource dan dashboard `justclick-fleet` — 16 panel
  dalam 4 baris — dari file di repo.

## Jalankan ulang

Dari `backend-go/`, env lokal dimuat, C: punya ruang cukup:

```powershell
docker compose up -d --build api worker caddy
docker compose --profile observability up -d   # opsional; lihat catatan di bawah
go run ./cmd/justclick migrate up
go run ./cmd/justclick roles set-password      # juga menyetel justclick_metrics

$env:VERIFY_BASE_URL='https://localhost:8443'; $env:VERIFY_INSECURE_TLS='1'
go run ./scripts/loadtest changes --rate 2000 --duration 60s --workers 200 --base-url $env:VERIFY_BASE_URL --insecure-tls --pgstat
go run ./scripts/loadtest orders  --orders-per-second 200 --duration 60s --devices 600 --workers 300 --base-url $env:VERIFY_BASE_URL --insecure-tls
go run ./scripts/loadtest rush    --devices 15000 --spread both --workers 200 --base-url $env:VERIFY_BASE_URL --insecure-tls
go run ./scripts/loadtest fanout  --devices 15000 --base-url $env:VERIFY_BASE_URL --insecure-tls
go run ./scripts/loadtest datascale --orders 2000000 --days 30
```

Grafana: `http://127.0.0.1:3000`, user `admin`, password `GRAFANA_PASSWORD`.
**Matikan profil observability saat mengambil angka gerbang di satu box** —
scrape-nya ikut menempati CPU yang sama dengan server yang sedang diukur.

Hasil lengkap tiap run (termasuk top-20 `pg_stat_statements` sebelum dan
sesudah) ada di `var/loadtest/*.json`; direktori itu gitignored.

## Gerbang yang masih terbuka

- **Uji beban di VPS pilot dengan generator terpisah belum dilakukan.** Semua
  angka di atas dari satu laptop yang juga menjalankan database, cache dan
  generator. Itu yang menentukan kapasitas produksi, bukan ini.
- **30 juta order belum di-seed** (butuh ±36 GB; disk tidak cukup).
- **Alert backup dan sertifikat belum bisa ditulis** — pgBackRest belum ada,
  Caddy tidak mengekspor umur sertifikat. Keduanya tercatat di `alerts.yml`
  beserta ekspresi yang akan dipakai begitu sumber datanya ada.
- **Alert belum punya tujuan pengiriman** (Alertmanager belum dipasang); aturan
  menyala di Prometheus dan terlihat di sana saja.
- **UAT perangkat keras** masih tertahan, seperti sejak Fase 6.
- **CI belum menjalankan perubahan ini** (belum di-push), termasuk `-race` dan
  `loadtest smoke` di pipeline.
- Keputusan TTL cache auth vs jendela sebar-startup (Temuan serbuan pagi)
  menunggu pemilik produk.
