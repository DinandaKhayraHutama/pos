package devices

import (
	"context"
	"errors"
	"slices"
	"strings"

	"github.com/jackc/pgx/v5"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
)

// Capability tokens a till build may report in X-Device-Capabilities.
//
// These are facts about an APP BUILD, not commercial switches: tenant feature
// flags (internal/domain/entitlements) close Backoffice sections, these say
// whether a tablet can honour a model the Backoffice is about to turn on.
const (
	// CapabilityPricingV2 is the Fase 3 pricing engine: sales-type prices,
	// inclusive tax, rounding, item discounts, custom amounts and the new
	// payment kinds. Gates an outlet's pricing_model.
	CapabilityPricingV2 = "pricing-v2"
	// CapabilityRolesV1 is permission-based roles. An older till reads an
	// unknown role as a cashier who may sell, so a custom role may not be
	// assigned anywhere in the business while such a till is active.
	CapabilityRolesV1 = "roles-v1"
	// CapabilityBillsV1 is saved bills (Fase 4): bills and dispatches pushed
	// ahead of their receipt, stock consumed at dispatch, tables held by an
	// online seating. An older till would read a seated table as free and take
	// a dispatched line's stock a second time at checkout. Gates an outlet's
	// bill_model.
	CapabilityBillsV1 = "bills-v1"
)

var knownCapabilities = []string{CapabilityBillsV1, CapabilityPricingV2, CapabilityRolesV1}

// KnownCapabilities is every token this server knows, sorted — what a build
// must report to run everything the Backoffice can switch on.
func KnownCapabilities() []string {
	out := slices.Clone(knownCapabilities)
	slices.Sort(out)
	return out
}

// ErrIncompatibleApp is an activation refused because the business already
// runs a model this build cannot honour.
var ErrIncompatibleApp = errors.New("devices: this app build cannot run the models the business has enabled")

// ParseCapabilities reads the header into a sorted, de-duplicated set of the
// tokens this server knows. Unknown tokens are dropped, so a newer build
// reporting something this server has never heard of changes nothing.
func ParseCapabilities(header string) []string {
	out := []string{}
	if len(header) > 256 {
		header = header[:256]
	}
	for _, token := range strings.Split(header, ",") {
		token = strings.ToLower(strings.TrimSpace(token))
		if slices.Contains(knownCapabilities, token) && !slices.Contains(out, token) {
			out = append(out, token)
		}
	}
	slices.Sort(out)
	return out
}

// SameCapabilities compares two parsed sets.
func SameCapabilities(a, b []string) bool {
	return slices.Equal(normalised(a), normalised(b))
}

func normalised(s []string) []string {
	if s == nil {
		return []string{}
	}
	return s
}

// RecordCapabilities stores what a device reported, only when it differs.
//
// Never through updated_at: that column feeds the device revision, and moving
// it would send the till to /devices/me on every report. The auth-version
// trigger ignores this column too; a cache in front drops the device's entry.
func (s *Service) RecordCapabilities(ctx context.Context, b Binding, caps []string) error {
	return pg.InTenantTx(ctx, s.pools.Tenant, b.Tenant.ID, func(ctx context.Context, tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `
			UPDATE devices SET capabilities = $2, capabilities_reported_at = now()
			WHERE id = $1 AND capabilities IS DISTINCT FROM $2`,
			b.Device.ID, normalised(caps))
		return err
	})
}

// IncompatibleDevice is a live installation that lacks a capability.
type IncompatibleDevice struct {
	ID           string
	Label        *string
	RegisterName string
	OutletName   string
	LastSeenAtMs *int64
}

// IncompatibleDevices lists the active devices of one outlet — or of the whole
// business when outletID is empty — that have not reported capability.
//
// "Active" means not revoked. An expired token is still counted: nothing
// guarantees the owner will not re-activate that tablet on the same build, and
// it is the answer that errs towards refusing a switch rather than towards a
// till silently mis-pricing.
func IncompatibleDevices(ctx context.Context, tx pgx.Tx, outletID, capability string) ([]IncompatibleDevice, error) {
	rows, err := tx.Query(ctx, `
		SELECT d.id::text, d.label, r.name, o.name,
		       (EXTRACT(EPOCH FROM d.last_seen_at) * 1000)::bigint
		FROM devices d
		JOIN pos_registers r ON r.tenant_id = d.tenant_id AND r.id = d.pos_register_id
		JOIN outlets o ON o.tenant_id = d.tenant_id AND o.id = d.outlet_id
		WHERE d.tenant_id = app.current_tenant_id()
		  AND d.revoked_at IS NULL
		  AND ($1 = '' OR d.outlet_id::text = $1)
		  AND NOT (d.capabilities @> ARRAY[$2]::text[])
		ORDER BY o.name, r.name, d.id`, outletID, capability)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(row pgx.CollectableRow) (IncompatibleDevice, error) {
		var d IncompatibleDevice
		err := row.Scan(&d.ID, &d.Label, &d.RegisterName, &d.OutletName, &d.LastSeenAtMs)
		return d, err
	})
}

// requiredForActivation names the capabilities a till activating at outletID
// must report, given what the business has already switched on.
func requiredForActivation(ctx context.Context, tx pgx.Tx, outletID string) ([]string, error) {
	var pricingV2, customRoles, billsV1 bool
	err := tx.QueryRow(ctx, `
		SELECT EXISTS (SELECT 1 FROM outlet_settings
		               WHERE tenant_id = app.current_tenant_id() AND outlet_id = $1 AND pricing_model = 'v2'),
		       EXISTS (SELECT 1 FROM employees
		               WHERE tenant_id = app.current_tenant_id() AND role = 'custom' AND deleted_at IS NULL),
		       EXISTS (SELECT 1 FROM outlet_settings
		               WHERE tenant_id = app.current_tenant_id() AND outlet_id = $1 AND bill_model = 'v1')`,
		outletID).Scan(&pricingV2, &customRoles, &billsV1)
	if err != nil {
		return nil, err
	}
	var need []string
	if billsV1 {
		need = append(need, CapabilityBillsV1)
	}
	if pricingV2 {
		need = append(need, CapabilityPricingV2)
	}
	if customRoles {
		need = append(need, CapabilityRolesV1)
	}
	return need, nil
}
