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

// The property everything else rests on. PostgreSQL exempts superusers and
// BYPASSRLS roles from every policy, silently — so if the credential the API
// connects with holds either, no isolation test below proves anything.
func TestTheApplicationCredentialCannotBypassRLS(t *testing.T) {
	db := pgtest.New(t)

	var role string
	var super, bypass bool
	require.NoError(t, db.Pools.Tenant.QueryRow(context.Background(),
		`SELECT rolname, rolsuper, rolbypassrls FROM pg_roles WHERE rolname = current_user`,
	).Scan(&role, &super, &bypass))

	require.Equal(t, pg.AppRole, role)
	require.False(t, super, "the API must never connect as a superuser")
	require.False(t, bypass, "the API must never hold BYPASSRLS")
}

// The escape hatch has to be able to, or device sign-in finds nothing and a
// till that cannot authenticate looks like a network fault.
func TestTheUnscopedCredentialCanCrossTenants(t *testing.T) {
	db := pgtest.New(t)

	alpha := seedTenant(t, db, "alpha")
	beta := seedTenant(t, db, "beta")
	seedOutlet(t, db, alpha, "Bintaro")
	seedOutlet(t, db, beta, "Kemang")

	var count int
	require.NoError(t, db.Pools.Unscoped.QueryRow(context.Background(),
		"SELECT count(*) FROM outlets").Scan(&count))

	require.Equal(t, 2, count)
}

// This is what a query that forgot InTenantTx actually does: straight through
// the pool, no transaction, no tenant context, no role switch.
func TestReadWithoutTenantContextFailsClosed(t *testing.T) {
	db := pgtest.New(t)
	tenant := seedTenant(t, db, "alpha")
	seedOutlet(t, db, tenant, "Bintaro")

	var count int
	err := db.Pools.Tenant.QueryRow(context.Background(), "SELECT count(*) FROM outlets").Scan(&count)

	require.NoError(t, err)
	require.Zero(t, count, "an unresolved tenant must match nothing, never everything")
}

func TestTenantRootItselfIsIsolated(t *testing.T) {
	db := pgtest.New(t)
	alpha := seedTenant(t, db, "alpha")
	seedTenant(t, db, "beta")
	ctx := context.Background()
	var count int
	require.NoError(t, db.Pools.Tenant.QueryRow(ctx, "SELECT count(*) FROM tenants").Scan(&count))
	require.Zero(t, count)
	require.NoError(t, pg.InTenantTx(ctx, db.Pools.Tenant, alpha, func(ctx context.Context, tx pgx.Tx) error {
		var id string
		if err := tx.QueryRow(ctx, "SELECT id::text FROM tenants").Scan(&id); err != nil {
			return err
		}
		require.Equal(t, alpha, id)
		return tx.QueryRow(ctx, "SELECT count(*) FROM tenants").Scan(&count)
	}))
	require.Equal(t, 1, count)
	_, err := db.Pools.Tenant.Exec(ctx, "INSERT INTO tenants (name, slug) VALUES ('forbidden', 'forbidden')")
	var pgErr *pgconn.PgError
	require.ErrorAs(t, err, &pgErr)
	require.Equal(t, "42501", pgErr.Code)
}

func TestWriteWithoutTenantContextFailsLoud(t *testing.T) {
	db := pgtest.New(t)
	tenant := seedTenant(t, db, "alpha")

	_, err := db.Pools.Tenant.Exec(context.Background(),
		"INSERT INTO outlets (tenant_id, name) VALUES ($1, $2)", tenant, "Kemang")

	require.Error(t, err, "a row nobody can later read must not be silently accepted")

	var pgErr *pgconn.PgError
	require.ErrorAs(t, err, &pgErr)
	require.Equal(t, "42501", pgErr.Code)
}

func TestTenantSeesOnlyItsOwnRows(t *testing.T) {
	db := pgtest.New(t)
	alpha := seedTenant(t, db, "alpha")
	beta := seedTenant(t, db, "beta")

	seedOutlet(t, db, alpha, "Bintaro")
	seedOutlet(t, db, beta, "Kemang")

	require.Equal(t, []string{"Bintaro"}, outletNames(t, db, alpha))
	require.Equal(t, []string{"Kemang"}, outletNames(t, db, beta))
}

func TestWriteForAnotherTenantIsRejected(t *testing.T) {
	db := pgtest.New(t)
	alpha := seedTenant(t, db, "alpha")
	beta := seedTenant(t, db, "beta")

	err := pg.InTenantTx(context.Background(), db.Pools.Tenant, alpha, func(ctx context.Context, tx pgx.Tx) error {
		_, err := tx.Exec(ctx, "INSERT INTO outlets (tenant_id, name) VALUES ($1, $2)", beta, "Smuggled")
		return err
	})

	require.Error(t, err, "WITH CHECK must stop a row being filed under another merchant")
}

func seedTenant(t *testing.T, db pgtest.DB, slug string) string {
	t.Helper()

	var id string
	err := db.Owner.QueryRow(context.Background(),
		"INSERT INTO tenants (name, slug) VALUES ($1, $1) RETURNING id", slug).Scan(&id)
	require.NoError(t, err)

	return id
}

func seedOutlet(t *testing.T, db pgtest.DB, tenantID, name string) {
	t.Helper()

	err := pg.InTenantTx(context.Background(), db.Pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		_, err := tx.Exec(ctx, "INSERT INTO outlets (tenant_id, name) VALUES ($1, $2)", tenantID, name)
		return err
	})
	require.NoError(t, err)
}

func outletNames(t *testing.T, db pgtest.DB, tenantID string) []string {
	t.Helper()

	var names []string
	err := pg.InTenantTx(context.Background(), db.Pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		rows, err := tx.Query(ctx, "SELECT name FROM outlets ORDER BY name")
		if err != nil {
			return err
		}
		defer rows.Close()

		for rows.Next() {
			var name string
			if err := rows.Scan(&name); err != nil {
				return err
			}
			names = append(names, name)
		}
		return rows.Err()
	})
	require.NoError(t, err)

	return names
}

// The rule that keeps the boundary from depending on anyone remembering it:
// every table carrying a tenant_id is inside it, and this test is what makes
// that automatic. A new table added with a tenant_id column and no policy fails
// here rather than in production, where the first symptom would be one merchant
// reading another's rows.
//
// FORCE matters as much as ENABLE. Without it the table's owner bypasses every
// policy, which is a second way to get exactly the failure this prevents — and
// the owner is who runs migrations and platform tooling.
func TestEveryTenantScopedTableEnforcesRowLevelSecurity(t *testing.T) {
	db := pgtest.New(t)

	rows, err := db.Owner.Query(context.Background(), `
		SELECT c.relname,
		       c.relrowsecurity,
		       c.relforcerowsecurity,
		       (SELECT count(*) FROM pg_policy p WHERE p.polrelid = c.oid),
		       has_table_privilege($1, c.oid, 'SELECT, INSERT, UPDATE, DELETE')
		FROM pg_class c
		JOIN pg_namespace n ON n.oid = c.relnamespace
		WHERE n.nspname = 'public'
		  AND c.relkind IN ('r', 'p')
		  AND EXISTS (
		      SELECT 1 FROM pg_attribute a
		      WHERE a.attrelid = c.oid AND a.attname = 'tenant_id' AND NOT a.attisdropped)
		ORDER BY c.relname`, pg.AppRole)
	require.NoError(t, err)
	defer rows.Close()

	checked := 0
	for rows.Next() {
		var (
			table           string
			enabled, forced bool
			policies        int
			appCanUse       bool
		)
		require.NoError(t, rows.Scan(&table, &enabled, &forced, &policies, &appCanUse))

		require.True(t, enabled, "%s carries tenant_id but has no row-level security", table)
		require.True(t, forced, "%s does not FORCE row-level security, so its owner bypasses every policy", table)
		require.Positive(t, policies, "%s has row-level security enabled but no policy, so it returns nothing", table)
		require.True(t, appCanUse, "%s is not granted to %s, so every request touching it fails", table, pg.AppRole)

		checked++
	}
	require.NoError(t, rows.Err())

	// Guards against the query itself breaking and passing vacuously.
	require.GreaterOrEqual(t, checked, 12, "far fewer tenant-scoped tables than expected")
}

// The catalogue in particular, at the deepest point of the composite-key chain:
// a variant belongs to a product, which belongs to a category, which belongs to
// a merchant.
func TestTheCatalogueIsTenantIsolated(t *testing.T) {
	db := pgtest.New(t)
	alpha := seedTenant(t, db, "alpha")
	beta := seedTenant(t, db, "beta")

	seedVariant(t, db, alpha, "Kopi Alpha", "Large")
	seedVariant(t, db, beta, "Kopi Beta", "Large")

	require.Equal(t, []string{"Kopi Alpha"}, productNames(t, db, alpha))
	require.Equal(t, []string{"Kopi Beta"}, productNames(t, db, beta))

	// And the composite foreign key refuses the cross-merchant row outright,
	// so it cannot survive a bug in application code either.
	var otherCategory string
	require.NoError(t, db.Owner.QueryRow(context.Background(),
		"SELECT id FROM categories WHERE tenant_id = $1", beta).Scan(&otherCategory))

	err := pg.InTenantTx(context.Background(), db.Pools.Tenant, alpha, func(ctx context.Context, tx pgx.Tx) error {
		_, err := tx.Exec(ctx,
			"INSERT INTO products (tenant_id, category_id, name, price) VALUES ($1, $2, 'Smuggled', 1)",
			alpha, otherCategory)
		return err
	})
	require.Error(t, err, "a product must not be able to point at another merchant's category")
}

func seedVariant(t *testing.T, db pgtest.DB, tenantID, productName, variantName string) {
	t.Helper()

	err := pg.InTenantTx(context.Background(), db.Pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		var categoryID string
		if err := tx.QueryRow(ctx,
			"INSERT INTO categories (tenant_id, name) VALUES ($1, 'Minuman') RETURNING id",
			tenantID).Scan(&categoryID); err != nil {
			return err
		}

		var productID string
		if err := tx.QueryRow(ctx,
			"INSERT INTO products (tenant_id, category_id, name, price) VALUES ($1, $2, $3, 25000) RETURNING id",
			tenantID, categoryID, productName).Scan(&productID); err != nil {
			return err
		}

		_, err := tx.Exec(ctx,
			"INSERT INTO product_variants (tenant_id, product_id, name) VALUES ($1, $2, $3)",
			tenantID, productID, variantName)
		return err
	})
	require.NoError(t, err)
}

func productNames(t *testing.T, db pgtest.DB, tenantID string) []string {
	t.Helper()

	var names []string
	err := pg.InTenantTx(context.Background(), db.Pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `
			SELECT p.name FROM products p
			JOIN product_variants v ON v.tenant_id = p.tenant_id AND v.product_id = p.id
			ORDER BY p.name`)
		if err != nil {
			return err
		}
		defer rows.Close()

		for rows.Next() {
			var name string
			if err := rows.Scan(&name); err != nil {
				return err
			}
			names = append(names, name)
		}
		return rows.Err()
	})
	require.NoError(t, err)

	return names
}
