package staff_test

import (
	"context"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/auth"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/staff"
)

// Every merchant is born with the three system roles, numbered for the feed,
// and every employee — old or new — points at the one their text names.
func TestProvisioningSeedsTheSystemRolesAndEmployeesPointAtThem(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	roles, err := f.svc.ListRoles(ctx, f.tenantID)
	require.NoError(t, err)
	require.Len(t, roles, 3)
	for _, r := range roles {
		require.NotNil(t, r.SystemKey)
		require.False(t, r.Deletable)
	}
	require.Positive(t, f.counter(t, "roles"), "seeded roles must carry sync numbers a till can pull")

	for _, role := range []auth.Role{auth.Cashier, auth.Manager, auth.Owner} {
		id := f.create(t, f.tenantID, "Staff "+string(role), role, "1234")
		p, err := f.svc.Profile(ctx, f.tenantID, id)
		require.NoError(t, err)
		require.Equal(t, role, p.Role)
		require.Equal(t, auth.SystemAccess(role).Permissions(), p.Access.Permissions(),
			"a system role grants exactly what it did before custom roles existed")
		row := f.row(t, f.tenantID, id)
		require.Equal(t, p.RoleID, row["role_id"])
		require.Equal(t, string(role), row["role"])
	}
}

func TestACustomRoleIsCreatedAssignedAndPublished(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	roleID, err := f.svc.SaveRole(ctx, f.tenantID, f.ownerID, staff.RoleInput{
		Name: "Supervisor", Permissions: []string{"sell", "openCloseShift", "refundOrder", "voidOrder"}, POS: true,
	})
	require.NoError(t, err)

	id, err := f.svc.Create(ctx, f.tenantID, f.ownerID, staff.ProfileInput{Name: "Rina", RoleID: roleID}, "4321")
	require.NoError(t, err)

	p, err := f.svc.Profile(ctx, f.tenantID, id)
	require.NoError(t, err)
	require.Equal(t, auth.Custom, p.Role, "employees.role is derived from the role row")
	require.True(t, p.Access.Grants(auth.RefundOrder))
	require.True(t, p.Access.Grants(auth.Sell), "a custom role may combine the till with managerial permissions")
	require.False(t, p.Access.Backoffice)

	page, err := f.feed.Pull(ctx, f.tenantID, "roles", 0, 100)
	require.NoError(t, err)
	found := false
	for _, raw := range page.Rows {
		if string(raw) != "" && containsAll(string(raw), roleID, `"permissions": "sell,openCloseShift,refundOrder,voidOrder"`) {
			found = true
		}
	}
	require.True(t, found, "the custom role reaches the till with its list as one string")

	require.ErrorIs(t, f.svc.DeleteRole(ctx, f.tenantID, f.ownerID, roleID), staff.ErrRoleInUse)
	require.ErrorIs(t, f.svc.DeleteRole(ctx, f.tenantID, f.ownerID, p.RoleID), staff.ErrRoleInUse)
	system := systemRoleID(t, f, "cashier")
	require.ErrorIs(t, f.svc.DeleteRole(ctx, f.tenantID, f.ownerID, system), staff.ErrSystemRole)
	_, err = f.svc.SaveRole(ctx, f.tenantID, f.ownerID, staff.RoleInput{ID: system, Name: "Kasir+", Permissions: []string{"sell"}, POS: true})
	require.ErrorIs(t, err, staff.ErrSystemRole)
}

// The escalation matrix: someone who manages staff through a custom role may
// hand out, edit and manage only what their own access covers.
func TestNobodyHandsOutMoreThanTheyHold(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	hrRole, err := f.svc.SaveRole(ctx, f.tenantID, f.ownerID, staff.RoleInput{
		Name: "HR", Permissions: []string{"manageEmployees", "viewDailySummary"}, Backoffice: true,
	})
	require.NoError(t, err)
	hr, err := f.svc.Create(ctx, f.tenantID, f.ownerID, staff.ProfileInput{Name: "Hana", RoleID: hrRole}, "1111")
	require.NoError(t, err)

	_, err = f.svc.SaveRole(ctx, f.tenantID, hr, staff.RoleInput{
		Name: "Finance", Permissions: []string{"viewFinancialReports"}, Backoffice: true,
	})
	requireField(t, err, "permissions")

	tillRole, err := f.svc.SaveRole(ctx, f.tenantID, hr, staff.RoleInput{
		Name: "Kasir senior", Permissions: []string{"sell", "openCloseShift"}, POS: true,
	})
	require.NoError(t, err, "the till set is not a privilege the editor must hold")

	_, err = f.svc.Create(ctx, f.tenantID, hr, staff.ProfileInput{Name: "Budi", Role: auth.Owner}, "2222")
	requireField(t, err, "role")
	_, err = f.svc.Create(ctx, f.tenantID, hr, staff.ProfileInput{Name: "Budi", Role: auth.Manager}, "2222")
	requireField(t, err, "role")
	cashier, err := f.svc.Create(ctx, f.tenantID, hr, staff.ProfileInput{Name: "Budi", RoleID: tillRole}, "2222")
	require.NoError(t, err)

	requireField(t, f.svc.SetPIN(ctx, f.tenantID, hr, f.ownerID, "9999"), "pin")
	requireField(t, f.svc.SetPassword(ctx, f.tenantID, hr, f.ownerID, "hijacked-the-owner"), "password")
	requireField(t, f.svc.SetActive(ctx, f.tenantID, hr, f.ownerID, false), "active")
	require.NoError(t, f.svc.SetPIN(ctx, f.tenantID, hr, cashier, "3333"))

	_, err = f.svc.SaveRole(ctx, f.tenantID, hr, staff.RoleInput{
		ID: hrRole, Name: "HR", Permissions: []string{"manageEmployees", "viewDailySummary"}, Backoffice: true,
	})
	requireField(t, err, "permissions")
}

func TestACustomRoleWaitsForEveryTillToUnderstandIt(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	var outlet, register, device string
	require.NoError(t, f.db.Owner.QueryRow(ctx, `INSERT INTO outlets (tenant_id, name) VALUES ($1, 'Pusat') RETURNING id`, f.tenantID).Scan(&outlet))
	require.NoError(t, f.db.Owner.QueryRow(ctx, `INSERT INTO pos_registers (tenant_id, outlet_id, name) VALUES ($1, $2, 'Kasir 1') RETURNING id`, f.tenantID, outlet).Scan(&register))
	require.NoError(t, f.db.Owner.QueryRow(ctx, `INSERT INTO devices (tenant_id, outlet_id, pos_register_id, device_uuid) VALUES ($1, $2, $3, 'old-tablet') RETURNING id`, f.tenantID, outlet, register).Scan(&device))

	roleID, err := f.svc.SaveRole(ctx, f.tenantID, f.ownerID, staff.RoleInput{Name: "Barista", Permissions: []string{"sell"}, POS: true})
	require.NoError(t, err, "defining a role touches no till")

	_, err = f.svc.Create(ctx, f.tenantID, f.ownerID, staff.ProfileInput{Name: "Dewi", RoleID: roleID}, "5555")
	requireField(t, err, "role")

	_, err = f.db.Owner.Exec(ctx, `UPDATE devices SET capabilities = ARRAY['roles-v1'] WHERE id = $1`, device)
	require.NoError(t, err)
	_, err = f.svc.Create(ctx, f.tenantID, f.ownerID, staff.ProfileInput{Name: "Dewi", RoleID: roleID}, "5555")
	require.NoError(t, err)
}

func TestARoleIDFromAnotherMerchantIsNotFound(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	otherTenant, otherOwner := f.provision(t, "beta")

	theirs, err := f.svc.SaveRole(ctx, otherTenant, otherOwner, staff.RoleInput{Name: "Theirs", Permissions: []string{"sell"}, POS: true})
	require.NoError(t, err)

	_, err = f.svc.Create(ctx, f.tenantID, f.ownerID, staff.ProfileInput{Name: "Mallory", RoleID: theirs}, "6666")
	requireField(t, err, "role")
	_, err = f.svc.SaveRole(ctx, f.tenantID, f.ownerID, staff.RoleInput{ID: theirs, Name: "Mine", Permissions: []string{"sell"}, POS: true})
	require.ErrorIs(t, err, staff.ErrNotFound)
}

func systemRoleID(t *testing.T, f fixture, key string) string {
	t.Helper()
	var id string
	require.NoError(t, f.db.Owner.QueryRow(context.Background(),
		`SELECT id::text FROM roles WHERE tenant_id = $1 AND system_key = $2`, f.tenantID, key).Scan(&id))
	return id
}

func containsAll(s string, parts ...string) bool {
	for _, p := range parts {
		if !contains(s, p) {
			return false
		}
	}
	return true
}

func contains(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}
