// Package tenancy creates merchants. Everything here is a platform action, not
// a merchant one — there is no tenant to scope to until it has run.
package tenancy

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/auth"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/staff"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/store/unscoped"
)

var (
	ErrSlugTaken  = errors.New("tenancy: that slug already belongs to a merchant")
	ErrEmailTaken = errors.New("tenancy: that email already belongs to an account")
)

type Input struct {
	BusinessName  string
	Slug          string
	OwnerName     string
	OwnerEmail    string
	OwnerPassword string
}

type Result struct {
	TenantID string
	OwnerID  string
}

// Provision creates a merchant and the one account that can sign in to it.
//
// Both rows are written in a single unscoped transaction: an owner is the only
// way into a new merchant, so a tenant that committed without one would be a
// business nobody can open.
func Provision(ctx context.Context, pools pg.Pools, in Input) (Result, error) {
	hash, err := staff.HashPassword(in.OwnerPassword)
	if err != nil {
		return Result{}, err
	}

	email := strings.ToLower(strings.TrimSpace(in.OwnerEmail))
	slug := strings.ToLower(strings.TrimSpace(in.Slug))

	var out Result
	err = unscoped.Tx(ctx, pools.Unscoped, func(ctx context.Context, tx pgx.Tx) error {
		if err := tx.QueryRow(ctx,
			`INSERT INTO tenants (name, slug) VALUES ($1, $2) RETURNING id`,
			strings.TrimSpace(in.BusinessName), slug,
		).Scan(&out.TenantID); err != nil {
			if isUniqueViolation(err) {
				return ErrSlugTaken
			}
			return err
		}

		// The owner is a syncable row like any other, so it is numbered here
		// rather than left at zero. Zero is the cursor a fresh till starts
		// from, and `sync_seq > 0` is strictly greater — an unnumbered owner is
		// an account no tablet in the business ever receives.
		seq, err := syncfeed.AllocSeq(ctx, tx, out.TenantID, syncfeed.CompanyScope(out.TenantID, "employees"))
		if err != nil {
			return err
		}

		if err := tx.QueryRow(ctx, `
			INSERT INTO employees (tenant_id, name, email, password, role, active, sync_seq)
			VALUES ($1, $2, $3, $4, $5, true, $6)
			RETURNING id`,
			out.TenantID, strings.TrimSpace(in.OwnerName), email, hash, string(auth.Owner), seq,
		).Scan(&out.OwnerID); err != nil {
			if isUniqueViolation(err) {
				return ErrEmailTaken
			}
			return err
		}

		return nil
	})
	if err != nil {
		return Result{}, err
	}

	return out, nil
}

func isUniqueViolation(err error) bool {
	var pgErr *pgconn.PgError
	return errors.As(err, &pgErr) && pgErr.Code == "23505"
}

func ValidateInput(in Input) error {
	switch {
	case strings.TrimSpace(in.BusinessName) == "":
		return fmt.Errorf("tenancy: a business name is required")
	case strings.TrimSpace(in.Slug) == "":
		return fmt.Errorf("tenancy: a slug is required")
	case strings.TrimSpace(in.OwnerName) == "":
		return fmt.Errorf("tenancy: an owner name is required")
	case !strings.Contains(in.OwnerEmail, "@"):
		return fmt.Errorf("tenancy: a valid owner email is required")
	case len(in.OwnerPassword) < 12:
		return fmt.Errorf("tenancy: the owner password must be at least 12 characters")
	default:
		return nil
	}
}
