package auth_test

import (
	"slices"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/auth"
)

// The device and the server must name the same permission without a
// translation table, so these strings are part of the wire contract with
// mobile/lib/core/auth/permissions.dart. Changing one here without changing it
// there silently splits the two systems' vocabulary.
func TestPermissionStringsMatchTheDartEnum(t *testing.T) {
	require.Equal(t, []auth.Permission{
		"sell",
		"manageTables",
		"openCloseShift",
		"viewOwnOrders",
		"viewAllOrders",
		"voidOrder",
		"refundOrder",
		"applyManualDiscount",
		"viewCashDrawer",
		"adjustStock",
		"manageCatalogue",
		"manageEmployees",
		"managePromos",
		"viewDailySummary",
		"viewFinancialReports",
		"manageSettings",
		"manageOutlets",
	}, auth.AllPermissions)
}

// The property that makes this a map in code rather than rows in a table: a
// permission added to AllPermissions reaches the owner with no other edit.
// Break this and the failure mode is a new feature its own owner cannot open.
func TestOwnerIsDerivedFromTheFullSet(t *testing.T) {
	for _, p := range auth.AllPermissions {
		if slices.Contains(auth.TillPermissions, p) {
			require.False(t, auth.Owner.Grants(p),
				"the owner must not hold %q: a sale rung up under the owner's name is attribution nobody wanted", p)
			continue
		}

		require.True(t, auth.Owner.Grants(p), "the owner must receive %q automatically", p)
	}

	require.Len(t, auth.Owner.Permissions(), len(auth.AllPermissions)-len(auth.TillPermissions))
}

func TestTheTillBelongsToCashiersOnly(t *testing.T) {
	for _, p := range auth.TillPermissions {
		require.True(t, auth.Cashier.Grants(p))
		require.False(t, auth.Manager.Grants(p))
		require.False(t, auth.Owner.Grants(p))
	}
}

func TestCashierHoldsExactlyTheTillTheFloorAndItsOwnDay(t *testing.T) {
	require.Equal(t, []auth.Permission{
		auth.Sell, auth.ManageTables, auth.OpenCloseShift, auth.ViewOwnOrders,
	}, auth.Cashier.Permissions())
}

// Keeping these out of the manager set is the whole reason the role exists.
func TestManagerReachesNeitherTheCatalogueNorTheMoneyView(t *testing.T) {
	for _, p := range []auth.Permission{
		auth.ManageCatalogue,
		auth.ViewFinancialReports,
		auth.ManageEmployees,
		auth.ManagePromos,
		auth.ManageSettings,
	} {
		require.False(t, auth.Manager.Grants(p), "a manager must not hold %q", p)
		require.True(t, auth.Owner.Grants(p))
	}
}

func TestManagerRunsTheFloorAndTheExceptions(t *testing.T) {
	for _, p := range []auth.Permission{
		auth.ManageTables, auth.ViewAllOrders, auth.VoidOrder, auth.RefundOrder,
		auth.ApplyManualDiscount, auth.ViewCashDrawer, auth.AdjustStock,
		auth.ViewDailySummary, auth.ManageOutlets,
	} {
		require.True(t, auth.Manager.Grants(p), "a manager must hold %q", p)
	}
}

func TestOnlySeniorRolesReachTheBackofficeAndApproveOverrides(t *testing.T) {
	require.False(t, auth.Cashier.UsesBackoffice())
	require.True(t, auth.Manager.UsesBackoffice())
	require.True(t, auth.Owner.UsesBackoffice())

	require.False(t, auth.Cashier.CanAuthorizeOverrides())
	require.True(t, auth.Manager.CanAuthorizeOverrides())
	require.True(t, auth.Owner.CanAuthorizeOverrides())
}

// A role must never land on a route it would immediately be redirected out of.
func TestHomeRouteIsReachableForEveryRole(t *testing.T) {
	require.Equal(t, "/", auth.Cashier.HomeRoute())
	require.Equal(t, "/dashboard", auth.Manager.HomeRoute())
	require.Equal(t, "/dashboard", auth.Owner.HomeRoute())
}

func TestParseRoleRejectsAnythingElse(t *testing.T) {
	for _, valid := range []string{"cashier", "manager", "owner"} {
		role, err := auth.ParseRole(valid)
		require.NoError(t, err)
		require.Equal(t, auth.Role(valid), role)
	}

	_, err := auth.ParseRole("superuser")
	require.Error(t, err)
}
