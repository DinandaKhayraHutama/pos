import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_id.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'gen/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('id'),
  ];

  /// No description provided for @remoteReceiptReadOnly.
  ///
  /// In en, this message translates to:
  /// **'Server receipt — read only on this device.'**
  String get remoteReceiptReadOnly;

  /// No description provided for @tillOnlineRequired.
  ///
  /// In en, this message translates to:
  /// **'Connect to the server to open or transfer a session. Try again with the same cashier.'**
  String get tillOnlineRequired;

  /// No description provided for @tillRegisterBusy.
  ///
  /// In en, this message translates to:
  /// **'This till already has an open session. Finish and sync it on the original device first.'**
  String get tillRegisterBusy;

  /// No description provided for @tillCashierBusy.
  ///
  /// In en, this message translates to:
  /// **'This cashier is already assigned to another till. End or hand over that assignment first.'**
  String get tillCashierBusy;

  /// No description provided for @tillSyncRequired.
  ///
  /// In en, this message translates to:
  /// **'Sync pending transactions and resolve rejected entries before handing over this till.'**
  String get tillSyncRequired;

  /// No description provided for @tillLoginRequired.
  ///
  /// In en, this message translates to:
  /// **'Verify your PIN again while online to continue.'**
  String get tillLoginRequired;

  /// No description provided for @tillSessionUnconfirmed.
  ///
  /// In en, this message translates to:
  /// **'This session is not confirmed for this cashier and device. Open a confirmed session before selling.'**
  String get tillSessionUnconfirmed;

  /// No description provided for @connectedMasterDataNotice.
  ///
  /// In en, this message translates to:
  /// **'Menu, modifiers, promotions and floor plans are managed in Backoffice. This till receives updates automatically.'**
  String get connectedMasterDataNotice;

  /// No description provided for @tableContested.
  ///
  /// In en, this message translates to:
  /// **'Conflicting table changes'**
  String get tableContested;

  /// No description provided for @tableContestedHelp.
  ///
  /// In en, this message translates to:
  /// **'Two tills changed this table. Check with staff, sync, then choose the correct status to resolve the conflict.'**
  String get tableContestedHelp;

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'JustClick POS'**
  String get appTitle;

  /// No description provided for @appTagline.
  ///
  /// In en, this message translates to:
  /// **'Restaurant Point of Sale & Management System'**
  String get appTagline;

  /// No description provided for @navPos.
  ///
  /// In en, this message translates to:
  /// **'New Sale'**
  String get navPos;

  /// No description provided for @navOrders.
  ///
  /// In en, this message translates to:
  /// **'Orders'**
  String get navOrders;

  /// No description provided for @navTables.
  ///
  /// In en, this message translates to:
  /// **'Tables'**
  String get navTables;

  /// No description provided for @navDashboard.
  ///
  /// In en, this message translates to:
  /// **'Dashboard'**
  String get navDashboard;

  /// No description provided for @navSettings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get navSettings;

  /// No description provided for @commonSearch.
  ///
  /// In en, this message translates to:
  /// **'Search'**
  String get commonSearch;

  /// No description provided for @commonCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get commonCancel;

  /// No description provided for @commonSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get commonSave;

  /// No description provided for @commonDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get commonDelete;

  /// No description provided for @commonEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get commonEdit;

  /// No description provided for @commonAdd.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get commonAdd;

  /// No description provided for @commonClose.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get commonClose;

  /// No description provided for @commonConfirm.
  ///
  /// In en, this message translates to:
  /// **'Confirm'**
  String get commonConfirm;

  /// No description provided for @commonContinue.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get commonContinue;

  /// No description provided for @commonBack.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get commonBack;

  /// No description provided for @commonRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get commonRetry;

  /// No description provided for @commonDone.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get commonDone;

  /// No description provided for @commonYes.
  ///
  /// In en, this message translates to:
  /// **'Yes'**
  String get commonYes;

  /// No description provided for @commonNo.
  ///
  /// In en, this message translates to:
  /// **'No'**
  String get commonNo;

  /// No description provided for @commonAll.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get commonAll;

  /// No description provided for @commonEmpty.
  ///
  /// In en, this message translates to:
  /// **'Nothing here yet'**
  String get commonEmpty;

  /// No description provided for @commonLoading.
  ///
  /// In en, this message translates to:
  /// **'Loading...'**
  String get commonLoading;

  /// No description provided for @commonError.
  ///
  /// In en, this message translates to:
  /// **'Something went wrong'**
  String get commonError;

  /// No description provided for @commonNoResults.
  ///
  /// In en, this message translates to:
  /// **'No results found'**
  String get commonNoResults;

  /// No description provided for @commonUnknown.
  ///
  /// In en, this message translates to:
  /// **'Unknown'**
  String get commonUnknown;

  /// No description provided for @commonRequired.
  ///
  /// In en, this message translates to:
  /// **'Required'**
  String get commonRequired;

  /// No description provided for @commonOptional.
  ///
  /// In en, this message translates to:
  /// **'Optional'**
  String get commonOptional;

  /// No description provided for @commonToday.
  ///
  /// In en, this message translates to:
  /// **'Today'**
  String get commonToday;

  /// No description provided for @commonCurrency.
  ///
  /// In en, this message translates to:
  /// **'Rp'**
  String get commonCurrency;

  /// No description provided for @categoryAll.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get categoryAll;

  /// No description provided for @categoryPopular.
  ///
  /// In en, this message translates to:
  /// **'Popular'**
  String get categoryPopular;

  /// No description provided for @posTitle.
  ///
  /// In en, this message translates to:
  /// **'New Sale'**
  String get posTitle;

  /// No description provided for @posGreetingMorning.
  ///
  /// In en, this message translates to:
  /// **'Good morning'**
  String get posGreetingMorning;

  /// No description provided for @posGreetingNoon.
  ///
  /// In en, this message translates to:
  /// **'Good afternoon'**
  String get posGreetingNoon;

  /// No description provided for @posGreetingAfternoon.
  ///
  /// In en, this message translates to:
  /// **'Good afternoon'**
  String get posGreetingAfternoon;

  /// No description provided for @posGreetingEvening.
  ///
  /// In en, this message translates to:
  /// **'Good evening'**
  String get posGreetingEvening;

  /// No description provided for @posSearchProduct.
  ///
  /// In en, this message translates to:
  /// **'Search menu...'**
  String get posSearchProduct;

  /// No description provided for @posNoProducts.
  ///
  /// In en, this message translates to:
  /// **'No products in this category'**
  String get posNoProducts;

  /// No description provided for @posCartEmpty.
  ///
  /// In en, this message translates to:
  /// **'Cart is empty'**
  String get posCartEmpty;

  /// No description provided for @posCartEmptyHint.
  ///
  /// In en, this message translates to:
  /// **'Tap a product to add it to the order'**
  String get posCartEmptyHint;

  /// No description provided for @posCart.
  ///
  /// In en, this message translates to:
  /// **'Cart'**
  String get posCart;

  /// No description provided for @posCartItems.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{0 items} =1{1 item} other{{count} items}}'**
  String posCartItems(int count);

  /// No description provided for @posSubtotal.
  ///
  /// In en, this message translates to:
  /// **'Subtotal'**
  String get posSubtotal;

  /// No description provided for @posDiscount.
  ///
  /// In en, this message translates to:
  /// **'Discount'**
  String get posDiscount;

  /// No description provided for @posServiceCharge.
  ///
  /// In en, this message translates to:
  /// **'Service Charge'**
  String get posServiceCharge;

  /// No description provided for @posTax.
  ///
  /// In en, this message translates to:
  /// **'PB1'**
  String get posTax;

  /// No description provided for @posTotal.
  ///
  /// In en, this message translates to:
  /// **'Total'**
  String get posTotal;

  /// No description provided for @posCharge.
  ///
  /// In en, this message translates to:
  /// **'Charge'**
  String get posCharge;

  /// No description provided for @posCheckout.
  ///
  /// In en, this message translates to:
  /// **'Checkout'**
  String get posCheckout;

  /// No description provided for @posClearCart.
  ///
  /// In en, this message translates to:
  /// **'Clear cart'**
  String get posClearCart;

  /// No description provided for @posCustomerName.
  ///
  /// In en, this message translates to:
  /// **'Customer name (optional)'**
  String get posCustomerName;

  /// No description provided for @posNote.
  ///
  /// In en, this message translates to:
  /// **'Order note'**
  String get posNote;

  /// No description provided for @posNoteHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. no chili, extra sauce'**
  String get posNoteHint;

  /// No description provided for @posOrderType.
  ///
  /// In en, this message translates to:
  /// **'Order type'**
  String get posOrderType;

  /// No description provided for @posDineIn.
  ///
  /// In en, this message translates to:
  /// **'Dine-in'**
  String get posDineIn;

  /// No description provided for @posTakeaway.
  ///
  /// In en, this message translates to:
  /// **'Takeaway'**
  String get posTakeaway;

  /// No description provided for @posDelivery.
  ///
  /// In en, this message translates to:
  /// **'Delivery'**
  String get posDelivery;

  /// No description provided for @posSelectTable.
  ///
  /// In en, this message translates to:
  /// **'Select table'**
  String get posSelectTable;

  /// No description provided for @posAddDiscount.
  ///
  /// In en, this message translates to:
  /// **'Add discount'**
  String get posAddDiscount;

  /// No description provided for @posAmountPaid.
  ///
  /// In en, this message translates to:
  /// **'Amount paid'**
  String get posAmountPaid;

  /// No description provided for @posChange.
  ///
  /// In en, this message translates to:
  /// **'Change'**
  String get posChange;

  /// No description provided for @posExactCash.
  ///
  /// In en, this message translates to:
  /// **'Exact'**
  String get posExactCash;

  /// No description provided for @posPaymentMethod.
  ///
  /// In en, this message translates to:
  /// **'Payment method'**
  String get posPaymentMethod;

  /// No description provided for @posCash.
  ///
  /// In en, this message translates to:
  /// **'Cash'**
  String get posCash;

  /// No description provided for @posQris.
  ///
  /// In en, this message translates to:
  /// **'QRIS'**
  String get posQris;

  /// No description provided for @posCard.
  ///
  /// In en, this message translates to:
  /// **'Card'**
  String get posCard;

  /// No description provided for @posPlaceOrder.
  ///
  /// In en, this message translates to:
  /// **'Place Order'**
  String get posPlaceOrder;

  /// No description provided for @posOrderPlaced.
  ///
  /// In en, this message translates to:
  /// **'Order placed successfully'**
  String get posOrderPlaced;

  /// No description provided for @posOrderNumber.
  ///
  /// In en, this message translates to:
  /// **'Order #{id}'**
  String posOrderNumber(String id);

  /// No description provided for @posQty.
  ///
  /// In en, this message translates to:
  /// **'Qty'**
  String get posQty;

  /// No description provided for @posRemoveItem.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get posRemoveItem;

  /// No description provided for @posQuickAdd.
  ///
  /// In en, this message translates to:
  /// **'Quick add'**
  String get posQuickAdd;

  /// No description provided for @posInCart.
  ///
  /// In en, this message translates to:
  /// **'in cart'**
  String get posInCart;

  /// No description provided for @posQtyIncrease.
  ///
  /// In en, this message translates to:
  /// **'Add one'**
  String get posQtyIncrease;

  /// No description provided for @posQtyDecrease.
  ///
  /// In en, this message translates to:
  /// **'Remove one'**
  String get posQtyDecrease;

  /// No description provided for @posUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Unavailable'**
  String get posUnavailable;

  /// No description provided for @posOutOfStock.
  ///
  /// In en, this message translates to:
  /// **'Out of stock'**
  String get posOutOfStock;

  /// No description provided for @posStockLeft.
  ///
  /// In en, this message translates to:
  /// **'{count} left'**
  String posStockLeft(int count);

  /// No description provided for @orderStatusAll.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get orderStatusAll;

  /// No description provided for @orderStatusPending.
  ///
  /// In en, this message translates to:
  /// **'Pending'**
  String get orderStatusPending;

  /// No description provided for @orderStatusPreparing.
  ///
  /// In en, this message translates to:
  /// **'Preparing'**
  String get orderStatusPreparing;

  /// No description provided for @orderStatusReady.
  ///
  /// In en, this message translates to:
  /// **'Ready'**
  String get orderStatusReady;

  /// No description provided for @orderStatusServed.
  ///
  /// In en, this message translates to:
  /// **'Served'**
  String get orderStatusServed;

  /// No description provided for @orderStatusPaid.
  ///
  /// In en, this message translates to:
  /// **'Completed'**
  String get orderStatusPaid;

  /// No description provided for @orderStatusCancelled.
  ///
  /// In en, this message translates to:
  /// **'Cancelled'**
  String get orderStatusCancelled;

  /// No description provided for @ordersTitle.
  ///
  /// In en, this message translates to:
  /// **'Orders'**
  String get ordersTitle;

  /// No description provided for @ordersEmpty.
  ///
  /// In en, this message translates to:
  /// **'No orders yet'**
  String get ordersEmpty;

  /// No description provided for @ordersEmptyHint.
  ///
  /// In en, this message translates to:
  /// **'Completed sales will appear here'**
  String get ordersEmptyHint;

  /// No description provided for @ordersTodayRevenue.
  ///
  /// In en, this message translates to:
  /// **'Today\'s revenue'**
  String get ordersTodayRevenue;

  /// No description provided for @ordersTodayCount.
  ///
  /// In en, this message translates to:
  /// **'Today\'s orders'**
  String get ordersTodayCount;

  /// No description provided for @ordersDetail.
  ///
  /// In en, this message translates to:
  /// **'Order detail'**
  String get ordersDetail;

  /// No description provided for @ordersMarkAs.
  ///
  /// In en, this message translates to:
  /// **'Mark as {status}'**
  String ordersMarkAs(String status);

  /// No description provided for @ordersCancelOrder.
  ///
  /// In en, this message translates to:
  /// **'Cancel order'**
  String get ordersCancelOrder;

  /// No description provided for @ordersPrintReceipt.
  ///
  /// In en, this message translates to:
  /// **'Print receipt'**
  String get ordersPrintReceipt;

  /// No description provided for @receiptPrintFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not open the print dialog'**
  String get receiptPrintFailed;

  /// No description provided for @ordersItemAt.
  ///
  /// In en, this message translates to:
  /// **'{time}'**
  String ordersItemAt(String time);

  /// No description provided for @ordersFilterByStatus.
  ///
  /// In en, this message translates to:
  /// **'Filter by status'**
  String get ordersFilterByStatus;

  /// No description provided for @tableStatusAvailable.
  ///
  /// In en, this message translates to:
  /// **'Available'**
  String get tableStatusAvailable;

  /// No description provided for @tableStatusOccupied.
  ///
  /// In en, this message translates to:
  /// **'Occupied'**
  String get tableStatusOccupied;

  /// No description provided for @tableStatusReserved.
  ///
  /// In en, this message translates to:
  /// **'Reserved'**
  String get tableStatusReserved;

  /// No description provided for @tablesTitle.
  ///
  /// In en, this message translates to:
  /// **'Tables'**
  String get tablesTitle;

  /// No description provided for @tablesTotal.
  ///
  /// In en, this message translates to:
  /// **'Total'**
  String get tablesTotal;

  /// No description provided for @tablesCapacity.
  ///
  /// In en, this message translates to:
  /// **'{count} seats'**
  String tablesCapacity(int count);

  /// No description provided for @tablesEmpty.
  ///
  /// In en, this message translates to:
  /// **'No tables configured'**
  String get tablesEmpty;

  /// No description provided for @tablesEmptyHint.
  ///
  /// In en, this message translates to:
  /// **'Add tables to start managing dine-in seats'**
  String get tablesEmptyHint;

  /// No description provided for @tablesAddTable.
  ///
  /// In en, this message translates to:
  /// **'Add table'**
  String get tablesAddTable;

  /// No description provided for @tablesTableName.
  ///
  /// In en, this message translates to:
  /// **'Table name'**
  String get tablesTableName;

  /// No description provided for @tablesCapacityLabel.
  ///
  /// In en, this message translates to:
  /// **'Capacity (seats)'**
  String get tablesCapacityLabel;

  /// No description provided for @tablesStatus.
  ///
  /// In en, this message translates to:
  /// **'Status'**
  String get tablesStatus;

  /// No description provided for @tablesSetStatus.
  ///
  /// In en, this message translates to:
  /// **'Set table status'**
  String get tablesSetStatus;

  /// No description provided for @tablesFloor.
  ///
  /// In en, this message translates to:
  /// **'Floor'**
  String get tablesFloor;

  /// No description provided for @tablesFloor1.
  ///
  /// In en, this message translates to:
  /// **'Floor 1'**
  String get tablesFloor1;

  /// No description provided for @tablesFloor2.
  ///
  /// In en, this message translates to:
  /// **'Floor 2'**
  String get tablesFloor2;

  /// No description provided for @tablesFloor3.
  ///
  /// In en, this message translates to:
  /// **'Floor 3'**
  String get tablesFloor3;

  /// No description provided for @tablesFloor4.
  ///
  /// In en, this message translates to:
  /// **'Terrace'**
  String get tablesFloor4;

  /// No description provided for @tablesStartOrder.
  ///
  /// In en, this message translates to:
  /// **'Start order'**
  String get tablesStartOrder;

  /// No description provided for @tablesInactive.
  ///
  /// In en, this message translates to:
  /// **'Inactive'**
  String get tablesInactive;

  /// No description provided for @tableManagementTitle.
  ///
  /// In en, this message translates to:
  /// **'Table Management'**
  String get tableManagementTitle;

  /// No description provided for @tableManagementEmpty.
  ///
  /// In en, this message translates to:
  /// **'This branch has no tables yet'**
  String get tableManagementEmpty;

  /// No description provided for @tablesEditTable.
  ///
  /// In en, this message translates to:
  /// **'Edit table'**
  String get tablesEditTable;

  /// No description provided for @tablesFloorHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. Floor 1, Rooftop, VIP'**
  String get tablesFloorHint;

  /// No description provided for @tablesNameTaken.
  ///
  /// In en, this message translates to:
  /// **'Another table at this branch already uses that name'**
  String get tablesNameTaken;

  /// No description provided for @tablesCapacityInvalid.
  ///
  /// In en, this message translates to:
  /// **'Capacity must be at least 1 seat'**
  String get tablesCapacityInvalid;

  /// No description provided for @tablesActive.
  ///
  /// In en, this message translates to:
  /// **'Active'**
  String get tablesActive;

  /// No description provided for @tablesActiveHint.
  ///
  /// In en, this message translates to:
  /// **'Can be picked for a new dine-in order'**
  String get tablesActiveHint;

  /// No description provided for @tablesInactiveHint.
  ///
  /// In en, this message translates to:
  /// **'Hidden from new dine-in orders'**
  String get tablesInactiveHint;

  /// No description provided for @tablesDeleteConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete this table?'**
  String get tablesDeleteConfirm;

  /// No description provided for @tablesDeleteConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'It disappears from the list. Orders already recorded keep its name.'**
  String get tablesDeleteConfirmBody;

  /// No description provided for @tablesHasHistory.
  ///
  /// In en, this message translates to:
  /// **'This table has orders, so it cannot be deleted. Deactivate it instead.'**
  String get tablesHasHistory;

  /// No description provided for @productManagementTitle.
  ///
  /// In en, this message translates to:
  /// **'Products'**
  String get productManagementTitle;

  /// No description provided for @productAdd.
  ///
  /// In en, this message translates to:
  /// **'Add product'**
  String get productAdd;

  /// No description provided for @productEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit product'**
  String get productEdit;

  /// No description provided for @productName.
  ///
  /// In en, this message translates to:
  /// **'Product name'**
  String get productName;

  /// No description provided for @productPrice.
  ///
  /// In en, this message translates to:
  /// **'Price'**
  String get productPrice;

  /// No description provided for @productCategory.
  ///
  /// In en, this message translates to:
  /// **'Category'**
  String get productCategory;

  /// No description provided for @productDescription.
  ///
  /// In en, this message translates to:
  /// **'Description'**
  String get productDescription;

  /// No description provided for @productAvailable.
  ///
  /// In en, this message translates to:
  /// **'Available'**
  String get productAvailable;

  /// No description provided for @productUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Unavailable'**
  String get productUnavailable;

  /// No description provided for @productEmoji.
  ///
  /// In en, this message translates to:
  /// **'Icon'**
  String get productEmoji;

  /// No description provided for @productDeleteConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete this product?'**
  String get productDeleteConfirm;

  /// No description provided for @productDeleteConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'This action cannot be undone.'**
  String get productDeleteConfirmBody;

  /// No description provided for @productEmpty.
  ///
  /// In en, this message translates to:
  /// **'No products yet'**
  String get productEmpty;

  /// No description provided for @productEmptyHint.
  ///
  /// In en, this message translates to:
  /// **'Add your first product to start selling'**
  String get productEmptyHint;

  /// No description provided for @productPopular.
  ///
  /// In en, this message translates to:
  /// **'Popular'**
  String get productPopular;

  /// No description provided for @productStock.
  ///
  /// In en, this message translates to:
  /// **'Stock'**
  String get productStock;

  /// No description provided for @productStockHint.
  ///
  /// In en, this message translates to:
  /// **'Leave empty if this item is not counted'**
  String get productStockHint;

  /// No description provided for @productCost.
  ///
  /// In en, this message translates to:
  /// **'Cost price'**
  String get productCost;

  /// No description provided for @productSku.
  ///
  /// In en, this message translates to:
  /// **'SKU / barcode'**
  String get productSku;

  /// No description provided for @productLowStock.
  ///
  /// In en, this message translates to:
  /// **'Low stock'**
  String get productLowStock;

  /// No description provided for @productOutOfStock.
  ///
  /// In en, this message translates to:
  /// **'Out of stock'**
  String get productOutOfStock;

  /// No description provided for @productStockValue.
  ///
  /// In en, this message translates to:
  /// **'Stock: {count}'**
  String productStockValue(int count);

  /// No description provided for @productNotTracked.
  ///
  /// In en, this message translates to:
  /// **'Not counted'**
  String get productNotTracked;

  /// No description provided for @employeesTitle.
  ///
  /// In en, this message translates to:
  /// **'Employees'**
  String get employeesTitle;

  /// No description provided for @employeesManage.
  ///
  /// In en, this message translates to:
  /// **'Staff and PINs'**
  String get employeesManage;

  /// No description provided for @employeeAdd.
  ///
  /// In en, this message translates to:
  /// **'Add employee'**
  String get employeeAdd;

  /// No description provided for @employeeEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit employee'**
  String get employeeEdit;

  /// No description provided for @employeeName.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get employeeName;

  /// No description provided for @employeePin.
  ///
  /// In en, this message translates to:
  /// **'PIN (4 digits)'**
  String get employeePin;

  /// No description provided for @employeeRole.
  ///
  /// In en, this message translates to:
  /// **'Role'**
  String get employeeRole;

  /// No description provided for @employeeRoleCashier.
  ///
  /// In en, this message translates to:
  /// **'Cashier'**
  String get employeeRoleCashier;

  /// No description provided for @employeeRoleManager.
  ///
  /// In en, this message translates to:
  /// **'Manager'**
  String get employeeRoleManager;

  /// No description provided for @employeeActive.
  ///
  /// In en, this message translates to:
  /// **'Can sign in'**
  String get employeeActive;

  /// No description provided for @employeeInactive.
  ///
  /// In en, this message translates to:
  /// **'Cannot sign in'**
  String get employeeInactive;

  /// No description provided for @employeePinTaken.
  ///
  /// In en, this message translates to:
  /// **'That PIN is already used by someone else'**
  String get employeePinTaken;

  /// No description provided for @employeePinLength.
  ///
  /// In en, this message translates to:
  /// **'PIN must be exactly 4 digits'**
  String get employeePinLength;

  /// No description provided for @employeeDeleteConfirm.
  ///
  /// In en, this message translates to:
  /// **'Remove this employee?'**
  String get employeeDeleteConfirm;

  /// No description provided for @employeeDeleteConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'Past orders keep their name. They will no longer be able to sign in.'**
  String get employeeDeleteConfirmBody;

  /// No description provided for @employeeCannotDeleteSelf.
  ///
  /// In en, this message translates to:
  /// **'You cannot remove the employee you are signed in as'**
  String get employeeCannotDeleteSelf;

  /// No description provided for @employeeSignedInAs.
  ///
  /// In en, this message translates to:
  /// **'Signed in as'**
  String get employeeSignedInAs;

  /// No description provided for @shiftTitle.
  ///
  /// In en, this message translates to:
  /// **'Shift'**
  String get shiftTitle;

  /// No description provided for @shiftOpen.
  ///
  /// In en, this message translates to:
  /// **'Open shift'**
  String get shiftOpen;

  /// No description provided for @shiftClose.
  ///
  /// In en, this message translates to:
  /// **'Close shift'**
  String get shiftClose;

  /// No description provided for @shiftNoneOpen.
  ///
  /// In en, this message translates to:
  /// **'No shift open'**
  String get shiftNoneOpen;

  /// No description provided for @shiftNoneOpenHint.
  ///
  /// In en, this message translates to:
  /// **'Open a shift with the cash float in the drawer'**
  String get shiftNoneOpenHint;

  /// No description provided for @shiftOpeningCash.
  ///
  /// In en, this message translates to:
  /// **'Opening cash'**
  String get shiftOpeningCash;

  /// No description provided for @shiftCountedCash.
  ///
  /// In en, this message translates to:
  /// **'Counted cash'**
  String get shiftCountedCash;

  /// No description provided for @shiftExpectedCash.
  ///
  /// In en, this message translates to:
  /// **'Expected in drawer'**
  String get shiftExpectedCash;

  /// No description provided for @shiftVariance.
  ///
  /// In en, this message translates to:
  /// **'Difference'**
  String get shiftVariance;

  /// No description provided for @shiftCashSales.
  ///
  /// In en, this message translates to:
  /// **'Cash sales'**
  String get shiftCashSales;

  /// No description provided for @shiftNonCashSales.
  ///
  /// In en, this message translates to:
  /// **'Card / QRIS'**
  String get shiftNonCashSales;

  /// No description provided for @shiftOrders.
  ///
  /// In en, this message translates to:
  /// **'Orders this shift'**
  String get shiftOrders;

  /// No description provided for @shiftOpenedAt.
  ///
  /// In en, this message translates to:
  /// **'Opened {time}'**
  String shiftOpenedAt(String time);

  /// No description provided for @shiftClosedAt.
  ///
  /// In en, this message translates to:
  /// **'Closed {time}'**
  String shiftClosedAt(String time);

  /// No description provided for @shiftNote.
  ///
  /// In en, this message translates to:
  /// **'Note (optional)'**
  String get shiftNote;

  /// No description provided for @shiftHistory.
  ///
  /// In en, this message translates to:
  /// **'Closing history'**
  String get shiftHistory;

  /// No description provided for @shiftHistoryEmpty.
  ///
  /// In en, this message translates to:
  /// **'No shift has been closed yet'**
  String get shiftHistoryEmpty;

  /// No description provided for @shiftOver.
  ///
  /// In en, this message translates to:
  /// **'Over'**
  String get shiftOver;

  /// No description provided for @shiftShort.
  ///
  /// In en, this message translates to:
  /// **'Short'**
  String get shiftShort;

  /// No description provided for @shiftBalanced.
  ///
  /// In en, this message translates to:
  /// **'Balanced'**
  String get shiftBalanced;

  /// No description provided for @shiftStillOpen.
  ///
  /// In en, this message translates to:
  /// **'Still open'**
  String get shiftStillOpen;

  /// No description provided for @reportTitle.
  ///
  /// In en, this message translates to:
  /// **'Sales report'**
  String get reportTitle;

  /// No description provided for @reportToday.
  ///
  /// In en, this message translates to:
  /// **'Today'**
  String get reportToday;

  /// No description provided for @reportLast7.
  ///
  /// In en, this message translates to:
  /// **'Last 7 days'**
  String get reportLast7;

  /// No description provided for @reportLast30.
  ///
  /// In en, this message translates to:
  /// **'Last 30 days'**
  String get reportLast30;

  /// No description provided for @reportThisMonth.
  ///
  /// In en, this message translates to:
  /// **'This month'**
  String get reportThisMonth;

  /// No description provided for @reportCustomRange.
  ///
  /// In en, this message translates to:
  /// **'Pick dates'**
  String get reportCustomRange;

  /// No description provided for @reportRevenue.
  ///
  /// In en, this message translates to:
  /// **'Revenue'**
  String get reportRevenue;

  /// No description provided for @reportOrders.
  ///
  /// In en, this message translates to:
  /// **'Orders'**
  String get reportOrders;

  /// No description provided for @reportAverage.
  ///
  /// In en, this message translates to:
  /// **'Average order'**
  String get reportAverage;

  /// No description provided for @reportItemsSold.
  ///
  /// In en, this message translates to:
  /// **'Items sold'**
  String get reportItemsSold;

  /// No description provided for @reportSubtotal.
  ///
  /// In en, this message translates to:
  /// **'Subtotal'**
  String get reportSubtotal;

  /// No description provided for @reportDiscount.
  ///
  /// In en, this message translates to:
  /// **'Discount'**
  String get reportDiscount;

  /// No description provided for @reportServiceCharge.
  ///
  /// In en, this message translates to:
  /// **'Service Charge'**
  String get reportServiceCharge;

  /// No description provided for @reportTax.
  ///
  /// In en, this message translates to:
  /// **'PB1'**
  String get reportTax;

  /// No description provided for @reportCancelled.
  ///
  /// In en, this message translates to:
  /// **'Cancelled'**
  String get reportCancelled;

  /// No description provided for @reportByPayment.
  ///
  /// In en, this message translates to:
  /// **'By payment method'**
  String get reportByPayment;

  /// No description provided for @reportByType.
  ///
  /// In en, this message translates to:
  /// **'By order type'**
  String get reportByType;

  /// No description provided for @reportByCashier.
  ///
  /// In en, this message translates to:
  /// **'By cashier'**
  String get reportByCashier;

  /// No description provided for @reportDaily.
  ///
  /// In en, this message translates to:
  /// **'Daily revenue'**
  String get reportDaily;

  /// No description provided for @reportExport.
  ///
  /// In en, this message translates to:
  /// **'Export CSV'**
  String get reportExport;

  /// No description provided for @reportExported.
  ///
  /// In en, this message translates to:
  /// **'Report exported'**
  String get reportExported;

  /// No description provided for @reportEmpty.
  ///
  /// In en, this message translates to:
  /// **'No sales in this range'**
  String get reportEmpty;

  /// No description provided for @reportSummary.
  ///
  /// In en, this message translates to:
  /// **'Summary'**
  String get reportSummary;

  /// No description provided for @reportMetric.
  ///
  /// In en, this message translates to:
  /// **'Metric'**
  String get reportMetric;

  /// No description provided for @reportAmount.
  ///
  /// In en, this message translates to:
  /// **'Amount'**
  String get reportAmount;

  /// No description provided for @reportMethod.
  ///
  /// In en, this message translates to:
  /// **'Method'**
  String get reportMethod;

  /// No description provided for @reportCount.
  ///
  /// In en, this message translates to:
  /// **'Orders'**
  String get reportCount;

  /// No description provided for @reportType.
  ///
  /// In en, this message translates to:
  /// **'Type'**
  String get reportType;

  /// No description provided for @reportCashier.
  ///
  /// In en, this message translates to:
  /// **'Cashier'**
  String get reportCashier;

  /// No description provided for @reportDate.
  ///
  /// In en, this message translates to:
  /// **'Date'**
  String get reportDate;

  /// No description provided for @reportPeriod.
  ///
  /// In en, this message translates to:
  /// **'Period'**
  String get reportPeriod;

  /// No description provided for @categoryManagementTitle.
  ///
  /// In en, this message translates to:
  /// **'Categories'**
  String get categoryManagementTitle;

  /// No description provided for @categoryAdd.
  ///
  /// In en, this message translates to:
  /// **'Add category'**
  String get categoryAdd;

  /// No description provided for @categoryEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit category'**
  String get categoryEdit;

  /// No description provided for @categoryName.
  ///
  /// In en, this message translates to:
  /// **'Category name'**
  String get categoryName;

  /// No description provided for @categoryDeleteConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete this category?'**
  String get categoryDeleteConfirm;

  /// No description provided for @categoryEmpty.
  ///
  /// In en, this message translates to:
  /// **'No categories yet'**
  String get categoryEmpty;

  /// No description provided for @categoryEmoji.
  ///
  /// In en, this message translates to:
  /// **'Icon'**
  String get categoryEmoji;

  /// No description provided for @dashboardTitle.
  ///
  /// In en, this message translates to:
  /// **'Dashboard'**
  String get dashboardTitle;

  /// No description provided for @dashboardGreeting.
  ///
  /// In en, this message translates to:
  /// **'Hello, {name}!'**
  String dashboardGreeting(String name);

  /// No description provided for @dashboardRevenue.
  ///
  /// In en, this message translates to:
  /// **'Revenue'**
  String get dashboardRevenue;

  /// No description provided for @dashboardOrders.
  ///
  /// In en, this message translates to:
  /// **'Orders'**
  String get dashboardOrders;

  /// No description provided for @dashboardAvgOrder.
  ///
  /// In en, this message translates to:
  /// **'Avg. order'**
  String get dashboardAvgOrder;

  /// No description provided for @dashboardTopProducts.
  ///
  /// In en, this message translates to:
  /// **'Top products'**
  String get dashboardTopProducts;

  /// No description provided for @dashboardRecentOrders.
  ///
  /// In en, this message translates to:
  /// **'Recent orders'**
  String get dashboardRecentOrders;

  /// No description provided for @dashboardThisWeek.
  ///
  /// In en, this message translates to:
  /// **'This week'**
  String get dashboardThisWeek;

  /// No description provided for @dashboardNoSales.
  ///
  /// In en, this message translates to:
  /// **'No sales recorded yet'**
  String get dashboardNoSales;

  /// No description provided for @dashboardItemsSold.
  ///
  /// In en, this message translates to:
  /// **'items sold'**
  String get dashboardItemsSold;

  /// No description provided for @dashboardViewAll.
  ///
  /// In en, this message translates to:
  /// **'View all'**
  String get dashboardViewAll;

  /// No description provided for @settingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTitle;

  /// No description provided for @settingsAppearance.
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get settingsAppearance;

  /// No description provided for @settingsTheme.
  ///
  /// In en, this message translates to:
  /// **'Theme'**
  String get settingsTheme;

  /// No description provided for @settingsThemeLight.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get settingsThemeLight;

  /// No description provided for @settingsThemeDark.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get settingsThemeDark;

  /// No description provided for @settingsThemeSystem.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get settingsThemeSystem;

  /// No description provided for @settingsBrandColor.
  ///
  /// In en, this message translates to:
  /// **'Brand color'**
  String get settingsBrandColor;

  /// No description provided for @settingsLanguage.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get settingsLanguage;

  /// No description provided for @settingsLanguageEn.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get settingsLanguageEn;

  /// No description provided for @settingsLanguageId.
  ///
  /// In en, this message translates to:
  /// **'Bahasa Indonesia'**
  String get settingsLanguageId;

  /// No description provided for @settingsBusiness.
  ///
  /// In en, this message translates to:
  /// **'Business'**
  String get settingsBusiness;

  /// No description provided for @settingsTaxRate.
  ///
  /// In en, this message translates to:
  /// **'PB1 rate (%)'**
  String get settingsTaxRate;

  /// No description provided for @settingsServiceCharge.
  ///
  /// In en, this message translates to:
  /// **'Service charge'**
  String get settingsServiceCharge;

  /// No description provided for @settingsServiceChargeRate.
  ///
  /// In en, this message translates to:
  /// **'Service charge rate (%)'**
  String get settingsServiceChargeRate;

  /// No description provided for @settingsServiceChargeOn.
  ///
  /// In en, this message translates to:
  /// **'Added to every bill'**
  String get settingsServiceChargeOn;

  /// No description provided for @settingsServiceChargeOff.
  ///
  /// In en, this message translates to:
  /// **'Not applied to bills'**
  String get settingsServiceChargeOff;

  /// No description provided for @settingsCurrency.
  ///
  /// In en, this message translates to:
  /// **'Currency symbol'**
  String get settingsCurrency;

  /// No description provided for @settingsStoreName.
  ///
  /// In en, this message translates to:
  /// **'Store name'**
  String get settingsStoreName;

  /// No description provided for @settingsStoreAddress.
  ///
  /// In en, this message translates to:
  /// **'Store address'**
  String get settingsStoreAddress;

  /// No description provided for @settingsTableService.
  ///
  /// In en, this message translates to:
  /// **'Table service'**
  String get settingsTableService;

  /// No description provided for @outletsTitle.
  ///
  /// In en, this message translates to:
  /// **'Outlets'**
  String get outletsTitle;

  /// No description provided for @outletsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Branches, addresses, and which one this device is in'**
  String get outletsSubtitle;

  /// No description provided for @outletAdd.
  ///
  /// In en, this message translates to:
  /// **'Add outlet'**
  String get outletAdd;

  /// No description provided for @outletEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit outlet'**
  String get outletEdit;

  /// No description provided for @outletName.
  ///
  /// In en, this message translates to:
  /// **'Outlet name'**
  String get outletName;

  /// No description provided for @outletAddress.
  ///
  /// In en, this message translates to:
  /// **'Address'**
  String get outletAddress;

  /// No description provided for @outletOpen.
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get outletOpen;

  /// No description provided for @outletClosed.
  ///
  /// In en, this message translates to:
  /// **'Closed'**
  String get outletClosed;

  /// No description provided for @outletNameTaken.
  ///
  /// In en, this message translates to:
  /// **'Another outlet already uses that name'**
  String get outletNameTaken;

  /// No description provided for @outletUseHere.
  ///
  /// In en, this message translates to:
  /// **'Use on this device'**
  String get outletUseHere;

  /// No description provided for @outletThisDevice.
  ///
  /// In en, this message translates to:
  /// **'This device'**
  String get outletThisDevice;

  /// No description provided for @outletPickTitle.
  ///
  /// In en, this message translates to:
  /// **'Which outlet is this device in?'**
  String get outletPickTitle;

  /// No description provided for @outletPickHint.
  ///
  /// In en, this message translates to:
  /// **'Sales, stock and tables all follow this choice'**
  String get outletPickHint;

  /// No description provided for @outletDeleteConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete this outlet?'**
  String get outletDeleteConfirm;

  /// No description provided for @outletDeleteConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'It disappears from the list. Sales already recorded keep its name.'**
  String get outletDeleteConfirmBody;

  /// No description provided for @outletHasSales.
  ///
  /// In en, this message translates to:
  /// **'This outlet has sales, so it cannot be deleted. Close it instead.'**
  String get outletHasSales;

  /// No description provided for @outletKeepOneOpen.
  ///
  /// In en, this message translates to:
  /// **'At least one outlet has to stay open'**
  String get outletKeepOneOpen;

  /// No description provided for @settingsTableServiceOn.
  ///
  /// In en, this message translates to:
  /// **'Guests are seated at numbered tables'**
  String get settingsTableServiceOn;

  /// No description provided for @settingsTableServiceOff.
  ///
  /// In en, this message translates to:
  /// **'No floor plan — dine-in needs no table'**
  String get settingsTableServiceOff;

  /// No description provided for @settingsAbout.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get settingsAbout;

  /// No description provided for @settingsVersion.
  ///
  /// In en, this message translates to:
  /// **'Version'**
  String get settingsVersion;

  /// No description provided for @settingsLogout.
  ///
  /// In en, this message translates to:
  /// **'Log out'**
  String get settingsLogout;

  /// No description provided for @settingsProfile.
  ///
  /// In en, this message translates to:
  /// **'Cashier profile'**
  String get settingsProfile;

  /// No description provided for @settingsData.
  ///
  /// In en, this message translates to:
  /// **'Data'**
  String get settingsData;

  /// No description provided for @settingsResetDemoData.
  ///
  /// In en, this message translates to:
  /// **'Reset demo data'**
  String get settingsResetDemoData;

  /// No description provided for @settingsResetConfirm.
  ///
  /// In en, this message translates to:
  /// **'Reset all demo data?'**
  String get settingsResetConfirm;

  /// No description provided for @settingsResetConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'All orders, products and settings will be restored to defaults.'**
  String get settingsResetConfirmBody;

  /// No description provided for @authWelcome.
  ///
  /// In en, this message translates to:
  /// **'Welcome back'**
  String get authWelcome;

  /// No description provided for @authLoginHint.
  ///
  /// In en, this message translates to:
  /// **'Enter your PIN to continue'**
  String get authLoginHint;

  /// No description provided for @ordersPrintFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not print the receipt'**
  String get ordersPrintFailed;

  /// No description provided for @navCollapseSidebar.
  ///
  /// In en, this message translates to:
  /// **'Collapse sidebar'**
  String get navCollapseSidebar;

  /// No description provided for @navExpandSidebar.
  ///
  /// In en, this message translates to:
  /// **'Expand sidebar'**
  String get navExpandSidebar;

  /// No description provided for @authChooseAccount.
  ///
  /// In en, this message translates to:
  /// **'Who is on duty?'**
  String get authChooseAccount;

  /// No description provided for @authChooseAccountHint.
  ///
  /// In en, this message translates to:
  /// **'Pick your account, then enter your PIN'**
  String get authChooseAccountHint;

  /// No description provided for @authChangeAccount.
  ///
  /// In en, this message translates to:
  /// **'Change'**
  String get authChangeAccount;

  /// No description provided for @authNoAccounts.
  ///
  /// In en, this message translates to:
  /// **'No staff accounts yet'**
  String get authNoAccounts;

  /// No description provided for @authPin.
  ///
  /// In en, this message translates to:
  /// **'PIN'**
  String get authPin;

  /// No description provided for @authLogin.
  ///
  /// In en, this message translates to:
  /// **'Log in'**
  String get authLogin;

  /// No description provided for @authWrongPin.
  ///
  /// In en, this message translates to:
  /// **'Wrong PIN'**
  String get authWrongPin;

  /// No description provided for @authCashier.
  ///
  /// In en, this message translates to:
  /// **'Cashier'**
  String get authCashier;

  /// No description provided for @authStoreManager.
  ///
  /// In en, this message translates to:
  /// **'Store Manager'**
  String get authStoreManager;

  /// No description provided for @authDemoPin.
  ///
  /// In en, this message translates to:
  /// **'Demo PIN: 1234'**
  String get authDemoPin;

  /// No description provided for @receiptThankYou.
  ///
  /// In en, this message translates to:
  /// **'Thank you!'**
  String get receiptThankYou;

  /// No description provided for @receiptStore.
  ///
  /// In en, this message translates to:
  /// **'Store'**
  String get receiptStore;

  /// No description provided for @receiptCashier.
  ///
  /// In en, this message translates to:
  /// **'Cashier'**
  String get receiptCashier;

  /// No description provided for @receiptDate.
  ///
  /// In en, this message translates to:
  /// **'Date'**
  String get receiptDate;

  /// No description provided for @receiptOrderType.
  ///
  /// In en, this message translates to:
  /// **'Type'**
  String get receiptOrderType;

  /// No description provided for @receiptPaid.
  ///
  /// In en, this message translates to:
  /// **'PAID'**
  String get receiptPaid;

  /// No description provided for @receiptPoweredBy.
  ///
  /// In en, this message translates to:
  /// **'Powered by JustClick POS'**
  String get receiptPoweredBy;

  /// No description provided for @employeeRoleOwner.
  ///
  /// In en, this message translates to:
  /// **'Owner'**
  String get employeeRoleOwner;

  /// No description provided for @employeeRoleCashierHint.
  ///
  /// In en, this message translates to:
  /// **'Sells, seats tables and counts their own drawer.'**
  String get employeeRoleCashierHint;

  /// No description provided for @employeeRoleManagerHint.
  ///
  /// In en, this message translates to:
  /// **'Everything a cashier does, plus void, refund, discounts and stock.'**
  String get employeeRoleManagerHint;

  /// No description provided for @employeeRoleOwnerHint.
  ///
  /// In en, this message translates to:
  /// **'Full control: catalogue, prices, reports, staff and promotions.'**
  String get employeeRoleOwnerHint;

  /// No description provided for @authorizeTitle.
  ///
  /// In en, this message translates to:
  /// **'Manager approval'**
  String get authorizeTitle;

  /// No description provided for @authorizeDenied.
  ///
  /// In en, this message translates to:
  /// **'That PIN is not authorised for this'**
  String get authorizeDenied;

  /// No description provided for @authorizeReasonVoid.
  ///
  /// In en, this message translates to:
  /// **'Voiding a sale needs a manager or owner PIN.'**
  String get authorizeReasonVoid;

  /// No description provided for @authorizeReasonRefund.
  ///
  /// In en, this message translates to:
  /// **'Refunding a sale needs a manager or owner PIN.'**
  String get authorizeReasonRefund;

  /// No description provided for @authorizeReasonDiscount.
  ///
  /// In en, this message translates to:
  /// **'A manual discount needs a manager or owner PIN.'**
  String get authorizeReasonDiscount;

  /// No description provided for @settingsSignedInAs.
  ///
  /// In en, this message translates to:
  /// **'Signed in as'**
  String get settingsSignedInAs;

  /// No description provided for @settingsRoleAccess.
  ///
  /// In en, this message translates to:
  /// **'Your access'**
  String get settingsRoleAccess;

  /// No description provided for @orderStatusRefunded.
  ///
  /// In en, this message translates to:
  /// **'Refunded'**
  String get orderStatusRefunded;

  /// No description provided for @ordersVoid.
  ///
  /// In en, this message translates to:
  /// **'Void order'**
  String get ordersVoid;

  /// No description provided for @ordersRefund.
  ///
  /// In en, this message translates to:
  /// **'Refund order'**
  String get ordersRefund;

  /// No description provided for @ordersVoidTitle.
  ///
  /// In en, this message translates to:
  /// **'Void this order?'**
  String get ordersVoidTitle;

  /// No description provided for @ordersRefundTitle.
  ///
  /// In en, this message translates to:
  /// **'Refund this order?'**
  String get ordersRefundTitle;

  /// No description provided for @ordersVoidBody.
  ///
  /// In en, this message translates to:
  /// **'The sale is struck out and its stock goes back on the shelf.'**
  String get ordersVoidBody;

  /// No description provided for @ordersRefundBody.
  ///
  /// In en, this message translates to:
  /// **'The money is handed back and its stock goes back on the shelf.'**
  String get ordersRefundBody;

  /// No description provided for @ordersVoidReason.
  ///
  /// In en, this message translates to:
  /// **'Reason'**
  String get ordersVoidReason;

  /// No description provided for @ordersVoidReasonHint.
  ///
  /// In en, this message translates to:
  /// **'Wrong order, customer changed their mind…'**
  String get ordersVoidReasonHint;

  /// No description provided for @ordersVoidReasonRequired.
  ///
  /// In en, this message translates to:
  /// **'Give a reason so the report can explain it'**
  String get ordersVoidReasonRequired;

  /// No description provided for @ordersAuthorizedBy.
  ///
  /// In en, this message translates to:
  /// **'Approved by {name}'**
  String ordersAuthorizedBy(String name);

  /// No description provided for @ordersRefundedAmount.
  ///
  /// In en, this message translates to:
  /// **'Refunded {amount}'**
  String ordersRefundedAmount(String amount);

  /// No description provided for @ordersVoided.
  ///
  /// In en, this message translates to:
  /// **'Order voided'**
  String get ordersVoided;

  /// No description provided for @ordersRefunded.
  ///
  /// In en, this message translates to:
  /// **'Order refunded'**
  String get ordersRefunded;

  /// No description provided for @ordersScopeOwnToday.
  ///
  /// In en, this message translates to:
  /// **'Your sales today'**
  String get ordersScopeOwnToday;

  /// No description provided for @ordersScopeAll.
  ///
  /// In en, this message translates to:
  /// **'All sales'**
  String get ordersScopeAll;

  /// No description provided for @posChooseOption.
  ///
  /// In en, this message translates to:
  /// **'Choose an option'**
  String get posChooseOption;

  /// No description provided for @productVariants.
  ///
  /// In en, this message translates to:
  /// **'Variants'**
  String get productVariants;

  /// No description provided for @productVariantsHint.
  ///
  /// In en, this message translates to:
  /// **'Sizes or options with their own price. Leave empty to sell one way.'**
  String get productVariantsHint;

  /// No description provided for @productVariantAdd.
  ///
  /// In en, this message translates to:
  /// **'Add variant'**
  String get productVariantAdd;

  /// No description provided for @productVariantName.
  ///
  /// In en, this message translates to:
  /// **'Option name'**
  String get productVariantName;

  /// No description provided for @productVariantPriceDelta.
  ///
  /// In en, this message translates to:
  /// **'Price difference'**
  String get productVariantPriceDelta;

  /// No description provided for @modifierManagementTitle.
  ///
  /// In en, this message translates to:
  /// **'Modifiers'**
  String get modifierManagementTitle;

  /// No description provided for @modifierGroupAdd.
  ///
  /// In en, this message translates to:
  /// **'Add modifier group'**
  String get modifierGroupAdd;

  /// No description provided for @modifierGroupEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit modifier group'**
  String get modifierGroupEdit;

  /// No description provided for @modifierGroupName.
  ///
  /// In en, this message translates to:
  /// **'Group name'**
  String get modifierGroupName;

  /// No description provided for @modifierGroupEmpty.
  ///
  /// In en, this message translates to:
  /// **'No modifier groups yet'**
  String get modifierGroupEmpty;

  /// No description provided for @modifierGroupEmptyHint.
  ///
  /// In en, this message translates to:
  /// **'Create a group like spice level or toppings to reuse across products'**
  String get modifierGroupEmptyHint;

  /// No description provided for @modifierSelectionType.
  ///
  /// In en, this message translates to:
  /// **'Selection type'**
  String get modifierSelectionType;

  /// No description provided for @modifierSelectionSingle.
  ///
  /// In en, this message translates to:
  /// **'Single choice'**
  String get modifierSelectionSingle;

  /// No description provided for @modifierSelectionMultiple.
  ///
  /// In en, this message translates to:
  /// **'Multiple choice'**
  String get modifierSelectionMultiple;

  /// No description provided for @modifierRequired.
  ///
  /// In en, this message translates to:
  /// **'Required'**
  String get modifierRequired;

  /// No description provided for @modifierRequiredHint.
  ///
  /// In en, this message translates to:
  /// **'The cashier must pick at least one option before adding this product'**
  String get modifierRequiredHint;

  /// No description provided for @modifierMaxSelect.
  ///
  /// In en, this message translates to:
  /// **'Max selections'**
  String get modifierMaxSelect;

  /// No description provided for @modifierMaxSelectHint.
  ///
  /// In en, this message translates to:
  /// **'Leave empty for unlimited'**
  String get modifierMaxSelectHint;

  /// No description provided for @modifierMaxSelectInvalid.
  ///
  /// In en, this message translates to:
  /// **'Must be at least 1'**
  String get modifierMaxSelectInvalid;

  /// No description provided for @modifierOptions.
  ///
  /// In en, this message translates to:
  /// **'Options'**
  String get modifierOptions;

  /// No description provided for @modifierOptionsHint.
  ///
  /// In en, this message translates to:
  /// **'Add at least one option, e.g. Mild, Medium, Spicy'**
  String get modifierOptionsHint;

  /// No description provided for @modifierOptionAdd.
  ///
  /// In en, this message translates to:
  /// **'Add option'**
  String get modifierOptionAdd;

  /// No description provided for @modifierOptionEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit option'**
  String get modifierOptionEdit;

  /// No description provided for @modifierOptionName.
  ///
  /// In en, this message translates to:
  /// **'Option name'**
  String get modifierOptionName;

  /// No description provided for @modifierOptionPriceDelta.
  ///
  /// In en, this message translates to:
  /// **'Extra price'**
  String get modifierOptionPriceDelta;

  /// No description provided for @modifierRequiredNoActiveOptions.
  ///
  /// In en, this message translates to:
  /// **'This group is required but has no active options — products using it will skip it rather than get stuck.'**
  String get modifierRequiredNoActiveOptions;

  /// No description provided for @modifierGroupDeleteConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete this modifier group?'**
  String get modifierGroupDeleteConfirm;

  /// No description provided for @modifierGroupDeleteConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{No products use it.} =1{1 product uses it.} other{{count} products use it.}} Past orders keep what was sold; this only removes it from future sales.'**
  String modifierGroupDeleteConfirmBody(int count);

  /// No description provided for @modifierGroupsSectionTitle.
  ///
  /// In en, this message translates to:
  /// **'Modifier groups'**
  String get modifierGroupsSectionTitle;

  /// No description provided for @modifierGroupsSectionHint.
  ///
  /// In en, this message translates to:
  /// **'Reusable across products — manage them from the Modifiers tab'**
  String get modifierGroupsSectionHint;

  /// No description provided for @modifierOptionCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{0 options} =1{1 option} other{{count} options}}'**
  String modifierOptionCount(int count);

  /// No description provided for @modifierPickTitle.
  ///
  /// In en, this message translates to:
  /// **'Choose modifiers'**
  String get modifierPickTitle;

  /// No description provided for @modifierPickRequiredBadge.
  ///
  /// In en, this message translates to:
  /// **'Required'**
  String get modifierPickRequiredBadge;

  /// No description provided for @modifierPickOptionalBadge.
  ///
  /// In en, this message translates to:
  /// **'Optional'**
  String get modifierPickOptionalBadge;

  /// No description provided for @modifierPickMaxBadge.
  ///
  /// In en, this message translates to:
  /// **'Pick up to {count}'**
  String modifierPickMaxBadge(int count);

  /// No description provided for @modifierAddToCart.
  ///
  /// In en, this message translates to:
  /// **'Add — {price}'**
  String modifierAddToCart(String price);

  /// No description provided for @modifierEditSelections.
  ///
  /// In en, this message translates to:
  /// **'Edit selections'**
  String get modifierEditSelections;

  /// No description provided for @cartLineEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get cartLineEdit;

  /// No description provided for @modifierOptionScopeHint.
  ///
  /// In en, this message translates to:
  /// **'Which {groupName} options apply to this product'**
  String modifierOptionScopeHint(String groupName);

  /// No description provided for @modifierOptionScopeEmpty.
  ///
  /// In en, this message translates to:
  /// **'This group has no active options yet — add some from the Modifiers tab'**
  String get modifierOptionScopeEmpty;

  /// No description provided for @promosTitle.
  ///
  /// In en, this message translates to:
  /// **'Promotions'**
  String get promosTitle;

  /// No description provided for @promosManage.
  ///
  /// In en, this message translates to:
  /// **'Discounts any cashier may apply'**
  String get promosManage;

  /// No description provided for @promoAdd.
  ///
  /// In en, this message translates to:
  /// **'New promotion'**
  String get promoAdd;

  /// No description provided for @promoEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit promotion'**
  String get promoEdit;

  /// No description provided for @promoName.
  ///
  /// In en, this message translates to:
  /// **'Promotion name'**
  String get promoName;

  /// No description provided for @promoKind.
  ///
  /// In en, this message translates to:
  /// **'Type'**
  String get promoKind;

  /// No description provided for @promoKindPercent.
  ///
  /// In en, this message translates to:
  /// **'Percent'**
  String get promoKindPercent;

  /// No description provided for @promoKindAmount.
  ///
  /// In en, this message translates to:
  /// **'Fixed amount'**
  String get promoKindAmount;

  /// No description provided for @promoValue.
  ///
  /// In en, this message translates to:
  /// **'Value'**
  String get promoValue;

  /// No description provided for @promoMinSpend.
  ///
  /// In en, this message translates to:
  /// **'Minimum spend'**
  String get promoMinSpend;

  /// No description provided for @promoMinSpendHint.
  ///
  /// In en, this message translates to:
  /// **'0 for no minimum'**
  String get promoMinSpendHint;

  /// No description provided for @promoActive.
  ///
  /// In en, this message translates to:
  /// **'Active'**
  String get promoActive;

  /// No description provided for @promoInactive.
  ///
  /// In en, this message translates to:
  /// **'Retired'**
  String get promoInactive;

  /// No description provided for @promoEmpty.
  ///
  /// In en, this message translates to:
  /// **'No promotions yet'**
  String get promoEmpty;

  /// No description provided for @promoEmptyHint.
  ///
  /// In en, this message translates to:
  /// **'Create one and every cashier can apply it.'**
  String get promoEmptyHint;

  /// No description provided for @promoDeleteConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete this promotion?'**
  String get promoDeleteConfirm;

  /// No description provided for @promoDeleteConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'Sales that already used it keep their discount.'**
  String get promoDeleteConfirmBody;

  /// No description provided for @promoRequiresMin.
  ///
  /// In en, this message translates to:
  /// **'Needs {amount} minimum'**
  String promoRequiresMin(String amount);

  /// No description provided for @posDiscountTitle.
  ///
  /// In en, this message translates to:
  /// **'Discount'**
  String get posDiscountTitle;

  /// No description provided for @posDiscountNone.
  ///
  /// In en, this message translates to:
  /// **'No discount'**
  String get posDiscountNone;

  /// No description provided for @posDiscountManual.
  ///
  /// In en, this message translates to:
  /// **'Custom'**
  String get posDiscountManual;

  /// No description provided for @posDiscountPercent.
  ///
  /// In en, this message translates to:
  /// **'Percent'**
  String get posDiscountPercent;

  /// No description provided for @posDiscountAmount.
  ///
  /// In en, this message translates to:
  /// **'Amount'**
  String get posDiscountAmount;

  /// No description provided for @posDiscountApprovedBy.
  ///
  /// In en, this message translates to:
  /// **'Approved by {name}'**
  String posDiscountApprovedBy(String name);

  /// No description provided for @posDiscountRemove.
  ///
  /// In en, this message translates to:
  /// **'Remove discount'**
  String get posDiscountRemove;

  /// No description provided for @posDiscountLocked.
  ///
  /// In en, this message translates to:
  /// **'Ask a manager to approve a custom discount'**
  String get posDiscountLocked;

  /// No description provided for @inventoryTitle.
  ///
  /// In en, this message translates to:
  /// **'Inventory'**
  String get inventoryTitle;

  /// No description provided for @inventoryManage.
  ///
  /// In en, this message translates to:
  /// **'Book stock in and out, review movements'**
  String get inventoryManage;

  /// No description provided for @inventoryLowStock.
  ///
  /// In en, this message translates to:
  /// **'Running low'**
  String get inventoryLowStock;

  /// No description provided for @inventoryAllStocked.
  ///
  /// In en, this message translates to:
  /// **'Nothing is running low'**
  String get inventoryAllStocked;

  /// No description provided for @inventoryAllStockedHint.
  ///
  /// In en, this message translates to:
  /// **'Every tracked product is above the threshold.'**
  String get inventoryAllStockedHint;

  /// No description provided for @inventoryAdjust.
  ///
  /// In en, this message translates to:
  /// **'Adjust stock'**
  String get inventoryAdjust;

  /// No description provided for @inventoryIn.
  ///
  /// In en, this message translates to:
  /// **'Stock in'**
  String get inventoryIn;

  /// No description provided for @inventoryOut.
  ///
  /// In en, this message translates to:
  /// **'Stock out'**
  String get inventoryOut;

  /// No description provided for @inventoryQuantity.
  ///
  /// In en, this message translates to:
  /// **'Quantity'**
  String get inventoryQuantity;

  /// No description provided for @inventoryReason.
  ///
  /// In en, this message translates to:
  /// **'Reason'**
  String get inventoryReason;

  /// No description provided for @inventoryNoteHint.
  ///
  /// In en, this message translates to:
  /// **'Note (optional)'**
  String get inventoryNoteHint;

  /// No description provided for @inventoryHistory.
  ///
  /// In en, this message translates to:
  /// **'Movement history'**
  String get inventoryHistory;

  /// No description provided for @inventoryHistoryEmpty.
  ///
  /// In en, this message translates to:
  /// **'No movements recorded yet'**
  String get inventoryHistoryEmpty;

  /// No description provided for @inventoryAdjusted.
  ///
  /// In en, this message translates to:
  /// **'Stock updated to {count}'**
  String inventoryAdjusted(int count);

  /// No description provided for @inventoryPickProduct.
  ///
  /// In en, this message translates to:
  /// **'Choose a product'**
  String get inventoryPickProduct;

  /// No description provided for @inventoryTrackedOnly.
  ///
  /// In en, this message translates to:
  /// **'Only stock-tracked products appear here.'**
  String get inventoryTrackedOnly;

  /// No description provided for @inventoryBalance.
  ///
  /// In en, this message translates to:
  /// **'Balance {count}'**
  String inventoryBalance(int count);

  /// No description provided for @stockReasonSale.
  ///
  /// In en, this message translates to:
  /// **'Sold'**
  String get stockReasonSale;

  /// No description provided for @stockReasonVoidReturn.
  ///
  /// In en, this message translates to:
  /// **'Returned'**
  String get stockReasonVoidReturn;

  /// No description provided for @stockReasonReceived.
  ///
  /// In en, this message translates to:
  /// **'Received'**
  String get stockReasonReceived;

  /// No description provided for @stockReasonWaste.
  ///
  /// In en, this message translates to:
  /// **'Waste'**
  String get stockReasonWaste;

  /// No description provided for @stockReasonCorrection.
  ///
  /// In en, this message translates to:
  /// **'Recount'**
  String get stockReasonCorrection;

  /// No description provided for @stockReasonOpening.
  ///
  /// In en, this message translates to:
  /// **'Opening'**
  String get stockReasonOpening;

  /// No description provided for @productTaxRate.
  ///
  /// In en, this message translates to:
  /// **'Tax rate (%)'**
  String get productTaxRate;

  /// No description provided for @productTaxRateHint.
  ///
  /// In en, this message translates to:
  /// **'Empty uses the store rate'**
  String get productTaxRateHint;

  /// No description provided for @productTaxStore.
  ///
  /// In en, this message translates to:
  /// **'Store rate'**
  String get productTaxStore;

  /// No description provided for @reportProfit.
  ///
  /// In en, this message translates to:
  /// **'Gross profit'**
  String get reportProfit;

  /// No description provided for @reportCostOfGoods.
  ///
  /// In en, this message translates to:
  /// **'Cost of goods'**
  String get reportCostOfGoods;

  /// No description provided for @reportMargin.
  ///
  /// In en, this message translates to:
  /// **'Margin'**
  String get reportMargin;

  /// No description provided for @reportProfitCaveat.
  ///
  /// In en, this message translates to:
  /// **'Gross profit only — rent, wages and utilities are not tracked here.'**
  String get reportProfitCaveat;

  /// No description provided for @reportCostCoverage.
  ///
  /// In en, this message translates to:
  /// **'Based on {percent}% of sold items having a cost recorded'**
  String reportCostCoverage(int percent);

  /// No description provided for @reportRefunded.
  ///
  /// In en, this message translates to:
  /// **'Refunded'**
  String get reportRefunded;

  /// No description provided for @reportByCategory.
  ///
  /// In en, this message translates to:
  /// **'By category'**
  String get reportByCategory;

  /// No description provided for @reportCategoryCaveat.
  ///
  /// In en, this message translates to:
  /// **'Pre-tax and pre-service-charge — totals match Subtotal minus Discount.'**
  String get reportCategoryCaveat;

  /// No description provided for @reportUncategorized.
  ///
  /// In en, this message translates to:
  /// **'Uncategorized'**
  String get reportUncategorized;

  /// No description provided for @reportGrossSales.
  ///
  /// In en, this message translates to:
  /// **'Gross sales'**
  String get reportGrossSales;

  /// No description provided for @reportNetSales.
  ///
  /// In en, this message translates to:
  /// **'Net sales'**
  String get reportNetSales;

  /// No description provided for @reportContribution.
  ///
  /// In en, this message translates to:
  /// **'Contribution %'**
  String get reportContribution;

  /// No description provided for @shiftDrawerNow.
  ///
  /// In en, this message translates to:
  /// **'Cash drawer now'**
  String get shiftDrawerNow;

  /// No description provided for @shiftDrawerNowHint.
  ///
  /// In en, this message translates to:
  /// **'Opening float plus cash taken so far this shift.'**
  String get shiftDrawerNowHint;

  /// No description provided for @posSwitchCashier.
  ///
  /// In en, this message translates to:
  /// **'Switch cashier'**
  String get posSwitchCashier;

  /// No description provided for @posSwitchCashierHint.
  ///
  /// In en, this message translates to:
  /// **'Enter your PIN to take the till. Your name goes on every sale from now on.'**
  String get posSwitchCashierHint;

  /// No description provided for @posSwitchCashierPickHint.
  ///
  /// In en, this message translates to:
  /// **'Pick who is taking the till. Their name goes on every sale from now on.'**
  String get posSwitchCashierPickHint;

  /// No description provided for @posOnDuty.
  ///
  /// In en, this message translates to:
  /// **'On duty'**
  String get posOnDuty;

  /// No description provided for @posSwitchedTo.
  ///
  /// In en, this message translates to:
  /// **'{name} is now on the till'**
  String posSwitchedTo(String name);

  /// No description provided for @registersTitle.
  ///
  /// In en, this message translates to:
  /// **'POS / Registers'**
  String get registersTitle;

  /// No description provided for @registersSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Tills at this branch, and what each one is for'**
  String get registersSubtitle;

  /// No description provided for @registersManage.
  ///
  /// In en, this message translates to:
  /// **'Manage POS'**
  String get registersManage;

  /// No description provided for @registersEmpty.
  ///
  /// In en, this message translates to:
  /// **'This branch has no POS yet'**
  String get registersEmpty;

  /// No description provided for @registerAdd.
  ///
  /// In en, this message translates to:
  /// **'Add POS'**
  String get registerAdd;

  /// No description provided for @registerEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit POS'**
  String get registerEdit;

  /// No description provided for @registerName.
  ///
  /// In en, this message translates to:
  /// **'POS name'**
  String get registerName;

  /// No description provided for @registerNameTaken.
  ///
  /// In en, this message translates to:
  /// **'Another POS at this branch already uses that name'**
  String get registerNameTaken;

  /// No description provided for @registerTableService.
  ///
  /// In en, this message translates to:
  /// **'Table service'**
  String get registerTableService;

  /// No description provided for @registerActive.
  ///
  /// In en, this message translates to:
  /// **'Active'**
  String get registerActive;

  /// No description provided for @registerRetired.
  ///
  /// In en, this message translates to:
  /// **'Retired'**
  String get registerRetired;

  /// No description provided for @registerKeepOneActive.
  ///
  /// In en, this message translates to:
  /// **'At least one POS has to stay active'**
  String get registerKeepOneActive;

  /// No description provided for @registerDeleteConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete this POS?'**
  String get registerDeleteConfirm;

  /// No description provided for @registerDeleteConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'It disappears from the list. Sales already recorded keep its name.'**
  String get registerDeleteConfirmBody;

  /// No description provided for @registerHasHistory.
  ///
  /// In en, this message translates to:
  /// **'This POS has sessions or sales, so it cannot be deleted. Retire it instead.'**
  String get registerHasHistory;

  /// No description provided for @sessionPickTitle.
  ///
  /// In en, this message translates to:
  /// **'Which POS are you opening?'**
  String get sessionPickTitle;

  /// No description provided for @sessionPickHint.
  ///
  /// In en, this message translates to:
  /// **'Sales you ring up land in this POS drawer until you close it'**
  String get sessionPickHint;

  /// No description provided for @sessionResume.
  ///
  /// In en, this message translates to:
  /// **'Resume'**
  String get sessionResume;

  /// No description provided for @sessionNeedsRecovery.
  ///
  /// In en, this message translates to:
  /// **'Cannot be resumed — needs a manager'**
  String get sessionNeedsRecovery;

  /// No description provided for @sessionNeedsRecoveryHint.
  ///
  /// In en, this message translates to:
  /// **'This drawer is open but the server holds no claim for it, so it cannot be resumed or closed here. Ask a manager to close it from Backoffice → Devices.'**
  String get sessionNeedsRecoveryHint;

  /// No description provided for @sessionReconciled.
  ///
  /// In en, this message translates to:
  /// **'The drawer now matches the server and can be resumed.'**
  String get sessionReconciled;

  /// No description provided for @sessionClosedForRecovery.
  ///
  /// In en, this message translates to:
  /// **'The old drawer was closed from the server. Review any held transactions in the Recovery centre.'**
  String get sessionClosedForRecovery;

  /// No description provided for @sessionInUse.
  ///
  /// In en, this message translates to:
  /// **'In use by {name}'**
  String sessionInUse(String name);

  /// No description provided for @sessionNoRegisters.
  ///
  /// In en, this message translates to:
  /// **'No POS is set up for this outlet yet'**
  String get sessionNoRegisters;

  /// No description provided for @sessionBusy.
  ///
  /// In en, this message translates to:
  /// **'{name} already has that POS open'**
  String sessionBusy(String name);

  /// No description provided for @shiftRegister.
  ///
  /// In en, this message translates to:
  /// **'POS'**
  String get shiftRegister;

  /// No description provided for @shiftClosedBy.
  ///
  /// In en, this message translates to:
  /// **'Closed by {name}'**
  String shiftClosedBy(String name);

  /// No description provided for @shiftNoRegister.
  ///
  /// In en, this message translates to:
  /// **'Opened before POS were set up'**
  String get shiftNoRegister;

  /// No description provided for @orderPos.
  ///
  /// In en, this message translates to:
  /// **'POS'**
  String get orderPos;

  /// No description provided for @shiftCloseConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Confirm your PIN'**
  String get shiftCloseConfirmTitle;

  /// No description provided for @shiftCloseConfirmHint.
  ///
  /// In en, this message translates to:
  /// **'Enter your PIN to close this session.'**
  String get shiftCloseConfirmHint;

  /// No description provided for @settingsLogoutBlockedTitle.
  ///
  /// In en, this message translates to:
  /// **'Close your session first'**
  String get settingsLogoutBlockedTitle;

  /// No description provided for @settingsLogoutBlockedBody.
  ///
  /// In en, this message translates to:
  /// **'You still have an open POS session. Close it and count the drawer before signing out.'**
  String get settingsLogoutBlockedBody;

  /// No description provided for @settingsLogoutBlockedAction.
  ///
  /// In en, this message translates to:
  /// **'Close session'**
  String get settingsLogoutBlockedAction;

  /// No description provided for @modifierSaveFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not save. Check the modifier options and try again.'**
  String get modifierSaveFailed;

  /// No description provided for @modifierConfigure.
  ///
  /// In en, this message translates to:
  /// **'Configure modifiers'**
  String get modifierConfigure;

  /// No description provided for @modifierSearchGroups.
  ///
  /// In en, this message translates to:
  /// **'Search modifier groups'**
  String get modifierSearchGroups;

  /// No description provided for @modifierDefaultOption.
  ///
  /// In en, this message translates to:
  /// **'Default option'**
  String get modifierDefaultOption;

  /// No description provided for @modifierDefaultsHint.
  ///
  /// In en, this message translates to:
  /// **'Select applicable options. Star the defaults. Missing required defaults are chosen at the till; tap a cart item to customize.'**
  String get modifierDefaultsHint;

  /// No description provided for @modifierConfigSummary.
  ///
  /// In en, this message translates to:
  /// **'{options} options · {defaults} defaults'**
  String modifierConfigSummary(int options, int defaults);

  /// No description provided for @activationTitle.
  ///
  /// In en, this message translates to:
  /// **'Activate this device'**
  String get activationTitle;

  /// No description provided for @activationComplete.
  ///
  /// In en, this message translates to:
  /// **'Device activated'**
  String get activationComplete;

  /// No description provided for @activationInstructions.
  ///
  /// In en, this message translates to:
  /// **'Enter the activation code created for this register in Backoffice.'**
  String get activationInstructions;

  /// No description provided for @activationCodeLabel.
  ///
  /// In en, this message translates to:
  /// **'Activation code'**
  String get activationCodeLabel;

  /// No description provided for @activationNextPhase.
  ///
  /// In en, this message translates to:
  /// **'This device is linked to the outlet and register above. The catalogue and staff come from the server, and sales upload automatically; demo accounts are kept separate.'**
  String get activationNextPhase;

  /// No description provided for @activationInvalid.
  ///
  /// In en, this message translates to:
  /// **'This code is invalid, expired, or already used. Request a new code from Backoffice.'**
  String get activationInvalid;

  /// No description provided for @activationRateLimited.
  ///
  /// In en, this message translates to:
  /// **'Too many attempts. Wait a minute before trying again.'**
  String get activationRateLimited;

  /// No description provided for @activationNetwork.
  ///
  /// In en, this message translates to:
  /// **'Unable to reach the server. Check the connection. If activation already succeeded on the server, request a new code.'**
  String get activationNetwork;

  /// No description provided for @activationStorage.
  ///
  /// In en, this message translates to:
  /// **'Unable to read or save device credentials. Retry loading the saved activation, or request a new code.'**
  String get activationStorage;

  /// No description provided for @activationRevoked.
  ///
  /// In en, this message translates to:
  /// **'Device access has ended. Request a new activation code from Backoffice.'**
  String get activationRevoked;

  /// No description provided for @activationConfiguration.
  ///
  /// In en, this message translates to:
  /// **'The backend address is invalid. Configure an HTTPS API address.'**
  String get activationConfiguration;

  /// No description provided for @activationContinue.
  ///
  /// In en, this message translates to:
  /// **'Continue to sign in'**
  String get activationContinue;

  /// No description provided for @activationSubmit.
  ///
  /// In en, this message translates to:
  /// **'Activate device'**
  String get activationSubmit;

  /// No description provided for @activationRetry.
  ///
  /// In en, this message translates to:
  /// **'Reload saved activation'**
  String get activationRetry;

  /// No description provided for @authorizePickHint.
  ///
  /// In en, this message translates to:
  /// **'Choose who is approving, then enter their PIN'**
  String get authorizePickHint;

  /// No description provided for @syncTitle.
  ///
  /// In en, this message translates to:
  /// **'Server sync'**
  String get syncTitle;

  /// No description provided for @syncStatus.
  ///
  /// In en, this message translates to:
  /// **'Sync status'**
  String get syncStatus;

  /// No description provided for @syncNever.
  ///
  /// In en, this message translates to:
  /// **'Not synced yet'**
  String get syncNever;

  /// No description provided for @syncRunning.
  ///
  /// In en, this message translates to:
  /// **'Syncing…'**
  String get syncRunning;

  /// No description provided for @syncLastSuccess.
  ///
  /// In en, this message translates to:
  /// **'Last synced at {time}'**
  String syncLastSuccess(String time);

  /// No description provided for @syncFailed.
  ///
  /// In en, this message translates to:
  /// **'The last attempt failed. Everything stays on this device and is retried automatically.'**
  String get syncFailed;

  /// No description provided for @syncUpdateRequired.
  ///
  /// In en, this message translates to:
  /// **'This app version is too old for the server. Update the app to keep syncing.'**
  String get syncUpdateRequired;

  /// No description provided for @syncPending.
  ///
  /// In en, this message translates to:
  /// **'Waiting to upload'**
  String get syncPending;

  /// No description provided for @syncPendingValue.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{Nothing waiting} =1{1 record} other{{count} records}}'**
  String syncPendingValue(int count);

  /// No description provided for @syncRejected.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 record refused by the server} other{{count} records refused by the server}}'**
  String syncRejected(int count);

  /// No description provided for @syncRejectedRetry.
  ///
  /// In en, this message translates to:
  /// **'Kept on this device. Tap to send them again.'**
  String get syncRejectedRetry;

  /// No description provided for @syncNow.
  ///
  /// In en, this message translates to:
  /// **'Sync now'**
  String get syncNow;

  /// No description provided for @syncNowHint.
  ///
  /// In en, this message translates to:
  /// **'Upload sales and download changes'**
  String get syncNowHint;

  /// No description provided for @tillBindingMismatch.
  ///
  /// In en, this message translates to:
  /// **'This device is activated for a different register or outlet. Nothing was saved.'**
  String get tillBindingMismatch;

  /// No description provided for @stockReasonCount.
  ///
  /// In en, this message translates to:
  /// **'Stock count'**
  String get stockReasonCount;

  /// No description provided for @stockReasonTransferIn.
  ///
  /// In en, this message translates to:
  /// **'Transfer in'**
  String get stockReasonTransferIn;

  /// No description provided for @stockReasonTransferOut.
  ///
  /// In en, this message translates to:
  /// **'Transfer out'**
  String get stockReasonTransferOut;

  /// No description provided for @inventoryCount.
  ///
  /// In en, this message translates to:
  /// **'Save count'**
  String get inventoryCount;

  /// No description provided for @inventoryCountedQuantity.
  ///
  /// In en, this message translates to:
  /// **'Counted quantity'**
  String get inventoryCountedQuantity;

  /// No description provided for @recoveryTitle.
  ///
  /// In en, this message translates to:
  /// **'Recovery centre'**
  String get recoveryTitle;

  /// No description provided for @recoveryIntro.
  ///
  /// In en, this message translates to:
  /// **'No evidence is ever removed automatically. Selling stays blocked on a drawer that needs recovery.'**
  String get recoveryIntro;

  /// No description provided for @recoveryLocalStatus.
  ///
  /// In en, this message translates to:
  /// **'This device: {status}'**
  String recoveryLocalStatus(String status);

  /// No description provided for @recoveryStatusHealthy.
  ///
  /// In en, this message translates to:
  /// **'nothing outstanding'**
  String get recoveryStatusHealthy;

  /// No description provided for @recoveryStatusPending.
  ///
  /// In en, this message translates to:
  /// **'waiting to upload'**
  String get recoveryStatusPending;

  /// No description provided for @recoveryStatusConflict.
  ///
  /// In en, this message translates to:
  /// **'needs investigation'**
  String get recoveryStatusConflict;

  /// No description provided for @recoveryStatusRecoveryRequired.
  ///
  /// In en, this message translates to:
  /// **'waiting for a manager'**
  String get recoveryStatusRecoveryRequired;

  /// No description provided for @recoverySectionHeading.
  ///
  /// In en, this message translates to:
  /// **'{label} ({count})'**
  String recoverySectionHeading(String label, int count);

  /// No description provided for @recoverySectionQueued.
  ///
  /// In en, this message translates to:
  /// **'Safe for the scheduler to retry'**
  String get recoverySectionQueued;

  /// No description provided for @recoverySectionQueuedEmpty.
  ///
  /// In en, this message translates to:
  /// **'The upload queue is empty.'**
  String get recoverySectionQueuedEmpty;

  /// No description provided for @recoverySectionManager.
  ///
  /// In en, this message translates to:
  /// **'Waiting for a manager'**
  String get recoverySectionManager;

  /// No description provided for @recoverySectionManagerEmpty.
  ///
  /// In en, this message translates to:
  /// **'Nothing is waiting for a manager.'**
  String get recoverySectionManagerEmpty;

  /// No description provided for @recoverySectionInvestigate.
  ///
  /// In en, this message translates to:
  /// **'Refused, and not sendable from here'**
  String get recoverySectionInvestigate;

  /// No description provided for @recoverySectionInvestigateEmpty.
  ///
  /// In en, this message translates to:
  /// **'No payload needs investigating.'**
  String get recoverySectionInvestigateEmpty;

  /// No description provided for @recoverySectionDiagnostics.
  ///
  /// In en, this message translates to:
  /// **'Diagnostic findings'**
  String get recoverySectionDiagnostics;

  /// No description provided for @recoveryQueuedDetail.
  ///
  /// In en, this message translates to:
  /// **'revision {revision} · {attempts} attempts'**
  String recoveryQueuedDetail(String revision, int attempts);

  /// No description provided for @recoveryLetterDetail.
  ///
  /// In en, this message translates to:
  /// **'{code} · revision {revision}'**
  String recoveryLetterDetail(String code, int revision);

  /// No description provided for @recoveryNoServerMessage.
  ///
  /// In en, this message translates to:
  /// **'The server sent no message.'**
  String get recoveryNoServerMessage;

  /// No description provided for @recoveryCaseLine.
  ///
  /// In en, this message translates to:
  /// **'Case {id}'**
  String recoveryCaseLine(String id);

  /// No description provided for @recoveryCaseLineWithStatus.
  ///
  /// In en, this message translates to:
  /// **'Case {id} · {status}'**
  String recoveryCaseLineWithStatus(String id, String status);

  /// No description provided for @recoveryRetry.
  ///
  /// In en, this message translates to:
  /// **'Send again'**
  String get recoveryRetry;

  /// No description provided for @recoveryRequeued.
  ///
  /// In en, this message translates to:
  /// **'Returned to the upload queue.'**
  String get recoveryRequeued;

  /// No description provided for @recoveryNotRetryable.
  ///
  /// In en, this message translates to:
  /// **'Not sendable yet: its local row is gone, or a manager has not approved it.'**
  String get recoveryNotRetryable;

  /// No description provided for @recoveryActionWaitForScheduler.
  ///
  /// In en, this message translates to:
  /// **'Leave it to the scheduler, or tap Sync now.'**
  String get recoveryActionWaitForScheduler;

  /// No description provided for @recoveryActionWaitForManager.
  ///
  /// In en, this message translates to:
  /// **'Wait for the manager\'s decision in the Backoffice before sending this one again.'**
  String get recoveryActionWaitForManager;

  /// No description provided for @recoveryActionIncompatible.
  ///
  /// In en, this message translates to:
  /// **'The server cannot accept this payload. Keep it and investigate.'**
  String get recoveryActionIncompatible;

  /// No description provided for @recoveryActionKeepSnapshot.
  ///
  /// In en, this message translates to:
  /// **'Keep the queued snapshot and inspect it by hand.'**
  String get recoveryActionKeepSnapshot;

  /// No description provided for @recoveryActionCheckTillMigration.
  ///
  /// In en, this message translates to:
  /// **'Keep the state and check the local session migration.'**
  String get recoveryActionCheckTillMigration;

  /// No description provided for @recoveryActionBlockedUntilDecided.
  ///
  /// In en, this message translates to:
  /// **'Selling stays blocked until this recovery is decided in the Backoffice.'**
  String get recoveryActionBlockedUntilDecided;

  /// No description provided for @recoveryActionMatchMovement.
  ///
  /// In en, this message translates to:
  /// **'Do not delete the movement; match it against its receipt payload.'**
  String get recoveryActionMatchMovement;

  /// No description provided for @recoveryActionFinishDependencies.
  ///
  /// In en, this message translates to:
  /// **'Finish the pending sales and refusals before the close is sent.'**
  String get recoveryActionFinishDependencies;

  /// No description provided for @recoveryActionReconcileBySigningIn.
  ///
  /// In en, this message translates to:
  /// **'This drawer predates coordinated tills. Sign in with a PIN while online and the server will reconcile it.'**
  String get recoveryActionReconcileBySigningIn;

  /// No description provided for @historyPeriodToday.
  ///
  /// In en, this message translates to:
  /// **'Today'**
  String get historyPeriodToday;

  /// No description provided for @historyPeriodYesterday.
  ///
  /// In en, this message translates to:
  /// **'Yesterday'**
  String get historyPeriodYesterday;

  /// No description provided for @historyPeriodLast7.
  ///
  /// In en, this message translates to:
  /// **'7 days'**
  String get historyPeriodLast7;

  /// No description provided for @historyPeriodMonth.
  ///
  /// In en, this message translates to:
  /// **'This month'**
  String get historyPeriodMonth;

  /// No description provided for @historyPeriodCustom.
  ///
  /// In en, this message translates to:
  /// **'Custom range'**
  String get historyPeriodCustom;

  /// No description provided for @historyReceiptSearch.
  ///
  /// In en, this message translates to:
  /// **'Receipt number'**
  String get historyReceiptSearch;

  /// No description provided for @historyScopeRegister.
  ///
  /// In en, this message translates to:
  /// **'This till'**
  String get historyScopeRegister;

  /// No description provided for @historyScopeOutlet.
  ///
  /// In en, this message translates to:
  /// **'Whole outlet'**
  String get historyScopeOutlet;

  /// No description provided for @historyScopeNarrowed.
  ///
  /// In en, this message translates to:
  /// **'The server returned this till only; your account cannot read the whole outlet.'**
  String get historyScopeNarrowed;

  /// No description provided for @historyLoadMore.
  ///
  /// In en, this message translates to:
  /// **'Load more'**
  String get historyLoadMore;

  /// No description provided for @historyEndOfList.
  ///
  /// In en, this message translates to:
  /// **'End of the list for this filter.'**
  String get historyEndOfList;

  /// No description provided for @historyOffline.
  ///
  /// In en, this message translates to:
  /// **'Offline — showing what was downloaded {when}.'**
  String historyOffline(String when);

  /// No description provided for @historyOfflineMissing.
  ///
  /// In en, this message translates to:
  /// **'Not downloaded yet. Connect to load this period.'**
  String get historyOfflineMissing;

  /// No description provided for @historyLocalOnly.
  ///
  /// In en, this message translates to:
  /// **'This device\'s own transactions only.'**
  String get historyLocalOnly;

  /// No description provided for @historyRangeIncomplete.
  ///
  /// In en, this message translates to:
  /// **'Only part of this period was downloaded. Refresh while online to complete it.'**
  String get historyRangeIncomplete;

  /// No description provided for @historyFilterApply.
  ///
  /// In en, this message translates to:
  /// **'Apply'**
  String get historyFilterApply;

  /// No description provided for @historyFilterReset.
  ///
  /// In en, this message translates to:
  /// **'Reset'**
  String get historyFilterReset;

  /// No description provided for @historyFrom.
  ///
  /// In en, this message translates to:
  /// **'From'**
  String get historyFrom;

  /// No description provided for @historyTo.
  ///
  /// In en, this message translates to:
  /// **'To'**
  String get historyTo;

  /// No description provided for @reportPeriodCompare.
  ///
  /// In en, this message translates to:
  /// **'vs previous {days} days'**
  String reportPeriodCompare(int days);

  /// No description provided for @reportNoComparison.
  ///
  /// In en, this message translates to:
  /// **'no comparison'**
  String get reportNoComparison;

  /// No description provided for @reportSalesReturns.
  ///
  /// In en, this message translates to:
  /// **'Sales returns'**
  String get reportSalesReturns;

  /// No description provided for @reportTotalReceipts.
  ///
  /// In en, this message translates to:
  /// **'Total sales receipts'**
  String get reportTotalReceipts;

  /// No description provided for @reportGrossMargin.
  ///
  /// In en, this message translates to:
  /// **'Gross margin'**
  String get reportGrossMargin;

  /// No description provided for @reportWaterfall.
  ///
  /// In en, this message translates to:
  /// **'Sales waterfall'**
  String get reportWaterfall;

  /// No description provided for @reportSourceServer.
  ///
  /// In en, this message translates to:
  /// **'Outlet totals from the server, computed {when}.'**
  String reportSourceServer(String when);

  /// No description provided for @reportSourceCache.
  ///
  /// In en, this message translates to:
  /// **'Offline — server totals downloaded {when}.'**
  String reportSourceCache(String when);

  /// No description provided for @reportSourceUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Outlet totals are not available offline yet. Connect once to download them.'**
  String get reportSourceUnavailable;

  /// No description provided for @reportSourceLocal.
  ///
  /// In en, this message translates to:
  /// **'This device\'s own transactions.'**
  String get reportSourceLocal;

  /// No description provided for @reportUnsyncedNotice.
  ///
  /// In en, this message translates to:
  /// **'{count} transactions on this device have not reached the server and are not in the totals above.'**
  String reportUnsyncedNotice(int count);

  /// No description provided for @reportIncomplete.
  ///
  /// In en, this message translates to:
  /// **'Some days in this period are still being recalculated; the waterfall is not final yet.'**
  String get reportIncomplete;

  /// No description provided for @reportByWeekday.
  ///
  /// In en, this message translates to:
  /// **'Day of week'**
  String get reportByWeekday;

  /// No description provided for @reportTopItemsInCategory.
  ///
  /// In en, this message translates to:
  /// **'Top items per category'**
  String get reportTopItemsInCategory;

  /// No description provided for @reportOutletComparison.
  ///
  /// In en, this message translates to:
  /// **'Outlet comparison'**
  String get reportOutletComparison;

  /// No description provided for @reportNotPermitted.
  ///
  /// In en, this message translates to:
  /// **'Your account cannot open this report.'**
  String get reportNotPermitted;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'id'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'id':
      return AppLocalizationsId();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
