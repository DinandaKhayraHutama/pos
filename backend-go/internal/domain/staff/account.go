package staff

import (
	"context"
	"errors"
	"strings"

	"github.com/jackc/pgx/v5"
	"golang.org/x/crypto/bcrypt"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/validation"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
)

// The account screen (Fase 3): anyone signed in to the Backoffice may change
// their own display name, contact number and password, without holding
// manageEmployees. Role, email and the active switch stay with whoever
// manages staff — changing your own of those is how a merchant locks itself
// out.

// UpdateOwnAccount changes the signed-in person's name and phone. The name is
// on the till's staff list, so it is published.
func (s *Service) UpdateOwnAccount(ctx context.Context, tenantID, id, name string, phone *string) error {
	name = strings.TrimSpace(name)
	in := ProfileInput{Name: name, Phone: phone, Role: "owner"}
	errs := validateProfile(&in)
	delete(errs, "role")
	if err := errs.Err(); err != nil {
		return err
	}
	return s.feed.Write(ctx, tenantID, func(ctx context.Context, w *syncfeed.Writer) error {
		var oldName string
		var oldPhone *string
		err := w.Tx.QueryRow(ctx, `SELECT name, phone FROM employees WHERE tenant_id = $1 AND id = $2 AND deleted_at IS NULL FOR UPDATE`,
			tenantID, id).Scan(&oldName, &oldPhone)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		if oldName == in.Name && samePtr(oldPhone, in.Phone) {
			return nil
		}
		seq, err := w.Seq(ctx, "employees")
		if err != nil {
			return err
		}
		_, err = w.Tx.Exec(ctx, `UPDATE employees SET name = $3, phone = $4, sync_seq = $5, updated_at = now() WHERE tenant_id = $1 AND id = $2`,
			tenantID, id, in.Name, in.Phone, seq)
		return err
	})
}

// ChangeOwnPassword replaces the signed-in person's password after checking
// the current one. The check is what separates "I am signed in" from "I am
// the person whose account this is": a borrowed, unlocked browser must not be
// enough to keep someone out of their own account.
func (s *Service) ChangeOwnPassword(ctx context.Context, tenantID, id, current, next string) error {
	if err := validatePassword(next); err != nil {
		return err
	}
	hash, err := HashPassword(next)
	if err != nil {
		return err
	}
	return pg.InTenantTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		var stored string
		err := tx.QueryRow(ctx, `SELECT COALESCE(password, '') FROM employees WHERE tenant_id = $1 AND id = $2 AND deleted_at IS NULL FOR UPDATE`,
			tenantID, id).Scan(&stored)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		if stored == "" || bcrypt.CompareHashAndPassword([]byte(stored), []byte(current)) != nil {
			return validation.Errors{"current_password": "Kata sandi saat ini salah."}
		}
		_, err = tx.Exec(ctx, `UPDATE employees SET password = $3, updated_at = now() WHERE tenant_id = $1 AND id = $2`, tenantID, id, hash)
		return err
	})
}

func samePtr(a, b *string) bool {
	if a == nil || b == nil {
		return a == nil && b == nil
	}
	return *a == *b
}
