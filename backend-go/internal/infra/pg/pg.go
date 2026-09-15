package pg

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// The two login roles the application uses. Their only difference is
// BYPASSRLS, and that difference is the whole security boundary.
const (
	AppRole      = "justclick_app"
	UnscopedRole = "justclick_unscoped"
)

// Pools keeps the two credentials apart on purpose.
//
// Before this split the API connected as the database owner and merely switched
// role inside a helper. That made row-level security a matter of remembering to
// use the helper: any query that went straight to the pool ran as a superuser,
// and PostgreSQL exempts superusers from every policy without a word.
type Pools struct {
	// Tenant cannot bypass RLS. Everything touching merchant data uses it.
	Tenant *pgxpool.Pool
	// Unscoped deliberately can, for the few lookups that must resolve an
	// identity before any tenant is known. See internal/store/unscoped.
	Unscoped *pgxpool.Pool
}

func (p Pools) Close() {
	if p.Tenant != nil {
		p.Tenant.Close()
	}
	if p.Unscoped != nil {
		p.Unscoped.Close()
	}
}

func Open(ctx context.Context, url string) (*pgxpool.Pool, error) {
	cfg, err := pgxpool.ParseConfig(url)
	if err != nil {
		return nil, fmt.Errorf("parse database url: %w", err)
	}

	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("connect to postgres: %w", err)
	}

	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("ping postgres: %w", err)
	}

	return pool, nil
}

// OpenPools opens both credentials and refuses to return if either is wired to
// the wrong role. One query at startup, in exchange for a misconfiguration
// whose first symptom would otherwise be one merchant reading another's rows.
func OpenPools(ctx context.Context, tenantURL, unscopedURL string) (Pools, error) {
	tenant, err := Open(ctx, tenantURL)
	if err != nil {
		return Pools{}, err
	}

	crossTenant, err := Open(ctx, unscopedURL)
	if err != nil {
		tenant.Close()
		return Pools{}, err
	}

	pools := Pools{Tenant: tenant, Unscoped: crossTenant}
	if err := AssertPools(ctx, pools); err != nil {
		pools.Close()
		return Pools{}, err
	}

	return pools, nil
}

// InTenantTx runs fn in a transaction scoped to one tenant, which is what every
// RLS policy reads.
//
// set_config(..., is_local => true) rather than a bare SET: the value reverts
// when the transaction ends, so it cannot survive on a connection returned to
// the pool and hand the next caller another merchant's rows. That also makes it
// safe under transaction pooling, which a bare SET is not.
//
// There is no SET ROLE here any more. The pool's own credential is already
// unable to bypass RLS — verified at startup by AssertPools — so switching role
// per transaction would be a round trip that buys nothing.
func InTenantTx(ctx context.Context, pool *pgxpool.Pool, tenantID string, fn func(context.Context, pgx.Tx) error) error {
	return inTenantTx(ctx, pool, tenantID, pgx.TxOptions{}, fn)
}

// InTenantReadTx keeps all reads on the same snapshot. READ COMMITTED would
// let a later counter SELECT acknowledge changes absent from an earlier scan.
// Writers retain their existing isolation and counter lock-until-commit rule.
func InTenantReadTx(ctx context.Context, pool *pgxpool.Pool, tenantID string, fn func(context.Context, pgx.Tx) error) error {
	return inTenantTx(ctx, pool, tenantID, pgx.TxOptions{
		IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly,
	}, fn)
}

// InTenantSnapshotTx reads and writes on one snapshot. A report rollup writes
// several tables from the orders it can see, and they must describe one moment:
// a sale committed between two of its statements would otherwise be in the
// totals and missing from the category split.
func InTenantSnapshotTx(ctx context.Context, pool *pgxpool.Pool, tenantID string, fn func(context.Context, pgx.Tx) error) error {
	return inTenantTx(ctx, pool, tenantID, pgx.TxOptions{IsoLevel: pgx.RepeatableRead}, fn)
}

func inTenantTx(ctx context.Context, pool *pgxpool.Pool, tenantID string, opts pgx.TxOptions, fn func(context.Context, pgx.Tx) error) error {
	return pgx.BeginTxFunc(ctx, pool, opts, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, "SELECT set_config('app.tenant_id', $1, true)", tenantID); err != nil {
			return fmt.Errorf("set tenant context: %w", err)
		}
		return fn(ctx, tx)
	})
}

// AssertPools refuses to start on a misconfiguration that would otherwise be
// invisible.
//
// Pointing DATABASE_URL at a superuser disables every tenant policy silently —
// nothing errors, and the first symptom is one merchant seeing another's rows.
// The mirror image is just as bad: an unscoped pool that cannot bypass RLS
// makes device authentication return nothing, and a till that cannot sign in
// looks like a network problem.
func AssertPools(ctx context.Context, pools Pools) error {
	tenant, err := privilegesOf(ctx, pools.Tenant)
	if err != nil {
		return err
	}
	if tenant.super || tenant.bypassRLS {
		return fmt.Errorf(
			"pg: the tenant credential (%s) can bypass row-level security; point DATABASE_URL at %s",
			tenant.name, AppRole)
	}

	unscoped, err := privilegesOf(ctx, pools.Unscoped)
	if err != nil {
		return err
	}
	if !unscoped.super && !unscoped.bypassRLS {
		return fmt.Errorf(
			"pg: the unscoped credential (%s) cannot bypass row-level security, so device sign-in will find nothing; point UNSCOPED_DATABASE_URL at %s",
			unscoped.name, UnscopedRole)
	}

	return nil
}

type rolePrivileges struct {
	name      string
	super     bool
	bypassRLS bool
}

func privilegesOf(ctx context.Context, pool *pgxpool.Pool) (rolePrivileges, error) {
	var out rolePrivileges

	err := pool.QueryRow(ctx,
		`SELECT rolname, rolsuper, rolbypassrls FROM pg_roles WHERE rolname = current_user`,
	).Scan(&out.name, &out.super, &out.bypassRLS)
	if err != nil {
		return rolePrivileges{}, fmt.Errorf("read role privileges: %w", err)
	}

	return out, nil
}
