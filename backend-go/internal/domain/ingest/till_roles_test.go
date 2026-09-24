package ingest

import (
	"context"
	"errors"
	"testing"

	"github.com/stretchr/testify/require"
	"golang.org/x/crypto/bcrypt"
)

// withRole creates an employee holding a custom role with the given
// permissions and access flags.
func (f *fixture) withRole(t *testing.T, permissions []string, pos, backoffice bool) string {
	t.Helper()
	ctx := context.Background()
	var roleID string
	require.NoError(t, f.db.Owner.QueryRow(ctx,
		`INSERT INTO roles(tenant_id,name,permissions,pos_access,backoffice_access) VALUES($1,gen_random_uuid()::text,$2,$3,$4) RETURNING id::text`,
		f.binding.Tenant.ID, permissions, pos, backoffice).Scan(&roleID))
	hash, err := bcrypt.GenerateFromPassword([]byte("1234"), bcrypt.MinCost)
	require.NoError(t, err)
	var id string
	require.NoError(t, f.db.Owner.QueryRow(ctx,
		`INSERT INTO employees(tenant_id,name,role_id,pin_hash) VALUES($1,'Rina',$2,$3) RETURNING id::text`,
		f.binding.Tenant.ID, roleID, string(hash)).Scan(&id))
	return id
}

// Fase 3: the till asks for a permission, not for the word "cashier". A
// supervisor whose custom role holds openCloseShift opens a drawer; a role
// that never signs in on a till is refused at the PIN, like a wrong one.
func TestTheTillAsksForAPermissionNotARoleName(t *testing.T) {
	f := setup(t)
	ctx := context.Background()

	supervisor := f.withRole(t, []string{"sell", "openCloseShift", "refundOrder", "viewAllOrders"}, true, true)
	token := f.access(t, f.binding, supervisor)
	s := f.session(t, false)
	s.EmployeeId = &supervisor
	_, err := f.svc.OpenTill(ctx, f.binding, token, s)
	require.NoError(t, err, "a custom role with the till permissions runs a drawer")

	actor, err := f.svc.WhoIsAtTheTill(ctx, f.binding, token)
	require.NoError(t, err)
	require.Equal(t, "custom", actor.Role)
	require.True(t, actor.Access.Grants("refundOrder"))

	backofficeOnly := f.withRole(t, []string{"viewFinancialReports"}, false, true)
	_, err = f.svc.TillLogin(ctx, f.binding, backofficeOnly, "1234")
	var tillErr *TillError
	require.True(t, errors.As(err, &tillErr))
	require.Equal(t, "invalid_pin", tillErr.Code)

	viewer := f.withRole(t, []string{"viewDailySummary"}, true, false)
	viewerToken := f.access(t, f.binding, viewer)
	s2 := f.session(t, false)
	s2.EmployeeId = &viewer
	_, err = f.svc.OpenTill(ctx, f.binding, viewerToken, s2)
	require.True(t, errors.As(err, &tillErr))
	require.Equal(t, "cashier_required", tillErr.Code, "signing in on a till is not permission to run a drawer")

	// A role moved off the till loses it on the very next call.
	_, err = f.db.Owner.Exec(ctx, `UPDATE roles SET pos_access=false, backoffice_access=true, permissions=ARRAY['viewDailySummary'] WHERE id=(SELECT role_id FROM employees WHERE id=$1)`, viewer)
	require.NoError(t, err)
	_, err = f.svc.WhoIsAtTheTill(ctx, f.binding, viewerToken)
	require.True(t, errors.As(err, &tillErr))
	require.Equal(t, "cashier_auth_required", tillErr.Code)
}
