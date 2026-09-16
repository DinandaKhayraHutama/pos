package platform

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/validation"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/store/unscoped"
)

// AuditEntry is one platform action. Empty ids are stored as NULL: a command
// run from the CLI has no admin, a sign-in has no merchant.
type AuditEntry struct {
	AdminID         string
	Action          string
	TenantID        string
	ImpersonationID string
	IP              string
	Detail          map[string]any
}

// Record writes an audit row on the caller's transaction. It takes a tx, never
// a pool, so the row commits or rolls back with the action it describes.
func Record(ctx context.Context, tx pgx.Tx, e AuditEntry) error {
	detail := e.Detail
	if detail == nil {
		detail = map[string]any{}
	}
	raw, err := json.Marshal(detail)
	if err != nil {
		return fmt.Errorf("encode audit detail: %w", err)
	}

	ip := e.IP
	if len(ip) > 64 {
		ip = ip[:64]
	}

	_, err = tx.Exec(ctx, `
		INSERT INTO platform_audit_log (super_admin_id, action, tenant_id, impersonation_id, ip, detail)
		VALUES (NULLIF($1, '')::uuid, $2, NULLIF($3, '')::uuid, NULLIF($4, '')::uuid, NULLIF($5, ''), $6)`,
		e.AdminID, e.Action, e.TenantID, e.ImpersonationID, ip, raw)
	if err != nil {
		return fmt.Errorf("write audit row %s: %w", e.Action, err)
	}
	return nil
}

type AuditRow struct {
	ID              string
	At              time.Time
	AdminName       string
	AdminEmail      string
	Action          string
	TenantID        string
	TenantName      string
	ImpersonationID string
	IP              string
	Detail          map[string]any
}

type AuditFilter struct {
	TenantID        string
	ImpersonationID string
	// Action matches a prefix, so "tenant." lists every merchant action.
	Action string
	// Before pages backwards: rows strictly older than this.
	Before time.Time
	Limit  int
}

// Audit lists the trail newest first.
func (s *Service) Audit(ctx context.Context, f AuditFilter) ([]AuditRow, error) {
	if f.Limit <= 0 || f.Limit > 200 {
		f.Limit = 50
	}
	if (f.TenantID != "" && !validation.UUID(f.TenantID)) || (f.ImpersonationID != "" && !validation.UUID(f.ImpersonationID)) {
		return nil, nil
	}
	var before any
	if !f.Before.IsZero() {
		before = f.Before
	}

	var out []AuditRow
	err := unscoped.Tx(ctx, s.pools.Unscoped, func(ctx context.Context, tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `
			SELECT l.id::text, l.at, COALESCE(a.name, ''), COALESCE(a.email, ''), l.action,
			       COALESCE(l.tenant_id::text, ''), COALESCE(t.name, ''),
			       COALESCE(l.impersonation_id::text, ''), COALESCE(l.ip, ''), l.detail
			FROM platform_audit_log l
			LEFT JOIN super_admins a ON a.id = l.super_admin_id
			LEFT JOIN tenants t ON t.id = l.tenant_id
			WHERE ($1 = '' OR l.tenant_id = NULLIF($1, '')::uuid)
			  AND ($2 = '' OR l.impersonation_id = NULLIF($2, '')::uuid)
			  AND ($3 = '' OR l.action LIKE $3 || '%')
			  AND ($4::timestamptz IS NULL OR l.at < $4::timestamptz)
			ORDER BY l.at DESC
			LIMIT $5`, f.TenantID, f.ImpersonationID, f.Action, before, f.Limit)
		if err != nil {
			return err
		}
		out, err = pgx.CollectRows(rows, func(row pgx.CollectableRow) (AuditRow, error) {
			var (
				r   AuditRow
				raw []byte
			)
			if err := row.Scan(&r.ID, &r.At, &r.AdminName, &r.AdminEmail, &r.Action,
				&r.TenantID, &r.TenantName, &r.ImpersonationID, &r.IP, &raw); err != nil {
				return r, err
			}
			return r, json.Unmarshal(raw, &r.Detail)
		})
		return err
	})
	return out, err
}
