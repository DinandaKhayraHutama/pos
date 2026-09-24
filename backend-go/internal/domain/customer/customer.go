// Package customer owns the customer master: who a merchant sells to, kept
// separate from the transient customer_name a till has always been able to
// type into an order's payload.
//
// It is company-scoped, like brands and categories — a customer belongs to
// the business, not a branch — with one exception the rest of this
// codebase's masters do not have: a till may CREATE a row here, not only
// pull it. See device.go for why that stays create-only, never an edit.
package customer

import (
	"context"
	"errors"
	"regexp"
	"strings"

	"github.com/jackc/pgx/v5"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/validation"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
)

var ErrNotFound = errors.New("customer: no such row")

type Service struct {
	pools pg.Pools
	feed  *syncfeed.Service
}

func NewService(pools pg.Pools, feed *syncfeed.Service) *Service {
	return &Service{pools: pools, feed: feed}
}

// Customer is the Backoffice's view: the merge/normalisation bookkeeping
// (device.go, merge.go) is deliberately not part of this shape — a form
// never edits merged_into_id or *_norm directly.
type Customer struct {
	ID      string
	Name    string
	Phone   *string
	Email   *string
	Address *string
	Note    *string
	Active  bool
}

func validateCustomer(in Customer) error {
	errs := validation.Errors{}
	errs.Name("name", in.Name, 120)
	errs.Optional("phone", in.Phone, 32)
	errs.Optional("email", in.Email, 255)
	errs.Optional("address", in.Address, 255)
	errs.Optional("note", in.Note, 500)
	return errs.Err()
}

var nonDigits = regexp.MustCompile(`\D+`)

// normalizePhone keeps digits only, so "0812-3456-7890" and "0812 3456
// 7890" and "+62 812-3456-7890" all badge as the same phone even though a
// merchant would never type them identically twice in a row. This is a
// duplicate BADGE, never a uniqueness constraint — see the migration's own
// note on why two customers may legitimately share a number.
func normalizePhone(s string) *string {
	digits := nonDigits.ReplaceAllString(strings.TrimSpace(s), "")
	if digits == "" {
		return nil
	}
	return &digits
}

func normalizeEmail(s string) *string {
	e := strings.ToLower(strings.TrimSpace(s))
	if e == "" {
		return nil
	}
	return &e
}

// SaveCustomer creates or updates a customer from the Backoffice and returns
// its id. Mirrors SaveCategory/SaveBrand's shape; the one thing those do not
// have is the normalised-contact columns kept in step here on every write.
func (s *Service) SaveCustomer(ctx context.Context, tenantID string, in Customer) (string, error) {
	in.Name = strings.TrimSpace(in.Name)
	in.Phone = validation.Trimmed(derefOr(in.Phone))
	in.Email = validation.Trimmed(derefOr(in.Email))
	in.Address = validation.Trimmed(derefOr(in.Address))
	in.Note = validation.Trimmed(derefOr(in.Note))
	if err := validateCustomer(in); err != nil {
		return "", err
	}
	if in.ID != "" && !validation.UUID(in.ID) {
		return "", ErrNotFound
	}

	var phoneNorm, emailNorm *string
	if in.Phone != nil {
		phoneNorm = normalizePhone(*in.Phone)
	}
	if in.Email != nil {
		emailNorm = normalizeEmail(*in.Email)
	}

	id := in.ID

	err := s.feed.Write(ctx, tenantID, func(ctx context.Context, w *syncfeed.Writer) error {
		if in.ID != "" {
			if err := claim(ctx, w.Tx, tenantID, in.ID); err != nil {
				return err
			}
		}

		seq, err := w.Seq(ctx, "customers")
		if err != nil {
			return err
		}

		// active is deliberately absent from the UPDATE branch's SET list: a
		// new row starts active (the VALUES side), but editing an existing
		// one — say, fixing a typoed phone number — must never silently
		// reactivate a customer someone deactivated on purpose. SetActive is
		// the only path that changes this column on an existing row.
		return w.Tx.QueryRow(ctx, `
			INSERT INTO customers
				(id, tenant_id, name, phone, email, address, note, phone_norm, email_norm, active, sync_seq)
			VALUES (COALESCE(NULLIF($1, '')::uuid, gen_random_uuid()),
			        $2, $3, $4, $5, $6, $7, $8, $9, true, $10)
			ON CONFLICT (id) DO UPDATE
			SET name       = EXCLUDED.name,
			    phone      = EXCLUDED.phone,
			    email      = EXCLUDED.email,
			    address    = EXCLUDED.address,
			    note       = EXCLUDED.note,
			    phone_norm = EXCLUDED.phone_norm,
			    email_norm = EXCLUDED.email_norm,
			    sync_seq   = EXCLUDED.sync_seq,
			    deleted_at = NULL,
			    updated_at = now()
			RETURNING id`,
			in.ID, tenantID, in.Name, in.Phone, in.Email, in.Address, in.Note,
			phoneNorm, emailNorm, seq,
		).Scan(&id)
	})
	if err != nil {
		return "", err
	}

	return id, nil
}

// SetActive is "deactivate, never delete" — the same rule
// OutletRepository's isNameTaken/orderCount guard already enforces for
// outlets, here for the reason a customer specifically needs it: an order
// may already reference this row, and deleting it would turn "who bought
// this" into a dangling reference.
func (s *Service) SetActive(ctx context.Context, tenantID, id string, active bool) error {
	if !validation.UUID(id) {
		return ErrNotFound
	}

	return s.feed.Write(ctx, tenantID, func(ctx context.Context, w *syncfeed.Writer) error {
		var current bool
		err := w.Tx.QueryRow(ctx, `
			SELECT active FROM customers
			WHERE tenant_id = $1 AND id = $2 AND deleted_at IS NULL
			FOR UPDATE`, tenantID, id).Scan(&current)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		if current == active {
			return nil
		}

		seq, err := w.Seq(ctx, "customers")
		if err != nil {
			return err
		}

		_, err = w.Tx.Exec(ctx, `
			UPDATE customers SET active = $3, sync_seq = $4, updated_at = now()
			WHERE tenant_id = $1 AND id = $2`, tenantID, id, active, seq)
		return err
	})
}

func claim(ctx context.Context, tx pgx.Tx, tenantID, id string) error {
	var found bool
	err := tx.QueryRow(ctx,
		`SELECT true FROM customers WHERE tenant_id = $1 AND id = $2 FOR UPDATE`,
		tenantID, id).Scan(&found)
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrNotFound
	}
	return err
}

func derefOr(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}
