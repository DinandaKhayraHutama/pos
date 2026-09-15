# Fase 3 — push order dan sesi

Tanggal: 13 September 2026. Acuan: `../../plan.md` dan `../api/openapi.yaml`.

Status: implementasi Fase 3 selesai dan verifikasi lokal lulus, termasuk suite
Linux race penuh. Gerbang Fase 0–2 dijalankan lebih dahulu dan dicatat di
`PHASE_0_2_VERIFICATION.md`.

## Implementasi

- `POST /api/v2/sync/push`, wajib bearer token dan `X-Schema-Version`.
  Maksimal 200 row total / 4 MiB. Envelope rusak → 400/413; isi row salah →
  hasil per row HTTP 200. Tidak ada 422 di jalur push.
- Manifest memuat `pos_sessions` lalu `orders`, keduanya `push:true,pull:false`.
  `/sync/changes` tetap memuat cursor entity pull saja.
- Setiap raw row di-commit ke `ingest_log` sebelum validasi/domain diproses.
  Jika audit tidak bisa disimpan, domain tidak dijalankan dan hasilnya retry.
- Setiap row bisnis memakai transaksi tersendiri. Order, item, modifier,
  dedupe, dirty marker, dan enqueue River commit/rollback bersama.
- Uang integer; identitas tenant/outlet/register berasal dari token. Snapshot
  struk immutable. Audit settlement memerlukan nama authorizer dan alasan.
- Sesi memiliki partial unique index satu drawer terbuka per register. Sesi
  tertutup tidak dapat dibuka atau dihitung ulang. Receipt offline boleh tiba
  setelah sesinya ditutup; session yang belum tiba menghasilkan retry/dependency_pending.
- `order_dedupe` mempertahankan UUID global, tanggal bisnis pertama, dan binding
  device/register. Order yang sudah diarsipkan tidak disisipkan ulang.
- Order/item/modifier: partisi bulanan, bulan berjalan +3 bulan, DEFAULT sebagai
  jaring pengaman. Audit: partisi harian, hari berjalan +7 hari, retensi 90 hari.
- Parent dan child finansial memiliki FORCE RLS. Job River juga difilter tenant
  dari args; worker global memakai credential unscoped, bukan owner DDL.
- Worker River `maintenance` menjalankan pemeliharaan partisi/retensi per jam
  dan saat startup. DEFAULT terisi memunculkan error log untuk operator. Fungsi
  DDL dibatasi ke tabel/rentang internal; credential API tidak boleh memanggilnya.

## Bukti yang sudah dijalankan

| Kasus | Hasil |
|---|---|
| Suite Go akhir | 170 fungsi test tingkat atas; seluruh paket lulus `go test ./... -race -count=1` di Linux dengan PostgreSQL 18/Redis asli |
| Analisis statis | `go vet`, staticcheck v0.8.1, golangci-lint v2.13.2 lulus; 0 issues |
| Generator | templ, OpenAPI, sqlc: hash output sebelum/sesudah identik |
| 200 row ×3 lewat HTTPS | Tetap 200 orders, dedupe, items dan modifiers; total tepat Rp2.000.000 |
| Audit percobaan pada verifier | Seluruh 611 attempt tersimpan, termasuk row invalid dan rejected |
| Retry UUID paralel 8 penulis | Satu order dan satu set detail; seluruh retry identik accepted |
| Retry dengan tanggal bergeser | Tetap tanggal dan order pertama, tidak pindah partisi |
| Settled/refund + retry | Retry revisi tersimpan accepted; perubahan/reopen ditolak |
| Closed drawer + busy register | Tidak reopen/restatement; konflik menyertakan holder session/name |
| Row `[]`, scalar, null, invalid | Rejected per row; tetangga valid tetap diterima |
| Konflik modifier pada receipt lain | Header/item/reservasi receipt baru ikut rollback |
| INSERT River sengaja dicabut | Retry; uang/detail/dedupe rollback; audit tetap tersimpan |
| Lock timeout pada satu UUID | Retry, bukan rejected; receipt berikutnya tetap commit |
| Tenant row ditahan penulis lain | Ingest tetap selesai; FK key-share normal tidak dilarang |
| UUID arsip / device register lain | Tidak dapat membuat ulang atau menimpa receipt/session |
| Routing partisi | Bulan ini +3 bulan dan DEFAULT untuk tanggal lama, header/detail konsisten |
| Tenant lain / tanpa konteks | Tidak membaca tabel finansial, audit, dirty marker, atau job tenant |
| Worker nyata | River menjalankan job maintenance sampai completed |
| Retensi | Child audit >90 hari dihapus; batas 90 hari, tabel bukan child, order dan dedupe tetap ada |
| Regresi Fase 0–2 lewat HTTPS | Aktivasi 17, Backoffice 21, CRUD 80, sync 53 lulus setelah rebuild |
| Regresi beban `/sync/changes` | Target 2.000 rps ×60s; 120.001 iterasi, p99 1,31 ms, HTTP failure=0, dropped=0, checks=100% |

Uji konkurensi memakai PostgreSQL asli. Verifier hidup menggunakan Caddy TLS
lokal di `https://localhost:8443`, bukan hanya mock handler. Pengujian gateway
memeriksa array/null/envelope/trailing JSON, body lebih dari 4 MiB, dan batch
lebih dari 200 row. CI sekarang menjalankan `verify-push` bersama verifier lama.

Uji beban terakhir dijalankan terpisah setelah race suite selesai, satu API di
jaringan Docker internal dengan auth/limiter aktif. k6 melaporkan minimum
durasi negatif sekitar −0,56 ms pada host Docker Desktop ini (anomali clock);
angka latensi lokal tersebut bukan sertifikasi SLO VPS. Gate sebelum Fase 3
juga telah lulus pada dua run yang tercatat di dokumen Fase 0–2.

## Penyesuaian terhadap contoh plan

1. **Idempotensi adalah state bisnis, bukan jumlah audit.** Percobaan retry
   memang menambah ingest_log; receipt/detail/timestamp bisnis/dirty generation
   dan jumlah job tidak berubah pada retry identik.
2. **Tidak memakai `xmax` sebagai API bisnis.** `INSERT ... ON CONFLICT DO NOTHING`
   memberi affected-row count. Reservasi UUID dikunci per order; pembacaan
   berikutnya memakai snapshot baru sehingga konflik dengan insert yang baru
   commit terlihat. Update tetap mempunyai predikat `settled_at IS NULL` /
   `closed_at_ms IS NULL` dan revision. Lock tersebut tidak mencakup tenant.
3. **Bulk SQL untuk detail.** `jsonb_array_elements` menyisipkan semua item dan
   modifier dalam dua statement, bukan round trip per item. Query berada di
   `internal/store/queries/ingest.sql`, hasilnya digenerate sqlc.
4. **Retry sukses bukan penolakan.** Revisi tersimpan + payload sama → accepted,
   bahkan saat final. Revisi sama tetapi payload berbeda → duplicate. Revisi
   lebih lama → stale_revision (atau settled/session_closed jika sudah final).
   Client hanya boleh menghapus revisi outbox yang sama dengan ACK.
5. **Unit price mengikuti Flutter.** Harga per unit sudah mencakup modifier dan
   varian (`CartLine.unitPrice`); modifier adalah rincian audit. Menambah delta
   lagi adalah hitung ganda. Regression test khusus menjaga invariant ini.
6. **RLS juga melindungi job.** River dipasang di schema `jobs`; metadata job
   tenant tidak boleh dapat dibaca oleh query biasa tanpa konteks tenant.
7. **River migration bukan satu transaksi gabungan.** Pinned River v0.47.0
   memiliki perubahan enum yang perlu commit sebelum versi berikutnya memakainya.
   Goose menjalankan langkah Go yang dapat diulang, tetap di bawah deploy lock.

Transaksi enqueue mengikuti [River transactional enqueueing](https://riverqueue.com/docs/transactional-enqueueing).
Perhatikan [River unique jobs](https://riverqueue.com/docs/unique-jobs): deduplikasi
job bukan dengan sendirinya jaminan bahwa perubahan saat job running ikut dihitung.

## Handoff dan batas yang tetap berlaku

Fase 7 belum dilaksanakan: queue `reporting` sengaja belum dikonsumsi, bukan
diselesaikan dengan worker kosong. `report_dirty_slices` dan job `report_slice`
tersimpan atomik sebagai pekerjaan laporan mendatang. Worker Fase 7 wajib
mengatasi perubahan dirty generation selama recompute; jangan menghapus marker
berdasarkan snapshot lama. Belum ada klaim laporan atau ekspor sudah siap.

Fase 4 belum dilaksanakan. Flutter yang ada masih memakai sync lama; keamanan
outbox v2 dan dead-letter lokal harus diimplementasikan dan diuji sebelum pilot.
UAT hardware, push load 200 order/s, 30 juta order, backup/restore, pengiriman
alert eksternal dan Fase 9/rollout bukan hasil dari verifikasi ini.

Jika DEFAULT berisi tanggal yang perlu dibuat partisinya, PostgreSQL dapat
menolak CREATE PARTITION sampai operator memindahkan data secara transaksional.
Worker mengeluarkan error/retry, tidak memindahkan atau menghapus receipt secara
otomatis. Kapasitas audit dan dedupe harus diukur dari data sebenarnya; angka
24 byte/row di plan tidak memperhitungkan binding, heap, dan index.

## Jalankan ulang

Dari `backend-go`, muat `.env` development (jangan cetak secret):

```powershell
go run ./cmd/justclick migrate up
docker compose up -d --build api worker
go test ./... -count=1
go vet ./...
go generate ./api ./internal/store
$env:VERIFY_BASE_URL = 'https://localhost:8443'
$env:VERIFY_INSECURE_TLS = '1'
go run ./scripts/verify-push
```

Gunakan Go Linux + gcc untuk `go test ./... -race -count=1`, dengan database dan
Redis asli. Jalankan verifier yang mengosongkan Redis secara berurutan, lalu
jalankan `go run ./scripts/verify-sync-load` tanpa suite DB lain bersamaan.
Verifier hanya menghapus tenant/job fixture yang dibuat invocation tersebut.
