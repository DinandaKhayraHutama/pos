// Package auth holds the permission map, in code rather than in database rows.
//
// It is a port of mobile/lib/core/auth/permissions.dart, and the string values
// are byte-identical to the Dart enum names on purpose: a device and the server
// must be able to name the same permission without a translation table between
// them, and a translation table is a second thing to keep in step.
//
// Two properties are the reason this is not a table:
//
//  1. Owner is DERIVED — every permission except the till set — so a newly
//     added permission reaches the owner automatically. A seeded
//     role-permission table cannot do that; it needs re-seeding on every new
//     permission, and forgetting is silent.
//  2. There is exactly one source of truth. A database copy would be free to
//     drift from the device's copy, which is the failure that "ask for a
//     permission, never a role" exists to prevent.
package auth

import (
	"fmt"
	"slices"
)

// Permission is a single capability, phrased as an action ("void an order")
// rather than as a screen: two roles can share a screen and still differ on
// what its buttons do.
type Permission string

const (
	Sell                 Permission = "sell"
	ManageTables         Permission = "manageTables"
	OpenCloseShift       Permission = "openCloseShift"
	ViewOwnOrders        Permission = "viewOwnOrders"
	ViewAllOrders        Permission = "viewAllOrders"
	VoidOrder            Permission = "voidOrder"
	RefundOrder          Permission = "refundOrder"
	ApplyManualDiscount  Permission = "applyManualDiscount"
	ViewCashDrawer       Permission = "viewCashDrawer"
	AdjustStock          Permission = "adjustStock"
	ManageCatalogue      Permission = "manageCatalogue"
	ManageEmployees      Permission = "manageEmployees"
	ManagePromos         Permission = "managePromos"
	ViewDailySummary     Permission = "viewDailySummary"
	ViewFinancialReports Permission = "viewFinancialReports"
	ManageSettings       Permission = "manageSettings"
	ManageOutlets        Permission = "manageOutlets"
	ManageCustomers      Permission = "manageCustomers"
	// EnterCustomAmount is selling a line typed at the till with no product
	// behind it (Fase 3). Owner receives it by derivation; manager does NOT —
	// an existing role gains nothing it was not given — and a custom role may.
	EnterCustomAmount Permission = "enterCustomAmount"
)

// AllPermissions is in the declaration order of the Dart enum. Adding one here
// is all it takes for the owner to receive it.
var AllPermissions = []Permission{
	Sell,
	ManageTables,
	OpenCloseShift,
	ViewOwnOrders,
	ViewAllOrders,
	VoidOrder,
	RefundOrder,
	ApplyManualDiscount,
	ViewCashDrawer,
	AdjustStock,
	ManageCatalogue,
	ManageEmployees,
	ManagePromos,
	ViewDailySummary,
	ViewFinancialReports,
	ManageSettings,
	ManageOutlets,
	ManageCustomers,
	EnterCustomAmount,
}

type Role string

const (
	Cashier Role = "cashier"
	Manager Role = "manager"
	Owner   Role = "owner"
)

// TillPermissions is running the till: taking money, and being accountable for
// a drawer. Held ONLY by cashiers — a manager or owner covering the counter
// signs in on a cashier account, which is also the honest outcome for
// attribution, since the sale belongs to whoever was actually at the till.
var TillPermissions = []Permission{Sell, OpenCloseShift}

// A manager runs the floor and the money, and deliberately not the till.
// Spelled out rather than extended from the cashier set, because a manager is
// no longer a superset of one: their job is the numbers and the exceptions.
// The catalogue and the financial reports stay out — keeping them out is the
// whole reason this role exists.
var managerPermissions = []Permission{
	ManageTables,
	ViewAllOrders,
	VoidOrder,
	RefundOrder,
	ApplyManualDiscount,
	ViewCashDrawer,
	AdjustStock,
	ViewDailySummary,
	ManageOutlets,
	ManageCustomers,
}

var cashierPermissions = append(slices.Clone(TillPermissions), ManageTables, ViewOwnOrders)

var rolePermissions = map[Role]map[Permission]struct{}{
	Cashier: index(cashierPermissions),
	Manager: index(managerPermissions),
	Owner:   index(ownerPermissions()),
}

// ownerPermissions is derived from the full set, never hand-kept: the
// alternative is a new feature that its own owner cannot open.
func ownerPermissions() []Permission {
	out := make([]Permission, 0, len(AllPermissions))
	for _, p := range AllPermissions {
		if !slices.Contains(TillPermissions, p) {
			out = append(out, p)
		}
	}
	return out
}

func index(perms []Permission) map[Permission]struct{} {
	out := make(map[Permission]struct{}, len(perms))
	for _, p := range perms {
		out[p] = struct{}{}
	}
	return out
}

func (r Role) Grants(p Permission) bool {
	_, ok := rolePermissions[r][p]
	return ok
}

// Permissions returns this role's set in AllPermissions order, so two calls
// never disagree on ordering.
func (r Role) Permissions() []Permission {
	held := rolePermissions[r]
	out := make([]Permission, 0, len(held))

	for _, p := range AllPermissions {
		if _, ok := held[p]; ok {
			out = append(out, p)
		}
	}

	return out
}

// CanAuthorizeOverrides reports whether this role can approve an action a
// cashier is blocked from, without anyone signing out.
func (r Role) CanAuthorizeOverrides() bool { return r != Cashier }

// UsesBackoffice reports whether this role belongs in the web Backoffice. A
// cashier's world is the till app; they hold no permission the Backoffice
// surfaces, so a login form for it would be an empty panel and a support call.
func (r Role) UsesBackoffice() bool { return r != Cashier }

// HomeRoute is where someone lands after signing in on the device. It must
// never name a route the role would itself be bounced out of.
func (r Role) HomeRoute() string {
	if r == Cashier {
		return "/"
	}
	return "/dashboard"
}

func ParseRole(s string) (Role, error) {
	switch r := Role(s); r {
	case Cashier, Manager, Owner:
		return r, nil
	default:
		return "", fmt.Errorf("auth: unknown role %q", s)
	}
}
