package syncfeed

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/httpapi/wire"
	"github.com/jackc/pgx/v5"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
)

var (
	ErrUnknownEntity = errors.New("syncfeed: unknown entity")
	// ErrOutletRequired is returned for an outlet feed asked for without the
	// branch it belongs to. There is no "every branch" page of stock.
	ErrOutletRequired = errors.New("syncfeed: this feed is numbered per outlet; name the outlet")
)

const (
	// DefaultPullLimit is what a client gets when it names no limit.
	DefaultPullLimit = 500
	// MaxPullLimit caps a page. A device asking for everything at once turns
	// one slow tablet into a request the server has to hold open, and the
	// cursor makes paging free anyway.
	MaxPullLimit = 1000
)

// ManifestEntity is one line of the contract a till reads before it syncs.
type ManifestEntity = wire.ManifestEntity
type Manifest = wire.Manifest

// Page is one pull response.
type Page = wire.PullPage

// BuildManifest publishes the entity list, in the order a device must apply it.
func BuildManifest() Manifest {
	all := Entities()
	out := Manifest{SchemaVersion: SchemaVersion, Entities: make([]ManifestEntity, 0, len(all)+2)}

	for _, e := range all {
		depends := e.DependsOn
		if depends == nil {
			// [] rather than null: a client should not have to treat "no
			// dependencies" as a separate case from "some".
			depends = []string{}
		}

		out.Entities = append(out.Entities, ManifestEntity{
			Name:      e.Name,
			Scope:     e.Scope,
			Key:       e.Key,
			DependsOn: depends,
			Pull:      true,
			Push:      e.Push,
			Apply:     e.Apply,
		})
	}
	out.Entities = append(out.Entities,
		ManifestEntity{Name: "pos_sessions", Scope: ScopeOutlet, Key: []string{"id"}, DependsOn: []string{"pos_registers", "employees"}, Pull: false, Push: true, Apply: ApplyUpsert},
		ManifestEntity{Name: "orders", Scope: ScopeOutlet, Key: []string{"id"}, DependsOn: []string{"pos_sessions"}, Pull: false, Push: true, Apply: ApplyUpsert},
		// Status changes go up as events; what comes back down is the
		// table_status projection above.
		ManifestEntity{Name: "table_status_events", Scope: ScopeOutlet, Key: []string{"id"}, DependsOn: []string{"table_status"}, Pull: false, Push: true, Apply: ApplyUpsert},
	)

	return out
}

// pullSQL is the one query every pull runs. The table and the projection come
// from the registry allow-list, never from the request, so there is no
// client-controlled text in it.
//
// tenant_id — and outlet_id for an outlet feed — are named explicitly even
// though RLS already restricts the rows: they lead the covering index, and
// without them the planner has only the policy's predicate to work from.
func pullSQL(e Entity) string {
	where := "tenant_id = $1 AND sync_seq > $2"
	if e.Scope == ScopeOutlet {
		where = "tenant_id = $1 AND outlet_id = $4 AND sync_seq > $2"
	}

	return fmt.Sprintf(
		`SELECT sync_seq, %s::text
		   FROM %s
		  WHERE %s
		  ORDER BY sync_seq
		  LIMIT $3`,
		e.selectJSON(), e.Table, where)
}

func pullArgs(e Entity, tenantID, outletID string, afterSeq int64, limit int) []any {
	args := []any{tenantID, afterSeq, limit}
	if e.Scope == ScopeOutlet {
		args = append(args, outletID)
	}
	return args
}

// ExplainPull returns PostgreSQL's plan for a pull, as text.
//
// It exists because "every pull is an Index Only Scan" is a property the
// covering indexes are built for and nothing else would notice losing: adding a
// published column without adding it to the index turns one scan into a heap
// fetch per row, which is invisible until fifteen thousand tablets do it at
// once. Both the test suite and the verification script assert on it.
//
// outletID is required for an outlet feed and ignored for a company feed.
func (s *Service) ExplainPull(ctx context.Context, tenantID, outletID, entity string, afterSeq int64, limit int) (string, error) {
	e, ok := Lookup(entity)
	if !ok {
		return "", ErrUnknownEntity
	}
	if e.Scope == ScopeOutlet && outletID == "" {
		return "", ErrOutletRequired
	}

	var plan strings.Builder

	err := pg.InTenantTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		rows, err := tx.Query(ctx, "EXPLAIN (ANALYZE, BUFFERS) "+pullSQL(e),
			pullArgs(e, tenantID, outletID, afterSeq, limit)...)
		if err != nil {
			return err
		}
		defer rows.Close()

		for rows.Next() {
			var line string
			if err := rows.Scan(&line); err != nil {
				return err
			}
			plan.WriteString(line)
			plan.WriteString("\n")
		}

		return rows.Err()
	})
	if err != nil {
		return "", err
	}

	return plan.String(), nil
}

// Pull returns one page of a company feed. An outlet feed needs PullOutlet.
func (s *Service) Pull(ctx context.Context, tenantID, entity string, afterSeq int64, limit int) (Page, error) {
	return s.PullOutlet(ctx, tenantID, "", entity, afterSeq, limit)
}

// PullOutlet returns one page of any feed for a device standing in outletID.
// Company feeds ignore the outlet; outlet feeds return that branch's rows and
// its counter only.
//
// Rows and the high-water mark share one REPEATABLE READ, READ ONLY snapshot.
// READ COMMITTED, even in one transaction, can observe a writer committing
// between the two SELECTs and move next_seq past a row the page never included.
func (s *Service) PullOutlet(ctx context.Context, tenantID, outletID, entity string, afterSeq int64, limit int) (Page, error) {
	e, ok := Lookup(entity)
	if !ok {
		return Page{}, ErrUnknownEntity
	}
	if e.Scope == ScopeOutlet && outletID == "" {
		return Page{}, ErrOutletRequired
	}

	switch {
	case limit <= 0:
		limit = DefaultPullLimit
	case limit > MaxPullLimit:
		limit = MaxPullLimit
	}

	page := Page{Entity: e.Name, Rows: []json.RawMessage{}, SchemaVersion: SchemaVersion}

	err := pg.InTenantReadTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		rows, err := tx.Query(ctx, pullSQL(e), pullArgs(e, tenantID, outletID, afterSeq, limit)...)
		if err != nil {
			return fmt.Errorf("pull %s: %w", e.Name, err)
		}
		defer rows.Close()

		var lastSeq int64
		for rows.Next() {
			var (
				seq     int64
				payload string
			)
			if err := rows.Scan(&seq, &payload); err != nil {
				return err
			}
			page.Rows = append(page.Rows, json.RawMessage(payload))
			lastSeq = seq
		}
		if err := rows.Err(); err != nil {
			return err
		}

		page.HasMore = len(page.Rows) == limit
		page.NextSeq = lastSeq

		if page.HasMore {
			return nil
		}

		// Nothing further is waiting, so the cursor may jump to the scope's
		// mark. That is what lets a device skip over sequence numbers whose
		// rows were re-stamped by a later edit and no longer exist at that
		// number — without it the cursor would crawl and every poll would
		// re-ask for a page it already has.
		mark, err := counterSeq(ctx, tx, scopeKeyFor(e, tenantID, outletID))
		if err != nil {
			return err
		}
		if mark > page.NextSeq {
			page.NextSeq = mark
		}

		return nil
	})
	if err != nil {
		return Page{}, err
	}

	return page, nil
}
