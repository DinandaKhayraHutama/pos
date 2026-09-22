// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Indonesian (`id`).
class AppLocalizationsId extends AppLocalizations {
  AppLocalizationsId([String locale = 'id']) : super(locale);

  @override
  String get remoteReceiptReadOnly =>
      'Struk dari server — hanya dapat dibaca di perangkat ini.';

  @override
  String get tillOnlineRequired =>
      'Hubungkan ke server untuk membuka atau memindahkan sesi. Coba lagi dengan kasir yang sama.';

  @override
  String get tillRegisterBusy =>
      'Till ini masih memiliki sesi terbuka. Selesaikan dan sinkronkan dari perangkat asal terlebih dahulu.';

  @override
  String get tillCashierBusy =>
      'Kasir ini masih bertugas di till lain. Akhiri atau serahkan penugasan tersebut terlebih dahulu.';

  @override
  String get tillSyncRequired =>
      'Sinkronkan transaksi tertunda dan selesaikan data yang ditolak sebelum menyerahkan till.';

  @override
  String get tillLoginRequired =>
      'Verifikasi PIN kembali saat online untuk melanjutkan.';

  @override
  String get tillSessionUnconfirmed =>
      'Sesi belum disahkan untuk kasir dan perangkat ini. Buka sesi yang terkonfirmasi sebelum berjualan.';

  @override
  String get connectedMasterDataNotice =>
      'Menu, modifier, promo, dan denah meja dikelola di Backoffice. Kasir ini menerima pembaruan otomatis.';

  @override
  String get tableContested => 'Perubahan meja bertabrakan';

  @override
  String get tableContestedHelp =>
      'Dua kasir mengubah meja ini. Konfirmasi dengan staf, sinkronkan, lalu pilih status yang benar untuk menyelesaikan konflik.';

  @override
  String get appTitle => 'JustClick POS';

  @override
  String get appTagline => 'Sistem Kasir & Manajemen Restoran';

  @override
  String get navPos => 'Transaksi';

  @override
  String get navOrders => 'Pesanan';

  @override
  String get navTables => 'Meja';

  @override
  String get navDashboard => 'Laporan';

  @override
  String get navSettings => 'Pengaturan';

  @override
  String get commonSearch => 'Cari';

  @override
  String get commonCancel => 'Batal';

  @override
  String get commonSave => 'Simpan';

  @override
  String get commonDelete => 'Hapus';

  @override
  String get commonEdit => 'Ubah';

  @override
  String get commonAdd => 'Tambah';

  @override
  String get commonClose => 'Tutup';

  @override
  String get commonConfirm => 'Konfirmasi';

  @override
  String get commonContinue => 'Lanjut';

  @override
  String get commonBack => 'Kembali';

  @override
  String get commonRetry => 'Coba lagi';

  @override
  String get commonDone => 'Selesai';

  @override
  String get commonYes => 'Ya';

  @override
  String get commonNo => 'Tidak';

  @override
  String get commonAll => 'Semua';

  @override
  String get commonEmpty => 'Belum ada data';

  @override
  String get commonLoading => 'Memuat...';

  @override
  String get commonError => 'Terjadi kesalahan';

  @override
  String get commonNoResults => 'Tidak ada hasil';

  @override
  String get commonUnknown => 'Tidak diketahui';

  @override
  String get commonRequired => 'Wajib diisi';

  @override
  String get commonOptional => 'Opsional';

  @override
  String get commonToday => 'Hari ini';

  @override
  String get commonCurrency => 'Rp';

  @override
  String get categoryAll => 'Semua';

  @override
  String get categoryPopular => 'Populer';

  @override
  String get posTitle => 'Transaksi';

  @override
  String get posGreetingMorning => 'Selamat pagi';

  @override
  String get posGreetingNoon => 'Selamat siang';

  @override
  String get posGreetingAfternoon => 'Selamat sore';

  @override
  String get posGreetingEvening => 'Selamat malam';

  @override
  String get posSearchProduct => 'Cari menu...';

  @override
  String get posNoProducts => 'Tidak ada produk di kategori ini';

  @override
  String get posCartEmpty => 'Keranjang kosong';

  @override
  String get posCartEmptyHint => 'Tap produk untuk menambahkan ke pesanan';

  @override
  String get posCart => 'Keranjang';

  @override
  String posCartItems(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count item',
      one: '1 item',
      zero: '0 item',
    );
    return '$_temp0';
  }

  @override
  String get posSubtotal => 'Subtotal';

  @override
  String get posDiscount => 'Diskon';

  @override
  String get posServiceCharge => 'Biaya Layanan';

  @override
  String get posTax => 'PB1';

  @override
  String get posTotal => 'Total';

  @override
  String get posCharge => 'Bayar';

  @override
  String get posCheckout => 'Bayar';

  @override
  String get posClearCart => 'Kosongkan keranjang';

  @override
  String get posCustomerName => 'Nama pelanggan (opsional)';

  @override
  String get posNote => 'Catatan pesanan';

  @override
  String get posNoteHint => 'mis. tanpa cabai, saus extra';

  @override
  String get posOrderType => 'Tipe pesanan';

  @override
  String get posDineIn => 'Makan di tempat';

  @override
  String get posTakeaway => 'Bawa pulang';

  @override
  String get posDelivery => 'Antar';

  @override
  String get posSelectTable => 'Pilih meja';

  @override
  String get posAddDiscount => 'Tambah diskon';

  @override
  String get posAmountPaid => 'Jumlah dibayar';

  @override
  String get posChange => 'Kembalian';

  @override
  String get posExactCash => 'Uang pas';

  @override
  String get posPaymentMethod => 'Metode bayar';

  @override
  String get posCash => 'Tunai';

  @override
  String get posQris => 'QRIS';

  @override
  String get posCard => 'Kartu';

  @override
  String get posPlaceOrder => 'Proses Pesanan';

  @override
  String get posOrderPlaced => 'Pesanan berhasil diproses';

  @override
  String posOrderNumber(String id) {
    return 'Pesanan #$id';
  }

  @override
  String get posQty => 'Jml';

  @override
  String get posRemoveItem => 'Hapus';

  @override
  String get posQuickAdd => 'Tambah cepat';

  @override
  String get posInCart => 'di keranjang';

  @override
  String get posQtyIncrease => 'Tambah satu';

  @override
  String get posQtyDecrease => 'Kurangi satu';

  @override
  String get posUnavailable => 'Tidak tersedia';

  @override
  String get posOutOfStock => 'Stok habis';

  @override
  String posStockLeft(int count) {
    return 'sisa $count';
  }

  @override
  String get orderStatusAll => 'Semua';

  @override
  String get orderStatusPending => 'Menunggu';

  @override
  String get orderStatusPreparing => 'Diproses';

  @override
  String get orderStatusReady => 'Siap';

  @override
  String get orderStatusServed => 'Disajikan';

  @override
  String get orderStatusPaid => 'Selesai';

  @override
  String get orderStatusCancelled => 'Dibatalkan';

  @override
  String get ordersTitle => 'Pesanan';

  @override
  String get ordersEmpty => 'Belum ada pesanan';

  @override
  String get ordersEmptyHint => 'Penjualan yang selesai akan muncul di sini';

  @override
  String get ordersTodayRevenue => 'Pendapatan hari ini';

  @override
  String get ordersTodayCount => 'Pesanan hari ini';

  @override
  String get ordersDetail => 'Detail pesanan';

  @override
  String ordersMarkAs(String status) {
    return 'Tandai $status';
  }

  @override
  String get ordersCancelOrder => 'Batalkan pesanan';

  @override
  String get ordersPrintReceipt => 'Cetak struk';

  @override
  String get receiptPrintFailed => 'Dialog cetak tidak dapat dibuka';

  @override
  String ordersItemAt(String time) {
    return '$time';
  }

  @override
  String get ordersFilterByStatus => 'Filter status';

  @override
  String get tableStatusAvailable => 'Tersedia';

  @override
  String get tableStatusOccupied => 'Terisi';

  @override
  String get tableStatusReserved => 'Dipesan';

  @override
  String get tablesTitle => 'Meja';

  @override
  String get tablesTotal => 'Total';

  @override
  String tablesCapacity(int count) {
    return '$count kursi';
  }

  @override
  String get tablesEmpty => 'Belum ada meja';

  @override
  String get tablesEmptyHint => 'Tambah meja untuk kelola dine-in';

  @override
  String get tablesAddTable => 'Tambah meja';

  @override
  String get tablesTableName => 'Nama meja';

  @override
  String get tablesCapacityLabel => 'Kapasitas (kursi)';

  @override
  String get tablesStatus => 'Status';

  @override
  String get tablesSetStatus => 'Atur status meja';

  @override
  String get tablesFloor => 'Lantai';

  @override
  String get tablesFloor1 => 'Lantai 1';

  @override
  String get tablesFloor2 => 'Lantai 2';

  @override
  String get tablesFloor3 => 'Lantai 3';

  @override
  String get tablesFloor4 => 'Teras';

  @override
  String get tablesStartOrder => 'Mulai pesanan';

  @override
  String get tablesInactive => 'Tidak aktif';

  @override
  String get tableManagementTitle => 'Manajemen Meja';

  @override
  String get tableManagementEmpty => 'Outlet ini belum punya meja';

  @override
  String get tablesEditTable => 'Ubah meja';

  @override
  String get tablesFloorHint => 'cth. Lantai 1, Rooftop, VIP';

  @override
  String get tablesNameTaken =>
      'Meja lain di outlet ini sudah memakai nama tersebut';

  @override
  String get tablesCapacityInvalid => 'Kapasitas minimal 1 kursi';

  @override
  String get tablesActive => 'Aktif';

  @override
  String get tablesActiveHint => 'Bisa dipilih untuk pesanan dine-in baru';

  @override
  String get tablesInactiveHint => 'Disembunyikan dari pesanan dine-in baru';

  @override
  String get tablesDeleteConfirm => 'Hapus meja ini?';

  @override
  String get tablesDeleteConfirmBody =>
      'Meja akan hilang dari daftar. Pesanan yang sudah tercatat tetap menyimpan nama mejanya.';

  @override
  String get tablesHasHistory =>
      'Meja ini memiliki riwayat pesanan, sehingga tidak bisa dihapus. Nonaktifkan saja.';

  @override
  String get productManagementTitle => 'Produk';

  @override
  String get productAdd => 'Tambah produk';

  @override
  String get productEdit => 'Ubah produk';

  @override
  String get productName => 'Nama produk';

  @override
  String get productPrice => 'Harga';

  @override
  String get productCategory => 'Kategori';

  @override
  String get productDescription => 'Deskripsi';

  @override
  String get productAvailable => 'Tersedia';

  @override
  String get productUnavailable => 'Tidak tersedia';

  @override
  String get productEmoji => 'Ikon';

  @override
  String get productDeleteConfirm => 'Hapus produk ini?';

  @override
  String get productDeleteConfirmBody => 'Tindakan ini tidak dapat dibatalkan.';

  @override
  String get productEmpty => 'Belum ada produk';

  @override
  String get productEmptyHint =>
      'Tambahkan produk pertama untuk mulai berjualan';

  @override
  String get productPopular => 'Populer';

  @override
  String get productStock => 'Stok';

  @override
  String get productStockHint => 'Kosongkan bila item ini tidak dihitung';

  @override
  String get productCost => 'Harga modal';

  @override
  String get productSku => 'SKU / barcode';

  @override
  String get productLowStock => 'Stok menipis';

  @override
  String get productOutOfStock => 'Stok habis';

  @override
  String productStockValue(int count) {
    return 'Stok: $count';
  }

  @override
  String get productNotTracked => 'Tidak dihitung';

  @override
  String get employeesTitle => 'Pegawai';

  @override
  String get employeesManage => 'Pegawai dan PIN';

  @override
  String get employeeAdd => 'Tambah pegawai';

  @override
  String get employeeEdit => 'Ubah pegawai';

  @override
  String get employeeName => 'Nama';

  @override
  String get employeePin => 'PIN (4 digit)';

  @override
  String get employeeRole => 'Peran';

  @override
  String get employeeRoleCashier => 'Kasir';

  @override
  String get employeeRoleManager => 'Manajer';

  @override
  String get employeeActive => 'Bisa masuk';

  @override
  String get employeeInactive => 'Tidak bisa masuk';

  @override
  String get employeePinTaken => 'PIN itu sudah dipakai orang lain';

  @override
  String get employeePinLength => 'PIN harus tepat 4 digit';

  @override
  String get employeeDeleteConfirm => 'Hapus pegawai ini?';

  @override
  String get employeeDeleteConfirmBody =>
      'Pesanan lama tetap menyimpan namanya. Dia tidak bisa masuk lagi.';

  @override
  String get employeeCannotDeleteSelf =>
      'Kamu tidak bisa menghapus pegawai yang sedang masuk';

  @override
  String get employeeSignedInAs => 'Masuk sebagai';

  @override
  String get shiftTitle => 'Shift';

  @override
  String get shiftOpen => 'Buka shift';

  @override
  String get shiftClose => 'Tutup shift';

  @override
  String get shiftNoneOpen => 'Belum ada shift terbuka';

  @override
  String get shiftNoneOpenHint => 'Buka shift dengan modal kas di laci';

  @override
  String get shiftOpeningCash => 'Kas awal';

  @override
  String get shiftCountedCash => 'Kas dihitung';

  @override
  String get shiftExpectedCash => 'Seharusnya di laci';

  @override
  String get shiftVariance => 'Selisih';

  @override
  String get shiftCashSales => 'Penjualan tunai';

  @override
  String get shiftNonCashSales => 'Kartu / QRIS';

  @override
  String get shiftOrders => 'Pesanan shift ini';

  @override
  String shiftOpenedAt(String time) {
    return 'Dibuka $time';
  }

  @override
  String shiftClosedAt(String time) {
    return 'Ditutup $time';
  }

  @override
  String get shiftNote => 'Catatan (opsional)';

  @override
  String get shiftHistory => 'Riwayat closing';

  @override
  String get shiftHistoryEmpty => 'Belum ada shift yang ditutup';

  @override
  String get shiftOver => 'Lebih';

  @override
  String get shiftShort => 'Kurang';

  @override
  String get shiftBalanced => 'Pas';

  @override
  String get shiftStillOpen => 'Masih terbuka';

  @override
  String get reportTitle => 'Laporan penjualan';

  @override
  String get reportToday => 'Hari ini';

  @override
  String get reportLast7 => '7 hari terakhir';

  @override
  String get reportLast30 => '30 hari terakhir';

  @override
  String get reportThisMonth => 'Bulan ini';

  @override
  String get reportCustomRange => 'Pilih tanggal';

  @override
  String get reportRevenue => 'Pendapatan';

  @override
  String get reportOrders => 'Pesanan';

  @override
  String get reportAverage => 'Rata-rata pesanan';

  @override
  String get reportItemsSold => 'Item terjual';

  @override
  String get reportSubtotal => 'Subtotal';

  @override
  String get reportDiscount => 'Diskon';

  @override
  String get reportServiceCharge => 'Biaya Layanan';

  @override
  String get reportTax => 'PB1';

  @override
  String get reportCancelled => 'Dibatalkan';

  @override
  String get reportByPayment => 'Per metode bayar';

  @override
  String get reportByType => 'Per tipe pesanan';

  @override
  String get reportByCashier => 'Per kasir';

  @override
  String get reportDaily => 'Pendapatan harian';

  @override
  String get reportExport => 'Export CSV';

  @override
  String get reportExported => 'Laporan diekspor';

  @override
  String get reportEmpty => 'Tidak ada penjualan di rentang ini';

  @override
  String get reportSummary => 'Ringkasan';

  @override
  String get reportMetric => 'Metrik';

  @override
  String get reportAmount => 'Jumlah';

  @override
  String get reportMethod => 'Metode';

  @override
  String get reportCount => 'Pesanan';

  @override
  String get reportType => 'Tipe';

  @override
  String get reportCashier => 'Kasir';

  @override
  String get reportDate => 'Tanggal';

  @override
  String get reportPeriod => 'Periode';

  @override
  String get categoryManagementTitle => 'Kategori';

  @override
  String get categoryAdd => 'Tambah kategori';

  @override
  String get categoryEdit => 'Ubah kategori';

  @override
  String get categoryName => 'Nama kategori';

  @override
  String get categoryDeleteConfirm => 'Hapus kategori ini?';

  @override
  String get categoryEmpty => 'Belum ada kategori';

  @override
  String get categoryEmoji => 'Ikon';

  @override
  String get dashboardTitle => 'Laporan';

  @override
  String dashboardGreeting(String name) {
    return 'Halo, $name!';
  }

  @override
  String get dashboardRevenue => 'Pendapatan';

  @override
  String get dashboardOrders => 'Pesanan';

  @override
  String get dashboardAvgOrder => 'Rata-rata';

  @override
  String get dashboardTopProducts => 'Produk terlaris';

  @override
  String get dashboardRecentOrders => 'Pesanan terbaru';

  @override
  String get dashboardThisWeek => 'Minggu ini';

  @override
  String get dashboardNoSales => 'Belum ada penjualan';

  @override
  String get dashboardItemsSold => 'item terjual';

  @override
  String get dashboardViewAll => 'Lihat semua';

  @override
  String get settingsTitle => 'Pengaturan';

  @override
  String get settingsAppearance => 'Tampilan';

  @override
  String get settingsTheme => 'Tema';

  @override
  String get settingsThemeLight => 'Terang';

  @override
  String get settingsThemeDark => 'Gelap';

  @override
  String get settingsThemeSystem => 'Sistem';

  @override
  String get settingsBrandColor => 'Warna merek';

  @override
  String get settingsLanguage => 'Bahasa';

  @override
  String get settingsLanguageEn => 'English';

  @override
  String get settingsLanguageId => 'Bahasa Indonesia';

  @override
  String get settingsBusiness => 'Bisnis';

  @override
  String get settingsTaxRate => 'Tarif PB1 (%)';

  @override
  String get settingsServiceCharge => 'Biaya layanan';

  @override
  String get settingsServiceChargeRate => 'Tarif biaya layanan (%)';

  @override
  String get settingsServiceChargeOn => 'Ditambahkan ke setiap tagihan';

  @override
  String get settingsServiceChargeOff => 'Tidak diterapkan ke tagihan';

  @override
  String get settingsCurrency => 'Simbol mata uang';

  @override
  String get settingsStoreName => 'Nama toko';

  @override
  String get settingsStoreAddress => 'Alamat toko';

  @override
  String get settingsTableService => 'Layanan meja';

  @override
  String get outletsTitle => 'Outlet';

  @override
  String get outletsSubtitle => 'Cabang, alamat, dan perangkat ini ada di mana';

  @override
  String get outletAdd => 'Tambah outlet';

  @override
  String get outletEdit => 'Ubah outlet';

  @override
  String get outletName => 'Nama outlet';

  @override
  String get outletAddress => 'Alamat';

  @override
  String get outletOpen => 'Buka';

  @override
  String get outletClosed => 'Tutup';

  @override
  String get outletNameTaken => 'Nama itu sudah dipakai outlet lain';

  @override
  String get outletUseHere => 'Pakai di perangkat ini';

  @override
  String get outletThisDevice => 'Perangkat ini';

  @override
  String get outletPickTitle => 'Perangkat ini ada di outlet mana?';

  @override
  String get outletPickHint =>
      'Penjualan, stok dan meja semuanya mengikuti pilihan ini';

  @override
  String get outletDeleteConfirm => 'Hapus outlet ini?';

  @override
  String get outletDeleteConfirmBody =>
      'Outlet hilang dari daftar. Penjualan yang sudah tercatat tetap menyimpan namanya.';

  @override
  String get outletHasSales =>
      'Outlet ini punya penjualan, jadi tidak bisa dihapus. Tutup saja.';

  @override
  String get outletKeepOneOpen => 'Minimal satu outlet harus tetap buka';

  @override
  String get settingsTableServiceOn => 'Tamu didudukkan di meja bernomor';

  @override
  String get settingsTableServiceOff =>
      'Tanpa denah meja — dine-in tak perlu meja';

  @override
  String get settingsAbout => 'Tentang';

  @override
  String get settingsVersion => 'Versi';

  @override
  String get settingsLogout => 'Keluar';

  @override
  String get settingsProfile => 'Profil kasir';

  @override
  String get settingsData => 'Data';

  @override
  String get settingsResetDemoData => 'Reset data demo';

  @override
  String get settingsResetConfirm => 'Reset semua data demo?';

  @override
  String get settingsResetConfirmBody =>
      'Semua pesanan, produk, dan pengaturan akan dikembalikan ke awal.';

  @override
  String get authWelcome => 'Selamat datang';

  @override
  String get authLoginHint => 'Masukkan PIN untuk lanjut';

  @override
  String get ordersPrintFailed => 'Struk gagal dicetak';

  @override
  String get navCollapseSidebar => 'Ciutkan sidebar';

  @override
  String get navExpandSidebar => 'Bentangkan sidebar';

  @override
  String get authChooseAccount => 'Siapa yang bertugas?';

  @override
  String get authChooseAccountHint => 'Pilih akun Anda, lalu masukkan PIN';

  @override
  String get authChangeAccount => 'Ganti';

  @override
  String get authNoAccounts => 'Belum ada akun staf';

  @override
  String get authPin => 'PIN';

  @override
  String get authLogin => 'Masuk';

  @override
  String get authWrongPin => 'PIN salah';

  @override
  String get authCashier => 'Kasir';

  @override
  String get authStoreManager => 'Manajer Toko';

  @override
  String get authDemoPin => 'PIN demo: 1234';

  @override
  String get receiptThankYou => 'Terima kasih!';

  @override
  String get receiptStore => 'Toko';

  @override
  String get receiptCashier => 'Kasir';

  @override
  String get receiptDate => 'Tanggal';

  @override
  String get receiptOrderType => 'Tipe';

  @override
  String get receiptPaid => 'LUNAS';

  @override
  String get receiptPoweredBy => 'Didukung JustClick POS';

  @override
  String get employeeRoleOwner => 'Pemilik';

  @override
  String get employeeRoleCashierHint =>
      'Melayani penjualan, mengatur meja, dan menghitung laci kasnya sendiri.';

  @override
  String get employeeRoleManagerHint =>
      'Semua yang kasir bisa, ditambah pembatalan, refund, diskon, dan stok.';

  @override
  String get employeeRoleOwnerHint =>
      'Kendali penuh: katalog, harga, laporan, karyawan, dan promo.';

  @override
  String get authorizeTitle => 'Persetujuan manajer';

  @override
  String get authorizeDenied => 'PIN itu tidak berwenang untuk ini';

  @override
  String get authorizeReasonVoid =>
      'Membatalkan penjualan perlu PIN manajer atau pemilik.';

  @override
  String get authorizeReasonRefund =>
      'Refund penjualan perlu PIN manajer atau pemilik.';

  @override
  String get authorizeReasonDiscount =>
      'Diskon manual perlu PIN manajer atau pemilik.';

  @override
  String get settingsSignedInAs => 'Masuk sebagai';

  @override
  String get settingsRoleAccess => 'Akses Anda';

  @override
  String get orderStatusRefunded => 'Refund';

  @override
  String get ordersVoid => 'Batalkan pesanan';

  @override
  String get ordersRefund => 'Refund pesanan';

  @override
  String get ordersVoidTitle => 'Batalkan pesanan ini?';

  @override
  String get ordersRefundTitle => 'Refund pesanan ini?';

  @override
  String get ordersVoidBody =>
      'Penjualan dicoret dan stoknya dikembalikan ke rak.';

  @override
  String get ordersRefundBody =>
      'Uang dikembalikan dan stoknya dikembalikan ke rak.';

  @override
  String get ordersVoidReason => 'Alasan';

  @override
  String get ordersVoidReasonHint => 'Salah pesan, pelanggan berubah pikiran…';

  @override
  String get ordersVoidReasonRequired =>
      'Isi alasan agar laporan bisa menjelaskannya';

  @override
  String ordersAuthorizedBy(String name) {
    return 'Disetujui $name';
  }

  @override
  String ordersRefundedAmount(String amount) {
    return 'Direfund $amount';
  }

  @override
  String get ordersVoided => 'Pesanan dibatalkan';

  @override
  String get ordersRefunded => 'Pesanan direfund';

  @override
  String get ordersScopeOwnToday => 'Penjualan Anda hari ini';

  @override
  String get ordersScopeAll => 'Semua penjualan';

  @override
  String get posChooseOption => 'Pilih varian';

  @override
  String get productVariants => 'Varian';

  @override
  String get productVariantsHint =>
      'Ukuran atau pilihan dengan harganya sendiri. Kosongkan bila hanya satu.';

  @override
  String get productVariantAdd => 'Tambah varian';

  @override
  String get productVariantName => 'Nama varian';

  @override
  String get productVariantPriceDelta => 'Selisih harga';

  @override
  String get modifierManagementTitle => 'Modifier';

  @override
  String get modifierGroupAdd => 'Tambah grup modifier';

  @override
  String get modifierGroupEdit => 'Edit grup modifier';

  @override
  String get modifierGroupName => 'Nama grup';

  @override
  String get modifierGroupEmpty => 'Belum ada grup modifier';

  @override
  String get modifierGroupEmptyHint =>
      'Buat grup seperti level pedas atau topping untuk dipakai ulang di banyak produk';

  @override
  String get modifierSelectionType => 'Tipe pilihan';

  @override
  String get modifierSelectionSingle => 'Pilihan tunggal';

  @override
  String get modifierSelectionMultiple => 'Pilihan ganda';

  @override
  String get modifierRequired => 'Wajib';

  @override
  String get modifierRequiredHint =>
      'Kasir harus pilih minimal satu opsi sebelum produk ini bisa ditambahkan';

  @override
  String get modifierMaxSelect => 'Maksimal pilihan';

  @override
  String get modifierMaxSelectHint => 'Kosongkan untuk tanpa batas';

  @override
  String get modifierMaxSelectInvalid => 'Minimal 1';

  @override
  String get modifierOptions => 'Opsi';

  @override
  String get modifierOptionsHint =>
      'Tambahkan minimal satu opsi, mis. Mild, Sedang, Pedas';

  @override
  String get modifierOptionAdd => 'Tambah opsi';

  @override
  String get modifierOptionEdit => 'Ubah opsi';

  @override
  String get modifierOptionName => 'Nama opsi';

  @override
  String get modifierOptionPriceDelta => 'Tambahan harga';

  @override
  String get modifierRequiredNoActiveOptions =>
      'Grup ini wajib tapi belum punya opsi aktif — produk yang memakainya akan melewati grup ini, bukan macet.';

  @override
  String get modifierGroupDeleteConfirm => 'Hapus grup modifier ini?';

  @override
  String modifierGroupDeleteConfirmBody(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count produk memakainya.',
      one: '1 produk memakainya.',
      zero: 'Tidak ada produk yang memakainya.',
    );
    return '$_temp0 Order lama tetap menyimpan apa yang terjual; ini hanya menghapusnya dari penjualan berikutnya.';
  }

  @override
  String get modifierGroupsSectionTitle => 'Grup modifier';

  @override
  String get modifierGroupsSectionHint =>
      'Bisa dipakai ulang di banyak produk — kelola dari tab Modifiers';

  @override
  String modifierOptionCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count opsi',
      one: '1 opsi',
      zero: '0 opsi',
    );
    return '$_temp0';
  }

  @override
  String get modifierPickTitle => 'Pilih modifier';

  @override
  String get modifierPickRequiredBadge => 'Wajib';

  @override
  String get modifierPickOptionalBadge => 'Opsional';

  @override
  String modifierPickMaxBadge(int count) {
    return 'Pilih maks $count';
  }

  @override
  String modifierAddToCart(String price) {
    return 'Tambah — $price';
  }

  @override
  String get modifierEditSelections => 'Ubah pilihan';

  @override
  String get cartLineEdit => 'Edit';

  @override
  String modifierOptionScopeHint(String groupName) {
    return 'Opsi $groupName mana yang berlaku untuk produk ini';
  }

  @override
  String get modifierOptionScopeEmpty =>
      'Grup ini belum punya opsi aktif — tambahkan dari tab Modifiers';

  @override
  String get promosTitle => 'Promo';

  @override
  String get promosManage => 'Diskon yang boleh dipakai kasir mana pun';

  @override
  String get promoAdd => 'Promo baru';

  @override
  String get promoEdit => 'Ubah promo';

  @override
  String get promoName => 'Nama promo';

  @override
  String get promoKind => 'Jenis';

  @override
  String get promoKindPercent => 'Persen';

  @override
  String get promoKindAmount => 'Nominal tetap';

  @override
  String get promoValue => 'Nilai';

  @override
  String get promoMinSpend => 'Belanja minimum';

  @override
  String get promoMinSpendHint => '0 bila tanpa minimum';

  @override
  String get promoActive => 'Aktif';

  @override
  String get promoInactive => 'Nonaktif';

  @override
  String get promoEmpty => 'Belum ada promo';

  @override
  String get promoEmptyHint => 'Buat satu dan semua kasir bisa memakainya.';

  @override
  String get promoDeleteConfirm => 'Hapus promo ini?';

  @override
  String get promoDeleteConfirmBody =>
      'Penjualan yang sudah memakainya tetap berdiskon.';

  @override
  String promoRequiresMin(String amount) {
    return 'Minimum $amount';
  }

  @override
  String get posDiscountTitle => 'Diskon';

  @override
  String get posDiscountNone => 'Tanpa diskon';

  @override
  String get posDiscountManual => 'Manual';

  @override
  String get posDiscountPercent => 'Persen';

  @override
  String get posDiscountAmount => 'Nominal';

  @override
  String posDiscountApprovedBy(String name) {
    return 'Disetujui $name';
  }

  @override
  String get posDiscountRemove => 'Hapus diskon';

  @override
  String get posDiscountLocked => 'Minta manajer menyetujui diskon manual';

  @override
  String get inventoryTitle => 'Stok';

  @override
  String get inventoryManage => 'Catat stok masuk/keluar dan riwayatnya';

  @override
  String get inventoryLowStock => 'Menipis';

  @override
  String get inventoryAllStocked => 'Tidak ada stok menipis';

  @override
  String get inventoryAllStockedHint =>
      'Semua produk terpantau masih di atas ambang.';

  @override
  String get inventoryAdjust => 'Sesuaikan stok';

  @override
  String get inventoryIn => 'Stok masuk';

  @override
  String get inventoryOut => 'Stok keluar';

  @override
  String get inventoryQuantity => 'Jumlah';

  @override
  String get inventoryReason => 'Alasan';

  @override
  String get inventoryNoteHint => 'Catatan (opsional)';

  @override
  String get inventoryHistory => 'Riwayat pergerakan';

  @override
  String get inventoryHistoryEmpty => 'Belum ada pergerakan tercatat';

  @override
  String inventoryAdjusted(int count) {
    return 'Stok diperbarui jadi $count';
  }

  @override
  String get inventoryPickProduct => 'Pilih produk';

  @override
  String get inventoryTrackedOnly =>
      'Hanya produk yang stoknya dilacak yang muncul di sini.';

  @override
  String inventoryBalance(int count) {
    return 'Sisa $count';
  }

  @override
  String get stockReasonSale => 'Terjual';

  @override
  String get stockReasonVoidReturn => 'Dikembalikan';

  @override
  String get stockReasonReceived => 'Barang masuk';

  @override
  String get stockReasonWaste => 'Rusak/hilang';

  @override
  String get stockReasonCorrection => 'Koreksi';

  @override
  String get stockReasonOpening => 'Saldo awal';

  @override
  String get productTaxRate => 'Pajak (%)';

  @override
  String get productTaxRateHint => 'Kosong berarti ikut pajak toko';

  @override
  String get productTaxStore => 'Pajak toko';

  @override
  String get reportProfit => 'Laba kotor';

  @override
  String get reportCostOfGoods => 'Harga pokok';

  @override
  String get reportMargin => 'Margin';

  @override
  String get reportProfitCaveat =>
      'Hanya laba kotor — sewa, gaji, dan utilitas tidak dihitung di sini.';

  @override
  String reportCostCoverage(int percent) {
    return 'Berdasarkan $percent% item terjual yang punya harga pokok';
  }

  @override
  String get reportRefunded => 'Direfund';

  @override
  String get reportByCategory => 'Per kategori';

  @override
  String get reportCategoryCaveat =>
      'Pra-pajak dan pra-biaya layanan — totalnya sama dengan Subtotal dikurangi Diskon.';

  @override
  String get reportUncategorized => 'Tanpa kategori';

  @override
  String get reportGrossSales => 'Penjualan kotor';

  @override
  String get reportNetSales => 'Penjualan bersih';

  @override
  String get reportContribution => 'Kontribusi %';

  @override
  String get shiftDrawerNow => 'Isi laci sekarang';

  @override
  String get shiftDrawerNowHint =>
      'Modal awal ditambah tunai yang masuk sejauh ini.';

  @override
  String get posSwitchCashier => 'Ganti kasir';

  @override
  String get posSwitchCashierHint =>
      'Masukkan PIN untuk mengambil alih kasir. Nama Anda yang tercatat pada penjualan berikutnya.';

  @override
  String get posSwitchCashierPickHint =>
      'Pilih siapa yang mengambil alih kasir. Namanya yang tercatat pada penjualan berikutnya.';

  @override
  String get posOnDuty => 'Bertugas';

  @override
  String posSwitchedTo(String name) {
    return '$name sekarang memegang kasir';
  }

  @override
  String get registersTitle => 'POS / Kasir';

  @override
  String get registersSubtitle =>
      'Kasir di cabang ini, dan masing-masing untuk apa';

  @override
  String get registersManage => 'Kelola POS';

  @override
  String get registersEmpty => 'Cabang ini belum punya POS';

  @override
  String get registerAdd => 'Tambah POS';

  @override
  String get registerEdit => 'Ubah POS';

  @override
  String get registerName => 'Nama POS';

  @override
  String get registerNameTaken =>
      'Nama itu sudah dipakai POS lain di cabang ini';

  @override
  String get registerTableService => 'Layanan meja';

  @override
  String get registerActive => 'Aktif';

  @override
  String get registerRetired => 'Nonaktif';

  @override
  String get registerKeepOneActive => 'Minimal satu POS harus tetap aktif';

  @override
  String get registerDeleteConfirm => 'Hapus POS ini?';

  @override
  String get registerDeleteConfirmBody =>
      'POS hilang dari daftar. Penjualan yang sudah tercatat tetap menyimpan namanya.';

  @override
  String get registerHasHistory =>
      'POS ini punya sesi atau penjualan, jadi tidak bisa dihapus. Nonaktifkan saja.';

  @override
  String get sessionPickTitle => 'Buka POS yang mana?';

  @override
  String get sessionPickHint =>
      'Penjualan yang kamu catat masuk ke laci POS ini sampai ditutup';

  @override
  String get sessionResume => 'Lanjutkan';

  @override
  String get sessionNeedsRecovery => 'Tidak bisa dilanjutkan — perlu manager';

  @override
  String get sessionNeedsRecoveryHint =>
      'Laci ini terbuka tetapi server tidak memegang klaimnya, sehingga tidak bisa dilanjutkan atau ditutup dari sini. Minta manager menutupnya dari Backoffice → Perangkat.';

  @override
  String get sessionReconciled =>
      'Laci sudah sesuai dengan server dan dapat dilanjutkan.';

  @override
  String get sessionClosedForRecovery =>
      'Laci lama sudah ditutup dari server. Periksa transaksi yang tertahan di Pusat pemulihan.';

  @override
  String sessionInUse(String name) {
    return 'Dipakai $name';
  }

  @override
  String get sessionNoRegisters => 'Outlet ini belum punya POS';

  @override
  String sessionBusy(String name) {
    return '$name sudah membuka POS itu';
  }

  @override
  String get shiftRegister => 'POS';

  @override
  String shiftClosedBy(String name) {
    return 'Ditutup oleh $name';
  }

  @override
  String get shiftNoRegister => 'Dibuka sebelum POS diatur';

  @override
  String get orderPos => 'POS';

  @override
  String get shiftCloseConfirmTitle => 'Konfirmasi PIN Anda';

  @override
  String get shiftCloseConfirmHint =>
      'Masukkan PIN Anda untuk menutup sesi ini.';

  @override
  String get settingsLogoutBlockedTitle => 'Tutup sesi dulu';

  @override
  String get settingsLogoutBlockedBody =>
      'Sesi POS Anda masih terbuka. Tutup dan hitung laci dulu sebelum keluar.';

  @override
  String get settingsLogoutBlockedAction => 'Tutup sesi';

  @override
  String get modifierSaveFailed =>
      'Gagal menyimpan. Periksa opsi modifier lalu coba lagi.';

  @override
  String get modifierConfigure => 'Atur modifier';

  @override
  String get modifierSearchGroups => 'Cari grup modifier';

  @override
  String get modifierDefaultOption => 'Opsi default';

  @override
  String get modifierDefaultsHint =>
      'Pilih opsi yang berlaku. Tandai bintang untuk default. Pilihan wajib tanpa default diisi kasir; ketuk item cart untuk mengubah pilihan.';

  @override
  String modifierConfigSummary(int options, int defaults) {
    return '$options opsi · $defaults default';
  }

  @override
  String get activationTitle => 'Aktivasi perangkat';

  @override
  String get activationComplete => 'Perangkat teraktivasi';

  @override
  String get activationInstructions =>
      'Masukkan kode aktivasi yang dibuat untuk register ini di Backoffice.';

  @override
  String get activationCodeLabel => 'Kode aktivasi';

  @override
  String get activationNextPhase =>
      'Perangkat terhubung ke outlet dan register di atas. Sinkronisasi katalog dan karyawan tersedia pada fase berikutnya; akun demo disimpan terpisah.';

  @override
  String get activationInvalid =>
      'Kode tidak valid, kedaluwarsa, atau sudah digunakan. Minta kode baru dari Backoffice.';

  @override
  String get activationRateLimited =>
      'Terlalu banyak percobaan. Tunggu satu menit sebelum mencoba lagi.';

  @override
  String get activationNetwork =>
      'Server tidak dapat dijangkau. Periksa koneksi. Jika aktivasi sudah berhasil di server, minta kode baru.';

  @override
  String get activationStorage =>
      'Kredensial perangkat tidak dapat dibaca atau disimpan. Coba muat ulang aktivasi tersimpan, atau minta kode baru.';

  @override
  String get activationRevoked =>
      'Akses perangkat telah berakhir. Minta kode aktivasi baru dari Backoffice.';

  @override
  String get activationConfiguration =>
      'Alamat backend tidak valid. Konfigurasikan alamat API HTTPS.';

  @override
  String get activationContinue => 'Lanjut ke login';

  @override
  String get activationSubmit => 'Aktifkan perangkat';

  @override
  String get activationRetry => 'Muat ulang aktivasi tersimpan';

  @override
  String get authorizePickHint =>
      'Pilih siapa yang menyetujui, lalu masukkan PIN-nya';

  @override
  String get syncTitle => 'Sinkronisasi server';

  @override
  String get syncStatus => 'Status sinkronisasi';

  @override
  String get syncNever => 'Belum pernah sinkron';

  @override
  String get syncRunning => 'Menyinkronkan…';

  @override
  String syncLastSuccess(String time) {
    return 'Terakhir sinkron pukul $time';
  }

  @override
  String get syncFailed =>
      'Percobaan terakhir gagal. Semua data tetap di perangkat ini dan dicoba lagi otomatis.';

  @override
  String get syncUpdateRequired =>
      'Versi aplikasi ini terlalu lama untuk server. Perbarui aplikasi untuk melanjutkan sinkronisasi.';

  @override
  String get syncPending => 'Menunggu diunggah';

  @override
  String syncPendingValue(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count data',
      zero: 'Tidak ada antrean',
    );
    return '$_temp0';
  }

  @override
  String syncRejected(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count data ditolak server',
    );
    return '$_temp0';
  }

  @override
  String get syncRejectedRetry =>
      'Tetap tersimpan di perangkat. Ketuk untuk mengirim ulang.';

  @override
  String get syncNow => 'Sinkronkan sekarang';

  @override
  String get syncNowHint => 'Unggah penjualan dan unduh perubahan';

  @override
  String get tillBindingMismatch =>
      'Perangkat ini diaktivasi untuk register atau outlet lain. Tidak ada yang disimpan.';

  @override
  String get stockReasonCount => 'Stok opname';

  @override
  String get stockReasonTransferIn => 'Transfer masuk';

  @override
  String get stockReasonTransferOut => 'Transfer keluar';

  @override
  String get inventoryCount => 'Simpan hitungan';

  @override
  String get inventoryCountedQuantity => 'Jumlah dihitung';

  @override
  String get recoveryTitle => 'Pusat pemulihan';

  @override
  String get recoveryIntro =>
      'Tidak ada bukti yang dihapus otomatis. Penjualan tetap diblokir pada laci yang memerlukan pemulihan.';

  @override
  String recoveryLocalStatus(String status) {
    return 'Perangkat ini: $status';
  }

  @override
  String get recoveryStatusHealthy => 'tidak ada yang tertahan';

  @override
  String get recoveryStatusPending => 'menunggu diunggah';

  @override
  String get recoveryStatusConflict => 'perlu investigasi';

  @override
  String get recoveryStatusRecoveryRequired => 'menunggu manager';

  @override
  String recoverySectionHeading(String label, int count) {
    return '$label ($count)';
  }

  @override
  String get recoverySectionQueued => 'Aman dicoba ulang oleh scheduler';

  @override
  String get recoverySectionQueuedEmpty => 'Antrean unggahan kosong.';

  @override
  String get recoverySectionManager => 'Menunggu manager';

  @override
  String get recoverySectionManagerEmpty => 'Tidak ada yang menunggu manager.';

  @override
  String get recoverySectionInvestigate =>
      'Ditolak, dan tidak bisa dikirim dari sini';

  @override
  String get recoverySectionInvestigateEmpty =>
      'Tidak ada payload yang perlu diinvestigasi.';

  @override
  String get recoverySectionDiagnostics => 'Temuan diagnostik';

  @override
  String recoveryQueuedDetail(String revision, int attempts) {
    return 'revisi $revision · $attempts percobaan';
  }

  @override
  String recoveryLetterDetail(String code, int revision) {
    return '$code · revisi $revision';
  }

  @override
  String get recoveryNoServerMessage => 'Server tidak mengirim pesan.';

  @override
  String recoveryCaseLine(String id) {
    return 'Kasus $id';
  }

  @override
  String recoveryCaseLineWithStatus(String id, String status) {
    return 'Kasus $id · $status';
  }

  @override
  String get recoveryRetry => 'Kirim ulang';

  @override
  String get recoveryRequeued => 'Dikembalikan ke antrean unggahan.';

  @override
  String get recoveryNotRetryable =>
      'Belum bisa dikirim: baris lokalnya sudah tidak ada, atau manager belum menyetujuinya.';

  @override
  String get recoveryActionWaitForScheduler =>
      'Serahkan ke scheduler, atau ketuk Sinkron sekarang.';

  @override
  String get recoveryActionWaitForManager =>
      'Tunggu keputusan manager di Backoffice sebelum mengirim ini lagi.';

  @override
  String get recoveryActionIncompatible =>
      'Server tidak dapat menerima payload ini. Simpan dan investigasi.';

  @override
  String get recoveryActionKeepSnapshot =>
      'Pertahankan snapshot antrean dan periksa secara manual.';

  @override
  String get recoveryActionCheckTillMigration =>
      'Pertahankan state dan periksa migrasi sesi lokal.';

  @override
  String get recoveryActionBlockedUntilDecided =>
      'Penjualan tetap diblokir sampai pemulihan ini diputuskan di Backoffice.';

  @override
  String get recoveryActionMatchMovement =>
      'Jangan hapus movement; cocokkan dengan payload struknya.';

  @override
  String get recoveryActionFinishDependencies =>
      'Selesaikan penjualan dan penolakan yang tertahan sebelum penutupan dikirim.';

  @override
  String get recoveryActionReconcileBySigningIn =>
      'Laci ini dibuat sebelum till terkoordinasi. Masuk dengan PIN saat online, server akan merekonsiliasinya.';

  @override
  String get historyPeriodToday => 'Hari ini';

  @override
  String get historyPeriodYesterday => 'Kemarin';

  @override
  String get historyPeriodLast7 => '7 hari';

  @override
  String get historyPeriodMonth => 'Bulan ini';

  @override
  String get historyPeriodCustom => 'Rentang khusus';

  @override
  String get historyReceiptSearch => 'Nomor struk';

  @override
  String get historyScopeRegister => 'Kasir ini';

  @override
  String get historyScopeOutlet => 'Seluruh outlet';

  @override
  String get historyScopeNarrowed =>
      'Server hanya mengembalikan kasir ini; akun Anda tidak bisa membaca seluruh outlet.';

  @override
  String get historyLoadMore => 'Muat lagi';

  @override
  String get historyEndOfList => 'Akhir daftar untuk filter ini.';

  @override
  String historyOffline(String when) {
    return 'Offline — menampilkan data yang diunduh $when.';
  }

  @override
  String get historyOfflineMissing =>
      'Belum pernah diunduh. Sambungkan ke server untuk memuat periode ini.';

  @override
  String get historyLocalOnly => 'Hanya transaksi perangkat ini.';

  @override
  String get historyRangeIncomplete =>
      'Baru sebagian periode ini yang terunduh. Segarkan saat online untuk melengkapinya.';

  @override
  String get historyFilterApply => 'Terapkan';

  @override
  String get historyFilterReset => 'Atur ulang';

  @override
  String get historyFrom => 'Dari';

  @override
  String get historyTo => 'Sampai';

  @override
  String reportPeriodCompare(int days) {
    return 'vs $days hari sebelumnya';
  }

  @override
  String get reportNoComparison => 'tidak ada pembanding';

  @override
  String get reportSalesReturns => 'Retur penjualan';

  @override
  String get reportTotalReceipts => 'Total penerimaan penjualan';

  @override
  String get reportGrossMargin => 'Margin kotor';

  @override
  String get reportWaterfall => 'Waterfall penjualan';

  @override
  String reportSourceServer(String when) {
    return 'Total outlet dari server, dihitung $when.';
  }

  @override
  String reportSourceCache(String when) {
    return 'Offline — total server diunduh $when.';
  }

  @override
  String get reportSourceUnavailable =>
      'Total outlet belum tersedia offline. Sambungkan sekali untuk mengunduhnya.';

  @override
  String get reportSourceLocal => 'Transaksi perangkat ini saja.';

  @override
  String reportUnsyncedNotice(int count) {
    return '$count transaksi di perangkat ini belum sampai ke server dan belum termasuk dalam angka di atas.';
  }

  @override
  String get reportIncomplete =>
      'Sebagian hari pada periode ini masih dihitung ulang; waterfall belum final.';

  @override
  String get reportByWeekday => 'Hari dalam minggu';

  @override
  String get reportTopItemsInCategory => 'Item teratas per kategori';

  @override
  String get reportOutletComparison => 'Perbandingan outlet';

  @override
  String get reportNotPermitted => 'Akun Anda tidak bisa membuka laporan ini.';
}
