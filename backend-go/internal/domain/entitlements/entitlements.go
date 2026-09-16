// Package entitlements is what a merchant has been sold: which Backoffice
// modules it may open, and how many branches, tills and tablets it may run.
//
// The platform panel writes both; everything else only reads them, inside the
// merchant's own transaction. It is a leaf package on purpose — outlets,
// devices, staff and the Backoffice all consult it, and none of them may pull
// in the platform domain to do so.
package entitlements

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
)

// Flag names a Backoffice module. The strings are the values the
// tenant_feature_flags CHECK constraint accepts.
//
// A flag closes the module's screens; it does not reach into the till. Promos
// already published keep applying and a floor plan already pulled stays on the
// tablet — switching a flag off is a sales decision, not a data deletion.
type Flag string

const (
	Stock         Flag = "stock"
	Tables        Flag = "tables"
	Promos        Flag = "promos"
	ReportExports Flag = "report_exports"
)

// AllFlags is the order the platform panel lists them in.
var AllFlags = []Flag{Stock, Tables, Promos, ReportExports}

// Every flag defaults to on. A merchant that existed before a flag did must not
// lose a module because nobody wrote a row for it, and a missing row is exactly
// what every existing merchant has.
const defaultEnabled = true

func (f Flag) Label() string {
	switch f {
	case Stock:
		return "Stok"
	case Tables:
		return "Denah meja"
	case Promos:
		return "Promo"
	case ReportExports:
		return "Ekspor & jadwal laporan"
	default:
		return string(f)
	}
}

func ParseFlag(s string) (Flag, bool) {
	for _, f := range AllFlags {
		if string(f) == s {
			return f, true
		}
	}
	return "", false
}

// Set is the explicit overrides one merchant has. A nil Set is valid and means
// every module at its default.
type Set map[Flag]bool

func (s Set) Has(f Flag) bool {
	if on, ok := s[f]; ok {
		return on
	}
	return defaultEnabled
}

// Load reads a merchant's overrides. tx must be in that merchant's tenant
// context, or on the unscoped credential.
func Load(ctx context.Context, tx pgx.Tx, tenantID string) (Set, error) {
	rows, err := tx.Query(ctx,
		`SELECT flag, enabled FROM tenant_feature_flags WHERE tenant_id = $1`, tenantID)
	if err != nil {
		return nil, fmt.Errorf("load feature flags: %w", err)
	}
	defer rows.Close()

	out := Set{}
	for rows.Next() {
		var (
			name    string
			enabled bool
		)
		if err := rows.Scan(&name, &enabled); err != nil {
			return nil, err
		}
		if f, ok := ParseFlag(name); ok {
			out[f] = enabled
		}
	}
	return out, rows.Err()
}

// Limit names something a merchant may have a bounded number of.
type Limit string

const (
	Outlets       Limit = "outlets"
	Registers     Limit = "registers"
	ActiveDevices Limit = "active_devices"
)

// ErrLimitReached is matched with errors.Is; the concrete error is *LimitError.
var ErrLimitReached = errors.New("entitlements: limit reached")

type LimitError struct {
	Limit Limit
	Max   int
}

func (e *LimitError) Error() string {
	return fmt.Sprintf("entitlements: %s limit of %d reached", e.Limit, e.Max)
}

func (e *LimitError) Is(target error) bool { return target == ErrLimitReached }

// Message is what a merchant is shown, in the Backoffice's language.
func (e *LimitError) Message() string {
	switch e.Limit {
	case Outlets:
		return fmt.Sprintf("Batas paket tercapai: maksimal %d outlet aktif.", e.Max)
	case Registers:
		return fmt.Sprintf("Batas paket tercapai: maksimal %d till aktif.", e.Max)
	default:
		return fmt.Sprintf("Batas paket tercapai: maksimal %d perangkat aktif. Cabut perangkat yang tidak dipakai dulu.", e.Max)
	}
}

// Limits is a merchant's bounds; nil means unlimited.
type Limits struct {
	MaxOutlets       *int
	MaxRegisters     *int
	MaxActiveDevices *int
}

// ReadLimits returns a merchant's bounds, all nil when it has no row.
func ReadLimits(ctx context.Context, tx pgx.Tx, tenantID string) (Limits, error) {
	var l Limits
	err := tx.QueryRow(ctx, `
		SELECT max_outlets, max_registers, max_active_devices
		FROM tenant_limits WHERE tenant_id = $1`, tenantID,
	).Scan(&l.MaxOutlets, &l.MaxRegisters, &l.MaxActiveDevices)
	if errors.Is(err, pgx.ErrNoRows) {
		return Limits{}, nil
	}
	return l, err
}

// limitSQL maps each limit to its column and to what counts against it. Every
// fragment is a constant from this file, never request input.
var limitSQL = map[Limit]struct{ column, count string }{
	Outlets: {"max_outlets", `
		SELECT count(*) FROM outlets
		WHERE tenant_id = $1 AND active AND deleted_at IS NULL`},
	Registers: {"max_registers", `
		SELECT count(*) FROM pos_registers
		WHERE tenant_id = $1 AND active AND deleted_at IS NULL`},
	ActiveDevices: {"max_active_devices", `
		SELECT count(*) FROM devices
		WHERE tenant_id = $1 AND revoked_at IS NULL AND token_expires_at > now()
		  AND device_uuid <> $2`},
}

// Enforce refuses to add one more outlet or till when the merchant already has
// as many active as it was sold. Call it inside the writing transaction, before
// the row is inserted or switched on.
func Enforce(ctx context.Context, tx pgx.Tx, tenantID string, limit Limit) error {
	return enforce(ctx, tx, tenantID, limit, "")
}

// EnforceDevices is Enforce for tablet activation. The installation being
// activated is not counted: a reinstall re-binds a device that is already
// active, and refusing it at the limit would lock a merchant out of its own
// till.
func EnforceDevices(ctx context.Context, tx pgx.Tx, tenantID, deviceUUID string) error {
	return enforce(ctx, tx, tenantID, ActiveDevices, deviceUUID)
}

// enforce is count-then-insert, which is only correct while nobody else can do
// the same in between: two branches created at once would each count two of
// three and both be let in. So a bounded merchant takes a transaction-scoped
// advisory lock for that one limit first.
//
// That is not the tenant-row lock this codebase forbids. It is taken only by
// the rare writes that add a counted row (a branch, a till, an activation),
// only for merchants that have a bound at all, and it never touches sales,
// sync or stock. An unlimited merchant reads one row and takes no lock.
//
// Lock order: after the caller has claimed the row it is changing, before any
// sync counter. Every caller follows it, so it cannot close a cycle.
func enforce(ctx context.Context, tx pgx.Tx, tenantID string, limit Limit, deviceUUID string) error {
	q, ok := limitSQL[limit]
	if !ok {
		return fmt.Errorf("entitlements: unknown limit %q", limit)
	}

	var max *int
	err := tx.QueryRow(ctx,
		`SELECT `+q.column+` FROM tenant_limits WHERE tenant_id = $1`, tenantID).Scan(&max)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && max == nil) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("read %s limit: %w", limit, err)
	}

	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1, 0))`,
		"limit:"+tenantID+":"+string(limit)); err != nil {
		return fmt.Errorf("lock %s limit: %w", limit, err)
	}

	// Re-read under the lock: the platform may have changed the bound while
	// this transaction waited for it. A row deleted in the meantime means
	// unlimited, so the previous value must not survive a missing row.
	max = nil
	if err := tx.QueryRow(ctx,
		`SELECT `+q.column+` FROM tenant_limits WHERE tenant_id = $1`, tenantID).Scan(&max); err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return fmt.Errorf("read %s limit: %w", limit, err)
	}
	if max == nil {
		return nil
	}

	var count int64
	args := []any{tenantID}
	if limit == ActiveDevices {
		args = append(args, deviceUUID)
	}
	if err := tx.QueryRow(ctx, q.count, args...).Scan(&count); err != nil {
		return fmt.Errorf("count %s: %w", limit, err)
	}

	if count >= int64(*max) {
		return &LimitError{Limit: limit, Max: *max}
	}
	return nil
}
