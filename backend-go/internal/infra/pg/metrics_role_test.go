package pg_test

import (
	"context"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pgtest"
)

// postgres_exporter holds a fourth credential, and the whole point of it is
// what it CANNOT do.
//
// The shortcut nobody should take is pointing the exporter at the owner: a
// superuser connection held open for the convenience of a graph, reading every
// merchant's rows while it is there. pg_monitor grants the statistics views
// and no table, so this test asserts the two halves of that separately —
// the role attributes, and the absence of a grant on the tables that hold
// money and credentials.
func TestTheMetricsCredentialCanReadStatisticsAndNoMerchantData(t *testing.T) {
	db := pgtest.New(t)
	ctx := context.Background()

	var super, bypassRLS, login bool
	require.NoError(t, db.Owner.QueryRow(ctx,
		`SELECT rolsuper, rolbypassrls, rolcanlogin FROM pg_roles WHERE rolname = $1`,
		pg.MetricsRole).Scan(&super, &bypassRLS, &login))
	require.False(t, super, "the metrics role must not be a superuser")
	require.False(t, bypassRLS, "the metrics role must not bypass row-level security")
	require.True(t, login, "the exporter connects as it, so it must be able to log in")

	var monitors bool
	require.NoError(t, db.Owner.QueryRow(ctx,
		`SELECT pg_has_role($1, 'pg_monitor', 'member')`, pg.MetricsRole).Scan(&monitors))
	require.True(t, monitors, "pg_monitor is what the exporter actually needs")

	// Membership of the merchant credential would inherit every table grant
	// migration 001 hands out by default, including the ones added by future
	// migrations. That is the mistake this test exists to catch.
	var inheritsApp bool
	require.NoError(t, db.Owner.QueryRow(ctx,
		`SELECT pg_has_role($1, $2, 'member')`, pg.MetricsRole, pg.AppRole).Scan(&inheritsApp))
	require.False(t, inheritsApp, "the metrics role must not inherit the merchant credential's grants")

	for _, table := range []string{"orders", "order_items", "devices", "employees", "super_admins", "platform_audit_log"} {
		var allowed bool
		require.NoError(t, db.Owner.QueryRow(ctx,
			`SELECT has_table_privilege($1, $2, 'SELECT')`, pg.MetricsRole, table).Scan(&allowed))
		require.False(t, allowed, "the metrics role must hold no SELECT on %s", table)
	}
}
