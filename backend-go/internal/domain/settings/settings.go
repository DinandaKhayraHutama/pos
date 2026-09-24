// Package settings owns the business configuration a till used to keep in its
// own preferences (Fase 3 paritas): the merchant's defaults, one outlet's
// overrides, the receipt profile, the business name and its timezone, and
// the switch that turns an outlet over to the version 2 pricing engine.
//
// Server-owned and published: every till pulls business_settings and its
// branch's outlet_settings and caches them for offline use, so two tablets in
// one shop can no longer total the same basket differently. A value is never
// recomputed into an old receipt — each order snapshots what it was priced
// with.
package settings

import (
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"slices"
	"strings"
	"time"
	"unicode"

	"github.com/jackc/pgx/v5"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/devices"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/validation"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
)

var ErrNotFound = errors.New("settings: no such outlet")

// Timezones a merchant may pick. Indonesia's three zones have fixed offsets
// and no daylight saving, which is what lets a till date its receipts without
// a timezone database.
var Timezones = []string{"Asia/Jakarta", "Asia/Makassar", "Asia/Jayapura"}

// RoundingUnits a merchant may round a bill to; 0 is no rounding.
var RoundingUnits = []int{0, 100, 500, 1000}

// Business is the merchant's defaults plus its identity.
type Business struct {
	// Configured says the owner has saved these at least once. Until then a
	// till keeps the values it was already using.
	Configured     bool
	Name           string
	Timezone       string
	TaxRateBP      int
	TaxMode        string
	ServiceEnabled bool
	ServiceRateBP  int
	ServiceTaxable bool
	RoundingUnit   int
	RoundingMode   string
	ReceiptLogoURL *string
	ReceiptFooter  *string
}

// Outlet is one branch's overrides. A nil override inherits the business
// value; zero is a real override.
type Outlet struct {
	OutletID           string
	OutletName         string
	Configured         bool
	TaxRateBP          *int
	TaxMode            *string
	ServiceEnabled     *bool
	ServiceRateBP      *int
	ServiceTaxable     *bool
	RoundingUnit       *int
	RoundingMode       *string
	ReceiptHeader      *string
	ReceiptFooter      *string
	ShowAddress        bool
	ShowPhone          bool
	TrackServer        bool
	DefaultSalesTypeID *string
	// SalesTypeIDs nil means every active sales type.
	SalesTypeIDs   []string
	PaymentGroupID *string
	PricingModel   string
	// BillModel is "v1" once saved bills are on at this branch (Fase 4).
	BillModel string
}

// ImageStore keeps a logo's bytes and says where tills fetch them.
type ImageStore interface {
	Put(ctx context.Context, key string, body []byte) error
	URL(key string) string
}

// ProcessImage re-encodes an upload (catalogue.ProcessUpload).
type ProcessImage func(data []byte, maxEdge int) ([]byte, string, string)

type Service struct {
	pools   pg.Pools
	feed    *syncfeed.Service
	images  ImageStore
	process ProcessImage
}

func NewService(pools pg.Pools, feed *syncfeed.Service, images ImageStore, process ProcessImage) *Service {
	return &Service{pools: pools, feed: feed, images: images, process: process}
}

func defaults() Business {
	return Business{TaxRateBP: 1000, TaxMode: "exclusive", ServiceRateBP: 500, ServiceTaxable: true, RoundingMode: "nearest"}
}

// Business returns the merchant's settings, or the defaults with Configured
// false when nothing was ever saved.
func (s *Service) Business(ctx context.Context, tenantID string) (Business, error) {
	b := defaults()
	err := pg.InTenantReadTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		if err := tx.QueryRow(ctx, `SELECT name, timezone FROM tenants WHERE id = $1`, tenantID).Scan(&b.Name, &b.Timezone); err != nil {
			return err
		}
		err := tx.QueryRow(ctx, `
			SELECT tax_rate_bp, tax_mode, service_enabled, service_rate_bp, service_taxable,
			       rounding_unit, rounding_mode, receipt_logo_url, receipt_footer
			FROM business_settings WHERE tenant_id = $1`, tenantID).Scan(
			&b.TaxRateBP, &b.TaxMode, &b.ServiceEnabled, &b.ServiceRateBP, &b.ServiceTaxable,
			&b.RoundingUnit, &b.RoundingMode, &b.ReceiptLogoURL, &b.ReceiptFooter)
		if errors.Is(err, pgx.ErrNoRows) {
			return nil
		}
		b.Configured = err == nil
		return err
	})
	return b, err
}

func validateBusiness(in *Business) validation.Errors {
	errs := validation.Errors{}
	checkRate(errs, "tax_rate", in.TaxRateBP)
	checkRate(errs, "service_rate", in.ServiceRateBP)
	if !slices.Contains([]string{"exclusive", "inclusive"}, in.TaxMode) {
		errs.Add("tax_mode", "Pilih cara pajak dihitung.")
	}
	if !slices.Contains(RoundingUnits, in.RoundingUnit) {
		errs.Add("rounding_unit", "Pilih satuan pembulatan.")
	}
	if !slices.Contains([]string{"nearest", "up", "down"}, in.RoundingMode) {
		errs.Add("rounding_mode", "Pilih arah pembulatan.")
	}
	in.ReceiptFooter = receiptText(errs, "receipt_footer", in.ReceiptFooter)
	return errs
}

func checkRate(errs validation.Errors, field string, bp int) {
	if bp < 0 || bp > 10000 {
		errs.Add(field, "Tarif harus antara 0 dan 100%.")
	}
}

// receiptText trims a line of receipt text and refuses what the printer
// cannot print. The receipt is set in a PDF base font that covers Latin-1
// only, so anything outside it would come out as a blank box on paper — the
// owner is told now instead. The byte bound matches the column CHECK, which
// exists because the text travels inside a covering index.
func receiptText(errs validation.Errors, field string, v *string) *string {
	if v == nil {
		return nil
	}
	t := strings.TrimSpace(strings.ReplaceAll(*v, "\r\n", "\n"))
	if t == "" {
		return nil
	}
	for _, r := range t {
		if r != '\n' && (r > 0xFF || !unicode.IsPrint(r)) {
			errs.Add(field, "Gunakan huruf, angka, dan tanda baca biasa; emoji dan aksara lain tidak bisa dicetak.")
			return &t
		}
	}
	if len(t) > 600 {
		errs.Add(field, "Teks struk maksimal 600 byte.")
	}
	return &t
}

// SaveBusiness writes the merchant's defaults. Re-saving the same values takes
// no sequence number and wakes no till.
func (s *Service) SaveBusiness(ctx context.Context, tenantID string, in Business) error {
	if err := validateBusiness(&in).Err(); err != nil {
		return err
	}
	return s.feed.Write(ctx, tenantID, func(ctx context.Context, w *syncfeed.Writer) error {
		var current Business
		err := w.Tx.QueryRow(ctx, `
			SELECT tax_rate_bp, tax_mode, service_enabled, service_rate_bp, service_taxable,
			       rounding_unit, rounding_mode, receipt_footer
			FROM business_settings WHERE tenant_id = $1 FOR UPDATE`, tenantID).Scan(
			&current.TaxRateBP, &current.TaxMode, &current.ServiceEnabled, &current.ServiceRateBP,
			&current.ServiceTaxable, &current.RoundingUnit, &current.RoundingMode, &current.ReceiptFooter)
		exists := err == nil
		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
		if exists && current.TaxRateBP == in.TaxRateBP && current.TaxMode == in.TaxMode &&
			current.ServiceEnabled == in.ServiceEnabled && current.ServiceRateBP == in.ServiceRateBP &&
			current.ServiceTaxable == in.ServiceTaxable && current.RoundingUnit == in.RoundingUnit &&
			current.RoundingMode == in.RoundingMode && equalPtr(current.ReceiptFooter, in.ReceiptFooter) {
			return nil
		}
		seq, err := w.Seq(ctx, "business_settings")
		if err != nil {
			return err
		}
		_, err = w.Tx.Exec(ctx, `
			INSERT INTO business_settings (tenant_id, tax_rate_bp, tax_mode, service_enabled, service_rate_bp,
			    service_taxable, rounding_unit, rounding_mode, receipt_footer, sync_seq)
			VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
			ON CONFLICT (tenant_id) DO UPDATE
			SET tax_rate_bp = EXCLUDED.tax_rate_bp, tax_mode = EXCLUDED.tax_mode,
			    service_enabled = EXCLUDED.service_enabled, service_rate_bp = EXCLUDED.service_rate_bp,
			    service_taxable = EXCLUDED.service_taxable, rounding_unit = EXCLUDED.rounding_unit,
			    rounding_mode = EXCLUDED.rounding_mode, receipt_footer = EXCLUDED.receipt_footer,
			    sync_seq = EXCLUDED.sync_seq, updated_at = now()`,
			tenantID, in.TaxRateBP, in.TaxMode, in.ServiceEnabled, in.ServiceRateBP, in.ServiceTaxable,
			in.RoundingUnit, in.RoundingMode, in.ReceiptFooter, seq)
		return err
	})
}

// SetProfile changes the business name and timezone. The caller bumps the
// device-auth cache's tenant generation after it returns, so every till
// re-reads its binding — which carries both — on its next sync.
//
// A timezone change marks today's and yesterday's slices of every outlet
// dirty, under both the old zone's and the new zone's today, so the hourly
// breakdowns recompute. Nothing older moves: rollups read each order's own
// offset, or the timezone frozen before Fase 3 for the orders that carry none.
func (s *Service) SetProfile(ctx context.Context, tenantID, name, timezone string) (timezoneChanged bool, err error) {
	name = strings.TrimSpace(name)
	errs := validation.Errors{}
	errs.Name("name", name, 120)
	if !slices.Contains(Timezones, timezone) {
		errs.Add("timezone", "Pilih WIB, WITA, atau WIT.")
	}
	if err := errs.Err(); err != nil {
		return false, err
	}
	err = pg.InTenantTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		var oldName, oldZone string
		if err := tx.QueryRow(ctx, `SELECT name, timezone FROM tenants WHERE id = $1`, tenantID).Scan(&oldName, &oldZone); err != nil {
			return err
		}
		if oldName == name && oldZone == timezone {
			return nil
		}
		if _, err := tx.Exec(ctx, `UPDATE tenants SET name = $2, timezone = $3, updated_at = now() WHERE id = $1`,
			tenantID, name, timezone); err != nil {
			return err
		}
		if oldZone == timezone {
			return nil
		}
		timezoneChanged = true
		_, err := tx.Exec(ctx, `
			INSERT INTO report_dirty_slices (tenant_id, outlet_id, business_date)
			SELECT $1, o.id, d.day
			FROM outlets o
			CROSS JOIN (
			    SELECT DISTINCT (now() AT TIME ZONE z)::date - k AS day
			    FROM unnest(ARRAY[$2::text, $3::text]) AS z, generate_series(0, 1) AS k
			) d
			WHERE o.tenant_id = $1
			ON CONFLICT (tenant_id, outlet_id, business_date) DO UPDATE
			SET generation = report_dirty_slices.generation + 1, changed_at = now()`,
			tenantID, oldZone, timezone)
		return err
	})
	return timezoneChanged, err
}

// SetReceiptLogo stores an uploaded logo and publishes its URL. Like product
// images, the file lands before the row that names it, and uploading the
// same logo again changes nothing.
func (s *Service) SetReceiptLogo(ctx context.Context, tenantID string, upload []byte) error {
	if s.images == nil || s.process == nil {
		return errors.New("settings: no image store is configured")
	}
	body, ext, problem := s.process(upload, receiptLogoEdge)
	if problem != "" {
		return validation.Errors{"logo": problem}
	}
	key := fmt.Sprintf("receipts/%s/%x.%s", tenantID, sha256.Sum256(body), ext)
	if err := s.images.Put(ctx, key, body); err != nil {
		return fmt.Errorf("store receipt logo: %w", err)
	}
	url := s.images.URL(key)
	return s.setLogo(ctx, tenantID, &url, &key)
}

// ClearReceiptLogo removes the logo from the receipt. The file stays: a till
// that has not synced may still print it.
func (s *Service) ClearReceiptLogo(ctx context.Context, tenantID string) error {
	return s.setLogo(ctx, tenantID, nil, nil)
}

const receiptLogoEdge = 576

func (s *Service) setLogo(ctx context.Context, tenantID string, url, key *string) error {
	return s.feed.Write(ctx, tenantID, func(ctx context.Context, w *syncfeed.Writer) error {
		var current *string
		err := w.Tx.QueryRow(ctx, `SELECT receipt_logo_key FROM business_settings WHERE tenant_id = $1 FOR UPDATE`, tenantID).Scan(&current)
		if errors.Is(err, pgx.ErrNoRows) {
			if url == nil {
				return nil
			}
			return validation.Errors{"logo": "Simpan pengaturan bisnis dulu, lalu unggah logo."}
		}
		if err != nil || equalPtr(current, key) {
			return err
		}
		seq, err := w.Seq(ctx, "business_settings")
		if err != nil {
			return err
		}
		_, err = w.Tx.Exec(ctx, `
			UPDATE business_settings SET receipt_logo_url = $2, receipt_logo_key = $3, sync_seq = $4, updated_at = now()
			WHERE tenant_id = $1`, tenantID, url, key, seq)
		return err
	})
}

// OutletSettings returns one branch's overrides, or an unconfigured outlet.
func (s *Service) OutletSettings(ctx context.Context, tenantID, outletID string) (Outlet, error) {
	if !validation.UUID(outletID) {
		return Outlet{}, ErrNotFound
	}
	o := Outlet{OutletID: outletID, ShowAddress: true, ShowPhone: true, PricingModel: "legacy", BillModel: "legacy"}
	err := pg.InTenantReadTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		if err := tx.QueryRow(ctx, `SELECT name FROM outlets WHERE tenant_id = $1 AND id = $2`, tenantID, outletID).Scan(&o.OutletName); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotFound
			}
			return err
		}
		err := tx.QueryRow(ctx, `
			SELECT tax_rate_bp, tax_mode, service_enabled, service_rate_bp, service_taxable,
			       rounding_unit, rounding_mode, receipt_header, receipt_footer, show_address,
			       show_phone, track_server, default_sales_type_id::text, sales_type_ids::text[],
			       payment_group_id::text, pricing_model, bill_model
			FROM outlet_settings WHERE tenant_id = $1 AND outlet_id = $2`, tenantID, outletID).Scan(
			&o.TaxRateBP, &o.TaxMode, &o.ServiceEnabled, &o.ServiceRateBP, &o.ServiceTaxable,
			&o.RoundingUnit, &o.RoundingMode, &o.ReceiptHeader, &o.ReceiptFooter, &o.ShowAddress,
			&o.ShowPhone, &o.TrackServer, &o.DefaultSalesTypeID, &o.SalesTypeIDs, &o.PaymentGroupID, &o.PricingModel, &o.BillModel)
		if errors.Is(err, pgx.ErrNoRows) {
			return nil
		}
		o.Configured = err == nil
		return err
	})
	return o, err
}

func validateOutlet(in *Outlet) validation.Errors {
	errs := validation.Errors{}
	if in.TaxRateBP != nil {
		checkRate(errs, "tax_rate", *in.TaxRateBP)
	}
	if in.ServiceRateBP != nil {
		checkRate(errs, "service_rate", *in.ServiceRateBP)
	}
	if in.TaxMode != nil && !slices.Contains([]string{"exclusive", "inclusive"}, *in.TaxMode) {
		errs.Add("tax_mode", "Pilih cara pajak dihitung.")
	}
	if in.RoundingUnit != nil && !slices.Contains(RoundingUnits, *in.RoundingUnit) {
		errs.Add("rounding_unit", "Pilih satuan pembulatan.")
	}
	if in.RoundingMode != nil && !slices.Contains([]string{"nearest", "up", "down"}, *in.RoundingMode) {
		errs.Add("rounding_mode", "Pilih arah pembulatan.")
	}
	for _, id := range append(slices.Clone(in.SalesTypeIDs), deref(in.DefaultSalesTypeID), deref(in.PaymentGroupID)) {
		if id != "" && !validation.UUID(id) {
			errs.Add("sales_types", "Pilihan tidak dikenal.")
		}
	}
	if len(in.SalesTypeIDs) > 32 {
		errs.Add("sales_types", "Terlalu banyak jenis penjualan.")
	}
	in.ReceiptHeader = receiptText(errs, "receipt_header", in.ReceiptHeader)
	in.ReceiptFooter = receiptText(errs, "receipt_footer", in.ReceiptFooter)
	return errs
}

// SaveOutlet writes one branch's overrides. The pricing model is not part of
// it: switching an outlet to version 2 has its own call, because it has its
// own precondition.
func (s *Service) SaveOutlet(ctx context.Context, tenantID string, in Outlet) error {
	if !validation.UUID(in.OutletID) {
		return ErrNotFound
	}
	if err := validateOutlet(&in).Err(); err != nil {
		return err
	}
	return s.feed.Write(ctx, tenantID, func(ctx context.Context, w *syncfeed.Writer) error {
		if err := claimOutlet(ctx, w.Tx, tenantID, in.OutletID, false); err != nil {
			return err
		}
		if err := checkReferences(ctx, w.Tx, tenantID, in); err != nil {
			return err
		}
		current, err := lockedOutlet(ctx, w.Tx, tenantID, in.OutletID)
		if err != nil {
			return err
		}
		in.PricingModel = current.PricingModel
		in.BillModel = current.BillModel
		if current.Configured && sameOutlet(current, in) {
			return nil
		}
		return writeOutlet(ctx, w, tenantID, in)
	})
}

// ErrDevicesNotReady carries the tills that cannot run a model yet.
type ErrDevicesNotReady struct{ Devices []devices.IncompatibleDevice }

func (e *ErrDevicesNotReady) Error() string {
	return fmt.Sprintf("settings: %d device(s) cannot run this model yet", len(e.Devices))
}

// SetPricingModel switches an outlet between the legacy cart math and the
// version 2 engine. Turning version 2 on is refused while any active till of
// the branch has not reported pricing-v2: an older build would keep pricing
// with its own rules, and two tills in one shop would charge differently.
//
// The outlet row is locked FOR UPDATE before the check, and activation holds
// it FOR SHARE for its own, so a tablet cannot be activated on an old build in
// between the check and the switch.
func (s *Service) SetPricingModel(ctx context.Context, tenantID, outletID, model string) error {
	if !validation.UUID(outletID) {
		return ErrNotFound
	}
	if model != "legacy" && model != "v2" {
		return validation.Errors{"pricing_model": "Pilih model harga."}
	}
	return s.feed.Write(ctx, tenantID, func(ctx context.Context, w *syncfeed.Writer) error {
		if err := claimOutlet(ctx, w.Tx, tenantID, outletID, true); err != nil {
			return err
		}
		if model == "v2" {
			stale, err := devices.IncompatibleDevices(ctx, w.Tx, outletID, devices.CapabilityPricingV2)
			if err != nil {
				return err
			}
			if len(stale) > 0 {
				return &ErrDevicesNotReady{Devices: stale}
			}
		}
		current, err := lockedOutlet(ctx, w.Tx, tenantID, outletID)
		if err != nil {
			return err
		}
		if current.Configured && current.PricingModel == model {
			return nil
		}
		current.PricingModel = model
		return writeOutlet(ctx, w, tenantID, current)
	})
}

// SetBillModel switches saved bills (Fase 4) on or off at one outlet.
//
// On only once every active till of the branch reports bills-v1: an older till
// reads a table held by a bill as free, has no idea a dispatch already took the
// stock, and would take it again at checkout. Off is always allowed — bills
// already open stay open and can still be settled, parked or claimed; only new
// bills stop — which is the forward-fix the rollback plan asks for rather than
// a flag that re-interprets history.
func (s *Service) SetBillModel(ctx context.Context, tenantID, outletID, model string) error {
	if !validation.UUID(outletID) {
		return ErrNotFound
	}
	if model != "legacy" && model != "v1" {
		return validation.Errors{"bill_model": "Pilih model bill."}
	}
	return s.feed.Write(ctx, tenantID, func(ctx context.Context, w *syncfeed.Writer) error {
		if err := claimOutlet(ctx, w.Tx, tenantID, outletID, true); err != nil {
			return err
		}
		if model == "v1" {
			stale, err := devices.IncompatibleDevices(ctx, w.Tx, outletID, devices.CapabilityBillsV1)
			if err != nil {
				return err
			}
			if len(stale) > 0 {
				return &ErrDevicesNotReady{Devices: stale}
			}
		}
		current, err := lockedOutlet(ctx, w.Tx, tenantID, outletID)
		if err != nil {
			return err
		}
		if current.Configured && billModelOf(current) == model {
			return nil
		}
		current.BillModel = model
		return writeOutlet(ctx, w, tenantID, current)
	})
}

func claimOutlet(ctx context.Context, tx pgx.Tx, tenantID, outletID string, exclusive bool) error {
	lock := "FOR KEY SHARE"
	if exclusive {
		lock = "FOR UPDATE"
	}
	var found bool
	err := tx.QueryRow(ctx, `SELECT true FROM outlets WHERE tenant_id = $1 AND id = $2 `+lock, tenantID, outletID).Scan(&found)
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrNotFound
	}
	return err
}

// checkReferences refuses a sales type or payment group of another merchant
// with a message rather than a foreign-key error, and one that no longer
// exists.
func checkReferences(ctx context.Context, tx pgx.Tx, tenantID string, in Outlet) error {
	ids := slices.Clone(in.SalesTypeIDs)
	if in.DefaultSalesTypeID != nil {
		ids = append(ids, *in.DefaultSalesTypeID)
	}
	if len(ids) > 0 {
		var known int
		if err := tx.QueryRow(ctx, `SELECT count(DISTINCT id) FROM sales_types WHERE tenant_id = $1 AND deleted_at IS NULL AND id = ANY($2::uuid[])`,
			tenantID, ids).Scan(&known); err != nil {
			return err
		}
		if known != len(uniq(ids)) {
			return validation.Errors{"sales_types": "Jenis penjualan yang dipilih tidak ada lagi."}
		}
	}
	if in.DefaultSalesTypeID != nil && in.SalesTypeIDs != nil && !slices.Contains(in.SalesTypeIDs, *in.DefaultSalesTypeID) {
		return validation.Errors{"default_sales_type": "Jenis penjualan bawaan harus termasuk yang tersedia."}
	}
	if in.PaymentGroupID != nil {
		var ok bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM payment_groups WHERE tenant_id = $1 AND id = $2 AND deleted_at IS NULL)`,
			tenantID, *in.PaymentGroupID).Scan(&ok); err != nil {
			return err
		}
		if !ok {
			return validation.Errors{"payment_group": "Grup pembayaran tidak ada lagi."}
		}
	}
	return nil
}

func lockedOutlet(ctx context.Context, tx pgx.Tx, tenantID, outletID string) (Outlet, error) {
	o := Outlet{OutletID: outletID, ShowAddress: true, ShowPhone: true, PricingModel: "legacy", BillModel: "legacy"}
	err := tx.QueryRow(ctx, `
		SELECT tax_rate_bp, tax_mode, service_enabled, service_rate_bp, service_taxable,
		       rounding_unit, rounding_mode, receipt_header, receipt_footer, show_address,
		       show_phone, track_server, default_sales_type_id::text, sales_type_ids::text[],
		       payment_group_id::text, pricing_model, bill_model
		FROM outlet_settings WHERE tenant_id = $1 AND outlet_id = $2 FOR UPDATE`, tenantID, outletID).Scan(
		&o.TaxRateBP, &o.TaxMode, &o.ServiceEnabled, &o.ServiceRateBP, &o.ServiceTaxable,
		&o.RoundingUnit, &o.RoundingMode, &o.ReceiptHeader, &o.ReceiptFooter, &o.ShowAddress,
		&o.ShowPhone, &o.TrackServer, &o.DefaultSalesTypeID, &o.SalesTypeIDs, &o.PaymentGroupID, &o.PricingModel, &o.BillModel)
	if errors.Is(err, pgx.ErrNoRows) {
		return o, nil
	}
	o.Configured = err == nil
	return o, err
}

func writeOutlet(ctx context.Context, w *syncfeed.Writer, tenantID string, in Outlet) error {
	seq, err := w.OutletSeqBlock(ctx, "outlet_settings", in.OutletID, 1)
	if err != nil {
		return err
	}
	var salesTypes any
	if in.SalesTypeIDs != nil {
		salesTypes = in.SalesTypeIDs
	}
	_, err = w.Tx.Exec(ctx, `
		INSERT INTO outlet_settings (tenant_id, outlet_id, tax_rate_bp, tax_mode, service_enabled, service_rate_bp,
		    service_taxable, rounding_unit, rounding_mode, receipt_header, receipt_footer, show_address, show_phone,
		    track_server, default_sales_type_id, sales_type_ids, payment_group_id, pricing_model, sync_seq, bill_model)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16::uuid[], $17, $18, $19, $20)
		ON CONFLICT (tenant_id, outlet_id) DO UPDATE
		SET tax_rate_bp = EXCLUDED.tax_rate_bp, tax_mode = EXCLUDED.tax_mode,
		    service_enabled = EXCLUDED.service_enabled, service_rate_bp = EXCLUDED.service_rate_bp,
		    service_taxable = EXCLUDED.service_taxable, rounding_unit = EXCLUDED.rounding_unit,
		    rounding_mode = EXCLUDED.rounding_mode, receipt_header = EXCLUDED.receipt_header,
		    receipt_footer = EXCLUDED.receipt_footer, show_address = EXCLUDED.show_address,
		    show_phone = EXCLUDED.show_phone, track_server = EXCLUDED.track_server,
		    default_sales_type_id = EXCLUDED.default_sales_type_id, sales_type_ids = EXCLUDED.sales_type_ids,
		    payment_group_id = EXCLUDED.payment_group_id, pricing_model = EXCLUDED.pricing_model,
		    bill_model = EXCLUDED.bill_model, sync_seq = EXCLUDED.sync_seq, updated_at = now()`,
		tenantID, in.OutletID, in.TaxRateBP, in.TaxMode, in.ServiceEnabled, in.ServiceRateBP, in.ServiceTaxable,
		in.RoundingUnit, in.RoundingMode, in.ReceiptHeader, in.ReceiptFooter, in.ShowAddress, in.ShowPhone,
		in.TrackServer, in.DefaultSalesTypeID, salesTypes, in.PaymentGroupID, in.PricingModel, seq, billModelOf(in))
	return err
}

func sameOutlet(a, b Outlet) bool {
	return equalPtr(a.TaxRateBP, b.TaxRateBP) && equalPtr(a.TaxMode, b.TaxMode) &&
		equalPtr(a.ServiceEnabled, b.ServiceEnabled) && equalPtr(a.ServiceRateBP, b.ServiceRateBP) &&
		equalPtr(a.ServiceTaxable, b.ServiceTaxable) && equalPtr(a.RoundingUnit, b.RoundingUnit) &&
		equalPtr(a.RoundingMode, b.RoundingMode) && equalPtr(a.ReceiptHeader, b.ReceiptHeader) &&
		equalPtr(a.ReceiptFooter, b.ReceiptFooter) && a.ShowAddress == b.ShowAddress &&
		a.ShowPhone == b.ShowPhone && a.TrackServer == b.TrackServer &&
		equalPtr(a.DefaultSalesTypeID, b.DefaultSalesTypeID) && (a.SalesTypeIDs == nil) == (b.SalesTypeIDs == nil) &&
		slices.Equal(a.SalesTypeIDs, b.SalesTypeIDs) && equalPtr(a.PaymentGroupID, b.PaymentGroupID) &&
		a.PricingModel == b.PricingModel && billModelOf(a) == billModelOf(b)
}

func billModelOf(o Outlet) string {
	if o.BillModel == "" {
		return "legacy"
	}
	return o.BillModel
}

func equalPtr[T comparable](a, b *T) bool {
	if a == nil || b == nil {
		return a == nil && b == nil
	}
	return *a == *b
}

func deref(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}

func uniq(ids []string) []string {
	out := []string{}
	for _, id := range ids {
		if !slices.Contains(out, id) {
			out = append(out, id)
		}
	}
	return out
}

// OffsetMinutes is the fixed offset of a supported zone. A till carries the
// same table.
func OffsetMinutes(zone string) (int, bool) {
	loc, err := time.LoadLocation(zone)
	if err != nil || !slices.Contains(Timezones, zone) {
		return 0, false
	}
	_, off := time.Now().In(loc).Zone()
	return off / 60, true
}
