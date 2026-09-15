package views

import (
	"slices"
	"strconv"
	"strings"
)

func pluralDevices(n int) string {
	if n == 1 {
		return "1 perangkat"
	}
	return strconv.Itoa(n) + " perangkat"
}

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
	// Which sections this person may open. Asked of permissions, never of the
	// role, so the nav cannot drift from what the routes actually allow.
	CanCatalogue bool
	CanPromos    bool
	CanStaff     bool
	CanOutlets   bool
	CanStock     bool
	CanDashboard bool
	CanReports   bool
}

type Register struct {
	ID           string
	Name         string
	OutletName   string
	Active       bool
	TableService bool
	DeviceCount  int
}

type Device struct {
	ID           string
	Label        string
	Platform     string
	RegisterName string
	OutletName   string
	LastSeen     string
	Revoked      bool
}

type IssuedCode struct {
	RegisterName string
	Code         string
	ExpiresIn    string
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
