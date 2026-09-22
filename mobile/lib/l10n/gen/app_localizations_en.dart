// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get remoteReceiptReadOnly =>
      'Server receipt — read only on this device.';

  @override
  String get tillOnlineRequired =>
      'Connect to the server to open or transfer a session. Try again with the same cashier.';

  @override
  String get tillRegisterBusy =>
      'This till already has an open session. Finish and sync it on the original device first.';

  @override
  String get tillCashierBusy =>
      'This cashier is already assigned to another till. End or hand over that assignment first.';

  @override
  String get tillSyncRequired =>
      'Sync pending transactions and resolve rejected entries before handing over this till.';

  @override
  String get tillLoginRequired =>
      'Verify your PIN again while online to continue.';

  @override
  String get tillSessionUnconfirmed =>
      'This session is not confirmed for this cashier and device. Open a confirmed session before selling.';

  @override
  String get connectedMasterDataNotice =>
      'Menu, modifiers, promotions and floor plans are managed in Backoffice. This till receives updates automatically.';

  @override
  String get tableContested => 'Conflicting table changes';

  @override
  String get tableContestedHelp =>
      'Two tills changed this table. Check with staff, sync, then choose the correct status to resolve the conflict.';

  @override
  String get appTitle => 'JustClick POS';

  @override
  String get appTagline => 'Restaurant Point of Sale & Management System';

  @override
  String get navPos => 'New Sale';

  @override
  String get navOrders => 'Orders';

  @override
  String get navTables => 'Tables';

  @override
  String get navDashboard => 'Dashboard';

  @override
  String get navSettings => 'Settings';

  @override
  String get commonSearch => 'Search';

  @override
  String get commonCancel => 'Cancel';

  @override
  String get commonSave => 'Save';

  @override
  String get commonDelete => 'Delete';

  @override
  String get commonEdit => 'Edit';

  @override
  String get commonAdd => 'Add';

  @override
  String get commonClose => 'Close';

  @override
  String get commonConfirm => 'Confirm';

  @override
  String get commonContinue => 'Continue';

  @override
  String get commonBack => 'Back';

  @override
  String get commonRetry => 'Retry';

  @override
  String get commonDone => 'Done';

  @override
  String get commonYes => 'Yes';

  @override
  String get commonNo => 'No';

  @override
  String get commonAll => 'All';

  @override
  String get commonEmpty => 'Nothing here yet';

  @override
  String get commonLoading => 'Loading...';

  @override
  String get commonError => 'Something went wrong';

  @override
  String get commonNoResults => 'No results found';

  @override
  String get commonUnknown => 'Unknown';

  @override
  String get commonRequired => 'Required';

  @override
  String get commonOptional => 'Optional';

  @override
  String get commonToday => 'Today';

  @override
  String get commonCurrency => 'Rp';

  @override
  String get categoryAll => 'All';

  @override
  String get categoryPopular => 'Popular';

  @override
  String get posTitle => 'New Sale';

  @override
  String get posGreetingMorning => 'Good morning';

  @override
  String get posGreetingNoon => 'Good afternoon';

  @override
  String get posGreetingAfternoon => 'Good afternoon';

  @override
  String get posGreetingEvening => 'Good evening';

  @override
  String get posSearchProduct => 'Search menu...';

  @override
  String get posNoProducts => 'No products in this category';

  @override
  String get posCartEmpty => 'Cart is empty';

  @override
  String get posCartEmptyHint => 'Tap a product to add it to the order';

  @override
  String get posCart => 'Cart';

  @override
  String posCartItems(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count items',
      one: '1 item',
      zero: '0 items',
    );
    return '$_temp0';
  }

  @override
  String get posSubtotal => 'Subtotal';

  @override
  String get posDiscount => 'Discount';

  @override
  String get posServiceCharge => 'Service Charge';

  @override
  String get posTax => 'PB1';

  @override
  String get posTotal => 'Total';

  @override
  String get posCharge => 'Charge';

  @override
  String get posCheckout => 'Checkout';

  @override
  String get posClearCart => 'Clear cart';

  @override
  String get posCustomerName => 'Customer name (optional)';

  @override
  String get posNote => 'Order note';

  @override
  String get posNoteHint => 'e.g. no chili, extra sauce';

  @override
  String get posOrderType => 'Order type';

  @override
  String get posDineIn => 'Dine-in';

  @override
  String get posTakeaway => 'Takeaway';

  @override
  String get posDelivery => 'Delivery';

  @override
  String get posSelectTable => 'Select table';

  @override
  String get posAddDiscount => 'Add discount';

  @override
  String get posAmountPaid => 'Amount paid';

  @override
  String get posChange => 'Change';

  @override
  String get posExactCash => 'Exact';

  @override
  String get posPaymentMethod => 'Payment method';

  @override
  String get posCash => 'Cash';

  @override
  String get posQris => 'QRIS';

  @override
  String get posCard => 'Card';

  @override
  String get posPlaceOrder => 'Place Order';

  @override
  String get posOrderPlaced => 'Order placed successfully';

  @override
  String posOrderNumber(String id) {
    return 'Order #$id';
  }

  @override
  String get posQty => 'Qty';

  @override
  String get posRemoveItem => 'Remove';

  @override
  String get posQuickAdd => 'Quick add';

  @override
  String get posInCart => 'in cart';

  @override
  String get posQtyIncrease => 'Add one';

  @override
  String get posQtyDecrease => 'Remove one';

  @override
  String get posUnavailable => 'Unavailable';

  @override
  String get posOutOfStock => 'Out of stock';

  @override
  String posStockLeft(int count) {
    return '$count left';
  }

  @override
  String get orderStatusAll => 'All';

  @override
  String get orderStatusPending => 'Pending';

  @override
  String get orderStatusPreparing => 'Preparing';

  @override
  String get orderStatusReady => 'Ready';

  @override
  String get orderStatusServed => 'Served';

  @override
  String get orderStatusPaid => 'Completed';

  @override
  String get orderStatusCancelled => 'Cancelled';

  @override
  String get ordersTitle => 'Orders';

  @override
  String get ordersEmpty => 'No orders yet';

  @override
  String get ordersEmptyHint => 'Completed sales will appear here';

  @override
  String get ordersTodayRevenue => 'Today\'s revenue';

  @override
  String get ordersTodayCount => 'Today\'s orders';

  @override
  String get ordersDetail => 'Order detail';

  @override
  String ordersMarkAs(String status) {
    return 'Mark as $status';
  }

  @override
  String get ordersCancelOrder => 'Cancel order';

  @override
  String get ordersPrintReceipt => 'Print receipt';

  @override
  String get receiptPrintFailed => 'Could not open the print dialog';

  @override
  String ordersItemAt(String time) {
    return '$time';
  }

  @override
  String get ordersFilterByStatus => 'Filter by status';

  @override
  String get tableStatusAvailable => 'Available';

  @override
  String get tableStatusOccupied => 'Occupied';

  @override
  String get tableStatusReserved => 'Reserved';

  @override
  String get tablesTitle => 'Tables';

  @override
  String get tablesTotal => 'Total';

  @override
  String tablesCapacity(int count) {
    return '$count seats';
  }

  @override
  String get tablesEmpty => 'No tables configured';

  @override
  String get tablesEmptyHint => 'Add tables to start managing dine-in seats';

  @override
  String get tablesAddTable => 'Add table';

  @override
  String get tablesTableName => 'Table name';

  @override
  String get tablesCapacityLabel => 'Capacity (seats)';

  @override
  String get tablesStatus => 'Status';

  @override
  String get tablesSetStatus => 'Set table status';

  @override
  String get tablesFloor => 'Floor';

  @override
  String get tablesFloor1 => 'Floor 1';

  @override
  String get tablesFloor2 => 'Floor 2';

  @override
  String get tablesFloor3 => 'Floor 3';

  @override
  String get tablesFloor4 => 'Terrace';

  @override
  String get tablesStartOrder => 'Start order';

  @override
  String get tablesInactive => 'Inactive';

  @override
  String get tableManagementTitle => 'Table Management';

  @override
  String get tableManagementEmpty => 'This branch has no tables yet';

  @override
  String get tablesEditTable => 'Edit table';

  @override
  String get tablesFloorHint => 'e.g. Floor 1, Rooftop, VIP';

  @override
  String get tablesNameTaken =>
      'Another table at this branch already uses that name';

  @override
  String get tablesCapacityInvalid => 'Capacity must be at least 1 seat';

  @override
  String get tablesActive => 'Active';

  @override
  String get tablesActiveHint => 'Can be picked for a new dine-in order';

  @override
  String get tablesInactiveHint => 'Hidden from new dine-in orders';

  @override
  String get tablesDeleteConfirm => 'Delete this table?';

  @override
  String get tablesDeleteConfirmBody =>
      'It disappears from the list. Orders already recorded keep its name.';

  @override
  String get tablesHasHistory =>
      'This table has orders, so it cannot be deleted. Deactivate it instead.';

  @override
  String get productManagementTitle => 'Products';

  @override
  String get productAdd => 'Add product';

  @override
  String get productEdit => 'Edit product';

  @override
  String get productName => 'Product name';

  @override
  String get productPrice => 'Price';

  @override
  String get productCategory => 'Category';

  @override
  String get productDescription => 'Description';

  @override
  String get productAvailable => 'Available';

  @override
  String get productUnavailable => 'Unavailable';

  @override
  String get productEmoji => 'Icon';

  @override
  String get productDeleteConfirm => 'Delete this product?';

  @override
  String get productDeleteConfirmBody => 'This action cannot be undone.';

  @override
  String get productEmpty => 'No products yet';

  @override
  String get productEmptyHint => 'Add your first product to start selling';

  @override
  String get productPopular => 'Popular';

  @override
  String get productStock => 'Stock';

  @override
  String get productStockHint => 'Leave empty if this item is not counted';

  @override
  String get productCost => 'Cost price';

  @override
  String get productSku => 'SKU / barcode';

  @override
  String get productLowStock => 'Low stock';

  @override
  String get productOutOfStock => 'Out of stock';

  @override
  String productStockValue(int count) {
    return 'Stock: $count';
  }

  @override
  String get productNotTracked => 'Not counted';

  @override
  String get employeesTitle => 'Employees';

  @override
  String get employeesManage => 'Staff and PINs';

  @override
  String get employeeAdd => 'Add employee';

  @override
  String get employeeEdit => 'Edit employee';

  @override
  String get employeeName => 'Name';

  @override
  String get employeePin => 'PIN (4 digits)';

  @override
  String get employeeRole => 'Role';

  @override
  String get employeeRoleCashier => 'Cashier';

  @override
  String get employeeRoleManager => 'Manager';

  @override
  String get employeeActive => 'Can sign in';

  @override
  String get employeeInactive => 'Cannot sign in';

  @override
  String get employeePinTaken => 'That PIN is already used by someone else';

  @override
  String get employeePinLength => 'PIN must be exactly 4 digits';

  @override
  String get employeeDeleteConfirm => 'Remove this employee?';

  @override
  String get employeeDeleteConfirmBody =>
      'Past orders keep their name. They will no longer be able to sign in.';

  @override
  String get employeeCannotDeleteSelf =>
      'You cannot remove the employee you are signed in as';

  @override
  String get employeeSignedInAs => 'Signed in as';

  @override
  String get shiftTitle => 'Shift';

  @override
  String get shiftOpen => 'Open shift';

  @override
  String get shiftClose => 'Close shift';

  @override
  String get shiftNoneOpen => 'No shift open';

  @override
  String get shiftNoneOpenHint =>
      'Open a shift with the cash float in the drawer';

  @override
  String get shiftOpeningCash => 'Opening cash';

  @override
  String get shiftCountedCash => 'Counted cash';

  @override
  String get shiftExpectedCash => 'Expected in drawer';

  @override
  String get shiftVariance => 'Difference';

  @override
  String get shiftCashSales => 'Cash sales';

  @override
  String get shiftNonCashSales => 'Card / QRIS';

  @override
  String get shiftOrders => 'Orders this shift';

  @override
  String shiftOpenedAt(String time) {
    return 'Opened $time';
  }

  @override
  String shiftClosedAt(String time) {
    return 'Closed $time';
  }

  @override
  String get shiftNote => 'Note (optional)';

  @override
  String get shiftHistory => 'Closing history';

  @override
  String get shiftHistoryEmpty => 'No shift has been closed yet';

  @override
  String get shiftOver => 'Over';

  @override
  String get shiftShort => 'Short';

  @override
  String get shiftBalanced => 'Balanced';

  @override
  String get shiftStillOpen => 'Still open';

  @override
  String get reportTitle => 'Sales report';

  @override
  String get reportToday => 'Today';

  @override
  String get reportLast7 => 'Last 7 days';

  @override
  String get reportLast30 => 'Last 30 days';

  @override
  String get reportThisMonth => 'This month';

  @override
  String get reportCustomRange => 'Pick dates';

  @override
  String get reportRevenue => 'Revenue';

  @override
  String get reportOrders => 'Orders';

  @override
  String get reportAverage => 'Average order';

  @override
  String get reportItemsSold => 'Items sold';

  @override
  String get reportSubtotal => 'Subtotal';

  @override
  String get reportDiscount => 'Discount';

  @override
  String get reportServiceCharge => 'Service Charge';

  @override
  String get reportTax => 'PB1';

  @override
  String get reportCancelled => 'Cancelled';

  @override
  String get reportByPayment => 'By payment method';

  @override
  String get reportByType => 'By order type';

  @override
  String get reportByCashier => 'By cashier';

  @override
  String get reportDaily => 'Daily revenue';

  @override
  String get reportExport => 'Export CSV';

  @override
  String get reportExported => 'Report exported';

  @override
  String get reportEmpty => 'No sales in this range';

  @override
  String get reportSummary => 'Summary';

  @override
  String get reportMetric => 'Metric';

  @override
  String get reportAmount => 'Amount';

  @override
  String get reportMethod => 'Method';

  @override
  String get reportCount => 'Orders';

  @override
  String get reportType => 'Type';

  @override
  String get reportCashier => 'Cashier';

  @override
  String get reportDate => 'Date';

  @override
  String get reportPeriod => 'Period';

  @override
  String get categoryManagementTitle => 'Categories';

  @override
  String get categoryAdd => 'Add category';

  @override
  String get categoryEdit => 'Edit category';

  @override
  String get categoryName => 'Category name';

  @override
  String get categoryDeleteConfirm => 'Delete this category?';

  @override
  String get categoryEmpty => 'No categories yet';

  @override
  String get categoryEmoji => 'Icon';

  @override
  String get dashboardTitle => 'Dashboard';

  @override
  String dashboardGreeting(String name) {
    return 'Hello, $name!';
  }

  @override
  String get dashboardRevenue => 'Revenue';

  @override
  String get dashboardOrders => 'Orders';

  @override
  String get dashboardAvgOrder => 'Avg. order';

  @override
  String get dashboardTopProducts => 'Top products';

  @override
  String get dashboardRecentOrders => 'Recent orders';

  @override
  String get dashboardThisWeek => 'This week';

  @override
  String get dashboardNoSales => 'No sales recorded yet';

  @override
  String get dashboardItemsSold => 'items sold';

  @override
  String get dashboardViewAll => 'View all';

  @override
  String get settingsTitle => 'Settings';

  @override
  String get settingsAppearance => 'Appearance';

  @override
  String get settingsTheme => 'Theme';

  @override
  String get settingsThemeLight => 'Light';

  @override
  String get settingsThemeDark => 'Dark';

  @override
  String get settingsThemeSystem => 'System';

  @override
  String get settingsBrandColor => 'Brand color';

  @override
  String get settingsLanguage => 'Language';

  @override
  String get settingsLanguageEn => 'English';

  @override
  String get settingsLanguageId => 'Bahasa Indonesia';

  @override
  String get settingsBusiness => 'Business';

  @override
  String get settingsTaxRate => 'PB1 rate (%)';

  @override
  String get settingsServiceCharge => 'Service charge';

  @override
  String get settingsServiceChargeRate => 'Service charge rate (%)';

  @override
  String get settingsServiceChargeOn => 'Added to every bill';

  @override
  String get settingsServiceChargeOff => 'Not applied to bills';

  @override
  String get settingsCurrency => 'Currency symbol';

  @override
  String get settingsStoreName => 'Store name';

  @override
  String get settingsStoreAddress => 'Store address';

  @override
  String get settingsTableService => 'Table service';

  @override
  String get outletsTitle => 'Outlets';

  @override
  String get outletsSubtitle =>
      'Branches, addresses, and which one this device is in';

  @override
  String get outletAdd => 'Add outlet';

  @override
  String get outletEdit => 'Edit outlet';

  @override
  String get outletName => 'Outlet name';

  @override
  String get outletAddress => 'Address';

  @override
  String get outletOpen => 'Open';

  @override
  String get outletClosed => 'Closed';

  @override
  String get outletNameTaken => 'Another outlet already uses that name';

  @override
  String get outletUseHere => 'Use on this device';

  @override
  String get outletThisDevice => 'This device';

  @override
  String get outletPickTitle => 'Which outlet is this device in?';

  @override
  String get outletPickHint => 'Sales, stock and tables all follow this choice';

  @override
  String get outletDeleteConfirm => 'Delete this outlet?';

  @override
  String get outletDeleteConfirmBody =>
      'It disappears from the list. Sales already recorded keep its name.';

  @override
  String get outletHasSales =>
      'This outlet has sales, so it cannot be deleted. Close it instead.';

  @override
  String get outletKeepOneOpen => 'At least one outlet has to stay open';

  @override
  String get settingsTableServiceOn => 'Guests are seated at numbered tables';

  @override
  String get settingsTableServiceOff =>
      'No floor plan — dine-in needs no table';

  @override
  String get settingsAbout => 'About';

  @override
  String get settingsVersion => 'Version';

  @override
  String get settingsLogout => 'Log out';

  @override
  String get settingsProfile => 'Cashier profile';

  @override
  String get settingsData => 'Data';

  @override
  String get settingsResetDemoData => 'Reset demo data';

  @override
  String get settingsResetConfirm => 'Reset all demo data?';

  @override
  String get settingsResetConfirmBody =>
      'All orders, products and settings will be restored to defaults.';

  @override
  String get authWelcome => 'Welcome back';

  @override
  String get authLoginHint => 'Enter your PIN to continue';

  @override
  String get ordersPrintFailed => 'Could not print the receipt';

  @override
  String get navCollapseSidebar => 'Collapse sidebar';

  @override
  String get navExpandSidebar => 'Expand sidebar';

  @override
  String get authChooseAccount => 'Who is on duty?';

  @override
  String get authChooseAccountHint => 'Pick your account, then enter your PIN';

  @override
  String get authChangeAccount => 'Change';

  @override
  String get authNoAccounts => 'No staff accounts yet';

  @override
  String get authPin => 'PIN';

  @override
  String get authLogin => 'Log in';

  @override
  String get authWrongPin => 'Wrong PIN';

  @override
  String get authCashier => 'Cashier';

  @override
  String get authStoreManager => 'Store Manager';

  @override
  String get authDemoPin => 'Demo PIN: 1234';

  @override
  String get receiptThankYou => 'Thank you!';

  @override
  String get receiptStore => 'Store';

  @override
  String get receiptCashier => 'Cashier';

  @override
  String get receiptDate => 'Date';

  @override
  String get receiptOrderType => 'Type';

  @override
  String get receiptPaid => 'PAID';

  @override
  String get receiptPoweredBy => 'Powered by JustClick POS';

  @override
  String get employeeRoleOwner => 'Owner';

  @override
  String get employeeRoleCashierHint =>
      'Sells, seats tables and counts their own drawer.';

  @override
  String get employeeRoleManagerHint =>
      'Everything a cashier does, plus void, refund, discounts and stock.';

  @override
  String get employeeRoleOwnerHint =>
      'Full control: catalogue, prices, reports, staff and promotions.';

  @override
  String get authorizeTitle => 'Manager approval';

  @override
  String get authorizeDenied => 'That PIN is not authorised for this';

  @override
  String get authorizeReasonVoid =>
      'Voiding a sale needs a manager or owner PIN.';

  @override
  String get authorizeReasonRefund =>
      'Refunding a sale needs a manager or owner PIN.';

  @override
  String get authorizeReasonDiscount =>
      'A manual discount needs a manager or owner PIN.';

  @override
  String get settingsSignedInAs => 'Signed in as';

  @override
  String get settingsRoleAccess => 'Your access';

  @override
  String get orderStatusRefunded => 'Refunded';

  @override
  String get ordersVoid => 'Void order';

  @override
  String get ordersRefund => 'Refund order';

  @override
  String get ordersVoidTitle => 'Void this order?';

  @override
  String get ordersRefundTitle => 'Refund this order?';

  @override
  String get ordersVoidBody =>
      'The sale is struck out and its stock goes back on the shelf.';

  @override
  String get ordersRefundBody =>
      'The money is handed back and its stock goes back on the shelf.';

  @override
  String get ordersVoidReason => 'Reason';

  @override
  String get ordersVoidReasonHint =>
      'Wrong order, customer changed their mind…';

  @override
  String get ordersVoidReasonRequired =>
      'Give a reason so the report can explain it';

  @override
  String ordersAuthorizedBy(String name) {
    return 'Approved by $name';
  }

  @override
  String ordersRefundedAmount(String amount) {
    return 'Refunded $amount';
  }

  @override
  String get ordersVoided => 'Order voided';

  @override
  String get ordersRefunded => 'Order refunded';

  @override
  String get ordersScopeOwnToday => 'Your sales today';

  @override
  String get ordersScopeAll => 'All sales';

  @override
  String get posChooseOption => 'Choose an option';

  @override
  String get productVariants => 'Variants';

  @override
  String get productVariantsHint =>
      'Sizes or options with their own price. Leave empty to sell one way.';

  @override
  String get productVariantAdd => 'Add variant';

  @override
  String get productVariantName => 'Option name';

  @override
  String get productVariantPriceDelta => 'Price difference';

  @override
  String get modifierManagementTitle => 'Modifiers';

  @override
  String get modifierGroupAdd => 'Add modifier group';

  @override
  String get modifierGroupEdit => 'Edit modifier group';

  @override
  String get modifierGroupName => 'Group name';

  @override
  String get modifierGroupEmpty => 'No modifier groups yet';

  @override
  String get modifierGroupEmptyHint =>
      'Create a group like spice level or toppings to reuse across products';

  @override
  String get modifierSelectionType => 'Selection type';

  @override
  String get modifierSelectionSingle => 'Single choice';

  @override
  String get modifierSelectionMultiple => 'Multiple choice';

  @override
  String get modifierRequired => 'Required';

  @override
  String get modifierRequiredHint =>
      'The cashier must pick at least one option before adding this product';

  @override
  String get modifierMaxSelect => 'Max selections';

  @override
  String get modifierMaxSelectHint => 'Leave empty for unlimited';

  @override
  String get modifierMaxSelectInvalid => 'Must be at least 1';

  @override
  String get modifierOptions => 'Options';

  @override
  String get modifierOptionsHint =>
      'Add at least one option, e.g. Mild, Medium, Spicy';

  @override
  String get modifierOptionAdd => 'Add option';

  @override
  String get modifierOptionEdit => 'Edit option';

  @override
  String get modifierOptionName => 'Option name';

  @override
  String get modifierOptionPriceDelta => 'Extra price';

  @override
  String get modifierRequiredNoActiveOptions =>
      'This group is required but has no active options — products using it will skip it rather than get stuck.';

  @override
  String get modifierGroupDeleteConfirm => 'Delete this modifier group?';

  @override
  String modifierGroupDeleteConfirmBody(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count products use it.',
      one: '1 product uses it.',
      zero: 'No products use it.',
    );
    return '$_temp0 Past orders keep what was sold; this only removes it from future sales.';
  }

  @override
  String get modifierGroupsSectionTitle => 'Modifier groups';

  @override
  String get modifierGroupsSectionHint =>
      'Reusable across products — manage them from the Modifiers tab';

  @override
  String modifierOptionCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count options',
      one: '1 option',
      zero: '0 options',
    );
    return '$_temp0';
  }

  @override
  String get modifierPickTitle => 'Choose modifiers';

  @override
  String get modifierPickRequiredBadge => 'Required';

  @override
  String get modifierPickOptionalBadge => 'Optional';

  @override
  String modifierPickMaxBadge(int count) {
    return 'Pick up to $count';
  }

  @override
  String modifierAddToCart(String price) {
    return 'Add — $price';
  }

  @override
  String get modifierEditSelections => 'Edit selections';

  @override
  String get cartLineEdit => 'Edit';

  @override
  String modifierOptionScopeHint(String groupName) {
    return 'Which $groupName options apply to this product';
  }

  @override
  String get modifierOptionScopeEmpty =>
      'This group has no active options yet — add some from the Modifiers tab';

  @override
  String get promosTitle => 'Promotions';

  @override
  String get promosManage => 'Discounts any cashier may apply';

  @override
  String get promoAdd => 'New promotion';

  @override
  String get promoEdit => 'Edit promotion';

  @override
  String get promoName => 'Promotion name';

  @override
  String get promoKind => 'Type';

  @override
  String get promoKindPercent => 'Percent';

  @override
  String get promoKindAmount => 'Fixed amount';

  @override
  String get promoValue => 'Value';

  @override
  String get promoMinSpend => 'Minimum spend';

  @override
  String get promoMinSpendHint => '0 for no minimum';

  @override
  String get promoActive => 'Active';

  @override
  String get promoInactive => 'Retired';

  @override
  String get promoEmpty => 'No promotions yet';

  @override
  String get promoEmptyHint => 'Create one and every cashier can apply it.';

  @override
  String get promoDeleteConfirm => 'Delete this promotion?';

  @override
  String get promoDeleteConfirmBody =>
      'Sales that already used it keep their discount.';

  @override
  String promoRequiresMin(String amount) {
    return 'Needs $amount minimum';
  }

  @override
  String get posDiscountTitle => 'Discount';

  @override
  String get posDiscountNone => 'No discount';

  @override
  String get posDiscountManual => 'Custom';

  @override
  String get posDiscountPercent => 'Percent';

  @override
  String get posDiscountAmount => 'Amount';

  @override
  String posDiscountApprovedBy(String name) {
    return 'Approved by $name';
  }

  @override
  String get posDiscountRemove => 'Remove discount';

  @override
  String get posDiscountLocked => 'Ask a manager to approve a custom discount';

  @override
  String get inventoryTitle => 'Inventory';

  @override
  String get inventoryManage => 'Book stock in and out, review movements';

  @override
  String get inventoryLowStock => 'Running low';

  @override
  String get inventoryAllStocked => 'Nothing is running low';

  @override
  String get inventoryAllStockedHint =>
      'Every tracked product is above the threshold.';

  @override
  String get inventoryAdjust => 'Adjust stock';

  @override
  String get inventoryIn => 'Stock in';

  @override
  String get inventoryOut => 'Stock out';

  @override
  String get inventoryQuantity => 'Quantity';

  @override
  String get inventoryReason => 'Reason';

  @override
  String get inventoryNoteHint => 'Note (optional)';

  @override
  String get inventoryHistory => 'Movement history';

  @override
  String get inventoryHistoryEmpty => 'No movements recorded yet';

  @override
  String inventoryAdjusted(int count) {
    return 'Stock updated to $count';
  }

  @override
  String get inventoryPickProduct => 'Choose a product';

  @override
  String get inventoryTrackedOnly => 'Only stock-tracked products appear here.';

  @override
  String inventoryBalance(int count) {
    return 'Balance $count';
  }

  @override
  String get stockReasonSale => 'Sold';

  @override
  String get stockReasonVoidReturn => 'Returned';

  @override
  String get stockReasonReceived => 'Received';

  @override
  String get stockReasonWaste => 'Waste';

  @override
  String get stockReasonCorrection => 'Recount';

  @override
  String get stockReasonOpening => 'Opening';

  @override
  String get productTaxRate => 'Tax rate (%)';

  @override
  String get productTaxRateHint => 'Empty uses the store rate';

  @override
  String get productTaxStore => 'Store rate';

  @override
  String get reportProfit => 'Gross profit';

  @override
  String get reportCostOfGoods => 'Cost of goods';

  @override
  String get reportMargin => 'Margin';

  @override
  String get reportProfitCaveat =>
      'Gross profit only — rent, wages and utilities are not tracked here.';

  @override
  String reportCostCoverage(int percent) {
    return 'Based on $percent% of sold items having a cost recorded';
  }

  @override
  String get reportRefunded => 'Refunded';

  @override
  String get reportByCategory => 'By category';

  @override
  String get reportCategoryCaveat =>
      'Pre-tax and pre-service-charge — totals match Subtotal minus Discount.';

  @override
  String get reportUncategorized => 'Uncategorized';

  @override
  String get reportGrossSales => 'Gross sales';

  @override
  String get reportNetSales => 'Net sales';

  @override
  String get reportContribution => 'Contribution %';

  @override
  String get shiftDrawerNow => 'Cash drawer now';

  @override
  String get shiftDrawerNowHint =>
      'Opening float plus cash taken so far this shift.';

  @override
  String get posSwitchCashier => 'Switch cashier';

  @override
  String get posSwitchCashierHint =>
      'Enter your PIN to take the till. Your name goes on every sale from now on.';

  @override
  String get posSwitchCashierPickHint =>
      'Pick who is taking the till. Their name goes on every sale from now on.';

  @override
  String get posOnDuty => 'On duty';

  @override
  String posSwitchedTo(String name) {
    return '$name is now on the till';
  }

  @override
  String get registersTitle => 'POS / Registers';

  @override
  String get registersSubtitle =>
      'Tills at this branch, and what each one is for';

  @override
  String get registersManage => 'Manage POS';

  @override
  String get registersEmpty => 'This branch has no POS yet';

  @override
  String get registerAdd => 'Add POS';

  @override
  String get registerEdit => 'Edit POS';

  @override
  String get registerName => 'POS name';

  @override
  String get registerNameTaken =>
      'Another POS at this branch already uses that name';

  @override
  String get registerTableService => 'Table service';

  @override
  String get registerActive => 'Active';

  @override
  String get registerRetired => 'Retired';

  @override
  String get registerKeepOneActive => 'At least one POS has to stay active';

  @override
  String get registerDeleteConfirm => 'Delete this POS?';

  @override
  String get registerDeleteConfirmBody =>
      'It disappears from the list. Sales already recorded keep its name.';

  @override
  String get registerHasHistory =>
      'This POS has sessions or sales, so it cannot be deleted. Retire it instead.';

  @override
  String get sessionPickTitle => 'Which POS are you opening?';

  @override
  String get sessionPickHint =>
      'Sales you ring up land in this POS drawer until you close it';

  @override
  String get sessionResume => 'Resume';

  @override
  String get sessionNeedsRecovery => 'Cannot be resumed — needs a manager';

  @override
  String get sessionNeedsRecoveryHint =>
      'This drawer is open but the server holds no claim for it, so it cannot be resumed or closed here. Ask a manager to close it from Backoffice → Devices.';

  @override
  String get sessionReconciled =>
      'The drawer now matches the server and can be resumed.';

  @override
  String get sessionClosedForRecovery =>
      'The old drawer was closed from the server. Review any held transactions in the Recovery centre.';

  @override
  String sessionInUse(String name) {
    return 'In use by $name';
  }

  @override
  String get sessionNoRegisters => 'No POS is set up for this outlet yet';

  @override
  String sessionBusy(String name) {
    return '$name already has that POS open';
  }

  @override
  String get shiftRegister => 'POS';

  @override
  String shiftClosedBy(String name) {
    return 'Closed by $name';
  }

  @override
  String get shiftNoRegister => 'Opened before POS were set up';

  @override
  String get orderPos => 'POS';

  @override
  String get shiftCloseConfirmTitle => 'Confirm your PIN';

  @override
  String get shiftCloseConfirmHint => 'Enter your PIN to close this session.';

  @override
  String get settingsLogoutBlockedTitle => 'Close your session first';

  @override
  String get settingsLogoutBlockedBody =>
      'You still have an open POS session. Close it and count the drawer before signing out.';

  @override
  String get settingsLogoutBlockedAction => 'Close session';

  @override
  String get modifierSaveFailed =>
      'Could not save. Check the modifier options and try again.';

  @override
  String get modifierConfigure => 'Configure modifiers';

  @override
  String get modifierSearchGroups => 'Search modifier groups';

  @override
  String get modifierDefaultOption => 'Default option';

  @override
  String get modifierDefaultsHint =>
      'Select applicable options. Star the defaults. Missing required defaults are chosen at the till; tap a cart item to customize.';

  @override
  String modifierConfigSummary(int options, int defaults) {
    return '$options options · $defaults defaults';
  }

  @override
  String get activationTitle => 'Activate this device';

  @override
  String get activationComplete => 'Device activated';

  @override
  String get activationInstructions =>
      'Enter the activation code created for this register in Backoffice.';

  @override
  String get activationCodeLabel => 'Activation code';

  @override
  String get activationNextPhase =>
      'This device is linked to the outlet and register above. The catalogue and staff come from the server, and sales upload automatically; demo accounts are kept separate.';

  @override
  String get activationInvalid =>
      'This code is invalid, expired, or already used. Request a new code from Backoffice.';

  @override
  String get activationRateLimited =>
      'Too many attempts. Wait a minute before trying again.';

  @override
  String get activationNetwork =>
      'Unable to reach the server. Check the connection. If activation already succeeded on the server, request a new code.';

  @override
  String get activationStorage =>
      'Unable to read or save device credentials. Retry loading the saved activation, or request a new code.';

  @override
  String get activationRevoked =>
      'Device access has ended. Request a new activation code from Backoffice.';

  @override
  String get activationConfiguration =>
      'The backend address is invalid. Configure an HTTPS API address.';

  @override
  String get activationContinue => 'Continue to sign in';

  @override
  String get activationSubmit => 'Activate device';

  @override
  String get activationRetry => 'Reload saved activation';

  @override
  String get authorizePickHint =>
      'Choose who is approving, then enter their PIN';

  @override
  String get syncTitle => 'Server sync';

  @override
  String get syncStatus => 'Sync status';

  @override
  String get syncNever => 'Not synced yet';

  @override
  String get syncRunning => 'Syncing…';

  @override
  String syncLastSuccess(String time) {
    return 'Last synced at $time';
  }

  @override
  String get syncFailed =>
      'The last attempt failed. Everything stays on this device and is retried automatically.';

  @override
  String get syncUpdateRequired =>
      'This app version is too old for the server. Update the app to keep syncing.';

  @override
  String get syncPending => 'Waiting to upload';

  @override
  String syncPendingValue(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count records',
      one: '1 record',
      zero: 'Nothing waiting',
    );
    return '$_temp0';
  }

  @override
  String syncRejected(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count records refused by the server',
      one: '1 record refused by the server',
    );
    return '$_temp0';
  }

  @override
  String get syncRejectedRetry =>
      'Kept on this device. Tap to send them again.';

  @override
  String get syncNow => 'Sync now';

  @override
  String get syncNowHint => 'Upload sales and download changes';

  @override
  String get tillBindingMismatch =>
      'This device is activated for a different register or outlet. Nothing was saved.';

  @override
  String get stockReasonCount => 'Stock count';

  @override
  String get stockReasonTransferIn => 'Transfer in';

  @override
  String get stockReasonTransferOut => 'Transfer out';

  @override
  String get inventoryCount => 'Save count';

  @override
  String get inventoryCountedQuantity => 'Counted quantity';

  @override
  String get recoveryTitle => 'Recovery centre';

  @override
  String get recoveryIntro =>
      'No evidence is ever removed automatically. Selling stays blocked on a drawer that needs recovery.';

  @override
  String recoveryLocalStatus(String status) {
    return 'This device: $status';
  }

  @override
  String get recoveryStatusHealthy => 'nothing outstanding';

  @override
  String get recoveryStatusPending => 'waiting to upload';

  @override
  String get recoveryStatusConflict => 'needs investigation';

  @override
  String get recoveryStatusRecoveryRequired => 'waiting for a manager';

  @override
  String recoverySectionHeading(String label, int count) {
    return '$label ($count)';
  }

  @override
  String get recoverySectionQueued => 'Safe for the scheduler to retry';

  @override
  String get recoverySectionQueuedEmpty => 'The upload queue is empty.';

  @override
  String get recoverySectionManager => 'Waiting for a manager';

  @override
  String get recoverySectionManagerEmpty => 'Nothing is waiting for a manager.';

  @override
  String get recoverySectionInvestigate =>
      'Refused, and not sendable from here';

  @override
  String get recoverySectionInvestigateEmpty =>
      'No payload needs investigating.';

  @override
  String get recoverySectionDiagnostics => 'Diagnostic findings';

  @override
  String recoveryQueuedDetail(String revision, int attempts) {
    return 'revision $revision · $attempts attempts';
  }

  @override
  String recoveryLetterDetail(String code, int revision) {
    return '$code · revision $revision';
  }

  @override
  String get recoveryNoServerMessage => 'The server sent no message.';

  @override
  String recoveryCaseLine(String id) {
    return 'Case $id';
  }

  @override
  String recoveryCaseLineWithStatus(String id, String status) {
    return 'Case $id · $status';
  }

  @override
  String get recoveryRetry => 'Send again';

  @override
  String get recoveryRequeued => 'Returned to the upload queue.';

  @override
  String get recoveryNotRetryable =>
      'Not sendable yet: its local row is gone, or a manager has not approved it.';

  @override
  String get recoveryActionWaitForScheduler =>
      'Leave it to the scheduler, or tap Sync now.';

  @override
  String get recoveryActionWaitForManager =>
      'Wait for the manager\'s decision in the Backoffice before sending this one again.';

  @override
  String get recoveryActionIncompatible =>
      'The server cannot accept this payload. Keep it and investigate.';

  @override
  String get recoveryActionKeepSnapshot =>
      'Keep the queued snapshot and inspect it by hand.';

  @override
  String get recoveryActionCheckTillMigration =>
      'Keep the state and check the local session migration.';

  @override
  String get recoveryActionBlockedUntilDecided =>
      'Selling stays blocked until this recovery is decided in the Backoffice.';

  @override
  String get recoveryActionMatchMovement =>
      'Do not delete the movement; match it against its receipt payload.';

  @override
  String get recoveryActionFinishDependencies =>
      'Finish the pending sales and refusals before the close is sent.';

  @override
  String get recoveryActionReconcileBySigningIn =>
      'This drawer predates coordinated tills. Sign in with a PIN while online and the server will reconcile it.';

  @override
  String get historyPeriodToday => 'Today';

  @override
  String get historyPeriodYesterday => 'Yesterday';

  @override
  String get historyPeriodLast7 => '7 days';

  @override
  String get historyPeriodMonth => 'This month';

  @override
  String get historyPeriodCustom => 'Custom range';

  @override
  String get historyReceiptSearch => 'Receipt number';

  @override
  String get historyScopeRegister => 'This till';

  @override
  String get historyScopeOutlet => 'Whole outlet';

  @override
  String get historyScopeNarrowed =>
      'The server returned this till only; your account cannot read the whole outlet.';

  @override
  String get historyLoadMore => 'Load more';

  @override
  String get historyEndOfList => 'End of the list for this filter.';

  @override
  String historyOffline(String when) {
    return 'Offline — showing what was downloaded $when.';
  }

  @override
  String get historyOfflineMissing =>
      'Not downloaded yet. Connect to load this period.';

  @override
  String get historyLocalOnly => 'This device\'s own transactions only.';

  @override
  String get historyRangeIncomplete =>
      'Only part of this period was downloaded. Refresh while online to complete it.';

  @override
  String get historyFilterApply => 'Apply';

  @override
  String get historyFilterReset => 'Reset';

  @override
  String get historyFrom => 'From';

  @override
  String get historyTo => 'To';

  @override
  String reportPeriodCompare(int days) {
    return 'vs previous $days days';
  }

  @override
  String get reportNoComparison => 'no comparison';

  @override
  String get reportSalesReturns => 'Sales returns';

  @override
  String get reportTotalReceipts => 'Total sales receipts';

  @override
  String get reportGrossMargin => 'Gross margin';

  @override
  String get reportWaterfall => 'Sales waterfall';

  @override
  String reportSourceServer(String when) {
    return 'Outlet totals from the server, computed $when.';
  }

  @override
  String reportSourceCache(String when) {
    return 'Offline — server totals downloaded $when.';
  }

  @override
  String get reportSourceUnavailable =>
      'Outlet totals are not available offline yet. Connect once to download them.';

  @override
  String get reportSourceLocal => 'This device\'s own transactions.';

  @override
  String reportUnsyncedNotice(int count) {
    return '$count transactions on this device have not reached the server and are not in the totals above.';
  }

  @override
  String get reportIncomplete =>
      'Some days in this period are still being recalculated; the waterfall is not final yet.';

  @override
  String get reportByWeekday => 'Day of week';

  @override
  String get reportTopItemsInCategory => 'Top items per category';

  @override
  String get reportOutletComparison => 'Outlet comparison';

  @override
  String get reportNotPermitted => 'Your account cannot open this report.';
}
