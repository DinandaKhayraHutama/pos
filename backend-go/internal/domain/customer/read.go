package customer

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/validation"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
)

type Purchase struct {
	ID, Number, Status string
	BusinessDate       time.Time
	Total              int64
}

func (s *Service) Purchases(ctx context.Context, tenantID, id string, from, to time.Time) ([]Purchase, error) {
	if !validation.UUID(id) {
		return nil, ErrNotFound
	}
	if from.IsZero() || to.IsZero() {
		to = time.Now()
		from = to.AddDate(-1, 0, 0)
	}
	var out []Purchase
	err := pg.InTenantReadTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `SELECT o.id,COALESCE(o.payload->>'number',''),o.status,o.business_date,o.total FROM orders o
			WHERE o.tenant_id=$1 AND o.business_date BETWEEN $2::date AND $3::date
			AND o.customer_id IN (SELECT c.id FROM customers c WHERE c.tenant_id=$1 AND (c.id=$4 OR c.merged_into_id=$4))
			ORDER BY o.business_date DESC,o.placed_at_ms DESC LIMIT 200`, tenantID, from.Format(time.DateOnly), to.Format(time.DateOnly), id)
		if err != nil {
			return err
		}
		out, err = pgx.CollectRows(rows, func(row pgx.CollectableRow) (Purchase, error) {
			var p Purchase
			err := row.Scan(&p.ID, &p.Number, &p.Status, &p.BusinessDate, &p.Total)
			return p, err
		})
		return err
	})
	return out, err
}

// PageSize keeps a large customer base from arriving as one page — same
// bound family as catalogue.ProductPageSize.
const PageSize = 50

type Filter struct {
	Query string
	// Page is 1-based.
	Page int
}

// Row is one line of the Backoffice list: the contact fields plus whether
// another live customer shares a normalised phone or email — a badge, not a
// refusal, computed inline rather than as a separate query per row.
type Row struct {
	Customer
	DuplicatePhone bool
	DuplicateEmail bool
}

type Page struct {
	Rows    []Row
	Page    int
	HasMore bool
}

// List is the Backoffice search: by name, phone or email, one page at a
// time, in the till's own display order (name).
func (s *Service) List(ctx context.Context, tenantID string, f Filter) (Page, error) {
	if f.Page < 1 {
		f.Page = 1
	}
	page := Page{Page: f.Page}

	err := pg.InTenantReadTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `
			SELECT c.id, c.name, c.phone, c.email, c.address, c.note, c.active,
			       c.phone_norm IS NOT NULL AND EXISTS (
			           SELECT 1 FROM customers d WHERE d.tenant_id = c.tenant_id AND d.id <> c.id
			             AND d.deleted_at IS NULL AND d.phone_norm = c.phone_norm),
			       c.email_norm IS NOT NULL AND EXISTS (
			           SELECT 1 FROM customers d WHERE d.tenant_id = c.tenant_id AND d.id <> c.id
			             AND d.deleted_at IS NULL AND d.email_norm = c.email_norm)
			FROM customers c
			WHERE c.tenant_id = $1
			  AND c.deleted_at IS NULL
			  AND ($2 = '' OR c.name  ILIKE '%' || $2 || '%' ESCAPE '\'
			              OR c.phone ILIKE '%' || $2 || '%' ESCAPE '\'
			              OR c.email ILIKE '%' || $2 || '%' ESCAPE '\')
			ORDER BY c.name
			LIMIT $3 OFFSET $4`,
			tenantID, escapeLike(strings.TrimSpace(f.Query)), PageSize+1, (f.Page-1)*PageSize)
		if err != nil {
			return err
		}

		page.Rows, err = pgx.CollectRows(rows, func(row pgx.CollectableRow) (Row, error) {
			var r Row
			err := row.Scan(&r.ID, &r.Name, &r.Phone, &r.Email, &r.Address, &r.Note, &r.Active,
				&r.DuplicatePhone, &r.DuplicateEmail)
			return r, err
		})
		return err
	})
	if err != nil {
		return Page{}, err
	}

	if len(page.Rows) > PageSize {
		page.Rows = page.Rows[:PageSize]
		page.HasMore = true
	}

	return page, nil
}

// Get returns one live customer.
func (s *Service) Get(ctx context.Context, tenantID, id string) (Customer, error) {
	if !validation.UUID(id) {
		return Customer{}, ErrNotFound
	}

	var c Customer
	err := pg.InTenantReadTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		return tx.QueryRow(ctx, `
			SELECT id, name, phone, email, address, note, active FROM customers
			WHERE tenant_id = $1 AND id = $2 AND deleted_at IS NULL`, tenantID, id,
		).Scan(&c.ID, &c.Name, &c.Phone, &c.Email, &c.Address, &c.Note, &c.Active)
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return Customer{}, ErrNotFound
	}

	return c, err
}

func escapeLike(s string) string {
	return strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`).Replace(s)
}
