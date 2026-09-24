package auth

import (
	"slices"
)

// Custom is the employees.role text of anyone holding a custom role (Fase 3).
// It is a marker, never a role with permissions of its own: Custom.Grants is
// false for everything and Access is what answers.
const Custom Role = "custom"

// Access is what one person may do: their role, resolved.
//
// A system role (cashier, manager, owner) takes its permissions from this
// package, exactly as before Fase 3, so owner is still derived and a new
// permission still reaches every owner without a reseed. A custom role takes
// the names stored on its row; names this build does not know are dropped,
// never granted — a newer Backoffice writing a permission this server has not
// heard of must not widen anyone's access here.
//
// Every server check asks an Access for a permission. Comparing role names is
// what Fase 3 removed: with custom roles, "not a cashier" no longer means
// anything about what a person may do.
type Access struct {
	// System is the system role, or empty for a custom role.
	System Role
	perms  map[Permission]struct{}
	// POS says the person may sign in on a till at all; Backoffice says they
	// may sign in to the web panel. Both are properties of the role.
	POS        bool
	Backoffice bool
}

// SystemAccess is a system role exactly as it has always behaved: every one
// may sign in on a till, and all but the cashier use the Backoffice.
func SystemAccess(r Role) Access {
	return Access{System: r, perms: rolePermissions[r], POS: r != "" && rolePermissions[r] != nil, Backoffice: r == Manager || r == Owner}
}

// CustomAccess is a custom role's stored list, with unknown names dropped.
func CustomAccess(names []string, pos, backoffice bool) Access {
	perms := make(map[Permission]struct{}, len(names))
	for _, n := range names {
		p := Permission(n)
		if slices.Contains(AllPermissions, p) {
			perms[p] = struct{}{}
		}
	}
	return Access{perms: perms, POS: pos, Backoffice: backoffice}
}

// ResolveAccess builds an Access from a roles row. A system row's stored
// permissions and access flags are ignored in favour of the code: the row
// exists for identity, the behaviour of a system role is not editable.
func ResolveAccess(systemKey *string, permissions []string, pos, backoffice bool) Access {
	if systemKey != nil {
		if r, err := ParseRole(*systemKey); err == nil {
			return SystemAccess(r)
		}
		// A system key this build does not know grants nothing.
		return Access{}
	}
	return CustomAccess(permissions, pos, backoffice)
}

func (a Access) Grants(p Permission) bool {
	_, ok := a.perms[p]
	return ok
}

// Permissions returns the set in AllPermissions order.
func (a Access) Permissions() []Permission {
	out := make([]Permission, 0, len(a.perms))
	for _, p := range AllPermissions {
		if _, ok := a.perms[p]; ok {
			out = append(out, p)
		}
	}
	return out
}

// IsOwner is the one place a role NAME still matters: the business must keep
// at least one active owner, and only an owner may make someone else one.
func (a Access) IsOwner() bool { return a.System == Owner }

// Covers reports whether a holds every permission of b — the rule that stops
// anyone handing out more than they have themselves. The till set is exempt:
// an owner holds neither sell nor openCloseShift, yet has to be able to
// create a role for the people who run the till.
func (a Access) Covers(b Access) bool {
	for p := range b.perms {
		if slices.Contains(TillPermissions, p) {
			continue
		}
		if !a.Grants(p) {
			return false
		}
	}
	return true
}
