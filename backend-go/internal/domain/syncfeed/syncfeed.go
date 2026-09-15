// Package syncfeed publishes server-owned rows to tills and hands them the
// cursors they page along.
//
// One direction only. Nothing here accepts a write from a device: the
// catalogue, the staff list and the branch structure belong to the Backoffice,
// and a till editing a price locally would be a change with no authority behind
// it and nowhere to go. Device-written feeds — orders, sessions, the stock
// ledger — arrive through push, which is a different contract.
//
// The package is named syncfeed rather than sync so that a file here can still
// use the standard library's sync. That is not a stylistic point: the race
// tests in this package need sync.WaitGroup.
package syncfeed

import (
	"log/slog"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/httpapi/wire"
	"github.com/redis/go-redis/v9"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
)

// SchemaVersion is the shape of the rows this server publishes.
//
// It travels in every manifest and every pull page so a till can tell "I do not
// understand this row" from "there is nothing to fetch". Bump it when a
// published column changes meaning — not when one is added, because the client
// contract is to IGNORE keys it does not recognise. In v1 an unknown column was
// a fatal SQLite error that took down the whole screen.
const SchemaVersion = 1

// MinDeviceSchemaVersion is the oldest client this server still answers.
//
// A device below it gets 409 device_schema_outdated and is told to update,
// which is a bounded outage for that till. The alternative — serving it rows it
// will misinterpret — is an unbounded one for the merchant's numbers.
const MinDeviceSchemaVersion = 1

// Scope says which counter an entity's rows are numbered by.
//
// Sharding along this axis is the point of the rewrite: with one counter per
// merchant, every catalogue and staff write in a 5,000-outlet company queued
// behind the same row.
type Scope = wire.ManifestEntityScope

const (
	// ScopeCompany covers rows every till in the business receives: the menu,
	// the staff list, the branch structure.
	ScopeCompany Scope = "company"
	// ScopeOutlet covers rows only one branch's tills care about — the stock
	// ledger and table status, from Fase 5 and 6. Contention then falls to the
	// two to four tills inside one outlet, which is exactly where a total
	// order is genuinely wanted.
	ScopeOutlet Scope = "outlet"
)

// CompanyScope names the counter for a company-shared entity.
func CompanyScope(tenantID, entity string) string {
	return "t:" + tenantID + "/e:" + entity
}

// OutletScope names the counter for an outlet-scoped entity.
func OutletScope(tenantID, outletID, entity string) string {
	return "t:" + tenantID + "/o:" + outletID + "/e:" + entity
}

// Service answers manifest, changes and pull.
type Service struct {
	pools  pg.Pools
	rdb    *redis.Client
	logger *slog.Logger
}

func NewService(pools pg.Pools, rdb *redis.Client, logger *slog.Logger) *Service {
	return &Service{pools: pools, rdb: rdb, logger: logger}
}
