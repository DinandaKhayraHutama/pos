package platform

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/staff"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/validation"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/store/unscoped"
)

// ErrSetupLinkInvalid covers a link that is unknown, used, replaced, expired, or
// whose account or merchant is no longer active — one answer for all of them.
var ErrSetupLinkInvalid = errors.New("platform: the sign-in link is invalid or has expired")

type SetupAccount struct {
	BusinessName string
	OwnerName    string
	Email        string
}

// the predicate a link must satisfy both to be shown and to be used.
const liveSetupLink = `
	p.id = $1 AND p.token_sha256 = $2
	AND p.used_at IS NULL AND p.cancelled_at IS NULL AND p.expires_at > now()
	AND e.tenant_id = p.tenant_id AND e.id = p.employee_id AND e.active AND e.deleted_at IS NULL
	AND t.id = p.tenant_id AND t.status = 'active'`

// SetupAccount says whose password a link sets, so the page can name it.
func (s *Service) SetupAccount(ctx context.Context, tokenID, token string) (SetupAccount, error) {
	if !validation.UUID(tokenID) || token == "" {
		return SetupAccount{}, ErrSetupLinkInvalid
	}
	var a SetupAccount
	err := unscoped.Tx(ctx, s.pools.Unscoped, func(ctx context.Context, tx pgx.Tx) error {
		return tx.QueryRow(ctx, `
			SELECT t.name, e.name, COALESCE(e.email, '')
			FROM password_setup_tokens p, employees e, tenants t
			WHERE `+liveSetupLink, tokenID, hashToken(token)).Scan(&a.BusinessName, &a.OwnerName, &a.Email)
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return SetupAccount{}, ErrSetupLinkInvalid
	}
	return a, err
}

// CompleteSetup sets the owner's password and spends the link, in one
// transaction. The link is claimed with a compare-and-swap, so two tabs racing
// to use it cannot both set a password.
func (s *Service) CompleteSetup(ctx context.Context, tokenID, token, password string) (SetupAccount, error) {
	switch {
	case len(password) < 12:
		return SetupAccount{}, validation.Errors{"password": "Kata sandi minimal 12 karakter."}
	case len(password) > 72:
		// bcrypt reads at most 72 bytes; the Backoffice applies the same rule.
		return SetupAccount{}, validation.Errors{"password": "Kata sandi maksimal 72 byte."}
	}
	if !validation.UUID(tokenID) || token == "" {
		return SetupAccount{}, ErrSetupLinkInvalid
	}

	hash, err := staff.HashPassword(password)
	if err != nil {
		return SetupAccount{}, err
	}

	var a SetupAccount
	err = unscoped.Tx(ctx, s.pools.Unscoped, func(ctx context.Context, tx pgx.Tx) error {
		var tenantID, employeeID string
		err := tx.QueryRow(ctx, `
			UPDATE password_setup_tokens p SET used_at = now()
			FROM employees e, tenants t
			WHERE `+liveSetupLink+`
			RETURNING p.tenant_id::text, p.employee_id::text, t.name, e.name, COALESCE(e.email, '')`,
			tokenID, hashToken(token)).Scan(&tenantID, &employeeID, &a.BusinessName, &a.OwnerName, &a.Email)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrSetupLinkInvalid
		}
		if err != nil {
			return err
		}

		// The Backoffice password is not in the device feed, so setting it takes
		// no sequence number — the same as the Backoffice's own password form.
		if _, err := tx.Exec(ctx, `
			UPDATE employees SET password = $3, updated_at = now()
			WHERE tenant_id = $1 AND id = $2`, tenantID, employeeID, hash); err != nil {
			return err
		}
		return Record(ctx, tx, AuditEntry{
			Action: "tenant.owner_password_set", TenantID: tenantID,
			Detail: map[string]any{"employee_id": employeeID, "via": "setup_link"},
		})
	})
	return a, err
}
