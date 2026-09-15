// Package unscoped is the only way to read across tenants.
//
// Importing it is the audit trail: "what can see another merchant's rows" is a
// search for this import path, which is the role TenantContext::runUnscoped()
// played in the Laravel original.
//
// It exists because authentication must resolve identity BEFORE a tenant is
// known. A till presents a bearer token and nothing else, so the lookup that
// turns that token into a tenant cannot itself be tenant-scoped.
//
// Everything else belongs in pg.InTenantTx.
package unscoped

import (
	"context"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Tx runs fn on the pool given to it, which callers must take from
// pg.Pools.Unscoped — a credential that holds BYPASSRLS while every other path
// in the system uses one that cannot.
//
// Passing the tenant pool here is not a security problem, only a silent
// failure: the policies would still apply, no tenant would be set, and the
// query would return nothing. That shows up as a till which cannot sign in.
//
// Callers are expected to stay countable on one hand.
func Tx(ctx context.Context, pool *pgxpool.Pool, fn func(context.Context, pgx.Tx) error) error {
	return pgx.BeginFunc(ctx, pool, func(tx pgx.Tx) error {
		return fn(ctx, tx)
	})
}
