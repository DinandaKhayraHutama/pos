# Rencana Implementasi Fase 4 — Saved Bill dan Siklus Pesanan Restoran

**Tanggal penyusunan:** 24 September 2026  
**Status:** rencana implementasi; belum dieksekusi.  
**Prasyarat:** implementasi Fase 3 selesai.  
**Acuan:** [Roadmap paritas MokaPOS](RENCANA_PARITAS_FITUR_MOKAPOS.md), terutama F4, aturan desain A–E, dan gerbang penyelesaian fase.

Dokumen ini disusun dari pembacaan seluruh roadmap, analisis bisnis lokal, memory proyek, serta penelusuran kode setelah F3. Ini **audit statis**, bukan hasil menjalankan ulang pengujian. Bukti F3 tetap mengacu pada [FASE_3_VERIFICATION.md](FASE_3_VERIFICATION.md): gate otomatis lokal tercatat lulus; build Windows release, workflow GitHub aktual, dan UAT interaktif dua perangkat masih tertunda. Sisa gate tersebut harus dibawa ke verifikasi F4, bukan dianggap sudah lulus.

Semua path kode di dokumen ini relatif terhadap **root monorepo**. Nomor fase di sini adalah **paritas F4**, bukan fase 4 roadmap backend lama di `mobile/docs/PHASE_4_VERIFICATION.md`.

## 0. Revisi rancangan saat eksekusi (24 September 2026)

Bagian ini ditulis saat implementasi dimulai, setelah menelusuri ulang kode. Bagian §1–§12 di bawahnya tetap menjadi catatan rencana asal; **bila keduanya berbeda, bagian §0 inilah yang diimplementasikan**. Kriteria lulus roadmap F4 tidak diubah: bill utuh setelah aplikasi dihentikan, simpan bill tidak menambah pendapatan, retry kirim dapur tidak menggandakan stok, dan perangkat kedua tidak dapat mengedit bill milik perangkat pertama.

Prinsip revisi: **pakai ulang mekanisme yang sudah terbukti** (snapshot outbox berrevisi, efek stok bersarang, gate kapabilitas F3, kasus recovery F0) dan buang mesin baru yang tidak dibutuhkan invariant. Setiap mesin koordinasi tambahan adalah sumber kebenaran kedua yang harus dijaga sinkron — pola cacat yang paling sering ditemukan UAT proyek ini.

| # | Rencana asal | Implementasi | Alasan berbasis kode |
|---|---|---|---|
| R1 | Log operasi `bill_operations` (seq, predecessor, generation per operasi, scheduler dependency) | **Snapshot bill berrevisi** (entity `bills`) + **fakta immutable** (entity `kitchen_dispatches`, receipt `orders`) | `_outbox` sudah menyimpan satu snapshot per `(entity, id)` dan ACK per revisi; `ingestSale` sudah membuktikan pola "efek immutable bersarang, revisi berikut tidak boleh menghilangkannya". Dispatch sebagai baris immutable tersendiri memberi urutan stok per kejadian tanpa rantai predecessor. Urutan antar-entity cukup `bills → kitchen_dispatches → orders` di satu request. |
| R2 | Handoff bertarget (offer/accept/cancel) + park/claim | **Park + claim saja** (keduanya online, CAS pada baris bill, `owner_generation` naik) | Handoff = A parkir, B klaim. Satu pemenang dijamin oleh lock baris bill; tidak ada race accept vs cancel yang perlu protokol sendiri. Mencakup pergantian shift dan serah bill antar perangkat. |
| R3 | `GET /till/bills/changes` dengan cursor, watermark, cache per viewer | **`GET /till/bills`**: snapshot lengkap bill terbuka + sesi meja aktif outlet, diambil saat dibutuhkan | Jumlah bill terbuka per outlet kecil dan terbatas; satu snapshot konsisten per permintaan lebih sederhana dan tidak bisa "melewatkan" perubahan. Cache `_remote_bills` diganti utuh per fetch. |
| R4 | Drain checkpoint per device, epoch cutover | **Pola gate F3**: kapabilitas `bills-v1`, `outlet_settings.bill_model` hanya bisa `v1` bila semua device aktif outlet melapor kapabilitas; aktivasi build lama ditolak | Receipt legacy tetap receipt legacy yang sah — tidak ada tafsir ganda yang perlu dikuras. Satu-satunya benturan nyata adalah event status meja lama; ditangani dengan `superseded` selama sesi meja aktif. |
| R5 | `bill_payments`, `bill_settlements`, `bill_adjustments` | Pembayaran tetap di **receipt (`orders`)**; bill menyimpan `closed_order_id`; pembatalan bill ada di snapshot bill; full refund F4 memakai jalur refund order yang ada **ditambah pilihan restock eksplisit** | Menghindari dua sumber kebenaran uang. Rekonsiliasi kas shift sudah membaca `orders`. Ledger pembayaran baru dibuat di F5 saat split payment benar-benar membutuhkannya. |
| R6 | D2: bill mensyaratkan `pricing_model = v2` | Bill berjalan di **pricing v1 dan v2**; konfigurasi harga dibekukan di bill apa pun versinya | Pembekuan tidak bergantung versi engine. Mode demo (legacy pricing) harus bisa memperagakan saved bill. |
| R7 | `bill_prebills` per revisi | Pre-bill mencetak **revisi saat ini** dengan nomor revisi dan waktu | Pre-bill bukan dokumen fiskal; cetak ulang revisi lama tidak dibutuhkan alur restoran. |
| R8 | D8: maksimal satu bill belum lunas per sesi meja | **Boleh beberapa bill** per sesi meja; meja hanya dapat dilepas bila tidak ada bill terbuka | Lebih sederhana, tetap memenuhi "tambah pesanan setelah bayar = bill baru di sesi yang sama". |
| R9 | Tutup shift diblokir bila bill lunas masih punya dispatch belum selesai | Tidak memblokir | Progres dapur milik perangkat pemilik bill, bukan milik laci; shift berikutnya di perangkat yang sama tetap dapat menandai `served`. |
| R10 | Quarantine per operasi bill setelah forced takeover | Receipt terlambat → **quarantine F0 yang ada** (sesi force-closed). Snapshot/dispatch dari generation lama → ditolak `bill_not_owned`, tersimpan di dead-letter perangkat sebagai bukti | Forced takeover mencabut token perangkat, sehingga operasi terlambat baru bisa datang setelah re-aktivasi. Receipt (uang) tetap melewati keputusan manajer; dispatch terlambat tercatat sebagai bukti dan manajer menyesuaikan stok bila perlu. Keterbatasan ini dicatat di verifikasi. |
| R11 | Draft autosave keranjang | Tidak dibuat; **Simpan bill** adalah tindakan eksplisit, bill tersimpan pulih penuh setelah restart | Memulihkan keranjang yang tidak pernah disimpan berisiko menghidupkan pesanan yang sudah dibatalkan tamu. Kriteria roadmap hanya menyangkut bill tersimpan. |

Temuan tambahan saat penelusuran: `ingestSale` memanggil `stock.RecordFromDevice` per movement, dan setiap panggilan mengunci satu baris proyeksi lalu counter (baris → counter → baris). Pada receipt hal ini **tidak** menghasilkan deadlock, karena `MarkReportDirty` di `ingestOrder` sudah menyerialkan receipt per outlet dan tanggal sebelum efek stok — uji mutasi membuktikannya. Dispatch F4 tidak memiliki serialisasi itu: dengan penerapan per movement, dua dispatch berurutan produk terbalik saling menunggu dan satu dibatalkan sebagai deadlock (uji mutasi `TestDispatchesWithReversedProductsDoNotDeadlock` gagal dengan `retry`). F4 menambahkan penerapan batch (`RecordBatchFromDevice`: kunci semua baris terurut, baru counter) untuk dispatch, pembatalan, dan receipt. Temuan kedua: menghitung efek sebuah receipt (`ref_type/ref_id`) tidak memiliki index sehingga memindai ledger merchant; migrasi 036 menambahkan `stock_movements_ref_idx`.

Yang **tidak** berubah dari rencana asal: bill terpisah dari receipt; simpan bill tanpa penjualan/pembayaran/stok; stok berkurang sekali saat kirim dapur termasuk penjualan langsung; pelunasan tanpa konsumsi ulang; satu editor per bill dengan `owner_generation`; pengikatan meja dan pelepasan meja online; pembayaran tidak melepas meja; tutup shift ditolak bila masih ada bill terbuka milik sesi itu; pembatalan sesudah dispatch meminta keputusan restock/waste; barrier stock opname lintas entity; semua skenario penerimaan yang masih relevan di §10.

## 1. Hasil bisnis yang dituju

Restoran dapat melayani satu kunjungan dengan alur berikut:

1. Kasir membuka bill, memilih pelanggan/pelayan dan, bila diperlukan, mengikat meja secara online.
2. Bill disimpan tanpa menerima uang dan tanpa mengurangi stok.
3. Kasir mengonfirmasi pesanan untuk diproses melalui **Kirim dapur**. Stok untuk bagian tersebut berkurang satu kali.
4. Bill dapat dibuka kembali dan ditambah. Pengiriman berikutnya hanya memproses tambahan.
5. Pre-bill dapat dicetak dengan tanda **BELUM LUNAS**, nomor bill dan revisinya.
6. Pelanggan membayar penuh dengan satu metode manual. Pembayaran menghasilkan satu struk final dan satu pengakuan penjualan, tanpa konsumsi stok ulang.
7. Meja tetap terpakai setelah pembayaran. Staf melepas meja setelah pelayanan selesai dan tamu meninggalkan meja.
8. Saat pergantian shift, bill diselesaikan, diserahkan kepada perangkat lain, atau diparkir di server. Uang masuk ke shift yang menerima pembayaran.

Penjualan langsung tetap cepat: satu tindakan **Bayar** menjalankan konfirmasi sisa pesanan dan pelunasan dalam satu transaksi lokal; satu operasi atomik menjalankan efek yang sama di server.

### Batas fase

| Masuk F4 | Tetap di fase berikutnya |
|---|---|
| Bill persisten, draft yang dapat dipulihkan, simpan/buka/tambah, metadata pelanggan/pelayan/catatan | Split bill dan split payment, DP, piutang/invoice |
| Status bill, pembayaran, dapur dan pemakaian meja yang terpisah | Void per item/kuantitas dan refund parsial F5 |
| Dispatch dapur logis, revisi dan snapshot baris, konsumsi stok tepat sekali | Printer LAN, routing printer/kategori, antrean cetak tahan restart F6 |
| Handoff online, parkir/claim, pemulihan kepemilikan, guard tutup shift | Pindah/gabung meja dan editor denah F6 |
| Sesi meja, waktu mulai/selesai, indikator durasi sederhana | Analisis omzet/durasi meja lanjutan F6 |
| Aktivitas bill terbuka, penjualan lunas dan pembatalan, Backoffice baca/audit | Cash in/out, cash drop, petty cash, Z-report lengkap F5 |
| Ledger pembayaran dasar dan jembatan koreksi **seluruh** transaksi agar kemampuan lama tidak hilang | Model alokasi refund terperinci dan rekonsiliasi pembayaran campuran F5 |

“Kirim dapur” pada F4 berarti pesanan telah dikonfirmasi untuk diproses, bukan klaim tiket sudah tercetak pada perangkat dapur. UI menyediakan daftar pengiriman dan statusnya. Cetak pre-bill tetap memakai fasilitas PDF/dialog sistem yang tersedia. Deployment dan integrasi eksternal tidak termasuk.

## 2. Baseline kode dan konsekuensinya

| Temuan setelah F3 | Bukti utama | Konsekuensi bagi F4 |
|---|---|---|
| SQLite **v32**, migrasi Go terakhir **035**, Device API **2.8.0**; `X-Schema-Version` masih **1** | `mobile/lib/data/database/app_database.dart`, `backend-go/migrations/`, `backend-go/api/openapi.yaml`, `mobile/lib/data/sync/sync_client.dart` | Bedakan versi database lokal, versi API, versi feed dan kapabilitas. Jangan mengambil angka v28/020 dari audit roadmap awal. |
| Keranjang hidup di memori dan membawa objek produk/varian/modifier | `mobile/lib/providers/cart_provider.dart` | Membuka kembali bill harus membaca snapshot persisten, bukan menyusun ulang dari master yang sudah berubah. |
| Checkout membuat `OrderStatus.preparing`, tetapi sudah menulis `amount_paid`, metode bayar, struk dan stok | `mobile/lib/data/repositories/order_repository.dart` (`create`) | `preparing` lama adalah transaksi yang sudah dibayar. Menambah `saved` ke enum order akan mencampurkan pendapatan dan pesanan. |
| Semua status selain `cancelled/refunded` dihitung sebagai revenue | `mobile/lib/data/models/enums.dart` (`kRevenueStatusSql`), `backend-go/internal/domain/reporting/rollup.go` | Bill belum lunas harus berada di model berbeda; semua query uang perlu diaudit, bukan hanya dashboard. |
| Receipt yang sudah diterima tidak boleh berubah nominal atau barisnya | `backend-go/internal/domain/ingest/orders.go` (`immutableOrder`) | Bill mutable tidak dikirim sebagai revisi `orders`. Pisahkan bill dari struk. |
| Efek stok coordinated till dikirim nested dalam order; pengiriman sale/return mandiri ditolak | `backend-go/internal/domain/ingest/sale.go`, `ingest.go`; `mobile/lib/data/sync/order_push.dart` | Perlu jalur dispatch dengan otoritas sendiri. Settlement F4 tidak boleh melewati `ingestSale` lama lalu memotong stok lagi. |
| `StockRepository.recordWithin` hanya menahan push mandiri bila memiliki `orderId` | `mobile/lib/data/repositories/stock_repository.dart` | Tambah identitas sumber operasi secara eksplisit; movement dispatch jangan bocor ke dua jalur push. |
| `_outbox` satu snapshot terbaru per `(entity, entity_id)` | `mobile/lib/data/sync/outbox_store.dart` | Gunakan UUID operasi sebagai `entity_id` F4 agar dua dispatch tidak saling menimpa. |
| ACK mencocokkan revisi; stok memakai `stock_seq`; status meja memakai `status_seq` | `outbox_push.dart`, `stock_repository.dart`, `table_repository.dart` | ACK F4 harus mengembalikan bukti efek lengkap, bukan sekadar `accepted`. |
| Status meja memakai event eventual dengan penanda konflik, bukan reservasi eksklusif | `backend-go/internal/domain/tables/tables.go` | Tambah sesi meja yang diklaim online. Status manual lama tidak boleh membebaskan meja dengan bill aktif. |
| Sesi/laci dikuasai satu device; penugasan kasir aktif unik; tidak ada heartbeat takeover | `backend-go/internal/domain/ingest/till.go`, `mobile/lib/data/device/till_coordinator.dart` | Handoff bill berbeda dari handover kasir dalam laci yang sama. Jangan memindahkan sesi/struk lama antar register. |
| Tutup sesi memeriksa `order_count`; client juga menahan push close saat antrean bisnis/dead-letter masih ada | `backend-go/internal/domain/ingest/sessions.go`, `mobile/lib/data/sync/outbox_push.dart` | `order_count` belum mencakup bill/dispatch tanpa struk. Tambah barrier operasi dan pemeriksaan bill terbuka. |
| Mesin harga Go/Dart, golden vector, snapshot F3, kapabilitas dan role kustom tersedia | `backend-go/internal/domain/pricing/`, `mobile/lib/providers/pricing_provider.dart`, `testdata/pricing/` | Pakai mesin dan permission yang ada. Tambahkan kalkulasi dari snapshot bill, jangan membuat mesin ketiga. |
| Histori remote terpisah, di-cache per viewer dan hanya baca | `mobile/lib/data/repositories/remote_order_repository.dart`, `backend-go/internal/domain/history/` | Bill perangkat lain membutuhkan cache operasional sendiri dan claim/handoff sah sebelum menjadi editor. |
| Recovery F0 menyimpan bukti; jalur approval saat ini khusus order | `backend-go/internal/domain/ingest/recovery.go`, `mobile/lib/data/recovery/recovery_inspector.dart` | Perluasan recovery menjadi pekerjaan inti F4, bukan cukup menambahkan kode error. |

Sebagian paragraf lama di `AGENTS.md`/`CLAUDE.md` masih menyebut versi, role dan perilaku sebelum F3. Untuk baseline, gunakan kode dan bagian F3 terbaru; perbarui bagian yang bersinggungan ketika implementasi selesai. Rincian penyimpangan rencana F3 ada di [RENCANA_IMPLEMENTASI_FASE_3.md](RENCANA_IMPLEMENTASI_FASE_3.md), termasuk penggunaan Hamilton largest-remainder dan penugasan metode bayar melalui grup.

## 3. Keputusan rancangan untuk eksekusi

Aturan satu editor, handoff online, stok saat konfirmasi, penjualan saat lunas, snapshot, dan meja terpisah dari pembayaran **sudah berasal dari roadmap**. Pilihan berikut adalah **default usulan F4**, bukan keputusan pengguna yang sudah dikonfirmasi sebelumnya.

| ID | Default implementasi | Alasan |
|---|---|---|
| D1 | `bills`/`bill_lines` terpisah; `orders` tetap struk final. | Mempertahankan ingest, histori dan rollup transaksi lama. |
| D2 | Connected outlet mengaktifkan `bill_model = 'v1'` secara eksplisit setelah `pricing_model = 'v2'` dan konfigurasi bisnis tersedia. Default outlet lama `legacy`. | Memakai snapshot harga lengkap F3 dan menghindari perilaku harga berbeda antar editor. Tidak otomatis mengaktifkan outlet yang belum memilih harga v2. |
| D3 | Kapabilitas `bills-v1` per outlet; aktivasi satu arah setelah cutover terverifikasi. | Client lama tidak memahami konsumsi stok sebelum struk. |
| D4 | Satu metode, pelunasan penuh, satu struk per bill pada F4. Ledger pembayaran disiapkan sebagai baris tersendiri. | Fondasi F5 tersedia tanpa mengaktifkan cicilan atau pembayaran campuran. |
| D5 | Konfigurasi pajak/layanan/pembulatan, sales type dan profil pre-bill dibekukan saat simpan pertama. Harga setiap baris dibekukan saat baris disimpan. Tambahan baru mengambil harga katalog yang diketahui saat ditambahkan. | Sync master tidak mengubah janji harga bill lama. Harga tambahan yang berbeda ditampilkan sebagai baris berbeda. |
| D6 | Baris yang sudah dikirim tidak dapat dihapus, dikurangi atau diganti produk/varian/modifier/catatan dapurnya. Tambahan selalu baris baru. | Pengiriman tambahan mudah ditelusuri; void item/revisi produksi terperinci menjadi F5. |
| D7 | Dispatch F4 memilih baris utuh yang belum dikirim. HPP dan status tracked/untracked dibekukan saat konfirmasi baris. | Satu baris tidak menyimpan dua biaya unit dari pengiriman yang berbeda; tidak perlu alokasi kuantitas parsial F5. |
| D8 | Satu sesi meja aktif per meja, maksimal satu bill **belum lunas** dalam sesi tersebut. Bill baru boleh dibuat setelah bill sebelumnya lunas; sesi dapat memiliki beberapa struk. | Memenuhi tambah pesanan, termasuk tambahan setelah bayar, tanpa menyunting struk final. |
| D9 | Ikat/claim/parkir/handoff/lepas meja dan pembatalan sesudah dispatch dilakukan online. Pemilik dapat simpan, tambah, kirim, ubah progres dapur dan melunasi offline pada sesi kasir sah. | Koordinasi bersama membutuhkan server; pembayaran normal tetap tahan gangguan jaringan. |
| D10 | Pembatalan seluruh bill sebelum lunas tersedia, dengan alasan dan izin. Sesudah dispatch, keputusan restock/waste eksplisit per baris terkirim. | Makanan yang sudah dibuat tidak otomatis kembali ke stok. Ini pembatalan bill penuh, bukan void item sebagian. |
| D11 | Full refund struk F4 dipertahankan melalui adapter koreksi baru, online dan pada perangkat penerima pembayaran; tidak lewat `_settle` lama. | Mencegah regresi kemampuan penuh yang sudah ada sekaligus menjaga snapshot, waktu refund, dan stok asal dispatch. Detail ada di §7. |
| D12 | Bill yang diparkir tetap unpaid dan terlihat sebagai pekerjaan operasional, tanpa jatuh tempo/piutang. Dapat melewati tengah malam bila layanan belum selesai. | Shift/laporan memakai waktu pembayaran; invoice lintas hari tetap di luar scope. Tidak ada auto-cancel saat hari berganti. |

Jika D2, D6, D8 atau D11 berubah saat review produk, perbarui kontrak dan skenario penerimaannya sebelum implementasi terkait. Rencana tetap dapat dimulai dari pemetaan invariant dan kontrak dengan default ini.

### Status yang berdiri sendiri

| Dimensi | State F4 | Aturan |
|---|---|---|
| Bill | `draft` lokal → `open` → `closed` atau `cancelled` | `closed` berarti pelunasan selesai; dapur bisa masih bekerja. Draft belum menjadi bill server. |
| Pembayaran | `unpaid` → `paid` | Refund adalah record koreksi terpisah; status refund diturunkan dari koreksi. Tidak ada `partial` pada F4. |
| Dispatch dapur | `queued` → `preparing` → `ready` → `served`; `cancelled` lewat pembatalan sah | Setiap batch mempunyai status sendiri. Bill dapat menampilkan ringkasan campuran. Tidak mengubah revenue. |
| Kepemilikan | `owned`, `handoff_pending`, `parked`, `recovery_required` | Connectivity/sync status terpisah; `parked` tidak mengubah payment status. |
| Sesi meja | `active` → `closed` | Pembayaran tidak menutup sesi meja. |
| Sinkronisasi lokal | `pending`, `acknowledged`, `blocked`, `recovery_required` | Label tersinkron tidak menggantikan status bisnis. |

Nilai wire asing untuk state baru harus ditampilkan tidak dikenal dan **tidak boleh memberikan hak mutasi**; jangan fallback ke meja kosong atau bill yang dapat diedit.

### Efek setiap tindakan

| Tindakan | Stok | Uang/laporan penjualan | Nomor struk | Meja |
|---|---|---|---|---|
| Autosave draft / simpan / buka / ubah metadata | Tidak bergerak | Tidak ada | Tidak dialokasikan | Pengikatan pertama hanya melalui server |
| Kirim dapur | Konsumsi baris baru saja | Belum revenue | Tidak dialokasikan | Tetap aktif |
| Cetak pre-bill | Tidak bergerak | Tidak ada pembayaran | Memakai nomor bill, bukan nomor struk | Tidak berubah |
| Bayar bill yang semua barisnya terkirim | Tidak bergerak | Satu payment + satu sale | Dialokasikan sekali | Tetap aktif |
| Bayar dengan sisa baris belum terkirim | Konfirmasi sisa dan konsumsi sekali | Payment + sale dalam operasi sama | Dialokasikan sekali | Tetap aktif |
| Ubah status dapur | Tidak bergerak | Tidak berubah | Tidak berubah | Tidak berubah |
| Batal sebelum dispatch | Tidak bergerak | Pembatalan operasional, tanpa refund | Tidak ada | Masih perlu pelepasan eksplisit |
| Batal sesudah dispatch | Restock hanya barang yang benar-benar kembali; waste tanpa debit kedua | Tidak ada penjualan; biaya waste operasional terlihat | Tidak ada | Masih perlu pelepasan eksplisit |
| Handoff / parkir / claim | Tidak bergerak | Tidak berubah | Tidak berubah | Tidak berubah |
| Lepas meja | Tidak bergerak | Tidak berubah | Tidak berubah | Tertutup setelah konfirmasi server |

## 4. Model data dan invariant

### 4.1 PostgreSQL

Nomor migrasi baru dimulai **sesudah 035**, dengan timestamp aktual saat implementasi. Jangan mengedit migrasi 031 atau migrasi F3 yang sudah diterapkan. Pembagian yang disarankan: fondasi bill/operasi → dispatch/pembayaran/stok → meja/kepemilikan/recovery → reporting/feature gate. Nomor final mengikuti urutan dependency, bukan dipaksakan dari dokumen ini.

| Entitas baru/perluasan | Isi utama dan constraint |
|---|---|
| `bills` | UUID, tenant/outlet, label bill, lifecycle, revision, owner device/register/session, owner generation, creator/pelayan/pelanggan snapshot, note, sales type, pricing config, timestamps, referensi table session. Metadata asal tidak ditimpa ketika owner berubah. |
| `bill_lines` | UUID stabil, bill, urutan stabil, revisi, qty integer positif, snapshot produk/brand/kategori/varian/modifier, harga/diskon/tarif, note, custom flag, status pengiriman. Referensi master tidak boleh cascade menghapus snapshot. |
| `bill_operations` | UUID operasi, bill, jenis, owner generation, expected/result revision, device/session/operator asal, sequence, dependency, canonical payload/hash, result lengkap, waktu kejadian dan diterima. Keunikan `(tenant, bill, generation, sequence)` serta UUID operasi. Operasi diterima immutable. |
| `kitchen_dispatches` + `kitchen_dispatch_lines` | UUID batch, bill, operasi asal, status, line ID + revision + qty dan snapshot dapur/HPP. Constraint satu pengiriman aktif per baris utuh F4; pembatalan tidak menghapus record. |
| `bill_payments` | UUID, bill, settlement operation, metode id/nama/kind/referensi, amount applied, tendered, change, cashier, receiving device/register/session, waktu dan business date. Satu penerimaan penuh per bill pada F4; aturan ini dilonggarkan secara eksplisit pada F5. |
| `bill_settlements` | Satu mapping unik per bill ke payment, order UUID dan **business date order**. UUID order tetap masuk `order_dedupe`; foreign key ke `orders` harus membawa partition key, bukan hanya UUID. |
| `bill_adjustments` | Pembatalan bill penuh atau full refund F4: ID operasi, reason, actor/approver, referensi payment/dispatch, nominal komponen reversal, session/date refund, snapshot restock/waste. Append-only; tidak digunakan untuk partial refund. |
| `table_sessions` | UUID, tenant/outlet/table, waktu mulai/selesai, actor, revision. Partial unique index `(tenant, outlet, table)` untuk sesi belum ditutup. Relasi bill menyimpan identitas sesi, bukan hanya nama meja. |
| `bill_handoffs` / riwayat ownership | Offer ID, source/target, revision barrier, generation lama/baru, pending/accepted/cancelled, actor dan result idempotensi. Park/claim juga meninggalkan event. |
| `stock_movements` | Tambahkan sumber operasi/baris dispatch dan link reversal; gunakan ledger/projection yang sama. `ref_type/ref_id` yang ada diperluas dengan referensi baris yang tidak ambigu. |
| Recovery dan barrier sesi | Perluas case/item/event F0 untuk operasi bill beserta dependensinya; checkpoint device/session dan kaitan bill yang terpengaruh. |
| `outlet_settings` | `bill_model`/activation epoch dan state cutover; capability requirement dipublikasikan melalui kontrak. Jangan mencampur dengan entitlement komersial. |

Seluruh entitas merchant menggunakan RLS `ENABLE` + `FORCE`, pool tenant, dan composite foreign key untuk referensi tenant/outlet yang wajib. Beri index daftar open bill per outlet/owner, operasi per bill/generation/sequence, dispatch per status, session meja aktif, payment per shift/date, serta recovery pending. Hindari index yang memasukkan seluruh JSON snapshot.

Bill operasional tidak perlu mengikuti partisi penjualan berdasarkan tanggal pembuatannya: satu bill dapat dibayar pada hari lain. Pada F4 gunakan tabel biasa berindex; jangan menambahkan purge bill/operation otomatis. Dedupe dan bukti kepemilikan harus tetap tersedia setelah retensi `ingest_log` lewat.

### 4.2 SQLite

- Target satu kenaikan **v32 → v33** setelah schema F4 dibekukan. Bila baseline bertambah sebelum eksekusi, ambil versi berikutnya; jangan memakai angka versi yang sudah terisi.
- Mirror data yang diperlukan owner: bill, lines, operasi immutable, dispatch, payment, settlement, adjustment, sesi meja, ownership, dan draft editor. Tabel antrean lama tetap dipakai.
- Simpan dependency/urutan stok lokal lintas entity dalam metadata tersendiri (misalnya `_operation_dependencies` dan sequence stok per instalasi). Menambahkan metadata tidak mengubah payload outbox legacy yang sudah dibekukan.
- Cache bill perangkat lain terpisah, misalnya `_remote_bills` dan metadata per viewer/filter. Cache sesi meja tidak memberi izin edit bill.
- Simpan model dokumen pre-bill yang dicetak per `(bill_id, bill_revision)` secara lokal, misalnya `bill_prebills`, agar cetak ulang revisi lama tidak membaca bill terbaru. Ini bukan payment/receipt atau pekerjaan printer persisten F6. Jika snapshot revisi lama tidak tersedia di device penerima handoff, tawarkan pre-bill revisi kini dengan label yang benar.
- Simpan pilihan bill aktif dan operasi online yang responsnya belum pasti di SQLite; SharedPreferences hanya untuk preferensi, bukan sumber otoritas.
- Semua accepted edit UI ditulis dalam transaksi sebelum diberi tanda tersimpan. Draft yang belum pernah dikirim dapat dipulihkan setelah kill/restart. Draft yang hanya ada di perangkat tidak diklaim dapat dilihat perangkat lain.
- Satu transaksi memuat mutasi bill, operation snapshot, efek stok lokal bila ada, payment/receipt bila ada, serta outbox. Kegagalan satu langkah me-rollback semuanya.
- Jangan `INSERT OR REPLACE` terhadap parent bill yang memiliki children. Gunakan update/insert seperti sync F3.
- Tidak ada FK cascade dari produk/pelanggan/pegawai/master konfigurasi menuju histori bill, dispatch atau payment. Tombstone master tidak boleh menghapus bill atau struk.
- DDL baru digunakan pada fresh schema dan upgrade. Perbarui daftar tabel connected/reset/demo sesuai urutan dependency; reset connected tetap dilarang. Uji file nyata v32 dengan antrean belum terkirim.

### 4.3 Identitas dan struk

`bill_id`, `bill_line_id`, `dispatch_id`, `operation_id`, `payment_id`, dan `order_id` adalah identitas berbeda. Jangan memakai nomor cetak untuk referensi stok atau dedupe. Bill memakai label operasional tersendiri; nomor struk tetap memakai blok receipt milik **shift penerima pembayaran** melalui mekanisme F0.

Saat settlement, simpan mapping `order_item → bill_line/dispatch_line` agar F5 dapat menelusuri stok dan alokasi tanpa menebak dari product ID. UUID, nomor struk dan business date ditentukan dalam transaksi lokal pertama, lalu selalu diulang sama pada retry. Pre-bill tidak mengambil jatah nomor struk.

## 5. Kontrak operasi, API dan sinkronisasi

### 5.1 Envelope operasi

Tambahkan entity push-only **`bill_operations`** pada manifest dan `/api/v2/sync/push`. `id` entity adalah **operation UUID**, bukan bill UUID. Contoh struktur kontrak yang dibekukan di F4.0:

```json
{
  "id": "operation-uuid",
  "revision": 1,
  "bill_id": "bill-uuid",
  "kind": "dispatch",
  "owner_generation": 1,
  "expected_bill_revision": 3,
  "operation_seq": 4,
  "previous_operation_id": "previous-operation-uuid",
  "session_id": "session-uuid",
  "actor_id": "employee-uuid",
  "occurred_at_ms": 1790200000000,
  "payload": {}
}
```

Nilai `*-uuid` di atas hanya placeholder dokumentasi. Schema aktual memakai UUID valid, batas ukuran/jumlah baris yang eksplisit, tagged payload per `kind`, integer rupiah dan epoch milliseconds. Tenant/outlet/device pemanggil berasal dari credential; nama snapshot bukan bukti kewenangan.

Jenis minimal: `create`, `edit`, `dispatch`, `kitchen_progress`, `settle`, `cancel`, dan `refund_full`. `settle` boleh membawa dispatch untuk sisa baris sebagai bagian atomiknya. Handoff, park/claim dan meja memakai endpoint online, tetapi result/audit/dedupe-nya masuk mekanisme operasi yang sama. Jangan menyediakan dua implementasi business rule untuk online dan outbox.

Bedakan tiga bilangan: **transport revision** outbox, **bill revision**, dan **owner generation**. Requeue tidak berarti mendapat hak baru atau mengganti fakta operasi. Payload bisnis satu operation ID tidak pernah diedit; koreksi menggunakan operasi baru yang menunjuk sumbernya.

### 5.2 Atomicity dan ACK

Urutan server untuk operasi baru: durable ingest audit → transaksi tenant → validasi otoritas/dependency/revisi → bill/dispatch/stock/payment/receipt yang terdampak → simpan result idempotensi → dirty slice/job jika ada efek laporan → commit → publish watermark.

- Retry dengan operation ID dan canonical payload yang sama mengembalikan result pertama, **termasuk setelah ownership/shift berubah**. Identitas pemanggil tetap harus sesuai sumber yang berhak melihat result itu. Periksa dedupe sebelum menolak operasi lama karena generation sudah berganti.
- ID sama dengan payload lain adalah konflik idempotensi. Operasi generation lama yang belum pernah diterima tidak dapat mengedit owner baru; masuk recovery bila membawa kejadian bisnis nyata.
- Response per operasi mencantumkan ID/revisi transport, bill revision/generation, payment/order identity bila ada, hasil meja bila ada, dan **daftar movement ID + `stock_seq` + `balance_after`** untuk efek stoknya.
- Client mencatat ACK dan applied stock sequence dalam transaksi yang sama sebelum melepas outbox. ACK yang hilang/tidak lengkap tetap pending; retry tidak membuat stok/payment/struk baru.
- ACK revisi lama tidak menimpa draft atau operasi berikutnya. Snapshot server hanya dapat menjadi baseline; local pending operations tetap menjadi overlay milik editor sah.
- `accepted` dengan shape rusak, response non-object, HTTP error, timeout, kode asing atau hasil yang tidak cocok tetap mempertahankan payload. Tidak ada penghapusan karena jumlah retry.

### 5.3 Urutan dependency, termasuk stock opname

Urutan daftar entity saja tidak cukup. Buat scheduler dependency di atas outbox yang ada:

1. Sesi/permit sah dan customer offline harus tersedia sebelum operasi bill yang merujuknya.
2. Operasi satu bill dikirim menurut `operation_seq` dan `previous_operation_id`. Operasi yang belum diterima pendahulunya mendapat `retry/dependency_pending`, bukan otomatis di-rebase.
3. Bill lain boleh maju ketika satu bill blocked; successor bill yang sama ditandai blocked dan menunjukkan sumber masalah.
4. **Stock opname wajib menunggu semua operasi stok lokal sebelumnya**, termasuk dispatch/settlement atomik/return dan sale legacy. Tambahkan urutan/barrier stok lintas entity; jangan mengandalkan `bill_operations` selalu dikirim sebelum `stock_movements` karena count yang berada di tengah dua dispatch harus tetap berada di tengah.
5. Batch operasi multi-produk tidak boleh dipecah menjadi efek bisnis terpisah. Validasi ukuran sebelum kasir mengonfirmasi; 200 row per push dan batas body tetap dipatuhi. Jika satu bill melampaui batas kontrak, tampilkan batas sebelum menerima pembayaran.
6. Close shift dan handoff hanya berjalan setelah dependency yang relevan mencapai ACK. Checkpoint mencakup UUID/revisi/sequence, bukan sekadar jumlah order atau “outbox kosong”.

Gunakan `SyncClient`, `RetryGate`, scheduler jitter/backoff dan reentrancy guard yang ada. Push tetap dapat berlangsung ketika refresh katalog gagal, kecuali gate `Retry-After`/credential melarangnya. Jangan menambah polling per bill atau heartbeat kepemilikan.

### 5.4 API baca dan koordinasi

Usulan endpoint baru di bawah `/api/v2`:

| Endpoint | Fungsi |
|---|---|
| `GET /till/bills`, `GET /till/bills/{id}` | Daftar/detail operasional berdasarkan hak aktor; open bill tidak dibatasi hari ini. |
| `GET /till/bills/changes` | Perubahan operasional dengan cursor dan watermark; termasuk penutupan/handoff supaya cache lama tidak terus menampilkan bill terbuka. |
| `GET /till/bill-operations/{id}` | Resolusi timeout/response hilang dan result operasi asli. |
| `POST /till/bills/{id}/handoff`, `.../accept`, `.../cancel-handoff` | Menyiapkan, menerima dan membatalkan transfer yang belum diterima. |
| `POST /till/bills/{id}/park`, `.../claim` | Melepas owner ke parkir server dan memperoleh editor baru. |
| `POST /till/table-sessions`, `POST /till/table-sessions/{id}/close` | Klaim/pengikatan pertama dan pelepasan meja. |
| Perluasan endpoint recovery/till yang ada | Inventaris bill saat takeover, keputusan late operation, barrier penutupan. |

Nama final dikunci pada F4.0. List/detail/changes memakai autentikasi aktor seperti API `/till`, bukan feed katalog company-wide tanpa viewer. Operational changes menggunakan sequence counter yang ditahan sampai commit, snapshot baca yang konsisten, cursor terikat viewer/scope/filter, serta penanda keluar dari cakupan. Jangan membagikan payload pelanggan/payment melalui feed status meja.

Snapshot awal harus memiliki anchor watermark dan pagination konsisten; cursor hanya dimajukan bersama transaksi penerapan page. Bila hak viewer berubah, batalkan response generation lama, reset cursor dan bersihkan cache viewer. Owner rows tidak dihapus oleh cache eviction. `CatalogueSync` tetap menangani master dan projection stok/meja; bill detail tidak dimasukkan ke `_remote_orders`.

Naikkan OpenAPI secara aditif (usulan **2.9.0**), generate DTO Go, dan perbarui schema test/peta entity. Tidak otomatis menaikkan `kClientSchemaVersion` ke 33: angka itu versi kontrak feed. Gate F4 menggunakan capability + manifest + flag outlet.

### 5.5 Error yang bisa ditindaklanjuti

| Kelompok | Contoh kode usulan | Perilaku |
|---|---|---|
| Sementara | `dependency_pending`, `server_unavailable`, rate limit | Simpan dan retry dengan gate; jangan buat operasi baru. |
| Kepemilikan/revisi | `bill_not_owned`, `bill_revision_conflict`, `owner_generation_stale` | Bekukan editor terkait, tampilkan owner/revisi server, simpan bukti; tidak auto-merge. |
| Koordinasi | `table_busy`, `open_bills_remaining`, `handoff_pending`, `sync_before_handoff` | Tampilkan bill/operasi yang harus diselesaikan. |
| Validasi/izin | `schema_rejected`, `forbidden_operation`, `idempotency_conflict` | Preserve payload di dead-letter; jangan bulk requeue atau otomatis meningkatkan hak. |
| Pemulihan | `recovery_required` + case ID | Buka Recovery Center; keputusan manusia hanya lewat alur berotorisasi. |

Tambahkan kode pada closed set OpenAPI, mapper Go/Dart, terjemahan, dead-letter dan skenario live secara bersamaan. Error asing tetap pending sampai client memahami kontraknya.

## 6. Kepemilikan, meja, shift dan pemulihan

### 6.1 Satu editor dan batas izin

- Bill tanpa meja boleh dibuat offline dengan UUID baru pada permit till `active_confirmed`. Create menyimpan owner device/register/session dan generation awal; server memastikan UUID itu belum dimiliki pihak lain. Sampai sync, bill hanya diketahui perangkat asal.
- Mutation guard berada di repository dalam transaksi dan di domain server: lifecycle, pemilik, generation, revision dan penugasan kasir diperiksa, bukan hanya tombol UI.
- `sell` + permit sah mengizinkan create/edit/dispatch/payment oleh owner. `manageTables` mengizinkan operasi meja, tetapi tidak otomatis memberi `sell`. `voidOrder`/`refundOrder` dan `adjustStock` menjadi izin terpisah untuk pembatalan/refund dan keputusan fisik stok. Diskon/custom amount tetap memakai izin F3.
- Read bill milik sendiri/yang ditugaskan dapat memakai `viewOwnOrders`; baca semua detail memakai `viewAllOrders`. Petugas `manageTables` tanpa hak histori cukup melihat meja, durasi, label bill dan owner, bukan seluruh data pelanggan/uang. Handoff hanya ke target sah dalam outlet yang sama; tidak melonggarkan akses histori kasir lain.
- Endpoint online memakai actor token dari login PIN terpilih, validasi pegawai live dan izin server. Persetujuan sensitif mengautentikasi approver, bukan menerima nama/ID dari form sebagai bukti.
- Operasi offline mengacu pada penugasan operator/permit yang pernah disahkan server, beserta konteks otorisasi tersimpan; tidak mengandalkan timestamp perangkat untuk membuktikan hak. Bila status aktor/permit sudah dicabut saat upload, simpan bukti ke recovery, jangan membuang penjualan yang mungkin sudah terjadi. Default F4 mengharuskan online untuk approval sensitif dan koreksi setelah dispatch.
- Handover kasir pada **device dan laci yang sama** mempertahankan bill owner device/session. Actor setiap operasi mengikuti operator baru yang disahkan; creator, pelayan dan penerima pembayaran tetap terpisah.
- Bill `closed` masih dapat menerima progres dapur serta koordinasi ownership untuk pekerjaan pelayanan yang belum selesai; `closed` melarang edit komersial dan settlement kedua. Context kerja boleh berpindah, sedangkan receiving session/payment/receipt asli tidak pernah ikut dipindah.
- Restart, refresh role, login ulang dan dua UI yang membuka bill sama harus tetap melalui CAS revision/guard lokal. Kehilangan izin menghentikan mutasi berikutnya tanpa menghapus bill dan antreannya.

### 6.2 Handoff normal

1. A menulis `handoff_pending` dan request UUID secara lokal; edit/dispatch/payment pada bill itu dibekukan.
2. A mengunggah semua operasi bill dan menunggu ACK sampai revision/sequence barrier, termasuk customer dan stok yang terkait. Dead-letter harus diselesaikan; kosong di memori bukan bukti drain.
3. Server mencatat offer kepada B dengan expected revision dan generation A. B harus merupakan device kompatibel di outlet sama, memiliki sesi aktif dan operator yang boleh menjual.
4. B menerima offer online. Dalam satu transaksi server memeriksa offer belum dibatalkan, mengganti owner dan session kerja, menaikkan generation/revision, serta menyimpan result dan audit.
5. B menyimpan snapshot lengkap dan ownership hasil server secara atomik sebelum mengaktifkan editor. Movement lama A tetap history/server-origin pada B, bukan pending debit baru.
6. A membaca hasil transfer dan menjadi read-only. Jika respons hilang, A/B menanyakan/retry **ID yang sama**, tanpa membuat offer/claim/payment baru.

Timeout tidak membebaskan editor lama. Pembatalan handoff memerlukan jawaban server bahwa offer belum diterima; race accept vs cancel hanya boleh menghasilkan satu pemenang. Tidak ada timeout heartbeat yang memindahkan bill. Struk yang nanti diterbitkan B menjadi milik B/shift B, tetapi dispatch dan actor asal A tetap utuh.

### 6.3 Parkir dan tutup shift

- Parkir menggunakan freeze → drain → konfirmasi server seperti handoff. Owner dilepas, generation dinaikkan dan bill tetap unpaid. Kasir lain melakukan claim online; dua claim bersamaan hanya satu menang.
- Shift yang masih memiliki bill draft/open di bawah tanggung jawabnya tidak dapat ditutup sebelum draft dibuang secara eksplisit atau bill dibayar/dibatalkan/diparkir/diserahkan. Draft dibuang bukan pembatalan penjualan; bill yang sudah disimpan tetap punya audit.
- Periksa juga **bill sudah lunas dengan dispatch belum selesai**: selesaikan pelayanan atau serahkan/parkir tanggung jawab dapurnya secara online sebelum close. Claim pada shift berikutnya hanya mengaktifkan pekerjaan dapur, tidak membuat payment baru. Meja aktif yang seluruh bill/dispatch-nya selesai tetap dapat dilepas online oleh staf `manageTables`, tanpa membuka kembali laci lama.
- Tambahkan pemeriksaan dalam `ShiftRepository.close`, `TillCoordinator`, ingest session dan server coordinator. Close yang bersamaan dengan create/claim/settle harus serial melalui lock sesi/register, sehingga tidak ada bill baru masuk setelah close barrier.
- Pertahankan `order_count` untuk legacy, tambah checkpoint operasi F4 yang telah diakui. Snapshot close menyebut bill yang diparkir/diserahkan dan pending discrepancy secara terpisah, tanpa memasukkannya sebagai uang laci.
- Close offline tetap `closing_pending` hanya bila tidak ada bill terbuka yang perlu koordinasi. Tidak boleh “parkir offline lalu langsung tutup”. Setelah lokal closing, tidak ada transaksi baru; server melepas claim setelah semua barrier terpenuhi.
- Saat membaca shift yang sudah tutup, gunakan snapshot penutupan tersimpan. Jangan menghitung ulang kas historis dari status order terkini. Refund berikutnya melekat pada shift pengembalian.

### 6.4 Sesi meja

- Pembukaan sesi meja dan pengikatan bill pertama adalah operasi online atomik: validasi outlet, meja aktif, register mengizinkan table service, sales type sesuai, meja belum dipakai, serta owner bill sah. Dua perangkat memilih meja sama: satu diterima, lainnya tetap menyimpan bill tanpa meja dengan penjelasan.
- Meja `reserved` memerlukan tindakan seating eksplisit. Menonaktifkan meja tidak menghilangkan sesi aktif; penutupan masih dapat dilakukan, seating baru ditolak.
- Setelah terikat, owner boleh melanjutkan bill offline. Perangkat lain membaca status snapshot dan tidak boleh mengklaim meja yang sama.
- `table_status` menjadi projection sesi aktif untuk outlet F4. Jalur `table_status_events` lama dilarang mengubah occupied menjadi available ketika sesi aktif; event pra-cutover tetap disimpan dan diarahkan ke rekonsiliasi bila berkonflik.
- Meja dilepas eksplisit secara online setelah semua bill-nya lunas/dibatalkan, seluruh dispatch selesai/dibatalkan, dan operasi terkait tersinkron. `parked` tetap unpaid dan menghalangi pelepasan. Pembayaran saja tidak menjalankan `setStatus(available)`.
- Untuk kunjungan dengan tambahan setelah lunas, buat bill baru pada sesi meja yang sama. Jangan menambah item ke order final. Pindah dan gabung meja tetap F6.

### 6.5 Perangkat hilang dan recovery

Perluas F0, jangan membuat tombol “ambil alih” tanpa case:

- Forced takeover menampilkan bill/dispatch yang diketahui server, payment terakhir, owner generation, pending handoff, dan keterbatasan data offline. Manager memberi alasan dan konfirmasi identitas seperti alur till saat ini.
- Fence generation lama dan tandai bill terkait `recovery_required`. Jangan otomatis mengubah unpaid menjadi cancelled/paid atau mengembalikan stok.
- Operasi terlambat dari device lama di-quarantine **per operation ID**, beserta predecessor dan payload asli. Receipt/dispatch/payment yang sudah pernah commit hanya menghasilkan duplicate acknowledgement.
- Approval memakai validasi bisnis yang sama: tidak melunasi dua kali, tidak mengonsumsi pengiriman yang sama, tidak menimpa tambahan owner baru. Bila ledger sudah bergerak, pembatalan keputusan membutuhkan kompensasi berjejak, bukan menghapus movement.
- Jika ada dua klaim pembayaran nyata, jangan memilih berdasarkan jam perangkat; tahan sebagai discrepancy yang memerlukan keputusan manusia. Jangan mengarang snapshot item yang tidak pernah tiba di server.
- Case tidak bisa ditutup selama dependent operations belum diputuskan. Recovery Center, diagnostics till dan Backoffice sama-sama menunjukkan jalur penyelesaian. Jangan hanya memberi `dependency_pending` tanpa akhir.
- Kehilangan device permanen berarti data yang belum pernah tersinkron mungkin tidak dapat dipulihkan. Sistem mempertahankan bukti yang tersedia dan menyatakan kekurangannya.

## 7. Harga, stok, pembayaran dan laporan

### 7.1 Snapshot harga dan HPP

Pisahkan snapshot **input harga**, **pengiriman**, dan **hasil final**:

- Simpan pertama membekukan tax mode, tarif layanan, aturan pembulatan, sales type, konfigurasi struk dan spesifikasi diskon bill. Baris menyimpan unit price final, price source, tarif item, varian/modifier, identitas dan diskon item F3.
- Reopen memakai snapshot, bukan `Product` live. Perubahan nama/harga/tarif/master ketika bill offline tidak mengubah baris lama; item tambahan memiliki snapshot baru. Produk yang sudah dihapus tetap terbaca pada baris lama, tetapi tidak ditawarkan untuk penambahan baru.
- Perubahan qty/diskon/metadata yang diizinkan menciptakan revisi. Perubahan diskon bill sebelum pelunasan boleh menghitung ulang alokasi pada semua baris melalui engine F3; itu perubahan eksplisit bill, bukan akibat sync. Snapshot dispatch fisik tidak berubah.
- HPP dan tracked/untracked dibekukan ketika baris dikonfirmasi. `unit_cost = null` tetap “tidak diketahui”. Baris yang sudah terkirim mempertahankan biaya itu sampai settlement; harga biaya master baru tidak mengubahnya.
- Setelah dispatch, tambahan produk sama dibuat sebagai line baru walaupun tampak identik. Identitas/urutan baris stabil menjadi tie-break alokasi; mengurutkan tampilan tidak mengubah hasil rupiah.
- Settlement membekukan seluruh allocation/header/receipt. Query UI, PDF, payload dan server memakai hasil yang sama. Validasi jumlah wajib menutup; mismatch hasil recompute tetap **diterima dan ditandai** sesuai invariant F3 untuk pembayaran yang sudah terjadi.

### 7.2 Ledger stok

Tambahkan API domain batch, misalnya `RecordOperationEffects`, yang menggunakan `stock.apply` dan menerima semua efek satu dispatch sekaligus. Jangan memanggil `RecordFromDevice` per produk dalam loop baru: fungsi itu memanggil `apply` untuk satu movement, sehingga transaksi multi-produk dapat mengambil counter sebelum semua projection row yang dibutuhkannya terkunci.

- Dedupe effect UUID dan source operation/dispatch line; quantity tidak boleh melebihi bagian yang dikonfirmasi. Custom amount tidak menghasilkan movement. Untracked menghasilkan snapshot tanpa debit dan tidak berubah menjadi tracked karena master terbaru saat push.
- Lock seluruh projection `(outlet, product)` terurut sebelum counter. Sediakan hasil per effect untuk ACK dan overlay lokal. Stok negatif tetap dicatat, dengan peringatan; jangan menolak fakta penjualan offline.
- Sumber dispatch tidak mengisi `order_id` palsu. Tambahkan `source_operation_id/source_line_id` dan kebijakan queue yang eksplisit; legacy order, manual adjustment, dispatch dan correction tidak saling mengunggah movement yang sama.
- Settlement mereferensikan dispatch yang sudah diterima, memvalidasi kelengkapan kuantitasnya, lalu mengonsumsi **hanya** sisa dalam envelope atomik jika diperlukan. B tidak mengirim ulang effect A sebagai miliknya setelah handoff.
- Restock mengacu pada movement konsumsi asli; akumulasi return tidak boleh melampaui qty yang dikonsumsi. Waste setelah dispatch adalah klasifikasi konsumsi yang sudah terjadi, **bukan debit stok kedua**.
- Rekonsiliasi tetap memakai `outlet_stock` dari ledger. Tambah diagnostic orphan dispatch/effect, paid bill tanpa settlement, dan sumber yang memiliki dua efek.

### 7.3 Lock order lintas domain

Dokumentasikan satu urutan sebelum menulis endpoint: kunci idempotensi operasi → register yang terlibat (urut ID) → sesi/claim → definisi/status/sesi meja → bill (urut ID) → reservasi payment/order → kunci effect dan projection stok terurut → counter feed yang diperlukan dalam urutan global tetap → dirty slice/job.

Writer hanya mengambil subset yang dibutuhkannya, tetapi tidak boleh kembali mengambil lock lebih awal setelah counter. Karena writer meja lama mengambil counter definisi sebelum counter status, review `tables.Save/Delete`, dispatch, settlement langsung, handoff, close, forced takeover dan stock count bersama; refactor primitive agar semua row lock diperoleh sebelum publish counter. Jangan memanggil writer publik yang membuka transaksi sendiri dari dalam transaksi bill. Jangan lock row tenant. Uji dua koneksi dengan urutan produk/bill berlawanan dan race antar operasi tersebut.

### 7.4 Pelunasan, uang tunai dan koreksi penuh

- `amount_applied = total bill`; tunai mencatat `tendered ≥ total` dan `change = tendered − total`. Penerimaan bersih laci adalah amount applied, bukan uang tendered. Non-tunai tetap manual, memenuhi referensi wajib F3 dan nominal tepat total. Total nol boleh ditutup dengan payment bernilai nol tanpa uang laci fiktif.
- Satu transaksi lokal settlement membuat payment, receipt, mapping bill, final snapshot, dispatch sisa dan outbox. Domain server melakukan efek yang sama dalam satu transaksi; double tap atau respons hilang menghasilkan payment/order yang sama.
- `orders.status` untuk struk F4 tetap `paid`. Progres dapur tidak lagi memperbarui status receipt. Tambahkan marker sumber/link bill, dan pisahkan helper persist receipt dari guard legacy `ingestSale` tanpa membuka jalan bagi client mengirim order tanpa efek stok yang semestinya.
- Bill yang dibayar pada device B diatribusikan ke receiving register/session/cashier B. Waktu buka bill, pengirim dapur A, pelayan dan pelanggan tetap dapat ditelusuri.
- Untuk receipt **legacy**, pertahankan payload/status dan kemampuan koreksi yang ada; jangan membuat payment/dispatch historis rekaan. Kekurangan data lama diberi label.
- Untuk receipt **F4**, tombol void sesudah bayar diarahkan ke **pengembalian penuh**, bukan membatalkan bill unpaid. Adapter membuat `bill_adjustments` immutable yang mengacu payment/struk asli, merekam seluruh komponen reversal dan keputusan stok terpisah. Tidak mengubah harga/baris/nomor receipt asli dan tidak memanggil restock otomatis `_settle`.
- Full refund F4 hanya sekali sampai batas payment bersih, online di device penerima dengan shift pengembalian aktif dan approval `refundOrder`; pilihan restock/waste membutuhkan `adjustStock`. Jika tanggung jawab bill sedang dimiliki device lain, drain/handoff kembali dahulu; perangkat asal tidak melewati guard owner. Bill terminal milik device yang sama dapat mengikat context koreksi ke shift baru lewat operasi online berjejak tanpa mengubah receiving session asli. Nominal/kuantitas parsial dan pemindahan hak refund lintas device menunggu F5. Device hilang memakai recovery.
- Adapter koreksi penuh adalah bagian kompatibilitas minimum F4. Jangan membuka fitur F4 sebelum jalur ini tersedia lalu membiarkan tombol lama menambah stok dua kali. F5 mengembangkan record yang sama menjadi partial, bukan membuat ledger refund kedua.

### 7.5 Aktivitas dan laporan

- Default daftar operasional menampilkan semua bill terbuka yang viewer berhak lihat, termasuk hari sebelumnya. Filter histori memakai tanggal event yang jelas; pencarian membedakan nomor bill dan nomor struk.
- Pendapatan, order count penjualan, metode bayar, kategori/produk/brand, pelanggan, dashboard, CSV/XLSX/PDF tetap bersumber dari **receipt final** dan koreksi terkait. Jangan menjumlahkan `bill_payments` dan `orders.total` sebagai dua pendapatan.
- `bill_payments` menjadi sumber cash reconciliation F4; legacy tetap dari order. Union kedua sumber memakai marker sumber yang saling eksklusif agar shift tidak menghitung dua kali.
- Waktu pengakuan dan `business_date` F4 adalah waktu settlement berdasarkan timezone tenant yang berlaku saat pembayaran, disimpan beserta offset F3. Dispatch memakai waktu operasionalnya sendiri. Bill dibuka kemarin dan dibayar hari ini masuk penjualan hari ini; tanggal legacy tidak berubah.
- Pertahankan persamaan F3: `net sales = gross − discounts − sales returns − tax_included`; `total collected = net sales + tax + service + rounding` setelah koreksi komponen sesuai periode. `gross profit = net sales − COGS` dengan biaya standar, cakupan HPP dan ambang 90%.
- Konsumsi bill unpaid ditampilkan sebagai metrik operasional terpisah; pembatalan yang menjadi waste tidak dimasukkan sebagai revenue atau dibebankan dua kali sebagai COGS dan waste. Jangan menyebut ini general ledger/valuasi inventori lengkap.
- Full refund F4 masuk tanggal/shift refund, termasuk retur penjualan/pajak/layanan/pembulatan dan pemulihan HPP hanya untuk barang yang benar-benar kembali. Struk dan snapshot kas shift lama tidak ditulis ulang. Laba tetap menanggung biaya konsumsi yang tidak kembali; tunjukkan klasifikasinya.
- Dirty slices untuk settlement dan koreksi di-enqueue dalam transaksi yang sama. Rebuild rollup tetap idempoten dari source record; exact retry tidak membuat pekerjaan/angka tambahan. Dispatch biasa hanya mengubah ringkasan operasional, bukan rollup sales.
- Audit `reporting/{rollup,product_net,brand,anomalies,consistency,report,csv,xlsx,pdf}.go`, history sessions, API reports, laporan lokal, server report parsing, export dan customer history. Group/filter pembatalan bill unpaid tidak boleh terbaca sebagai pengembalian penjualan.

## 8. Pengalaman kasir dan Backoffice

### POS

- Keranjang mempunyai konteks bill aktif yang jelas: baru, tersimpan, pending sync, milik perangkat lain, atau sedang transfer. Autosave draft tidak menyamar sebagai bill yang sudah tersinkron.
- Aksi terpisah **Simpan bill**, **Kirim dapur**, **Cetak pre-bill**, **Bayar**. Ringkasan jumlah item belum dikirim ditampilkan sebelum konfirmasi; bayar dapat mengonfirmasi sisa sekali jalan.
- Buka bill dari Aktivitas atau meja memuat snapshot, pelanggan, pelayan, note dan batch dapur. UI membedakan baris terkirim dan tambahan. Read-only menampilkan owner dan aksi handoff/claim yang sah.
- Keluar editor/switch bill tidak menghapus draft. Handover kasir mempertahankan konteks sesuai aturan sesi. Saat izin/ownership berubah, simpan draft yang belum terkirim sebagai bukti tanpa menerapkannya ke owner baru.
- Pre-bill menyebut **BELUM LUNAS**, label bill, revisi, timestamp dan total estimasi revisi tersebut; tidak menampilkan seolah pembayaran sudah diterima. Cetak ulang memakai snapshot revisi yang dipilih. Print gagal tidak mengulangi dispatch atau pembayaran.
- Aktivitas memisahkan **Bill terbuka**, **Penjualan lunas**, **Dibatalkan**, dengan filter pelanggan/meja/pelayan/kasir/periode yang relevan. Receipt F4 dapat membuka timeline bill, tanpa menjadikannya editable.
- Halaman shift menampilkan blocker spesifik dan pilihan selesaikan/serahkan/parkir. Tabel operasional menampilkan durasi dan label “sudah dibayar, meja masih terpakai”.
- Bill snapshot/repository menjadi sumber data; `cart_provider` hanya editor. `pricing_provider` menyediakan quote snapshot, `order_provider` mengarahkan legacy vs F4. Jangan menambah sqflite ke widget atau memakai `checkoutProvider` yang masih decoy.

### Backoffice

- Tambah daftar/detail bill operasional serta timeline dispatch/ownership/payment/cancellation. Integrasikan dengan halaman transaksi, shift dan status meja yang ada; jangan mengganti paket `history` yang sengaja read-only menjadi writer.
- Owner/manager melihat backlog bill, parked, konflik dan konsumsi belum lunas sesuai permission; monetary reports tidak memasukkan nominal open bill.
- Koordinasi recovery dilakukan melalui domain recovery dengan audit/CSRF/izin, bukan edit bebas snapshot bill. Tidak menambahkan tombol pembayaran/refund di halaman histori Backoffice.
- Halaman perangkat/pengaturan menampilkan kompatibilitas `bills-v1` dan alasan aktivasi belum bisa dilakukan. Form validation mengikuti `validation.Errors` + round-trip input + HTTP 200 yang digunakan proyek.

Semua layar baru mengikuti `mobile/CLAUDE.md`: ARB Indonesia/Inggris, `context.design`/glass components, `AppDimensions`, light/dark, brand preset dan layout di bawah/di atas 900dp. Guard sesi tetap di dalam tab POS; router tidak direkonstruksi ketika provider berubah. Invalidate provider terdampak secara eksplisit setelah write/pull, termasuk bill, meja, stok, shift, history dan laporan.

## 9. Urutan implementasi dan deliverable

Ukuran di bawah adalah kompleksitas relatif, bukan janji kalender. Setiap langkah ditutup dengan gate terkait sebelum aktivasi fitur. Seluruh scope inti diperlukan untuk menyatakan F4 selesai.

| Langkah | Pekerjaan dan area kode | Dependency | Gate/deliverable |
|---|---|---|---|
| **F4.0 — Kontrak dan fixture** · besar | Bekukan D1–D12, state machine, envelope, payload limit, auth offline/online, error, lock order, migration dan capability matrix. `backend-go/api/openapi.yaml`; fixture `testdata/bills/` baru. | Baseline F3 | Contoh lifecycle, response hilang, handoff dan uang/stok eksplisit; OpenAPI/schema test konsisten. |
| **F4.1 — Schema dan domain bill** · besar | Migrasi PostgreSQL; paket `backend-go/internal/domain/bills/` baru; create/edit/cancel belum terkirim, operasi/idempotensi/CAS, snapshot dan actor guard. | F4.0 | RLS/cross-outlet, duplicate/revisi, rollback, tidak ada order/payment/stock saat save. |
| **F4.2 — SQLite dan recovery draft** · besar | v33; `models/bill*.dart`, `repositories/bill_repository.dart`, `bill_operation_push.dart`, snapshot editor, codec deterministik. | F4.0–1 schema stabil | Upgrade file v32, kill/reopen, data/outbox/dead-letter lama identik, dua editor lokal tidak lost update. |
| **F4.3 — Outbox operasi** · besar | `ingest/ingest.go`, manifest/schema registry, `outbox_store.dart`, `outbox_push.dart`, dependency/barrier stok, ACK dan dead-letter. | F4.1–2 | Dua edit/dispatch tidak overwrite; predecessor hilang; ACK lama; response malformed; starvation dan count ordering. |
| **F4.4 — Dispatch dan stok** · besar | Domain bills + batch effects `stock/stock.go`; repository stok/dispatch, kitchen progress, HPP snapshot. | F4.3 | Save nol effect; dispatch/additional tepat sekali; batch rollback; race produk berlawanan; opname di antara dispatch. |
| **F4.5 — Settlement dan koreksi penuh** · besar | Payment/settlement mapping; refactor persist receipt `ingest/orders.go`/`sale.go`; `order_repository.dart`, pricing snapshot, receipt allocation; adapter cancel dispatched/full refund. | F4.4 | Settlement atomic, tidak double stock, receipt immutable, exact retry, money/refund/stock menutup. |
| **F4.6 — Meja dan koordinasi ownership** · besar | Domain tables + table sessions; endpoints bills/handoff/park/claim; `bill_coordinator.dart` baru dan `TillCoordinator`. | F4.3–5 | Claim meja/bill hanya satu; accept/cancel race; payment tidak melepas meja; B menerima tanpa replay stock A. |
| **F4.7 — Shift dan recovery** · besar | `ingest/{sessions,till,recovery}.go`, `ShiftRepository.close`, Recovery Center/inspector, diagnostics, barrier sesi. | F4.6 | Tutup shift ditolak dengan blocker; park/claim berhasil; forced takeover dan late operation tidak hilang/terhitung dua kali. |
| **F4.8 — Read model dan laporan** · besar | API bills/changes, cache viewer, domain history read-only; reporting rollup/exports, local/server reports, shift/cash dan customer history. | F4.5–7 | Open bill nol sales; transfer/overnight atribusi benar; refund tanggal kini; pagination/cursor tidak kehilangan update. |
| **F4.9 — UI POS, pre-bill dan Backoffice** · besar | POS/cart/checkout, halaman bill/aktivitas/meja/shift, PDF pre-bill, l10n; handler/view templ bill dan gate devices/settings. | F4.2 untuk draft; integrasi lengkap setelah F4.8 | Smoke Windows/Android/browser, semua loading/error/blocked state dapat dipulihkan; cetak tidak mengulang efek bisnis. |
| **F4.10 — Compatibility dan cutover** · sedang | `devices/capabilities.go`, settings/activation, manifest/DTO, epoch/drain checkpoints, old endpoint guard; demo opt-in. | Semua alur inti | Matriks client/server lama-baru, race activation/downgrade, data legacy tidak berubah; fitur tetap default off. |
| **F4.11 — Verifikasi dan closeout** · sedang | `scripts/verify-bills` baru, perluasan verifier lama, CI, manual lokal, memory dan `docs/FASE_4_VERIFICATION.md`. | F4.10 | Bukti aktual per gate, UAT dua instalasi, rekonsiliasi dan daftar keterbatasan. |

Urutan efektif: **F4.0 → F4.1/F4.2 → F4.3 → F4.4 → F4.5 → F4.6 → F4.7 → F4.8 → penyelesaian F4.9 → F4.10 → F4.11**. Desain UI dapat dibuat ketika state/kontrak stabil, tetapi tombol aktivasi terakhir. Dokumen ini tidak mengharuskan kerja multi-agent, tapi juga tidak melarang, tentukan yang paling efektif dan efisien.

### Titik integrasi yang mudah terlewat

| Titik | Pemeriksaan wajib |
|---|---|
| `backend-go/internal/domain/ingest/ingest.go` | Schema map, routing transaksi, durable audit, result correlation, quarantine dan kode penolakan. |
| `backend-go/internal/domain/syncfeed/` + `internal/infra/syncfixture/` | Manifest push-only; kolom outlet settings/status baru ikut schema allow-list, covering index, fixture dan kontrak. Bill detail tidak otomatis menjadi feed katalog. |
| `backend-go/internal/store/`, `internal/httpapi/wire/`, `internal/backoffice/views/` | Regenerasi sqlc, OpenAPI dan templ; generated files di-commit. |
| `backend-go/internal/backoffice/backoffice.go` + routes/nav tests | Dependency service baru benar-benar disalin; permission, entitlement lama, CSRF dan nav konsisten. |
| `backend-go/internal/domain/history/sessions.go` + recovery cash snapshot | Union pembayaran legacy/F4, closed snapshot, waktu koreksi dan tidak double count. |
| `backend-go/internal/domain/reporting/report.go` | Batch query posisional, tabel fingerprint consistency, cost redaction dan export mengikuti kolom baru. |
| `mobile/lib/data/sync/session_push.dart` | `order_count`, checkpoint operasi dan close tidak mendahului bill/payment pending. |
| `mobile/lib/data/sync/{outbox_store,outbox_push,dead_letter_store}.dart` | entity/schema baru, queue source ownership, register binding, error whitelist dan replay operation ID. |
| `mobile/lib/data/sync/device_sync_runner.dart` | Perubahan bill/ownership dibaca tanpa menghapus overlay; tetap push jika pull gagal; satu RetryGate. |
| `mobile/lib/providers/{synced_data,settings_provider,order_history_provider}.dart` | Refresh izin dan invalidate cache viewer; jangan reset cart/shell saat sinkronisasi. |
| `mobile/lib/features/orders/order_detail_page.dart` | Jangan memakai status/action/restock legacy untuk receipt F4; remote receipt tetap read-only. |
| `mobile/lib/core/print/` | Builder pre-bill terpisah dari receipt final; snapshot/revisi; offline/logo fallback; nilai nol dan bill tanpa item ditangani. |
| `.github/workflows/{backend-go,flutter}.yml` | Verifier baru, fixtures `testdata/**`, generator freshness, migrasi, tests Linux/Windows; tidak mengklaim workflow sudah berjalan sebelum ada bukti. |

## 10. Pengujian dan penerimaan

### 10.1 Fixture uang/stok yang menjadi acuan bersama

Gunakan fixture angka eksplisit pada Go dan Dart, bukan expected yang dihitung dengan memanggil engine implementasi yang sedang diuji:

- Stok awal nasi 10 dan teh 10. Nasi Rp25.000, HPP Rp15.000; teh Rp10.000, HPP Rp4.000.
- Simpan bill 2 nasi: stok tetap 10/10; payment/order/revenue nol.
- Dispatch pertama 2 nasi: stok 8/10. Tambah 1 teh dan simpan: tetap 8/10. Dispatch kedua: 8/9.
- Diskon bill 10%, layanan 5%, PB1 exclude 10% atas net + layanan, pembulatan nearest Rp100.
- Final: gross Rp60.000; diskon Rp6.000; net Rp54.000; layanan Rp2.700; pajak Rp5.670; pembulatan Rp30; **total Rp62.400**; HPP Rp34.000; **laba kotor standar Rp20.000**.
- Tunai Rp100.000 → kembali Rp37.600; uang bersih shift Rp62.400. Tepat 2 dispatch, 2 movement konsumsi, 1 payment dan 1 receipt. Retry tidak mengubah jumlah tersebut.
- Handoff setelah dispatch kedua ke B: kas shift A nol untuk bill ini, shift B Rp62.400. Bill dibuka sebelum tengah malam dan dilunasi sesudahnya: revenue masuk tanggal B menerima pembayaran.
- Full refund seluruh bill kemudian tanpa restock: uang refund Rp62.400 pada shift refund; stok tetap 8/9, tanpa debit waste kedua. Jika seluruh barang dinyatakan kembali, stok menjadi 10/10, return maksimal sekali. Snapshot shift penjualan sebelumnya tetap Rp62.400.

Tambahkan vector include/exclude F3, diskon item berbeda, custom amount, total nol, biaya tidak diketahui dan perubahan master. Golden vector pricing F3 tetap dijalankan seluruhnya.

### 10.2 Matriks pengujian wajib

| ID | Skenario | Hasil yang harus dibuktikan |
|---|---|---|
| T01 | Fresh schema dan upgrade PostgreSQL 035/SQLite v32 berisi transaksi pending | UUID, receipt, snapshot, owner, queue, dead-letter dan saldo tidak hilang atau diberi identitas rekaan. |
| T02 | Simpan, force-stop, restart, buka kembali | Semua line/note/customer/server/snapshot kembali; draft dan saved bill dibedakan. |
| T03 | Save/pre-bill berulang | Nol payment/order/revenue/stock movement. |
| T04 | Dispatch response hilang, retry sebelum/sesudah pull stok | Satu dispatch dan efek; overlay tidak double count. |
| T05 | Tambah item/modifier setelah pengiriman | Baris lama immutable, hanya baris tambahan dikonsumsi. |
| T06 | Bayar bill terkirim dan direct checkout dengan baris belum dikirim | Satu receipt/payment; hanya sisa dikonsumsi; crash di setiap tahap tidak menyisakan state parsial. |
| T07 | Double tap/restart ketika settlement pending, ACK lama tiba setelah edit berikutnya | Operasi asli pulih; tidak ada receipt kedua atau operasi baru terhapus. |
| T08 | Device B mencoba edit/dispatch/pay bill A tanpa handoff | Ditolak di server dan repository; `readOnly` tidak dapat dijadikan bypass. |
| T09 | Handoff normal, accept/cancel bersamaan, putus pada setiap langkah | Satu owner/generation; A beku saat hasil tidak pasti; B tidak mengulang stok A. |
| T10 | Parkir → tutup shift → claim shift baru | Claim eksklusif, creator tetap, pembayaran milik shift baru; parked bukan piutang/revenue. |
| T11 | Close bersamaan dengan create/claim/dispatch/settle; bill paid masih preparing | Tidak ada operasi melewati close barrier; pending/dead-letter terlihat; tanggung jawab dapur berpindah tanpa payment ulang. |
| T12 | Dua device mengambil meja yang sama | Satu sesi meja; pihak kalah mempertahankan bill tanpa meja. |
| T13 | Bayar sebelum served, melepas meja sebelum unpaid selesai, manual status lama | Bayar tidak membebaskan meja; release yang belum sah ditolak; event lama tidak bypass session. |
| T14 | Meja dinonaktifkan saat occupied; tambahan setelah bill sebelumnya paid | Sesi tetap terlihat, seating baru ditolak; tambahan mendapat bill baru dalam sesi sama. |
| T15 | Batal sebelum/sesudah dispatch, restock/waste, retry | Pengembalian sesuai konsumsi fisik; waste tidak mendebit ulang; tanpa revenue/refund fiktif. |
| T16 | Full refund F4 setelah shift/hari lama tutup | Struk asli immutable; refund pada shift/hari baru, stok eksplisit, limit refund dan closed snapshot terjaga. |
| T17 | Price/tax/discount/customer/product berubah atau dihapus saat bill offline | Existing snapshot dan HPP tidak berubah; tambahan baru eksplisit; struk lama konsisten. |
| T18 | Tenant/outlet/actor/session/generation/payment/line ID dimanipulasi | RLS, referensi, izin dan domain guard menolak; tidak bocor data/efek. |
| T19 | Role/PIN/staf berubah saat login/offline, cold start dan cache viewer sebelumnya | Hak ditinjau ulang saat online; offline limitations jelas; operasi lama dipertahankan untuk recovery. |
| T20 | Forced takeover, device lama kembali membawa dispatch atau payment | Quarantine dengan dependency; approval tidak double pay/stock; case tidak ditutup sebelum selesai. |
| T21 | Dispatch → opname → dispatch, upload tersusun ulang | Barrier menjaga urutan lokal, saldo server/local/ledger cocok; bill blocked tidak menahan bill independen. |
| T22 | Dua writer multi-produk dengan urutan input berlawanan, race table/stock/close | Tidak deadlock/drift; retry lock timeout mempertahankan operasi. |
| T23 | Paging open bill/history/changes, update/closure selama paging, switch viewer/filter | Tidak kehilangan perubahan; dedupe UUID; terminal/removal marker membersihkan cache yang tepat. |
| T24 | Midnight WIB/WITA/WIT, timezone berubah antara buka dan bayar | Date settlement benar, dispatch time terpisah, legacy tetap; slice/export menutup. |
| T25 | Aktivasi/downgrade/client-server campuran dan legacy queue terlambat | Flag off kompatibel; legacy tidak menyamar sebagai F4; transaksi meragukan dipreservasi lewat recovery. |
| T26 | Print PDF gagal, tanpa logo/jaringan, reprint pre-bill lama | Tidak ada pengulangan bisnis; status BELUM LUNAS dan revisi jelas; receipt final memakai snapshot. |
| T27 | Windows/Android dua instalasi independen + browser Backoffice | Alur end-to-end sama; tidak berbagi DB/credential; restart/offline dan rekonsiliasi benar. |

### 10.3 Lapisan pengujian dan perintah

Backend memakai PostgreSQL/Redis nyata melalui `pgtest`, credential RLS yang benar, concurrency test dan live verifier. Dart menambahkan **unit/model/repository/sync/migration/calculation tests** yang menguji risiko di atas. Pertahankan suite regresi yang ada. Ikuti [testing policy mobile](../mobile/.claude/rules/testing-policy.md): tidak membuat suite widget/E2E baru per fitur; UI diverifikasi langsung lewat tooling perangkat/browser yang tersedia, dengan log/error dan bukti hasil.

Perintah backend, **dari `backend-go/`**, setelah implementasi:

```bash
templ generate
go generate ./api ./internal/store
go build ./...
go vet ./...
go test ./... -count=1
go test ./... -race -count=1
go run honnef.co/go/tools/cmd/staticcheck@v0.8.1 ./...
```

`-race` memerlukan cgo/toolchain yang sesuai; gunakan Linux CI/container bila Windows host belum memenuhinya. Jalankan lint dan generator freshness mengikuti workflow yang dipin repo. Uji migration up dan down/up hanya pada database uji disposable/salinan yang jelas, termasuk upgrade data 035; bukan rollback database merchant yang sudah menampung transaksi F4.

Verifier live dijalankan **satu per satu**, terhadap API + worker dari kode yang diuji. `verify-activation` pertama karena pemeriksaan rate limiter. Pertahankan seluruh verifier lama; urutan tambahan:

```bash
go run ./scripts/verify-activation
go run ./scripts/verify-backoffice
go run ./scripts/verify-backoffice-crud
go run ./scripts/verify-sync
go run ./scripts/verify-push
go run ./scripts/verify-stock
go run ./scripts/verify-tables
go run ./scripts/verify-till
go run ./scripts/verify-recovery
go run ./scripts/verify-pricing
go run ./scripts/verify-bills
go run ./scripts/verify-history
go run ./scripts/verify-reports
go run ./scripts/verify-platform
go run ./scripts/loadtest smoke
```

`verify-bills` adalah deliverable baru, belum tersedia saat rencana ditulis. Gunakan tenant uji terisolasi dan dua register/device/kasir. Verifier mencakup create/save/dispatch/settle/handoff/park/table/refund/recovery melalui HTTP nyata, lalu merekonsiliasi source records, ledger, rollup dan ekspor. PDF memerlukan Gotenberg lokal yang berjalan. Perluas verifier lama agar memeriksa campuran legacy/F4, bukan mengganti fixture legacy seluruhnya dengan model baru.

Perintah mobile, **dari `mobile/`**, menggunakan FVM proyek:

```bash
fvm flutter gen-l10n
fvm flutter analyze --no-fatal-infos
fvm flutter test
fvm flutter build apk --debug
fvm flutter build windows --release
```

Untuk unit/device UI, gunakan MCP Dart sesuai testing policy bila tersedia; catat fallback/ketidaktersediaan tooling. Build Windows/UAT yang tidak dapat dijalankan harus dilabeli tertunda. Build demo web menjadi smoke tambahan bila jalur demo/bootstrap/conditional database terdampak. Jangan menyebut test F3 yang tercatat sebagai bukti F4.

## 11. Migrasi, aktivasi dan pemulihan versi

1. **Backup terverifikasi:** salinan PostgreSQL, SQLite tiap instalasi, outbox/dead-letter dan inventaris versi. Restore diuji pada salinan; jangan menyalin satu SQLite agar dipakai dua device.
2. **Migrasi backend aditif:** endpoint/DTO baru tersedia, flag F4 masih off. Existing receipt, stock effect, dedupe reservation, schema feed dan entitlement lama tetap dapat dibaca.
3. **Upgrade semua till outlet:** migrasi SQLite menjaga antrean; kirim `bills-v1`; build baru masih memakai jalur lama selama outlet belum diaktifkan. Demo diaktifkan tersendiri memakai konfigurasi lokal/fixture, tidak memerlukan server palsu atau men-seed connected store.
4. **Rekonsiliasi cutover online:** masing-masing device aktif memberi drain checkpoint yang disahkan server setelah queue/dead-letter diselesaikan dan sesi lama ditutup. Capability saja tidak membuktikan antrean perangkat offline kosong. Device yang hilang harus melalui recovery/revocation, bukan diabaikan karena `last_seen` lama.
5. **Meja lama:** selesaikan sesi layanan/status occupied/reserved legacy secara eksplisit sebelum cutover, atau melalui recovery yang dicatat. Jangan menyimpulkan `orders.preparing` adalah unpaid lalu membuat bill/session fiktif. Receipt legacy tetap legacy.
6. **Aktifkan per outlet:** transaksi memvalidasi seluruh capability/checkpoint/konfigurasi dan state cutover; serialkan dengan aktivasi perangkat serta pembukaan sesi supaya pemeriksaan tidak lolos race. Terbitkan epoch kontrak dan flag, lalu tarik konfigurasi sebelum sesi F4 pertama dibuka.
7. **Jaga jalur lama:** setelah aktif, old build tidak boleh membuka writer/sesi baru atau memutasi status meja dengan aturan lama. Exact retry legacy yang sudah tercatat tetap diterima; payload legacy baru yang muncul terlambat masuk recovery terarah bila tidak dapat dibuktikan oleh checkpoint. Tidak dibuang atau diterima bebas hanya berdasarkan timestamp.
8. **UAT dua perangkat dan rekonsiliasi:** jalankan T01–T27 yang relevan dan periksa backlog, bukan hanya status UI. Fitur aktif hanya setelah hasil sesuai.

Matriks kompatibilitas minimum:

| Client | Server/flag | Hasil |
|---|---|---|
| F3 | Server F4, flag off | Kontrak lama tetap berjalan. |
| F4 | Server F3 | Fitur F4 tidak ditawarkan/dikirim; transaksi legacy tetap kompatibel. |
| F4 | Server F4, flag off | Database sudah siap, belum membuat operasi F4. |
| Semua client outlet F4 | Server F4, flag on | Operasi baru melalui F4; legacy receipt dibaca sesuai semantik lamanya. |
| Client lama/downgrade | Server F4, flag on | Tidak mendapat writer baru; retry sah/late evidence ditangani tanpa kehilangan data. |
| Client dengan data F4 | Backend turun ke server tanpa F4 | Sinkron F4 diblokir dengan penjelasan; queue tetap utuh. Tidak mengonversi bill ke legacy order atau menurunkan SQLite. |

Setelah data F4 ada, pemulihan utama adalah **forward fix** atau menghentikan pembuatan bill baru sambil tetap melayani penyelesaian/recovery bill yang ada. Jangan rollback flag ke legacy lalu mengulang konsumsi stok. Pemulihan dari backup harus merekonsiliasi operasi perangkat yang terjadi setelah backup; backup lama bukan alasan membuang antrean baru.

## 12. Definition of done dan dokumen akhir

F4 dinyatakan selesai setelah:

- Semua workstream inti F4.0–F4.11 selesai; API/sync/permission/recovery hadir bersama UI, dan fitur tidak diaktifkan hanya karena happy path berhasil.
- Migrasi fresh/upgrade menjaga seluruh bukti transaksi lama; restart/offline/retry/handoff tidak menghasilkan efek ganda.
- Simpan bill tidak menghasilkan revenue, dispatch mengonsumsi tepat sekali, settlement tidak mengonsumsi ulang, dan receipt final immutable.
- Handoff/park/claim/close shift dan sesi meja melewati gate dua perangkat. Windows, Android dan Backoffice memiliki bukti aktual atau status tertunda yang eksplisit; yang tertunda tidak dinyatakan lulus.
- Fixture uang/stok, closed shift, koreksi, rollup dan CSV/XLSX/PDF menutup tanpa selisih yang tidak dijelaskan. Cache operasional/riwayat tidak digunakan sebagai agregat seluruh outlet.
- Gate otomatis relevan lulus; generated code bersih setelah regenerasi ulang; verifier baru masuk CI. Hasil lokal dan workflow GitHub aktual dicatat terpisah.
- `docs/FASE_4_VERIFICATION.md` baru mencatat commit/build/lingkungan, command, hasil, UAT dan keterbatasan nyata. Dokumen ini tetap rencana, bukan diubah menjadi klaim pengujian.
- Perbarui `docs/MANUAL_TEST_LOKAL.md` dengan bagian F4 setelah bagian J F3, roadmap, `backend-go/CLAUDE.md`, `mobile/CLAUDE.md`, dan baseline relevan `mobile/AGENTS.md`; koreksi paragraf lama yang bertentangan dengan alur baru.
- Commit mengikuti Conventional Commits: `feat(api):`, `feat(pos):`, `test(api):`, `docs:` sesuai perubahan. Deployment tidak menjadi syarat fase lokal ini.

**Langkah pertama eksekusi:** buat fixture lifecycle dengan angka §10.1, bekukan state/operasi dan batas kompatibilitas pada F4.0, lalu bangun schema/domain bill dan persistensi SQLite. Jangan memulai dengan tombol “Simpan” yang menulis order belum lunas ke tabel penjualan lama.

### Referensi yang dipakai

- [Roadmap paritas seluruh fase](RENCANA_PARITAS_FITUR_MOKAPOS.md).
- [Analisis fitur kasir](<Analisis Fitur Kasir MokaPos.md>) dan [Backoffice](<Analisis Fitur Backoffice MokaPos.md>), terutama saved bill, aktivitas, shift, checkout dan meja.
- [Rencana konsistensi multi-device](RENCANA_KONSISTENSI_MULTI_DEVICE.md), dibaca sebagai asal invariant dan dibandingkan dengan implementasi F0–F3 terkini.
- [Rencana F3](RENCANA_IMPLEMENTASI_FASE_3.md) dan [bukti F3](FASE_3_VERIFICATION.md), termasuk penyimpangan rancangan dan gate lingkungan.
- [Memory backend](../backend-go/CLAUDE.md), [memory mobile](../mobile/CLAUDE.md), [AGENTS mobile](../mobile/AGENTS.md), dan [testing policy](../mobile/.claude/rules/testing-policy.md).
- Titik kode yang ditelusuri dan dipakai sebagai dasar perubahan tercantum di §2, §7 dan §9.
