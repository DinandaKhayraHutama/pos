package platform

import (
	"context"
	"errors"
	"fmt"
	"net/mail"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/entitlements"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/tenancy"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/validation"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/mailer"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/store/unscoped"
)

// Actor is who did something on the platform, for the audit row.
type Actor struct {
	AdminID string
	IP      string
}

const (
	StatusActive    = "active"
	StatusSuspended = "suspended"

	// SetupLinkTTL is how long a first sign-in link stays good. Long enough to
	// survive a weekend in an inbox, short enough not to be a standing key.
	SetupLinkTTL = 72 * time.Hour

	maxLimit = 100000
)

// defaultCategories give a new merchant a menu to put its first products in.
// They are ordinary rows the owner may rename or delete.
var defaultCategories = []string{"Makanan", "Minuman", "Lainnya"}

type OnboardInput struct {
	BusinessName     string
	Slug             string
	OwnerName        string
	OwnerEmail       string
	Timezone         string
	MaxOutlets       *int
	MaxRegisters     *int
	MaxActiveDevices *int
}

// SetupLink is a first sign-in link and whether it reached the owner by mail.
// When it did not, the platform panel shows Link exactly once so the admin can
// pass it on; when it did, the admin never sees it.
type SetupLink struct {
	Link      string
	Mailed    bool
	MailError string
}

type Onboarded struct {
	TenantID string
	OwnerID  string
	SetupLink
}

// the tenants.timezone CHECK, so a zone Go accepts is never one the row refuses.
var timezoneShape = regexp.MustCompile(`^[A-Za-z_]+(/[A-Za-z0-9_+-]+)*$`)

func validateOnboard(in *OnboardInput) error {
	in.BusinessName = strings.TrimSpace(in.BusinessName)
	in.Slug = strings.ToLower(strings.TrimSpace(in.Slug))
	in.OwnerName = strings.TrimSpace(in.OwnerName)
	in.OwnerEmail = strings.ToLower(strings.TrimSpace(in.OwnerEmail))
	in.Timezone = strings.TrimSpace(in.Timezone)
	if in.Timezone == "" {
		in.Timezone = tenancy.DefaultTimezone
	}

	errs := validation.Errors{}
	errs.Name("business_name", in.BusinessName, 120)
	if !tenancy.ValidSlug(in.Slug) {
		errs.Add("slug", "3–50 karakter: huruf kecil, angka dan tanda hubung, tidak diawali/diakhiri tanda hubung.")
	}
	errs.Name("owner_name", in.OwnerName, 120)
	if addr, err := mail.ParseAddress(in.OwnerEmail); err != nil || addr.Address != in.OwnerEmail || len(in.OwnerEmail) > 254 {
		errs.Add("owner_email", "Alamat email tidak valid.")
	}
	if _, err := time.LoadLocation(in.Timezone); err != nil || !timezoneShape.MatchString(in.Timezone) {
		errs.Add("timezone", "Zona waktu tidak dikenal, contoh: Asia/Jakarta.")
	}
	validateLimits(errs, entitlements.Limits{
		MaxOutlets: in.MaxOutlets, MaxRegisters: in.MaxRegisters, MaxActiveDevices: in.MaxActiveDevices,
	})
	return errs.Err()
}

func validateLimits(errs validation.Errors, l entitlements.Limits) {
	for field, v := range map[string]*int{
		"max_outlets": l.MaxOutlets, "max_registers": l.MaxRegisters, "max_active_devices": l.MaxActiveDevices,
	} {
		if v != nil && (*v < 0 || *v > maxLimit) {
			errs.Add(field, fmt.Sprintf("Antara 0 dan %d, atau kosong untuk tanpa batas.", maxLimit))
		}
	}
}

// Onboard creates a merchant, its first owner, a starter menu, its limits and
// the owner's first sign-in link, in one transaction with its audit row. The
// owner has no password until the link is used: nobody — the admin included —
// ever knows it.
func (s *Service) Onboard(ctx context.Context, actor Actor, in OnboardInput) (Onboarded, error) {
	if err := validateOnboard(&in); err != nil {
		return Onboarded{}, err
	}

	var (
		out     Onboarded
		tokenID string
		plain   string
	)
	err := unscoped.Tx(ctx, s.pools.Unscoped, func(ctx context.Context, tx pgx.Tx) error {
		res, err := tenancy.ProvisionTx(ctx, tx, tenancy.Input{
			BusinessName: in.BusinessName, Slug: in.Slug,
			OwnerName: in.OwnerName, OwnerEmail: in.OwnerEmail, Timezone: in.Timezone,
		})
		switch {
		case errors.Is(err, tenancy.ErrSlugTaken):
			return validation.Errors{"slug": "Slug ini sudah dipakai perusahaan lain."}
		case errors.Is(err, tenancy.ErrEmailTaken):
			return validation.Errors{"owner_email": "Email ini sudah dipakai akun lain."}
		case err != nil:
			return err
		}
		out.TenantID, out.OwnerID = res.TenantID, res.OwnerID

		// Numbered like any Backoffice write, one sequence per row, or a fresh
		// till starting from cursor zero would never receive them.
		for i, name := range defaultCategories {
			seq, err := syncfeed.AllocSeq(ctx, tx, out.TenantID, syncfeed.CompanyScope(out.TenantID, "categories"))
			if err != nil {
				return err
			}
			if _, err := tx.Exec(ctx, `
				INSERT INTO categories (tenant_id, name, sort_order, sync_seq) VALUES ($1, $2, $3, $4)`,
				out.TenantID, name, i, seq); err != nil {
				return err
			}
		}

		if in.MaxOutlets != nil || in.MaxRegisters != nil || in.MaxActiveDevices != nil {
			if _, err := tx.Exec(ctx, `
				INSERT INTO tenant_limits (tenant_id, max_outlets, max_registers, max_active_devices, updated_by)
				VALUES ($1, $2, $3, $4, NULLIF($5, '')::uuid)`,
				out.TenantID, in.MaxOutlets, in.MaxRegisters, in.MaxActiveDevices, actor.AdminID); err != nil {
				return err
			}
		}

		tokenID, plain, err = issueSetupToken(ctx, tx, out.TenantID, out.OwnerID, actor.AdminID)
		if err != nil {
			return err
		}

		return Record(ctx, tx, AuditEntry{
			AdminID: actor.AdminID, IP: actor.IP, Action: "tenant.create", TenantID: out.TenantID,
			Detail: map[string]any{
				"name": in.BusinessName, "slug": in.Slug, "timezone": in.Timezone,
				"owner_id": out.OwnerID, "owner_email": in.OwnerEmail,
				"limits": limitsDetail(entitlements.Limits{
					MaxOutlets: in.MaxOutlets, MaxRegisters: in.MaxRegisters, MaxActiveDevices: in.MaxActiveDevices,
				}),
			},
		})
	})
	if err != nil {
		return Onboarded{}, err
	}

	out.SetupLink = s.deliverSetupLink(ctx, in.OwnerEmail, in.OwnerName, in.BusinessName, tokenID, plain)
	return out, nil
}

// ReissueSetupLink sends an owner a fresh link and cancels any unused one. It is
// also how support recovers an owner locked out of their password, without
// ever learning or setting it: the existing password keeps working until the
// link is used.
func (s *Service) ReissueSetupLink(ctx context.Context, actor Actor, tenantID, employeeID string) (SetupLink, error) {
	if !validation.UUID(tenantID) || !validation.UUID(employeeID) {
		return SetupLink{}, ErrNotFound
	}

	var tokenID, plain, email, ownerName, businessName string
	err := unscoped.Tx(ctx, s.pools.Unscoped, func(ctx context.Context, tx pgx.Tx) error {
		err := tx.QueryRow(ctx, `
			SELECT COALESCE(e.email, ''), e.name, t.name
			FROM employees e JOIN tenants t ON t.id = e.tenant_id
			WHERE e.tenant_id = $1 AND e.id = $2 AND e.role = 'owner'
			  AND e.active AND e.deleted_at IS NULL`, tenantID, employeeID,
		).Scan(&email, &ownerName, &businessName)
		if errors.Is(err, pgx.ErrNoRows) || (err == nil && email == "") {
			return ErrNotFound
		}
		if err != nil {
			return err
		}

		if tokenID, plain, err = issueSetupToken(ctx, tx, tenantID, employeeID, actor.AdminID); err != nil {
			return err
		}
		return Record(ctx, tx, AuditEntry{
			AdminID: actor.AdminID, IP: actor.IP, Action: "tenant.owner_setup_link", TenantID: tenantID,
			Detail: map[string]any{"employee_id": employeeID},
		})
	})
	if err != nil {
		return SetupLink{}, err
	}
	return s.deliverSetupLink(ctx, email, ownerName, businessName, tokenID, plain), nil
}

// issueSetupToken cancels an owner's outstanding links and issues one more, so
// at most one link for an account is ever live.
func issueSetupToken(ctx context.Context, tx pgx.Tx, tenantID, employeeID, adminID string) (id, plain string, err error) {
	plain, hash, err := newToken()
	if err != nil {
		return "", "", err
	}
	if _, err := tx.Exec(ctx, `
		UPDATE password_setup_tokens SET cancelled_at = now()
		WHERE tenant_id = $1 AND employee_id = $2 AND used_at IS NULL AND cancelled_at IS NULL`,
		tenantID, employeeID); err != nil {
		return "", "", err
	}
	err = tx.QueryRow(ctx, `
		INSERT INTO password_setup_tokens (tenant_id, employee_id, token_sha256, expires_at, created_by)
		VALUES ($1, $2, $3, now() + make_interval(secs => $4), NULLIF($5, '')::uuid)
		RETURNING id::text`,
		tenantID, employeeID, hash, SetupLinkTTL.Seconds(), adminID).Scan(&id)
	return id, plain, err
}

// SetupPath is where a first sign-in link points: the Backoffice, outside its
// signed-in section, with the token as the only credential.
func SetupPath(tokenID string) string { return "/backoffice/welcome/" + tokenID }

func (s *Service) deliverSetupLink(ctx context.Context, email, ownerName, businessName, tokenID, plain string) SetupLink {
	link := SetupLink{Link: strings.TrimRight(s.linkBase, "/") + SetupPath(tokenID) + "?token=" + plain}
	if s.mail == nil || !s.mail.Configured() {
		link.MailError = "SMTP belum dikonfigurasi."
		return link
	}

	err := s.mail.Send(ctx, mailer.Message{
		To:      []string{email},
		Subject: "Akun JustClick POS untuk " + businessName,
		Text: fmt.Sprintf("Halo %s,\n\nAkun Owner untuk %s di JustClick POS sudah dibuat.\n"+
			"Buka tautan berikut untuk menyetel kata sandi Anda. Tautan ini hanya bisa dipakai sekali "+
			"dan berlaku %d jam:\n\n%s\n\nJika Anda tidak merasa mendaftar, abaikan email ini.\n",
			ownerName, businessName, int(SetupLinkTTL.Hours()), link.Link),
	})
	if err != nil {
		s.logger.Error("send owner setup link", "error", err)
		link.MailError = "Email gagal dikirim."
		return link
	}
	link.Mailed = true
	return link
}

// Suspend stops a merchant: its Backoffice closes on the next click and every
// till it runs answers 401 on its next request. Nothing is deleted; sales still
// queued on a tablet stay in its outbox and are pushed after reactivation.
//
// confirmSlug must be the merchant's slug, typed: stopping thousands of tills
// in the middle of a service is not something a misclick should do.
func (s *Service) Suspend(ctx context.Context, actor Actor, tenantID, reason, confirmSlug string) error {
	reason = strings.TrimSpace(reason)
	errs := validation.Errors{}
	if n := utf8.RuneCountInString(reason); n < 10 || n > 500 {
		errs.Add("reason", "Tulis alasan 10–500 karakter.")
	}
	if err := errs.Err(); err != nil {
		return err
	}
	return s.setStatus(ctx, actor, tenantID, StatusSuspended, reason, confirmSlug)
}

// Reactivate lets a suspended merchant trade again. Tills that were refused keep
// their tokens and work again on their next request after the app reloads its
// binding; nothing needs re-activating.
func (s *Service) Reactivate(ctx context.Context, actor Actor, tenantID string) error {
	return s.setStatus(ctx, actor, tenantID, StatusActive, "", "")
}

func (s *Service) setStatus(ctx context.Context, actor Actor, tenantID, status, reason, confirmSlug string) error {
	if !validation.UUID(tenantID) {
		return ErrNotFound
	}

	changed := false
	err := unscoped.Tx(ctx, s.pools.Unscoped, func(ctx context.Context, tx pgx.Tx) error {
		var slug string
		// A plain read, never a row lock on tenants: the UPDATE below takes the
		// lock it needs, and it is FOR NO KEY UPDATE, which does not conflict
		// with the FOR KEY SHARE every order's foreign key takes.
		err := tx.QueryRow(ctx, `SELECT slug FROM tenants WHERE id = $1`, tenantID).Scan(&slug)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		if status == StatusSuspended && strings.TrimSpace(confirmSlug) != slug {
			return validation.Errors{"confirm_slug": "Ketik slug perusahaan persis untuk mengonfirmasi."}
		}

		tag, err := tx.Exec(ctx, `
			UPDATE tenants
			SET status = $2,
			    suspended_at = CASE WHEN $2 = 'suspended' THEN now() END,
			    suspended_reason = NULLIF($3, ''),
			    updated_at = now()
			WHERE id = $1 AND status <> $2`, tenantID, status, reason)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return nil // already there; nothing happened, so nothing is audited
		}
		changed = true

		action := "tenant.reactivate"
		if status == StatusSuspended {
			action = "tenant.suspend"
			if _, err := tx.Exec(ctx, `
				UPDATE impersonation_sessions SET ended_at = now(), ended_by = 'suspended'
				WHERE tenant_id = $1 AND ended_at IS NULL`, tenantID); err != nil {
				return err
			}
		}
		return Record(ctx, tx, AuditEntry{
			AdminID: actor.AdminID, IP: actor.IP, Action: action, TenantID: tenantID,
			Detail: map[string]any{"reason": reason},
		})
	})
	if err != nil {
		return err
	}

	// After the commit, never before: a till re-authenticating in between would
	// cache the binding again and keep selling for the life of the entry.
	if changed && s.auth != nil {
		s.auth.Bump(ctx, "tenant", tenantID)
	}
	return nil
}

// SetLimits replaces a merchant's limits; nil means unlimited. Lowering one
// below what the merchant already has is allowed — nothing running is switched
// off — and only adding another is refused from then on.
func (s *Service) SetLimits(ctx context.Context, actor Actor, tenantID string, l entitlements.Limits) error {
	errs := validation.Errors{}
	validateLimits(errs, l)
	if err := errs.Err(); err != nil {
		return err
	}
	if !validation.UUID(tenantID) {
		return ErrNotFound
	}

	return unscoped.Tx(ctx, s.pools.Unscoped, func(ctx context.Context, tx pgx.Tx) error {
		if err := tenantExists(ctx, tx, tenantID); err != nil {
			return err
		}
		before, err := entitlements.ReadLimits(ctx, tx, tenantID)
		if err != nil {
			return err
		}
		if sameLimits(before, l) {
			return nil
		}

		if l.MaxOutlets == nil && l.MaxRegisters == nil && l.MaxActiveDevices == nil {
			_, err = tx.Exec(ctx, `DELETE FROM tenant_limits WHERE tenant_id = $1`, tenantID)
		} else {
			_, err = tx.Exec(ctx, `
				INSERT INTO tenant_limits (tenant_id, max_outlets, max_registers, max_active_devices, updated_by)
				VALUES ($1, $2, $3, $4, NULLIF($5, '')::uuid)
				ON CONFLICT (tenant_id) DO UPDATE
				SET max_outlets = EXCLUDED.max_outlets, max_registers = EXCLUDED.max_registers,
				    max_active_devices = EXCLUDED.max_active_devices,
				    updated_by = EXCLUDED.updated_by, updated_at = now()`,
				tenantID, l.MaxOutlets, l.MaxRegisters, l.MaxActiveDevices, actor.AdminID)
		}
		if err != nil {
			return err
		}
		return Record(ctx, tx, AuditEntry{
			AdminID: actor.AdminID, IP: actor.IP, Action: "tenant.limits", TenantID: tenantID,
			Detail: map[string]any{"before": limitsDetail(before), "after": limitsDetail(l)},
		})
	})
}

// SetFlags sets every module's switch. A switch at its default is stored as no
// row, so a default changed in code later reaches this merchant too.
func (s *Service) SetFlags(ctx context.Context, actor Actor, tenantID string, enabled map[entitlements.Flag]bool) error {
	if !validation.UUID(tenantID) {
		return ErrNotFound
	}

	return unscoped.Tx(ctx, s.pools.Unscoped, func(ctx context.Context, tx pgx.Tx) error {
		if err := tenantExists(ctx, tx, tenantID); err != nil {
			return err
		}
		current, err := entitlements.Load(ctx, tx, tenantID)
		if err != nil {
			return err
		}

		changes := map[string]any{}
		for _, flag := range entitlements.AllFlags {
			want := enabled[flag]
			if current.Has(flag) == want {
				continue
			}
			changes[string(flag)] = map[string]bool{"from": current.Has(flag), "to": want}

			if want == (entitlements.Set{}).Has(flag) {
				_, err = tx.Exec(ctx,
					`DELETE FROM tenant_feature_flags WHERE tenant_id = $1 AND flag = $2`, tenantID, string(flag))
			} else {
				_, err = tx.Exec(ctx, `
					INSERT INTO tenant_feature_flags (tenant_id, flag, enabled, updated_by)
					VALUES ($1, $2, $3, NULLIF($4, '')::uuid)
					ON CONFLICT (tenant_id, flag) DO UPDATE
					SET enabled = EXCLUDED.enabled, updated_by = EXCLUDED.updated_by, updated_at = now()`,
					tenantID, string(flag), want, actor.AdminID)
			}
			if err != nil {
				return err
			}
		}
		if len(changes) == 0 {
			return nil
		}
		return Record(ctx, tx, AuditEntry{
			AdminID: actor.AdminID, IP: actor.IP, Action: "tenant.flags", TenantID: tenantID,
			Detail: map[string]any{"changes": changes},
		})
	})
}

func tenantExists(ctx context.Context, tx pgx.Tx, tenantID string) error {
	var found bool
	err := tx.QueryRow(ctx, `SELECT true FROM tenants WHERE id = $1`, tenantID).Scan(&found)
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrNotFound
	}
	return err
}

func sameLimits(a, b entitlements.Limits) bool {
	eq := func(x, y *int) bool { return (x == nil && y == nil) || (x != nil && y != nil && *x == *y) }
	return eq(a.MaxOutlets, b.MaxOutlets) && eq(a.MaxRegisters, b.MaxRegisters) && eq(a.MaxActiveDevices, b.MaxActiveDevices)
}

func limitsDetail(l entitlements.Limits) map[string]any {
	v := func(p *int) any {
		if p == nil {
			return nil
		}
		return *p
	}
	return map[string]any{
		"max_outlets": v(l.MaxOutlets), "max_registers": v(l.MaxRegisters), "max_active_devices": v(l.MaxActiveDevices),
	}
}

// Usage is what a merchant runs, read from the tables that already hold it:
// devices for tablets, the sales rollup for orders. Orders are never counted
// from the order tables — at this scale that is the query that takes a database
// down — so they are only as fresh as the rollup, which is shown beside them.
type Usage struct {
	ActiveOutlets   int
	ActiveRegisters int
	ActiveDevices   int
	DevicesSeen5m   int
	DevicesSeen24h  int
	LastSeenAt      *time.Time
	OrdersToday     int64
	OrdersLast7Days int64
	RollupAsOf      *time.Time
}

type TenantSummary struct {
	ID              string
	Name            string
	Slug            string
	Status          string
	Timezone        string
	CreatedAt       time.Time
	SuspendedAt     *time.Time
	SuspendedReason string
	Usage           Usage
}

type Owner struct {
	ID           string
	Name         string
	Email        string
	Active       bool
	HasPassword  bool
	PendingSetup bool
}

type TenantDetail struct {
	TenantSummary
	Owners   []Owner
	Limits   entitlements.Limits
	Flags    entitlements.Set
	Activity []AuditRow
}

type TenantFilter struct {
	Search string
	Status string
	Offset int
	Limit  int
}

// Every fragment is a constant; the filter only ever arrives as parameters.
const tenantSummarySQL = `
	SELECT t.id::text, t.name, t.slug, t.status, t.timezone, t.created_at, t.suspended_at,
	       COALESCE(t.suspended_reason, ''),
	       (SELECT count(*) FROM outlets o WHERE o.tenant_id = t.id AND o.active AND o.deleted_at IS NULL),
	       (SELECT count(*) FROM pos_registers r WHERE r.tenant_id = t.id AND r.active AND r.deleted_at IS NULL),
	       d.active, d.seen_5m, d.seen_24h, d.last_seen,
	       s.today, s.week, s.as_of
	FROM tenants t
	CROSS JOIN LATERAL (
	    SELECT count(*) FILTER (WHERE revoked_at IS NULL AND token_expires_at > now()) AS active,
	           count(*) FILTER (WHERE revoked_at IS NULL AND last_seen_at > now() - interval '5 minutes') AS seen_5m,
	           count(*) FILTER (WHERE revoked_at IS NULL AND last_seen_at > now() - interval '24 hours') AS seen_24h,
	           max(last_seen_at) AS last_seen
	    FROM devices WHERE tenant_id = t.id) d
	CROSS JOIN LATERAL (
	    SELECT COALESCE(sum(order_count) FILTER (WHERE business_date = (now() AT TIME ZONE t.timezone)::date), 0) AS today,
	           COALESCE(sum(order_count), 0) AS week,
	           max(computed_at) AS as_of
	    FROM daily_sales_rollup
	    WHERE tenant_id = t.id
	      AND business_date BETWEEN (now() AT TIME ZONE t.timezone)::date - 6 AND (now() AT TIME ZONE t.timezone)::date) s`

func scanSummary(row pgx.Row) (TenantSummary, error) {
	var (
		t                                   TenantSummary
		outlets, registers, active, s5, s24 int64
	)
	err := row.Scan(&t.ID, &t.Name, &t.Slug, &t.Status, &t.Timezone, &t.CreatedAt, &t.SuspendedAt,
		&t.SuspendedReason, &outlets, &registers, &active, &s5, &s24, &t.Usage.LastSeenAt,
		&t.Usage.OrdersToday, &t.Usage.OrdersLast7Days, &t.Usage.RollupAsOf)
	t.Usage.ActiveOutlets, t.Usage.ActiveRegisters = int(outlets), int(registers)
	t.Usage.ActiveDevices, t.Usage.DevicesSeen5m, t.Usage.DevicesSeen24h = int(active), int(s5), int(s24)
	return t, err
}

var likeEscaper = strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`)

// Tenants lists merchants newest first, with their usage. The bool reports
// whether another page follows.
func (s *Service) Tenants(ctx context.Context, f TenantFilter) ([]TenantSummary, bool, error) {
	if f.Limit <= 0 || f.Limit > 100 {
		f.Limit = 25
	}
	if f.Offset < 0 {
		f.Offset = 0
	}
	if f.Status != StatusActive && f.Status != StatusSuspended {
		f.Status = ""
	}

	var out []TenantSummary
	err := unscoped.Tx(ctx, s.pools.Unscoped, func(ctx context.Context, tx pgx.Tx) error {
		rows, err := tx.Query(ctx, tenantSummarySQL+`
			WHERE ($1 = '' OR t.name ILIKE '%' || $1 || '%' OR t.slug ILIKE '%' || $1 || '%')
			  AND ($2 = '' OR t.status = $2)
			ORDER BY t.created_at DESC, t.id
			LIMIT $3 OFFSET $4`,
			likeEscaper.Replace(strings.TrimSpace(f.Search)), f.Status, f.Limit+1, f.Offset)
		if err != nil {
			return err
		}
		out, err = pgx.CollectRows(rows, func(row pgx.CollectableRow) (TenantSummary, error) { return scanSummary(row) })
		return err
	})
	if err != nil {
		return nil, false, err
	}
	more := len(out) > f.Limit
	if more {
		out = out[:f.Limit]
	}
	return out, more, nil
}

// Tenant is one merchant's page: usage, owners, what it is sold, and what the
// platform last did to it.
func (s *Service) Tenant(ctx context.Context, id string) (TenantDetail, error) {
	if !validation.UUID(id) {
		return TenantDetail{}, ErrNotFound
	}

	var d TenantDetail
	err := unscoped.Tx(ctx, s.pools.Unscoped, func(ctx context.Context, tx pgx.Tx) error {
		var err error
		d.TenantSummary, err = scanSummary(tx.QueryRow(ctx, tenantSummarySQL+` WHERE t.id = $1`, id))
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}

		rows, err := tx.Query(ctx, `
			SELECT e.id::text, e.name, COALESCE(e.email, ''), e.active, e.password IS NOT NULL,
			       EXISTS (SELECT 1 FROM password_setup_tokens p
			               WHERE p.tenant_id = e.tenant_id AND p.employee_id = e.id
			                 AND p.used_at IS NULL AND p.cancelled_at IS NULL AND p.expires_at > now())
			FROM employees e
			WHERE e.tenant_id = $1 AND e.role = 'owner' AND e.deleted_at IS NULL
			ORDER BY e.active DESC, e.created_at`, id)
		if err != nil {
			return err
		}
		d.Owners, err = pgx.CollectRows(rows, func(row pgx.CollectableRow) (Owner, error) {
			var o Owner
			return o, row.Scan(&o.ID, &o.Name, &o.Email, &o.Active, &o.HasPassword, &o.PendingSetup)
		})
		if err != nil {
			return err
		}

		if d.Limits, err = entitlements.ReadLimits(ctx, tx, id); err != nil {
			return err
		}
		d.Flags, err = entitlements.Load(ctx, tx, id)
		return err
	})
	if err != nil {
		return TenantDetail{}, err
	}

	d.Activity, err = s.Audit(ctx, AuditFilter{TenantID: id, Limit: 20})
	return d, err
}
