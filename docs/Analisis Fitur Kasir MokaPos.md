# Detail Fitur Aplikasi Kasir Moka POS

Moka POS adalah sistem *Point of Sale* (POS) berbasis *cloud* yang dirancang untuk memudahkan operasional bisnis, khususnya di sektor F&B (makanan dan minuman), retail, dan layanan jasa. Berdasarkan alur operasional standar dari tutorial Moka POS, aplikasi ini didesain agar kasir dan manajer dapat mengelola pesanan, stok, hingga laporan keuangan dalam satu pintu.

Berikut adalah penjelasan detail, runtut, dan terverifikasi mengenai 7 (tujuh) menu utama yang ada di dalam aplikasi Moka POS:

---

## 1. Denah Meja (*Table Management*)
Fitur ini sangat krusial bagi bisnis restoran (F&B) berkonsep *dine-in* (makan di tempat) karena membantu staf dalam memvisualisasikan tata letak restoran secara digital.

*   **Visualisasi Tata Letak (Layout):** Pengguna dapat membuat denah digital yang merepresentasikan posisi meja di dunia nyata (misalnya: area VIP, area *Outdoor*, area lantai 2).
*   **Indikator Status Meja:** Meja kosong dan meja yang sedang terisi dibedakan menggunakan warna atau ikon. Hal ini mencegah kasir atau *waiter* memberikan meja yang sama kepada tamu yang berbeda.
*   **Manajemen Pesanan (*Save Bill*):** Pesanan tamu akan langsung diikat ke nomor meja tersebut. Jika tamu memesan tambahan (*add-on*), staf hanya perlu membuka kembali meja tersebut di sistem dan menambahkan item.
*   **Lacak Durasi Pelanggan:** Terdapat indikator waktu (*timer*) yang menunjukkan sudah berapa lama pelanggan duduk di meja tertentu. Ini sangat berguna untuk restoran *All You Can Eat* (AYCE) atau saat menghadapi kondisi antrean panjang (*waiting list*).
*   **Pindah dan Gabung Meja (*Move & Join Table*):** Jika tamu ingin pindah meja (misal dari area luar ke dalam) atau ada dua rombongan yang ingin menggabungkan meja, kasir dapat memindahkan tagihan ke meja baru tanpa harus membatalkan pesanan awal.

## 2. *Point of Sale* (Menu Kasir Utama)
Ini adalah menu inti di mana kasir melakukan transaksi sehari-hari. Alurnya didesain sangat cepat untuk mencegah antrean pelanggan.

*   **Katalog Produk (*Item Library*):** Menampilkan seluruh menu atau barang yang dijual beserta fotonya, dikelompokkan berdasarkan Kategori (contoh: Makanan Utama, Minuman, *Dessert*).
*   **Varian dan Modifikasi ( *Modifiers*):** Kasir dapat dengan mudah menambahkan spesifikasi pesanan, seperti tingkat kemanisan (Normal/Less Sugar), ukuran (Regular/Large), atau tambahan *topping* (Ekstra Keju/Boba).
*   **Input Harga Manual (*Custom Amount*):** Tersedia ikon kalkulator yang memungkinkan kasir memasukkan nominal penjualan di luar menu yang ada di sistem (berguna untuk layanan kustom atau ongkos kirim manual).
*   **Tipe Penjualan (*Sales Type*):** Kasir bisa memilih jenis pesanan untuk menentukan pajak atau harga yang berbeda, seperti *Dine-in*, *Takeaway*, atau *Delivery*.
*   **Penerapan Diskon (Promo):** Diskon dapat diaplikasikan per produk atau per total tagihan (*bill*). Sistem secara otomatis memotong harga jika syarat promo terpenuhi.
*   **Metode Pembayaran (*Charge*):** Mendukung pembayaran Tunai (*Cash*), Kartu Debit/Kredit (EDC), dan dompet digital (OVO, GoPay, Dana, dll). 
*   **Split Bill:** Memungkinkan pelanggan dalam satu meja membayar pesanannya masing-masing secara terpisah dalam satu struk.

## 3. Pesanan Online (*Online Orders*)
Fitur ini merupakan integrasi mutakhir yang menghubungkan Moka POS langsung dengan platform pesan antar makanan seperti **GoFood**, **GrabFood**, dan **ShopeeFood**. (Catatan: Moka merupakan bagian dari grup GoTo, sehingga integrasi GoFood sangat mulus).

*   **Satu Dasbor Terpusat:** Kasir tidak perlu lagi menyediakan banyak tablet/HP tambahan dari masing-masing aplikator. Semua pesanan GoFood atau GrabFood yang masuk akan berbunyi dan muncul di satu layar aplikasi Moka POS.
*   **Penerimaan Otomatis (*Auto-Accept*):** Pesanan *online* bisa diatur untuk langsung diterima oleh sistem dan otomatis tercetak di printer dapur, sehingga memangkas waktu proses.
*   **Sinkronisasi Menu dan Stok:** Jika ada menu yang habis di Moka POS, kasir dapat mengubah statusnya menjadi *Out of Stock* (OOS), dan sistem akan otomatis menutup ketersediaan menu tersebut di aplikasi GoFood/GrabFood pelanggan.
*   **Laporan Terpisah:** Pendapatan dari pesanan *online* akan dipisah secara otomatis dari penjualan reguler (*dine-in*) pada laporan akhir, memudahkan pembukuan dan perhitungan bagi hasil dengan pihak aplikator.

## 4. Aktivitas (*Activity*)
Menu *Aktivitas* berfungsi sebagai riwayat operasional dan transaksi yang terjadi pada hari tersebut atau hari-hari sebelumnya.

*   **Lacak Riwayat Transaksi:** Semua transaksi, baik yang berhasil dibayar, disimpan (*saved bill*), maupun yang dibatalkan, terekam di sini beserta jam transaksi dan nama kasir yang bertugas.
*   **Cetak Ulang Struk (*Reprint Receipt*):** Jika pelanggan meminta struk fisik kembali, atau jika kertas printer sebelumnya habis di tengah transaksi, kasir dapat mencari transaksi tersebut dan mencetak ulang struknya.
*   **Pengembalian Dana (*Refund* / *Void*):** Jika terjadi kesalahan input atau pembatalan dari pelanggan, kasir dapat melakukan proses pengembalian dana. Biasanya, tindakan ini dilindungi oleh PIN Otorisasi sehingga hanya Manajer atau Pemilik yang bisa menyetujui *refund* untuk mencegah kecurangan.
*   **Kirim Struk Digital:** Kasir dapat mengirimkan bukti pembayaran via Email atau SMS langsung dari menu ini kepada pelanggan.

## 5. Inventori (*Inventory*)
Menu inventori mengelola keluar masuknya barang dagangan atau bahan baku secara *real-time*.

*   **Pelacakan Stok Otomatis:** Setiap kali terjadi transaksi di menu *Point of Sale*, jumlah stok barang di menu Inventori akan otomatis berkurang secara *real-time*.
*   **Peringatan Stok Menipis (*Low Stock Alert*):** Sistem akan memberikan notifikasi warna peringatan jika barang sudah mencapai batas minimum stok, sehingga pihak resto bisa segera berbelanja.
*   **Manajemen Bahan Baku (*Ingredient Tracking* / *Recipe*):** (Fitur ini biasanya diatur di *Backoffice*, namun laporannya terhubung ke POS). Misalnya, untuk 1 cup Kopi Susu, sistem otomatis memotong 20 gram biji kopi, 100 ml susu, dan 1 buah gelas plastik.
*   **Penyesuaian Stok (*Stock Adjustment*):** Kasir/Manajer dapat mengoreksi jumlah barang jika terjadi kerusakan, barang kedaluwarsa, atau ketidaksesuaian saat *stock opname* (audit barang).

## 6. Shift (Manajemen Waktu Kerja Kasir)
Menu *Shift* mengatur pertanggungjawaban uang fisik yang ada di laci kasir (*Cash Drawer*), sangat penting untuk mencegah selisih uang (*fraud*).

*   **Mulai Shift (*Start Shift* / *Starting Cash*):** Saat kasir mulai bekerja (misal pukul 08.00 pagi), mereka wajib memasukkan nominal "Uang Modal/Kembalian" yang ada di dalam mesin kasir.
*   **Kas Masuk / Kas Keluar (*Cash Drop & Petty Cash*):** Jika di tengah *shift* ada uang yang diambil untuk beli galon/es batu (Kas Keluar) atau ada penambahan uang receh (Kas Masuk), semua harus dicatat di sistem.
*   **Tutup Shift (*End Shift* / *Closing*):** Saat *shift* berakhir, sistem akan memberikan laporan: Berapa total uang tunai yang *seharusnya* ada di laci (Modal Awal + Penjualan Tunai - Kas Keluar). Kasir wajib menghitung uang fisik secara manual dan mencocokkannya dengan sistem.
*   **Laporan Shift Cetak:** Setelah divalidasi, sistem akan mencetak struk *Z-Report* (Laporan Shift) sebagai bukti pertanggungjawaban serah terima kepada manajer atau *shift* selanjutnya.

## 7. Pengaturan (*Settings*)
Menu ini digunakan untuk melakukan konfigurasi teknis dari aplikasi Moka POS pada perangkat kasir (*hardware & software configuration*).

*   **Pengaturan Perangkat (*Hardware*):** Tempat untuk menyambungkan aplikasi Moka dengan Printer *Bluetooth*/*LAN*, *Barcode Scanner*, dan Laci Uang Digital (*Cash Drawer*). Pengguna juga bisa memisahkan mana *Printer* Kasir (untuk cetak struk total) dan mana *Printer Ticket* (untuk dikirim ke dapur).
*   **Pengaturan Struk (*Receipt Settings*):** Menambahkan logo toko, alamat, serta catatan tambahan (misal: "Follow IG kami @TokoKopi" atau kata sandi WiFi) di bagian kaki struk (*footer*).
*   **Pengaturan Keamanan (*Passcode*):** Mengharuskan staf untuk memasukkan 4-digit PIN setiap kali membuka aplikasi, melakukan pembatalan (*void*), atau mengakses menu laporan. Ini menjaga sistem dari pihak yang tidak berkepentingan.
*   **Manajemen Staf:** Mengatur hak akses siapa saja (kasir, *waiter*, manajer) yang sedang log in di perangkat keras tersebut.