# Testing Policy — verifikasi hemat token

Aturan ini menggantikan kebiasaan menulis test otomatis tiap ada fitur. Tujuannya:
memangkas biaya token menulis/menjalankan test yang low-value, tanpa kehilangan
jaring pengaman regresi yang sudah terbukti berharga. Pendekatannya **jalan tengah**,
bukan menghapus test.

## Aturan utama

1. **JANGAN menulis widget test atau integration/E2E test baru untuk fitur baru
   secara default.** Verifikasi fitur baru lewat MCP dart + simulator/Playwright
   (lihat "Cara verifikasi" di bawah).
2. **Unit test tetap ditulis** untuk logika data murni — models, repositories,
   formatters, kalkulasi (mis. cart math). Ini murah, cepat, tidak butuh simulator,
   dan ROI-nya tertinggi.
3. **Pertahankan test regresi yang sudah ada. Jangan hapus tanpa izin eksplisit.**
   Beberapa mengunci bug yang terbukti berulang:
   - `test/router_stability_test.dart` — `routerProvider` tidak boleh `ref.watch`
     provider lain (dulu menendang user keluar Settings tiap ganti tema/brand/bahasa).
   - `test/product_card_layout_test.dart` — kartu produk ke-clip karena `textScaler`.
   - `test/repositories/migration_test.dart` — migrasi DB.
   - `integration_test/app_e2e_test.dart` — nav index bertahan saat setting berubah.
4. **Boleh menambah SATU regression test kecil hanya setelah memperbaiki bug yang
   jenisnya gampang balik lagi — dan tanya user dulu.** Jangan generate suite.

## Cara verifikasi fitur baru (pengganti widget/E2E test)

Gunakan MCP server `dart` — jangan pakai shell mentah:
- `launch_app` / `list_devices` — jalankan di device yang diminta user.
- `hot_reload` / `hot_restart` — setelah edit.
- `get_runtime_errors` — pastikan tidak ada error runtime.
- `get_widget_tree` / `get_selected_widget` — verifikasi struktur UI.
- `get_app_logs` — cek log.
- `run_tests` — untuk menjalankan unit test yang tetap dipertahankan.

Untuk web, gunakan Playwright (`browser_navigate`, `browser_snapshot`,
`browser_take_screenshot`, dst) di Chrome.

**Platform (iOS simulator / macOS desktop / Chrome web) ditentukan oleh instruksi
user per tugas — jangan berasumsi.** Untuk iOS ingat flag wajib
`--no-tree-shake-icons` (lihat CLAUDE.md).

## Ringkasan per lapisan

| Lapisan | Keputusan |
|---|---|
| Unit (models, repositories, formatters, cart) | Tetap tulis — murah & bernilai |
| Widget test per halaman/komponen | **Stop by default**; kecuali layout-invariant nyata |
| Integration / E2E | **Bekukan yang ada; jangan tambah rutin** — ganti dengan MCP/Playwright |
| Regression guard (router, migration, layout) | Pertahankan; hapus hanya dengan izin |

## Catatan

Ini guidance yang dibaca Claude, bukan konfigurasi yang dipaksakan Claude Code.
Kalau suatu saat mau penegakan keras (mis. memblok pembuatan file test),
gunakan hooks atau permissions — bukan file rule ini.
