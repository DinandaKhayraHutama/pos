package views

import (
	"slices"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/reporting"
	"strconv"
	"strings"
)

func pluralDevices(n int) string {
	if n == 1 {
		return "1 perangkat"
	}
	return strconv.Itoa(n) + " perangkat"
}

func int64String(n int64) string { return strconv.FormatInt(n, 10) }

// View models are deliberately separate from the domain types where a domain
// type could carry something that must not leave the server: a template that
// takes such a struct will happily render a field the moment someone adds one.
// The read models the catalogue, promo, outlet and staff screens render are
// display-only by construction — staff.Profile says whether a PIN is set, never
// what it is — so those are rendered as they are.
type Session struct {
	EmployeeName string
	Role         string
	BusinessName string
	CSRFToken    string
	// Path is the request path, so the sidebar can light the entry the person
	// is actually looking at. Set from the request, never from a link.
	Path string
	// Which sections this person may open. Asked of permissions, never of the
	// role, so the nav cannot drift from what the routes actually allow.
	CanCatalogue bool
	CanCustomers bool
	CanPromos    bool
	CanStaff     bool
	CanOutlets   bool
	CanStock     bool
	CanDashboard bool
	CanReports   bool
	// The two read-only history sections. Separate flags rather than one,
	// because they ask for different permissions: reading somebody else's
	// sales and looking inside a cash drawer are not the same question.
	CanTransactions bool
	CanShifts       bool
	// CanTables and CanExports are modules the platform can switch off per
	// merchant; the sections above that are sold as modules fold the switch in.
	CanTables  bool
	CanExports bool
	// CanSettings opens the Fase 3 business configuration (manageSettings).
	CanSettings bool
	// CanDiscounts is managePromos without the promos module switch: named
	// discounts are not sold separately.
	CanDiscounts bool
	// Impersonation is set while a platform admin is signed in as this owner.
	// Every page shows it, and nothing about it can be dismissed.
	Impersonation *ImpersonationBanner
}

type ImpersonationBanner struct {
	AdminName    string
	EmployeeName string
	Reason       string
	EndsAt       string
}

// SetupAccount names whose password a first sign-in link sets.
type SetupAccount struct {
	BusinessName string
	OwnerName    string
	Email        string
}

type Register struct {
	ID                string
	Name              string
	OutletName        string
	Active            bool
	TableService      bool
	DeviceCount       int
	OperationID       string
	ActiveSessionID   string
	ActiveDeviceID    string
	ActiveDeviceLabel string
	ActiveCashier     string
	ActiveSince       string
}

type Device struct {
	ID           string
	Label        string
	Platform     string
	RegisterName string
	OutletName   string
	LastSeen     string
	Revoked      bool
	// Outdated is a build that has not reported every Fase 3 capability
	// (pricing-v2, roles-v1): while it is active the Backoffice refuses to
	// switch an outlet to v2 pricing or assign a custom role.
	Outdated bool
}

type IssuedCode struct {
	RegisterName string
	Code         string
	ExpiresIn    string
}

type RecoveryItem struct {
	ID             string
	Entity         string
	EntityID       string
	Revision       int64
	Status         string
	BusinessDate   string
	PaymentMethod  string
	Total          int64
	StockEffects   int
	DecisionReason string
}

type Recovery struct {
	ID                   string
	SessionID            string
	RegisterName         string
	OutletName           string
	DeviceLabel          string
	Status               string
	Reason               string
	ActorName            string
	ForcedAt             string
	OrderCountAtTakeover int64
	ExpectedCash         int64
	CountedCash          *int64
	ReconciliationBasis  string
	Items                []RecoveryItem
}

type DiagnosticFinding struct {
	Classification string
	Code           string
	Entity         string
	EntityID       string
	Action         string
}

// Form is what a form renders from: the raw strings, not parsed values.
//
// Re-rendering a rejected form from parsed values would turn "25.000,-" into 0
// beside the message saying it was wrong — the person would no longer see what
// they typed. So a form round-trips exactly what arrived, and the errors sit
// beside it keyed by input name.
type Form struct {
	Values map[string]string
	// Multi holds checkbox groups, which submit a name more than once.
	Multi  map[string][]string
	Errors map[string]string
}

func NewForm() Form {
	return Form{Values: map[string]string{}, Multi: map[string][]string{}, Errors: map[string]string{}}
}

func (f Form) V(name string) string     { return f.Values[name] }
func (f Form) E(name string) string     { return f.Errors[name] }
func (f Form) Checked(name string) bool { return f.Values[name] == "on" }
func (f Form) Has(name, value string) bool {
	return slices.Contains(f.Multi[name], value)
}

// Rupiah formats integer rupiah the way a receipt does: "Rp 25.000".
func Rupiah(amount int64) string {
	negative := amount < 0
	if negative {
		amount = -amount
	}

	digits := strconv.FormatInt(amount, 10)
	var b strings.Builder
	for i, d := range digits {
		if i > 0 && (len(digits)-i)%3 == 0 {
			b.WriteByte('.')
		}
		b.WriteRune(d)
	}

	if negative {
		return "−Rp " + b.String()
	}
	return "Rp " + b.String()
}

// SignedRupiah shows a delta with its direction, so "+Rp 5.000" and
// "−Rp 3.000" read as adjustments rather than prices.
func SignedRupiah(delta int64) string {
	if delta > 0 {
		return "+" + Rupiah(delta)
	}
	return Rupiah(delta)
}

type Option struct {
	Value string
	Label string
	// System is set when the option is a built-in role, so a form can default
	// to the cashier role by what it is rather than by its id.
	System string
}

var RoleOptions = []Option{
	{Value: "cashier", Label: "Kasir"},
	{Value: "manager", Label: "Manajer"},
	{Value: "owner", Label: "Owner"},
}

func RoleLabel(role string) string {
	for _, o := range RoleOptions {
		if o.Value == role {
			return o.Label
		}
	}
	return role
}

// PermissionGroup is one block of checkboxes on the role form. Values are the
// wire names shared with the till (internal/domain/auth); labels say what a
// person may DO, because that is what an owner is deciding.
type PermissionGroup struct {
	Label   string
	Options []Option
}

var PermissionGroups = []PermissionGroup{
	{Label: "Kasir", Options: []Option{
		{Value: "sell", Label: "Berjualan di kasir"},
		{Value: "openCloseShift", Label: "Membuka dan menutup shift"},
		{Value: "manageTables", Label: "Mengatur meja (duduk dan kosongkan)"},
		{Value: "viewOwnOrders", Label: "Melihat transaksi sendiri hari ini"},
		{Value: "enterCustomAmount", Label: "Memasukkan nominal bebas (custom amount)"},
	}},
	{Label: "Pengawasan", Options: []Option{
		{Value: "viewAllOrders", Label: "Melihat semua transaksi"},
		{Value: "voidOrder", Label: "Membatalkan transaksi"},
		{Value: "refundOrder", Label: "Refund transaksi"},
		{Value: "applyManualDiscount", Label: "Memberi diskon manual"},
		{Value: "viewCashDrawer", Label: "Melihat laci kas semua shift"},
		{Value: "viewDailySummary", Label: "Melihat ringkasan penjualan"},
		{Value: "viewFinancialReports", Label: "Melihat laporan keuangan (HPP dan laba)"},
	}},
	{Label: "Pengelolaan", Options: []Option{
		{Value: "manageCatalogue", Label: "Mengelola produk dan harga"},
		{Value: "managePromos", Label: "Mengelola promo dan diskon"},
		{Value: "adjustStock", Label: "Menyesuaikan stok"},
		{Value: "manageCustomers", Label: "Mengelola pelanggan"},
		{Value: "manageEmployees", Label: "Mengelola karyawan dan peran"},
		{Value: "manageOutlets", Label: "Mengelola outlet dan perangkat"},
		{Value: "manageSettings", Label: "Mengubah pengaturan bisnis"},
	}},
}

// PermissionLabel is the label a permission is shown with.
func PermissionLabel(name string) string {
	for _, g := range PermissionGroups {
		for _, o := range g.Options {
			if o.Value == name {
				return o.Label
			}
		}
	}
	return name
}

// SalesTypeLabel names a sales type on a report (reporting.SalesTypeLabel).
func SalesTypeLabel(name string) string { return reporting.SalesTypeLabel(name) }
