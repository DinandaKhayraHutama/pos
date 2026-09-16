package pg_test

import (
	"context"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/stretchr/testify/require"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pgtest"
)

func requireDenied(t *testing.T, err error, what string) {
	t.Helper()

	var pgErr *pgconn.PgError
	require.ErrorAs(t, err, &pgErr, "%s must be refused by the database", what)
	require.Equal(t, "42501", pgErr.Code, "%s must fail on privilege, got %s", what, pgErr.Message)
}

// Migration 001 grants every new table to the merchant credential by default,
// so a platform table is reachable from a Backoffice handler unless a migration
// revokes it. This is the proof that one did: a merchant request cannot read a
// super admin's hash or TOTP secret, cannot mint a sign-in link, and cannot see
// another merchant's audit trail — even inside its own tenant context.
func TestTheMerchantCredentialCannotReachPlatformTables(t *testing.T) {
	db := pgtest.New(t)
	ctx := context.Background()
	tenant := seedTenant(t, db, "alpha")

	for _, table := range []string{
		"super_admins", "super_admin_recovery_codes", "platform_sessions",
		"platform_audit_log", "password_setup_tokens",
	} {
		err := pg.InTenantTx(ctx, db.Pools.Tenant, tenant, func(ctx context.Context, tx pgx.Tx) error {
			_, err := tx.Exec(ctx, "SELECT 1 FROM "+pgx.Identifier{table}.Sanitize()+" LIMIT 1")
			return err
		})
		requireDenied(t, err, "reading "+table+" as "+pg.AppRole)
	}
}

// A merchant may read its own limits and flags — they are enforced inside its
// own transaction — but raising them is a platform action.
func TestTheMerchantCredentialCannotChangeItsOwnEntitlements(t *testing.T) {
	db := pgtest.New(t)
	ctx := context.Background()
	tenant := seedTenant(t, db, "alpha")

	for name, stmt := range map[string]string{
		"insert tenant_limits":          "INSERT INTO tenant_limits (tenant_id, max_outlets) VALUES ($1, 999)",
		"insert tenant_feature_flags":   "INSERT INTO tenant_feature_flags (tenant_id, flag, enabled) VALUES ($1, 'stock', true)",
		"update impersonation_sessions": "UPDATE impersonation_sessions SET ended_at = now() WHERE tenant_id = $1",
	} {
		err := pg.InTenantTx(ctx, db.Pools.Tenant, tenant, func(ctx context.Context, tx pgx.Tx) error {
			_, err := tx.Exec(ctx, stmt, tenant)
			return err
		})
		requireDenied(t, err, name)
	}

	_, err := db.Pools.Unscoped.Exec(ctx, "INSERT INTO tenant_limits (tenant_id, max_outlets) VALUES ($1, 3)", tenant)
	require.NoError(t, err, "the platform credential writes limits")

	other := seedTenant(t, db, "beta")
	_, err = db.Pools.Unscoped.Exec(ctx, "INSERT INTO tenant_limits (tenant_id, max_outlets) VALUES ($1, 7)", other)
	require.NoError(t, err)

	var limits []int
	require.NoError(t, pg.InTenantTx(ctx, db.Pools.Tenant, tenant, func(ctx context.Context, tx pgx.Tx) error {
		rows, err := tx.Query(ctx, "SELECT max_outlets FROM tenant_limits")
		if err != nil {
			return err
		}
		limits, err = pgx.CollectRows(rows, pgx.RowTo[int])
		return err
	}))
	require.Equal(t, []int{3}, limits, "a merchant reads its own limits and nobody else's")
}

// The audit trail's own author cannot edit it.
func TestThePlatformAuditLogIsAppendOnly(t *testing.T) {
	db := pgtest.New(t)
	ctx := context.Background()

	var id string
	require.NoError(t, db.Pools.Unscoped.QueryRow(ctx,
		`INSERT INTO platform_audit_log (action, detail) VALUES ('tenant.create', '{"via":"test"}') RETURNING id`,
	).Scan(&id))

	_, err := db.Pools.Unscoped.Exec(ctx, "UPDATE platform_audit_log SET action = 'tenant.nothing' WHERE id = $1", id)
	requireDenied(t, err, "rewriting an audit row")

	_, err = db.Pools.Unscoped.Exec(ctx, "DELETE FROM platform_audit_log WHERE id = $1", id)
	requireDenied(t, err, "deleting an audit row")

	var action string
	require.NoError(t, db.Pools.Unscoped.QueryRow(ctx,
		"SELECT action FROM platform_audit_log WHERE id = $1", id).Scan(&action))
	require.Equal(t, "tenant.create", action)
}

// A merchant status the code does not know would pass every `status = 'active'`
// predicate as "not active" and lock a business out with no screen that names why.
func TestATenantStatusMustBeOneTheCodeKnows(t *testing.T) {
	db := pgtest.New(t)
	tenant := seedTenant(t, db, "alpha")

	_, err := db.Pools.Unscoped.Exec(context.Background(),
		"UPDATE tenants SET status = 'paused' WHERE id = $1", tenant)

	var pgErr *pgconn.PgError
	require.ErrorAs(t, err, &pgErr)
	require.Equal(t, "23514", pgErr.Code)
}
