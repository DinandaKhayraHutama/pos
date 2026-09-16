package platform

import (
	"context"
	"errors"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/validation"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/store/unscoped"
)

// Impersonation is designed on purpose rather than tolerated: without it,
// support starts asking owners for their passwords. So it has a stated reason,
// a banner on every page, an hour's life, and an audit row for every change
// made under it.
const (
	ImpersonationTTL = time.Hour
	// The handoff moves the grant from the platform page to the Backoffice
	// cookie in one automatic form post; a minute is ample and a leaked token
	// is worthless after it.
	handoffTTL = time.Minute
)

// ErrImpersonationInvalid is a handoff or impersonation that is unknown,
// expired, ended, or whose admin, owner or merchant is no longer active.
var ErrImpersonationInvalid = errors.New("platform: the impersonation is no longer valid")

type Handoff struct {
	ID    string
	Token string
}

type Impersonation struct {
	ID           string
	TenantID     string
	EmployeeID   string
	AdminID      string
	AdminName    string
	EmployeeName string
	Reason       string
	ExpiresAt    time.Time
}

// StartImpersonation opens an impersonation of one of a merchant's active
// owners and returns the one-time handoff the Backoffice consumes. Any other
// impersonation this admin still holds is ended first: one support engineer
// is inside one merchant at a time.
func (s *Service) StartImpersonation(ctx context.Context, actor Actor, tenantID, employeeID, reason string) (Handoff, error) {
	reason = strings.TrimSpace(reason)
	if n := utf8.RuneCountInString(reason); n < 10 || n > 500 {
		return Handoff{}, validation.Errors{"reason": "Tulis alasan 10–500 karakter, misalnya nomor tiket support."}
	}
	if !validation.UUID(tenantID) || !validation.UUID(employeeID) || !validation.UUID(actor.AdminID) {
		return Handoff{}, ErrNotFound
	}

	plain, hash, err := newToken()
	if err != nil {
		return Handoff{}, err
	}

	h := Handoff{Token: plain}
	err = unscoped.Tx(ctx, s.pools.Unscoped, func(ctx context.Context, tx pgx.Tx) error {
		var ok bool
		err := tx.QueryRow(ctx, `
			SELECT true FROM employees e JOIN tenants t ON t.id = e.tenant_id
			WHERE e.tenant_id = $1 AND e.id = $2 AND e.role = 'owner'
			  AND e.active AND e.deleted_at IS NULL AND t.status = 'active'`, tenantID, employeeID).Scan(&ok)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}

		if _, err := tx.Exec(ctx, `
			UPDATE impersonation_sessions SET ended_at = now(), ended_by = 'replaced'
			WHERE super_admin_id = $1 AND ended_at IS NULL`, actor.AdminID); err != nil {
			return err
		}

		if err := tx.QueryRow(ctx, `
			INSERT INTO impersonation_sessions
				(tenant_id, employee_id, super_admin_id, reason, handoff_sha256, handoff_expires_at, expires_at)
			VALUES ($1, $2, $3, $4, $5, now() + make_interval(secs => $6), now() + make_interval(secs => $6))
			RETURNING id::text`,
			tenantID, employeeID, actor.AdminID, reason, hash, handoffTTL.Seconds()).Scan(&h.ID); err != nil {
			return err
		}

		return Record(ctx, tx, AuditEntry{
			AdminID: actor.AdminID, IP: actor.IP, Action: "impersonation.start",
			TenantID: tenantID, ImpersonationID: h.ID,
			Detail: map[string]any{"employee_id": employeeID, "reason": reason},
		})
	})
	if err != nil {
		return Handoff{}, err
	}
	return h, nil
}

// ConsumeHandoff spends a handoff token and starts the impersonation's hour.
// A compare-and-swap: the token is cleared by the same statement that checks
// it, so it signs in exactly one browser.
func (s *Service) ConsumeHandoff(ctx context.Context, token, ip string) (Impersonation, error) {
	if token == "" {
		return Impersonation{}, ErrImpersonationInvalid
	}

	var imp Impersonation
	err := unscoped.Tx(ctx, s.pools.Unscoped, func(ctx context.Context, tx pgx.Tx) error {
		err := tx.QueryRow(ctx, `
			UPDATE impersonation_sessions i
			SET handoff_sha256 = NULL, started_at = now(),
			    expires_at = now() + make_interval(secs => $2)
			FROM tenants t, employees e, super_admins a
			WHERE i.handoff_sha256 = $1 AND i.handoff_expires_at > now()
			  AND i.started_at IS NULL AND i.ended_at IS NULL
			  AND t.id = i.tenant_id AND t.status = 'active'
			  AND e.tenant_id = i.tenant_id AND e.id = i.employee_id AND e.active AND e.deleted_at IS NULL
			  AND a.id = i.super_admin_id AND a.active
			RETURNING i.id::text, i.tenant_id::text, i.employee_id::text, i.super_admin_id::text,
			          a.name, e.name, i.reason, i.expires_at`,
			hashToken(token), ImpersonationTTL.Seconds(),
		).Scan(&imp.ID, &imp.TenantID, &imp.EmployeeID, &imp.AdminID,
			&imp.AdminName, &imp.EmployeeName, &imp.Reason, &imp.ExpiresAt)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrImpersonationInvalid
		}
		if err != nil {
			return err
		}
		return Record(ctx, tx, AuditEntry{
			AdminID: imp.AdminID, IP: ip, Action: "impersonation.enter",
			TenantID: imp.TenantID, ImpersonationID: imp.ID,
		})
	})
	return imp, err
}

// ActiveImpersonation re-checks an impersonation on every Backoffice request:
// started, not ended, not expired, and its admin still active. One that has
// run out is closed here, with its audit row, so the trail says when it ended
// and why rather than just trailing off.
func (s *Service) ActiveImpersonation(ctx context.Context, id, tenantID, employeeID string) (Impersonation, error) {
	if !validation.UUID(id) {
		return Impersonation{}, ErrImpersonationInvalid
	}

	imp := Impersonation{ID: id, TenantID: tenantID, EmployeeID: employeeID}
	valid := false
	err := unscoped.Tx(ctx, s.pools.Unscoped, func(ctx context.Context, tx pgx.Tx) error {
		err := tx.QueryRow(ctx, `
			SELECT i.super_admin_id::text, a.name, e.name, i.reason, i.expires_at
			FROM impersonation_sessions i
			JOIN super_admins a ON a.id = i.super_admin_id
			JOIN employees e ON e.tenant_id = i.tenant_id AND e.id = i.employee_id
			WHERE i.id = $1 AND i.tenant_id::text = $2 AND i.employee_id::text = $3
			  AND i.started_at IS NOT NULL AND i.ended_at IS NULL AND i.expires_at > now()
			  AND a.active`, id, tenantID, employeeID,
		).Scan(&imp.AdminID, &imp.AdminName, &imp.EmployeeName, &imp.Reason, &imp.ExpiresAt)
		if err == nil {
			valid = true
			return nil
		}
		if !errors.Is(err, pgx.ErrNoRows) {
			return err
		}

		// Closing a run-out impersonation must COMMIT, so this function returns
		// nil here and reports invalid after the transaction. Returning the
		// error from inside would roll back the very row and audit entry that
		// say when it ended.
		var adminID, tenant string
		err = tx.QueryRow(ctx, `
			UPDATE impersonation_sessions SET ended_at = now(), ended_by = 'expired'
			WHERE id = $1 AND ended_at IS NULL AND expires_at <= now()
			RETURNING super_admin_id::text, tenant_id::text`, id).Scan(&adminID, &tenant)
		if errors.Is(err, pgx.ErrNoRows) {
			return nil
		}
		if err != nil {
			return err
		}
		return Record(ctx, tx, AuditEntry{
			AdminID: adminID, Action: "impersonation.end", TenantID: tenant, ImpersonationID: id,
			Detail: map[string]any{"by": "expired"},
		})
	})
	switch {
	case err != nil:
		return Impersonation{}, err
	case !valid:
		return Impersonation{}, ErrImpersonationInvalid
	}
	return imp, nil
}

// EndImpersonation closes one. by is "admin" (the banner's button) or "logout".
func (s *Service) EndImpersonation(ctx context.Context, id, by, ip string) error {
	if by != "admin" && by != "logout" {
		by = "admin"
	}
	if !validation.UUID(id) {
		return nil
	}
	return unscoped.Tx(ctx, s.pools.Unscoped, func(ctx context.Context, tx pgx.Tx) error {
		var adminID, tenantID string
		err := tx.QueryRow(ctx, `
			UPDATE impersonation_sessions SET ended_at = now(), ended_by = $2
			WHERE id = $1 AND ended_at IS NULL
			RETURNING super_admin_id::text, tenant_id::text`, id, by).Scan(&adminID, &tenantID)
		if errors.Is(err, pgx.ErrNoRows) {
			return nil // already ended: ending it again is not an event
		}
		if err != nil {
			return err
		}
		return Record(ctx, tx, AuditEntry{
			AdminID: adminID, IP: ip, Action: "impersonation.end", TenantID: tenantID, ImpersonationID: id,
			Detail: map[string]any{"by": by},
		})
	})
}

// RecordImpersonatedRequest writes the audit row for one change made while
// impersonating. The Backoffice calls it BEFORE running the request and refuses
// the request when it fails: under impersonation, the audit row is the
// condition for being allowed to write at all.
func (s *Service) RecordImpersonatedRequest(ctx context.Context, imp Impersonation, method, path, ip string) error {
	if len(path) > 500 {
		path = path[:500]
	}
	return unscoped.Tx(ctx, s.pools.Unscoped, func(ctx context.Context, tx pgx.Tx) error {
		return Record(ctx, tx, AuditEntry{
			AdminID: imp.AdminID, IP: ip, Action: "impersonation.request",
			TenantID: imp.TenantID, ImpersonationID: imp.ID,
			Detail: map[string]any{"method": method, "path": path, "employee_id": imp.EmployeeID},
		})
	})
}
