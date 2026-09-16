// Package devices turns a physical tablet into a till the server recognises.
//
// The trust chain points one way: an owner creates a register and issues an
// activation code for it, and the tablet trades that code for a token. Nothing
// the client sends may select a merchant — the code is the only thing that
// does, or anyone could bind a tablet to any business by editing a JSON body.
package devices

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/entitlements"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/store/unscoped"
)

var (
	ErrInvalidCode      = errors.New("devices: activation code is invalid or expired")
	ErrBoundToAnother   = errors.New("devices: installation is already bound to another register")
	ErrRegisterInactive = errors.New("devices: register or outlet is not active")
	ErrUnauthenticated  = errors.New("devices: token is unknown, expired or revoked")
)

type Device struct {
	ID       string  `json:"id"`
	UUID     string  `json:"device_uuid"`
	Label    *string `json:"label"`
	Platform *string `json:"platform"`
}

type Tenant struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

type Outlet struct {
	ID      string  `json:"id"`
	Name    string  `json:"name"`
	Address *string `json:"address"`
	Phone   *string `json:"phone"`
}

type Register struct {
	ID           string `json:"id"`
	OutletID     string `json:"outlet_id"`
	Name         string `json:"name"`
	TableService bool   `json:"table_service"`
}

// Binding is what a token resolves to, and what the till stores.
type Binding struct {
	Device   Device   `json:"device"`
	Tenant   Tenant   `json:"tenant"`
	Outlet   Outlet   `json:"outlet"`
	Register Register `json:"pos_register"`
	// RevisionMs is the newest change among the four rows above, in epoch
	// milliseconds. It rides along on the binding so /sync/changes can hand a
	// till one number to compare instead of the fleet polling /devices/me every
	// thirty seconds to find out nothing happened.
	//
	// It is not part of the binding the device is shown; the JSON tag is short
	// because this struct is what the auth cache stores.
	RevisionMs      int64    `json:"rev"`
	AuthGenerations [3]int64 `json:"auth_generations"`
	ExpiresAtMs     int64    `json:"expires_at_ms"`
	CacheReadAtMs   int64    `json:"cache_read_at_ms"`
}

type Activation struct {
	Binding
	Token          string
	TokenExpiresAt time.Time
}

type ActivateInput struct {
	Code       string
	DeviceUUID string
	Label      *string
	Platform   *string
}

type IssuedCode struct {
	Code      string
	ExpiresAt time.Time
}

type Service struct {
	pools  pg.Pools
	appKey string
}

func NewService(pools pg.Pools, appKey string) *Service {
	return &Service{pools: pools, appKey: appKey}
}

// Issue returns the plaintext code once. Issuing cancels any code still
// outstanding for the register: a code that never expires is a permanent
// credential sitting in someone's chat history.
func (s *Service) Issue(ctx context.Context, tenantID, registerID string, issuedBy *string) (IssuedCode, error) {
	code, err := newCode()
	if err != nil {
		return IssuedCode{}, err
	}

	var issued IssuedCode
	err = pg.InTenantTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		var outletID string
		err := tx.QueryRow(ctx, `
			SELECT r.outlet_id
			FROM pos_registers r
			JOIN outlets o ON o.tenant_id = r.tenant_id AND o.id = r.outlet_id
			WHERE r.id = $1 AND r.active AND o.active FOR UPDATE OF r`, registerID).Scan(&outletID)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrRegisterInactive
		}
		if err != nil {
			return err
		}

		// Checked here too, not only at activation, so an owner at the limit is
		// told why in the panel instead of reading a tablet's "invalid code".
		// Activation stays the authority: a code issued before the limit was
		// lowered is still refused there.
		if err := entitlements.EnforceDevices(ctx, tx, tenantID, ""); err != nil {
			return err
		}

		if _, err := tx.Exec(ctx, `
			UPDATE activation_codes SET cancelled_at = now()
			WHERE pos_register_id = $1 AND consumed_at IS NULL AND cancelled_at IS NULL`, registerID); err != nil {
			return err
		}

		return tx.QueryRow(ctx, `
			INSERT INTO activation_codes
				(tenant_id, outlet_id, pos_register_id, fingerprint, expires_at, issued_by_employee_id)
			VALUES ($1, $2, $3, $4, now() + make_interval(secs => $5), $6)
			RETURNING expires_at`,
			tenantID, outletID, registerID, Fingerprint(code, s.appKey),
			ActivationTTL.Seconds(), issuedBy,
		).Scan(&issued.ExpiresAt)
	})
	if err != nil {
		return IssuedCode{}, err
	}

	issued.Code = code
	return issued, nil
}

// Activate trades a code for a token.
func (s *Service) Activate(ctx context.Context, in ActivateInput) (Activation, error) {
	fingerprint := Fingerprint(strings.ToUpper(strings.TrimSpace(in.Code)), s.appKey)
	deviceUUID := strings.ToLower(strings.TrimSpace(in.DeviceUUID))

	// The one unauthenticated cross-tenant read in the system: a high-entropy
	// secret locates the merchant. This only narrows which tenant to open a
	// scoped transaction against — every check that matters is re-applied
	// inside the claim below, so a code consumed in between still loses.
	var tenantID string
	err := unscoped.Tx(ctx, s.pools.Unscoped, func(ctx context.Context, tx pgx.Tx) error {
		return tx.QueryRow(ctx,
			`SELECT tenant_id FROM activation_codes WHERE fingerprint = $1`, fingerprint).Scan(&tenantID)
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return Activation{}, ErrInvalidCode
	}
	if err != nil {
		return Activation{}, err
	}

	plain, hash, err := newToken()
	if err != nil {
		return Activation{}, err
	}

	var out Activation
	err = pg.InTenantTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		// Register -> code -> device is the common lock order for issue,
		// activate and revoke. Only operations on this register serialize.
		var registerID string
		if err := tx.QueryRow(ctx, `SELECT r.id FROM pos_registers r JOIN activation_codes ac ON ac.pos_register_id=r.id AND ac.tenant_id=r.tenant_id WHERE ac.fingerprint=$1 FOR UPDATE OF r`, fingerprint).Scan(&registerID); err != nil {
			return err
		}
		// Claim the code. Single use, expiry, cancellation, and tenant/outlet/
		// register liveness are all predicates on this one statement, so two
		// tablets racing on one code serialise on the code's own row. Locking
		// the tenant row instead — as the Laravel original did — would put
		// every outlet in the company behind a single lock.
		var codeID string
		err := tx.QueryRow(ctx, `
			UPDATE activation_codes ac
			SET consumed_at = now()
			FROM pos_registers r
			JOIN outlets o ON o.tenant_id = r.tenant_id AND o.id = r.outlet_id
			JOIN tenants t ON t.id = r.tenant_id
			WHERE ac.fingerprint = $1
			  AND ac.consumed_at IS NULL
			  AND ac.cancelled_at IS NULL
			  AND ac.expires_at > now()
			  AND r.tenant_id = ac.tenant_id
			  AND r.id = ac.pos_register_id
			  AND r.active AND o.active AND t.status = 'active'
			RETURNING ac.id, t.id, t.name,
			          o.id, o.name, o.address, o.phone,
			          r.id, r.outlet_id, r.name, r.table_service`,
			fingerprint,
		).Scan(
			&codeID, &out.Tenant.ID, &out.Tenant.Name,
			&out.Outlet.ID, &out.Outlet.Name, &out.Outlet.Address, &out.Outlet.Phone,
			&out.Register.ID, &out.Register.OutletID, &out.Register.Name, &out.Register.TableService,
		)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrInvalidCode
		}
		if err != nil {
			return err
		}

		// The authority on the device limit. Refusing returns an error, so this
		// transaction rolls back and the code claimed above stays unconsumed —
		// the owner can revoke a tablet and have this one try again. The
		// installation itself is not counted, so a reinstall at the limit still
		// re-binds.
		if err := entitlements.EnforceDevices(ctx, tx, out.Tenant.ID, deviceUUID); err != nil {
			return err
		}

		// The UUID identifies an installation, not a credential. Re-activating
		// overwrites token_sha256, so every previously issued token for this
		// device stops working — a reinstall never leaves an old one alive.
		err = tx.QueryRow(ctx, `
			INSERT INTO devices
				(tenant_id, outlet_id, pos_register_id, device_uuid, label, platform,
				 token_sha256, token_expires_at, last_seen_at)
			VALUES ($1, $2, $3, $4, $5, $6, $7, now() + make_interval(secs => $8), now())
			ON CONFLICT (tenant_id, device_uuid) DO UPDATE
			SET label            = EXCLUDED.label,
			    platform         = EXCLUDED.platform,
			    token_sha256     = EXCLUDED.token_sha256,
			    token_expires_at = EXCLUDED.token_expires_at,
			    last_seen_at     = now(),
			    revoked_at       = NULL,
			    updated_at       = now()
			WHERE devices.pos_register_id = EXCLUDED.pos_register_id
			RETURNING id, device_uuid, label, platform, token_expires_at`,
			out.Tenant.ID, out.Outlet.ID, out.Register.ID, deviceUUID, in.Label, in.Platform,
			hash, TokenTTL.Seconds(),
		).Scan(&out.Device.ID, &out.Device.UUID, &out.Device.Label, &out.Device.Platform, &out.TokenExpiresAt)
		if errors.Is(err, pgx.ErrNoRows) {
			// The row exists but sits on a different register, so the upsert's
			// WHERE refused it. Moving a till between registers must go through
			// a revoke, not a quiet re-bind.
			return ErrBoundToAnother
		}
		if err != nil {
			return err
		}

		_, err = tx.Exec(ctx, `UPDATE activation_codes SET device_id = $1 WHERE id = $2`, out.Device.ID, codeID)
		return err
	})
	if err != nil {
		return Activation{}, err
	}

	out.Token = plain
	return out, nil
}

// Authenticate re-checks the whole chain on every request, not just the token:
// the device is not revoked, its tenant is active, and its outlet and register
// are both still active and still related. A tablet in a branch the owner
// closed yesterday stops working today.
func (s *Service) Authenticate(ctx context.Context, plainToken string) (Binding, error) {
	var b Binding
	b.CacheReadAtMs = time.Now().UnixMilli()

	err := unscoped.Tx(ctx, s.pools.Unscoped, func(ctx context.Context, tx pgx.Tx) error {
		return tx.QueryRow(ctx, `
			SELECT d.id, d.device_uuid, d.label, d.platform,
			       t.id, t.name,
			       o.id, o.name, o.address, o.phone,
			       r.id, r.outlet_id, r.name, r.table_service,
			       (EXTRACT(EPOCH FROM GREATEST(
			           d.updated_at, t.updated_at, o.updated_at, r.updated_at)) * 1000)::bigint,
			       t.auth_generation, o.auth_generation, r.auth_generation,
			       (EXTRACT(EPOCH FROM d.token_expires_at) * 1000)::bigint
			FROM devices d
			JOIN tenants t ON t.id = d.tenant_id
			JOIN outlets o ON o.tenant_id = d.tenant_id AND o.id = d.outlet_id
			JOIN pos_registers r ON r.tenant_id = d.tenant_id
			                    AND r.outlet_id = d.outlet_id
			                    AND r.id = d.pos_register_id
			WHERE d.token_sha256 = $1
			  AND d.revoked_at IS NULL
			  AND d.token_expires_at > now()
			  AND t.status = 'active'
			  AND o.active
			  AND r.active`,
			HashToken(plainToken),
		).Scan(
			&b.Device.ID, &b.Device.UUID, &b.Device.Label, &b.Device.Platform,
			&b.Tenant.ID, &b.Tenant.Name,
			&b.Outlet.ID, &b.Outlet.Name, &b.Outlet.Address, &b.Outlet.Phone,
			&b.Register.ID, &b.Register.OutletID, &b.Register.Name, &b.Register.TableService,
			&b.RevisionMs,
			&b.AuthGenerations[0], &b.AuthGenerations[1], &b.AuthGenerations[2], &b.ExpiresAtMs,
		)
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return Binding{}, ErrUnauthenticated
	}
	if err != nil {
		return Binding{}, err
	}

	return b, nil
}

// Revoked reports what a revocation touched, so a cache in front of
// Authenticate can drop exactly the entries it invalidated.
type Revoked struct {
	RegisterID string
	TokenHash  []byte
}

// Revoke is immediate and total. The device row stays: a stolen tablet is
// something an owner needs to keep seeing.
func (s *Service) Revoke(ctx context.Context, tenantID, deviceID string) (Revoked, error) {
	var out Revoked

	err := pg.InTenantTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		if err := tx.QueryRow(ctx, `SELECT r.id FROM pos_registers r JOIN devices d ON d.pos_register_id=r.id AND d.tenant_id=r.tenant_id WHERE d.id=$1 FOR UPDATE OF r`, deviceID).Scan(&out.RegisterID); err != nil {
			return err
		}
		// Read the credential before clearing it: the caller needs the old
		// hash to drop the matching cache entry. Locking the device's own row
		// is fine — it is the row whose invariant this protects.
		err := tx.QueryRow(ctx,
			`SELECT pos_register_id, token_sha256 FROM devices WHERE id = $1 FOR UPDATE`,
			deviceID).Scan(&out.RegisterID, &out.TokenHash)
		if err != nil {
			return err
		}

		if _, err := tx.Exec(ctx, `
			UPDATE devices
			SET revoked_at = COALESCE(revoked_at, now()),
			    token_sha256 = NULL,
			    token_expires_at = NULL,
			    updated_at = now()
			WHERE id = $1`, deviceID); err != nil {
			return err
		}

		// A pending code for this till is a way back in, so it goes too.
		_, err = tx.Exec(ctx, `
			UPDATE activation_codes SET cancelled_at = now()
			WHERE pos_register_id = $1 AND consumed_at IS NULL AND cancelled_at IS NULL`, out.RegisterID)
		return err
	})

	return out, err
}
