# Kompilasi Lengkap Fitur Backoffice Moka POS
*Dokumen ini merupakan hasil penggabungan dan verifikasi dari analisis tutorial penggunaan Moka POS dan eksplorasi langsung pada sistem demo Backoffice.*

---

## 1. Dashboard
Modul ini menyajikan ringkasan performa penjualan dan operasional bisnis.
**Filter & Kontrol Utama:** Pilihan `< periode waktu >`

*   **Summary (Ringkasan Penjualan):**
    *   **Sales Summary:** Menampilkan 8 metrik keuangan utama: Gross Sales (Kotor), Net Sales (Bersih), Gross Profit (Laba Kotor), Total Transaction, Average Sales per Transaction, Gross Margin, serta grafik *Gross Sales by Day of Week* dan *Gross Sales by Hour* (sangat berguna untuk mengidentifikasi jam sibuk/rush hour).
    *   **Item Summary:** Memantau produk *fast-moving* melalui 4 metrik: Top Items, Category by Volume, Category by Sales, dan Top Items by Category.
*   **Outlet Comparison (Perbandingan Outlet):**
    *   Fitur bagi pengguna multi-cabang untuk membandingkan kinerja penjualan antar outlet secara berdampingan pada periode yang sama.
    *   > **Catatan Sistem:** Fitur ini tidak menambah metrik baru, melainkan menyajikan data *Sales Summary* dan *Items* secara *side-by-side*. Secara arsitektur, ini adalah bentuk *view* lain dari query data Dashboard utama.

---

## 2. Reports (Laporan)
Pencatatan detail transaksi penjualan yang dapat diekspor ke CSV/Excel. Terdiri dari 4 sub-menu utama:

*   **Sales (Laporan Penjualan):**
    *   Menyajikan data berdasarkan metode pembayaran, tipe penjualan (dine-in/takeaway/online), penjualan item, kategori & brand, serta efektivitas diskon & modifier.
    *   > **Catatan Sistem:** *Sales Summary* disusun sebagai alur perhitungan *waterfall* (menurun): `Gross Sales -> (-) Discounts -> (-) Refunds -> (=) Net Sales -> (+) Gratuity -> (+) Tax -> (±) Rounding -> (=) Total Collected`.
*   **Transactions (Riwayat Transaksi):** Terbagi menjadi 3 tab dengan filter `Outlet -> Periode -> Receipt Number`:
    *   *Success Orders:* Menampilkan kolom Outlet, Time, Collected By, Items, Total Price.
    *   *Cancelled Orders:* Menyimpan alasan batal, pelaku (Cancelled By), dan waktu pembatalan. (Pembatalan dihitung per-order).
    *   *Void Items:* Menyimpan alasan void, pelaku, dan waktu. (Void dihitung per-item).
*   **Invoices (Laporan Tagihan):**
    *   Manajemen pembayaran tertunda/cicilan. Merchant bisa melakukan pencatatan pembayaran (DP/pelunasan) langsung dari backoffice. Status yang tersedia: *Cancelled, Unpaid, Overdue, Paid, Partially Paid*.
*   **Shift (Laporan Shift Karyawan):**
    *   Memantau periode buka-tutup shift kasir, mencatat uang kas awal, total transaksi, dan mendeteksi selisih uang kas (cash drawer) saat tutup shift.

---

## 3. Library (Master Data Produk)
Pusat pengaturan produk jual. 
**Pola UI Umum:** `Filter Outlet` → `Search` → `Create <entitas>`.

*   **Item Library:** Daftar induk seluruh produk. Bisa dibuat manual atau via Import/Export CSV. Mendukung pengaturan harga berbeda per *Sales Type* (misal: harga GrabFood lebih mahal dari Dine-in), melacak HPP, dan sinkronisasi ke katalog online.
*   **Modifier:** Opsi tambahan/topping pada item (contoh: keju, level pedas, ukuran). Bisa diatur berbayar atau gratis, dilimitasi pilihannya, dan stoknya bisa dihubungkan ke fitur *Ingredients*.
*   **Categories:** Pengelompokan produk (contoh: Minuman, Makanan, Sepatu).
*   **Bundle Package:** Paket gabungan beberapa item (contoh: Paket Ramadhan). Harga bisa dibedakan per *Sales Type*. Untuk mengedit isi paket, status bundle harus dinonaktifkan dulu.
*   **Promo:** Promosi otomatis dengan aturan (rules). Bisa berupa diskon item atau *free item*. Bisa ditargetkan ke *Sales Type*, rentang tanggal, atau jam tertentu. *(Catatan: Filter berdasarkan Status Promo, bukan Outlet).*
*   **Discounts:** Diskon manual yang tampil di tablet kasir. Kasir bisa mengatur *customizable amount* (nominal/persentase kasir yang tentukan) atau *fixed amount* (misal: Diskon Karyawan 100%).
*   **Taxes:** Pajak tambahan otomatis (contoh: PB1 10%).
*   **Gratuity:** Persentase biaya tambahan (contoh: Service Charge 5%, Takeaway Charge).
*   **Sales Type:** Tipe pesanan (Dine in, Take away, GrabFood, Grosir). Terintegrasi dengan pengaturan harga item dan gratuity.
*   **Brands:** Label merek produk (sangat berguna untuk bisnis ritel).

---

## 4. Ingredient (Master Data Bahan Baku)
Fokus pada komponen penyusun produk (F&B/Manufaktur ringan). Strukturnya mencerminkan modul Library.

*   **Ingredient Categories:** Pengelompokan bahan baku (contoh: Daging, Sayuran).
*   **Ingredient Library:** Master data bahan baku.
    *   *Raw Ingredients:* Bahan dasar (contoh: Telur, Tepung). Diset per satuan hitung (gram/pcs) beserta HPP dasar untuk *tracking cost*.
    *   *Semi-finish Ingredients:* Bahan olahan dari bahan mentah. Terdapat tombol **Produce**: jika ditekan, sistem otomatis memotong stok bahan dasar yang menyusunnya.
*   **Recipes:** Pemetaan komposisi bahan baku untuk item jual di *Item Library*.
    *   > **Catatan Sistem:** Saat item terjual di kasir, yang berkurang dari inventori adalah bahan baku penyusunnya (berdasarkan resep), bukan item jadinya. Relasi ini vital untuk akurasi perhitungan *Gross Profit*.

---

## 5. Inventory (Manajemen Stok)
Melacak pergerakan stok secara detail.

*   **Summary:** Laporan posisi stok (Bisa diekspor). Alur pergerakan stok mencakup: *Beginning (Awal) -> Purchase/In (Masuk) -> Sales (Terjual) -> Transfer (Pindah) -> Adjustment (Koreksi) -> Stok Akhir*.
*   **Suppliers:** Database pemasok (Nama, Email, Alamat) sebagai referensi *Purchase Order*.
*   **Purchase Order (PO):** Pemesanan stok masuk. Melayani barang jadi (*Items*) maupun bahan baku (*Ingredients*).
    *   *Simple PO:* Stok otomatis bertambah saat disimpan.
    *   *Advanced PO:* Melewati tahap *Approval* dan *Fulfillment* (Penerimaan Barang). Status PO: *Waiting, Completed, Cancelled*.
*   **Transfer:** Perpindahan stok antar outlet (maksimal 50 item per request). Juga memiliki mode *Simple* (langsung pindah) dan *Advanced* (Request -> Approval -> Shipment -> Fulfillment).
*   **Adjustment (Stock Opname):** Koreksi selisih stok aktual fisik vs sistem. Jika barang kurang = *Expense* (Kerugian), jika lebih = *Adjustment Income*.

---

## 6. Online Channels
Integrasi Moka dengan platform digital (Ekosistem GoTo & GoStore).

*   **GoFood:** Integrasi *native* dengan GoBiz. Pesanan masuk otomatis ke tablet kasir. Nama menu, gambar, dan harga khusus GoFood diatur langsung dari *Item Library* Moka.
*   **Moka Order:** Pembuatan website/katalog pesanan mandiri (powered by GoStore).
    *   Fitur: *Dine-in via QR Code* (pesan dari meja), dan *Self Pick-up*.
    *   Stok otomatis terpotong. Katalog bisa dikustomisasi (kondisi barang, pre-order, gambar, varian) lewat *Item Library*.

---

## 7. Customers (Manajemen Pelanggan)
*   **Customer List:** Database pelanggan (Nama, Kontak). Input awal dilakukan dari tablet kasir, namun Backoffice bisa Import/Export data untuk kebutuhan *blast promo/marketing*.
*   **Feedback:** Melacak tingkat kepuasan pelanggan lewat rating/komentar dari struk digital (SMS/Email) atau layar *Moka Prime*.
*   **Loyalty Program:** (Khusus paket Pro/Enterprise). Sistem poin member menggunakan nomor HP. Poin didapat berdasarkan total belanja atau item tertentu. Reward bisa berupa diskon persentase atau potongan nominal. Dilengkapi fitur *Security Code* (OTP) saat *redeem* poin.

---

## 8. Employees (Manajemen Karyawan)
*   **Employee Access (Hak Akses/Role):** Membuat jabatan (contoh: Kasir, SPV) dan membatasi izin akses mereka (hanya aplikasi Kasir, hanya Backoffice, atau keduanya).
*   **Employee Slots:** Mendaftarkan data karyawan (Nama, Email, HP) dan menugaskan *Role* yang sudah dibuat.
*   **PIN Access:** Mengatur PIN untuk masuk ke aplikasi dan membatasi tindakan sensitif di kasir (misal: PIN SPV dibutuhkan untuk membuka/membatalkan tagihan).

---

## 9. Table Management (Manajemen Meja)
*(Berlaku untuk bisnis F&B Dine-in)*

*   **Table Group:** Membagi area restoran (contoh: Lantai 1, Outdoor, VIP).
*   **Table Map:** Denah visual meja (fitur *Drag & Drop*). Pengaturan bentuk meja, nomor meja, dan kapasitas kursi.
*   **Integrasi Kasir:** Denah akan tersinkronisasi di tablet kasir dengan indikator warna (Kosong/Terisi). Terdapat *Time Tracker* untuk melihat durasi tamu menempati meja (berguna untuk *upselling*).
*   **Table Report:** Riwayat transaksi difilter berdasarkan meja tertentu (omzet per meja, durasi penggunaan).

---

## 10. Account Settings (Pengaturan Akun)
*   **Account:** Info bisnis dasar dan ganti password. (Email terenkripsi, penggantian butuh bantuan support Moka).
*   **Billing:** Melihat siklus tagihan aktif, status langganan per outlet, dan form *Payment/Coupon*. (Langganan Moka dihitung *per-outlet*, bukan *per-akun*).
*   **Outlets:** Master data seluruh cabang (ID Outlet, Nama, Alamat, Status GoBiz).
*   **Bank Account:** Rekening tujuan *settlement* pencairan dana (hanya mendukung 1 rekening utama per akun/bisnis).
*   **Public Profile & Receipt:** Kustomisasi info struk digital/cetak (Logo, alamat, medsos, catatan kaki/password wifi). Terdapat *Live Preview*.
*   **Checkout (Konfigurasi Kasir):** Toggle ON/OFF untuk: *Tax & Gratuity* (Include/Exclude), *Rounding*, *Stock Limit* (cegah jual barang jika stok habis), *Track Server*, *Split Payment*, dan *Save/Print Bill*.
*   **Inventory:** Memilih tingkat kerumitan stok (*Simple* atau *Advanced* untuk PO dan Transfer).
*   **Email Notification:** Toggle untuk ringkasan laporan harian, notifikasi stok menipis, dan update promo.

---

## 11. Payment (Pengaturan Pembayaran)
*   **Mobile Payment:** Aktivasi otomatis QRIS Dinamis/E-Wallet (seperti GoPay).
*   **Payment Configuration:** Membuat sekumpulan daftar opsi pembayaran yang akan muncul di layar kasir (Cash, EDC BCA, QRIS, Tokopedia, dll).
    *   > **Catatan Sistem:** Menggunakan arsitektur *Group Configuration*. Merchant membuat 1 set grup pembayaran, lalu di-*assign* ke cabang-cabang tertentu. Ini memudahkan pemeliharaan sistem jika ada puluhan outlet.