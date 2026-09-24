package backoffice

import (
	"context"
	"errors"
	"io"
	"net/http"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/backoffice/views"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/catalogue"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/devices"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/payments"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/pricing"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/promos"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/settings"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/validation"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
)

// Business settings (Fase 3 paritas). Every screen here is manageSettings,
// except discounts (managePromos), product prices (manageCatalogue) and the
// account page (anyone signed in).

// ---- percent fields ---------------------------------------------------------

// percentBP reads a percentage typed the way people write it ("10", "10,5",
// "11.25") into basis points. Two decimals at most: a rate finer than that is
// not a rate anyone publishes.
func (p *parser) percentBP(name string) int {
	v := p.optionalPercentBP(name)
	if v == nil {
		p.errs.Add(name, "Isi persentase.")
		return 0
	}
	return *v
}

func (p *parser) optionalPercentBP(name string) *int {
	raw := strings.ReplaceAll(p.text(name), ",", ".")
	if raw == "" {
		return nil
	}
	whole, frac, _ := strings.Cut(raw, ".")
	if len(frac) > 2 || whole == "" {
		p.errs.Add(name, "Maksimal dua angka di belakang koma.")
		return nil
	}
	frac += strings.Repeat("0", 2-len(frac))
	w, err1 := strconv.Atoi(whole)
	f, err2 := strconv.Atoi(frac)
	if err1 != nil || err2 != nil || w < 0 {
		p.errs.Add(name, "Harus angka.")
		return nil
	}
	bp := w*100 + f
	if bp > 10000 {
		p.errs.Add(name, "Maksimal 100%.")
		return nil
	}
	return &bp
}

func bpText(bp int) string { return strings.ReplaceAll(views.BasisPoints(int64(bp)), ",", ",") }

// ---- business -----------------------------------------------------------------

func businessForm(b settings.Business) views.Form {
	f := views.NewForm()
	f.Values["tax_rate"] = bpText(b.TaxRateBP)
	f.Values["tax_mode"] = b.TaxMode
	f.Values["service_rate"] = bpText(b.ServiceRateBP)
	if b.ServiceEnabled {
		f.Values["service_enabled"] = "on"
	}
	if b.ServiceTaxable {
		f.Values["service_taxable"] = "on"
	}
	f.Values["rounding_unit"] = itoa(b.RoundingUnit)
	f.Values["rounding_mode"] = b.RoundingMode
	f.Values["receipt_footer"] = optionalString(b.ReceiptFooter)
	return f
}

func profileSettingsForm(b settings.Business) views.Form {
	f := views.NewForm()
	f.Values["name"] = b.Name
	f.Values["timezone"] = b.Timezone
	return f
}

func (h *Handler) settingsPage(w http.ResponseWriter, r *http.Request) {
	b, err := h.settings.Business(r.Context(), tenantOf(r))
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	h.render(w, r, views.SettingsPage(h.sessionView(r), profileSettingsForm(b), businessForm(b), b, receiptPreview(b, nil)))
}

func (h *Handler) saveSettingsProfile(w http.ResponseWriter, r *http.Request) {
	f, ok := h.parseForm(w, r)
	if !ok {
		return
	}
	tenantID := tenantOf(r)
	p := newParser(f)
	_, err := h.settings.SetProfile(r.Context(), tenantID, p.text("name"), p.text("timezone"))
	if err == nil {
		// The name and zone ride on every till's binding; bumping the tenant
		// generation is what makes each till re-read it on its next sync.
		if h.auth != nil {
			h.auth.Bump(r.Context(), "tenant", tenantID)
		}
		toast(w, "Profil bisnis disimpan.")
	} else if !absorb(&f, err) {
		h.serverError(w, r, err)
		return
	}
	h.render(w, r, views.ProfileSettingsForm(f))
}

func (h *Handler) saveBusinessSettings(w http.ResponseWriter, r *http.Request) {
	f, ok := h.parseForm(w, r)
	if !ok {
		return
	}
	p := newParser(f)
	unit, _ := strconv.Atoi(p.text("rounding_unit"))
	in := settings.Business{
		TaxRateBP:      p.percentBP("tax_rate"),
		TaxMode:        p.text("tax_mode"),
		ServiceEnabled: p.check("service_enabled"),
		ServiceTaxable: p.check("service_taxable"),
		RoundingUnit:   unit,
		RoundingMode:   p.text("rounding_mode"),
		ReceiptFooter:  p.optionalText("receipt_footer"),
	}
	if rate := p.optionalPercentBP("service_rate"); rate != nil {
		in.ServiceRateBP = *rate
	}
	err := p.errs.Err()
	if err == nil {
		err = h.settings.SaveBusiness(r.Context(), tenantOf(r), in)
	}
	if err == nil {
		toast(w, "Pengaturan disimpan. Till menerimanya pada sinkron berikutnya.")
	} else if !absorb(&f, err) {
		h.serverError(w, r, err)
		return
	}
	h.render(w, r, views.BusinessSettingsForm(f))
}

func (h *Handler) uploadReceiptLogo(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, maxImageUploadBytes)
	if err := r.ParseMultipartForm(maxImageUploadBytes); err != nil {
		toastError(w, "Berkas tidak terbaca atau lebih dari 10 MB.")
		w.WriteHeader(http.StatusNoContent)
		return
	}
	defer r.MultipartForm.RemoveAll()
	file, _, err := r.FormFile("logo")
	if err != nil {
		toastError(w, "Pilih berkas gambar.")
		w.WriteHeader(http.StatusNoContent)
		return
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, catalogue.MaxImageBytes+1))
	if err != nil {
		toastError(w, "Berkas tidak terbaca.")
		w.WriteHeader(http.StatusNoContent)
		return
	}
	err = h.settings.SetReceiptLogo(r.Context(), tenantOf(r), data)
	if fields, ok := validation.As(err); ok {
		toastError(w, fields["logo"])
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	redirect(w, r, "/backoffice/settings")
}

func (h *Handler) deleteReceiptLogo(w http.ResponseWriter, r *http.Request) {
	if err := h.settings.ClearReceiptLogo(r.Context(), tenantOf(r)); err != nil {
		h.serverError(w, r, err)
		return
	}
	redirect(w, r, "/backoffice/settings")
}

// receiptPreview prices a sample bill with the settings on screen — through
// the same engine the till runs — so what the owner reads is what a customer
// will be charged.
func receiptPreview(b settings.Business, o *settings.Outlet) views.ReceiptPreview {
	cfg := effective(b, o)
	in := pricing.Input{
		Version: pricing.VersionV2, TaxMode: cfg.TaxMode, ServiceTaxable: cfg.ServiceTaxable,
		RoundingUnit: int64(cfg.RoundingUnit), RoundingMode: cfg.RoundingMode,
		Lines: []pricing.Line{
			{UnitPrice: 25000, Quantity: 2, TaxRateBP: int64(cfg.TaxRateBP)},
			{UnitPrice: 8500, Quantity: 1, TaxRateBP: int64(cfg.TaxRateBP)},
		},
	}
	if cfg.ServiceEnabled {
		in.ServiceRateBP = int64(cfg.ServiceRateBP)
	}
	res, err := pricing.Compute(in)
	p := views.ReceiptPreview{BusinessName: b.Name, Footer: "Terima kasih"}
	if b.ReceiptFooter != nil {
		p.Footer = *b.ReceiptFooter
	}
	if o != nil && o.ReceiptFooter != nil {
		p.Footer = *o.ReceiptFooter
	}
	if o != nil && o.ReceiptHeader != nil {
		p.Header = *o.ReceiptHeader
	}
	if b.ReceiptLogoURL != nil {
		p.LogoURL = *b.ReceiptLogoURL
	}
	if err != nil {
		return p
	}
	p.Lines = []views.PreviewLine{
		{Label: "2 x Nasi goreng", Amount: views.Rupiah(res.Lines[0].Gross)},
		{Label: "1 x Es teh", Amount: views.Rupiah(res.Lines[1].Gross)},
	}
	p.Totals = append(p.Totals, views.PreviewLine{Label: "Subtotal", Amount: views.Rupiah(res.Subtotal)})
	if res.ServiceCharge > 0 {
		p.Totals = append(p.Totals, views.PreviewLine{Label: "Service " + views.BasisPoints(int64(cfg.ServiceRateBP)) + "%", Amount: views.Rupiah(res.ServiceCharge)})
	}
	if res.Tax > 0 {
		label := "PB1 " + views.BasisPoints(int64(cfg.TaxRateBP)) + "%"
		if res.TaxIncluded > 0 {
			label += " (termasuk " + views.Rupiah(res.TaxIncluded) + ")"
		}
		amount := views.Rupiah(res.Tax - res.TaxIncluded)
		p.Totals = append(p.Totals, views.PreviewLine{Label: label, Amount: amount})
	}
	if res.Rounding != 0 {
		p.Totals = append(p.Totals, views.PreviewLine{Label: "Pembulatan", Amount: views.Rupiah(res.Rounding)})
	}
	p.Totals = append(p.Totals, views.PreviewLine{Label: "Total", Amount: views.Rupiah(res.Total), Strong: true})
	return p
}

func effective(b settings.Business, o *settings.Outlet) settings.Business {
	if o == nil {
		return b
	}
	if o.TaxRateBP != nil {
		b.TaxRateBP = *o.TaxRateBP
	}
	if o.TaxMode != nil {
		b.TaxMode = *o.TaxMode
	}
	if o.ServiceEnabled != nil {
		b.ServiceEnabled = *o.ServiceEnabled
	}
	if o.ServiceRateBP != nil {
		b.ServiceRateBP = *o.ServiceRateBP
	}
	if o.ServiceTaxable != nil {
		b.ServiceTaxable = *o.ServiceTaxable
	}
	if o.RoundingUnit != nil {
		b.RoundingUnit = *o.RoundingUnit
	}
	if o.RoundingMode != nil {
		b.RoundingMode = *o.RoundingMode
	}
	return b
}

// ---- outlets ------------------------------------------------------------------

func (h *Handler) outletSettingsList(w http.ResponseWriter, r *http.Request) {
	tenantID := tenantOf(r)
	list, err := h.outlets.List(r.Context(), tenantID)
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	rows := make([]views.OutletSettingsRow, 0, len(list))
	for _, o := range list {
		s, err := h.settings.OutletSettings(r.Context(), tenantID, o.ID)
		if err != nil {
			h.serverError(w, r, err)
			return
		}
		stale, err := h.incompatible(r, o.ID)
		if err != nil {
			h.serverError(w, r, err)
			return
		}
		rows = append(rows, views.OutletSettingsRow{ID: o.ID, Name: o.Name, Configured: s.Configured, PricingModel: s.PricingModel, BillModel: s.BillModel, Incompatible: len(stale)})
	}
	h.render(w, r, views.OutletSettingsListPage(h.sessionView(r), rows))
}

func (h *Handler) incompatible(r *http.Request, outletID string) ([]views.IncompatibleDeviceView, error) {
	return h.incompatibleFor(r, outletID, devices.CapabilityPricingV2)
}

// incompatibleFor lists the active tills of one outlet that have not reported
// capability — what stands between the owner and switching a model on.
func (h *Handler) incompatibleFor(r *http.Request, outletID, capability string) ([]views.IncompatibleDeviceView, error) {
	var out []views.IncompatibleDeviceView
	err := pg.InTenantReadTx(r.Context(), h.pools.Tenant, tenantOf(r), func(ctx context.Context, tx pgx.Tx) error {
		found, err := devices.IncompatibleDevices(ctx, tx, outletID, capability)
		for _, d := range found {
			v := views.IncompatibleDeviceView{Register: d.RegisterName, Label: "tanpa nama", LastSeen: "belum pernah"}
			if d.Label != nil && *d.Label != "" {
				v.Label = *d.Label
			}
			if d.LastSeenAtMs != nil {
				v.LastSeen = time.UnixMilli(*d.LastSeenAtMs).Format("02-01-2006 15:04")
			}
			out = append(out, v)
		}
		return err
	})
	return out, err
}

func outletSettingsForm(o settings.Outlet) views.Form {
	f := views.NewForm()
	if o.TaxRateBP != nil {
		f.Values["tax_rate"] = bpText(*o.TaxRateBP)
	}
	f.Values["tax_mode"] = optionalString(o.TaxMode)
	if o.ServiceEnabled != nil {
		f.Values["service_enabled"] = map[bool]string{true: "on", false: "off"}[*o.ServiceEnabled]
	}
	if o.ServiceRateBP != nil {
		f.Values["service_rate"] = bpText(*o.ServiceRateBP)
	}
	if o.RoundingUnit != nil {
		f.Values["rounding_unit"] = itoa(*o.RoundingUnit)
	}
	f.Values["rounding_mode"] = optionalString(o.RoundingMode)
	f.Values["receipt_header"] = optionalString(o.ReceiptHeader)
	f.Values["receipt_footer"] = optionalString(o.ReceiptFooter)
	for name, on := range map[string]bool{"show_address": o.ShowAddress, "show_phone": o.ShowPhone, "track_server": o.TrackServer} {
		if on {
			f.Values[name] = "on"
		}
	}
	f.Multi["sales_types"] = o.SalesTypeIDs
	f.Values["default_sales_type"] = optionalString(o.DefaultSalesTypeID)
	f.Values["payment_group"] = optionalString(o.PaymentGroupID)
	return f
}

func (h *Handler) outletSettingsOptions(r *http.Request) ([]catalogue.SalesType, []views.Option, error) {
	types, err := h.catalogue.ListSalesTypes(r.Context(), tenantOf(r))
	if err != nil {
		return nil, nil, err
	}
	groups, err := h.payments.Groups(r.Context(), tenantOf(r))
	if err != nil {
		return nil, nil, err
	}
	options := []views.Option{{Value: "", Label: "Semua metode aktif"}}
	for _, g := range groups {
		options = append(options, views.Option{Value: g.ID, Label: g.Name})
	}
	return types, options, nil
}

func (h *Handler) outletSettingsPage(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	o, err := h.settings.OutletSettings(r.Context(), tenantOf(r), id)
	if h.failed(w, r, err, settings.ErrNotFound) {
		return
	}
	types, groups, err := h.outletSettingsOptions(r)
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	stale, err := h.incompatible(r, id)
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	staleBills, err := h.incompatibleFor(r, id, devices.CapabilityBillsV1)
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	h.render(w, r, views.OutletSettingsPage(h.sessionView(r), o, outletSettingsForm(o), types, groups, stale, staleBills))
}

// setOutletBillModel switches saved bills (Fase 4) on or off at one outlet.
func (h *Handler) setOutletBillModel(w http.ResponseWriter, r *http.Request) {
	f, ok := h.parseForm(w, r)
	if !ok {
		return
	}
	id := chi.URLParam(r, "id")
	err := h.settings.SetBillModel(r.Context(), tenantOf(r), id, f.V("model"))
	var notReady *settings.ErrDevicesNotReady
	switch {
	case errors.As(err, &notReady):
		f.Errors["bill_model"] = strconv.Itoa(len(notReady.Devices)) + " perangkat belum siap. Perbarui aplikasinya dulu."
	case err == nil:
		toast(w, "Saved bill diperbarui. Till menerimanya pada sinkron berikutnya.")
	case !absorb(&f, err) && h.failed(w, r, err, settings.ErrNotFound):
		return
	}
	o, err := h.settings.OutletSettings(r.Context(), tenantOf(r), id)
	if h.failed(w, r, err, settings.ErrNotFound) {
		return
	}
	stale, err := h.incompatibleFor(r, id, devices.CapabilityBillsV1)
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	h.render(w, r, views.BillModelCard(o, stale, f))
}

func (h *Handler) saveOutletSettings(w http.ResponseWriter, r *http.Request) {
	f, ok := h.parseForm(w, r, "sales_types")
	if !ok {
		return
	}
	id := chi.URLParam(r, "id")
	p := newParser(f)
	in := settings.Outlet{
		OutletID:           id,
		TaxRateBP:          p.optionalPercentBP("tax_rate"),
		ServiceRateBP:      p.optionalPercentBP("service_rate"),
		ReceiptHeader:      p.optionalText("receipt_header"),
		ReceiptFooter:      p.optionalText("receipt_footer"),
		ShowAddress:        p.check("show_address"),
		ShowPhone:          p.check("show_phone"),
		TrackServer:        p.check("track_server"),
		DefaultSalesTypeID: p.optionalText("default_sales_type"),
		PaymentGroupID:     p.optionalText("payment_group"),
	}
	in.TaxMode = p.optionalText("tax_mode")
	in.RoundingMode = p.optionalText("rounding_mode")
	if unit := p.text("rounding_unit"); unit != "" {
		n, _ := strconv.Atoi(unit)
		in.RoundingUnit = &n
	}
	switch p.text("service_enabled") {
	case "on":
		in.ServiceEnabled = ptrTo(true)
	case "off":
		in.ServiceEnabled = ptrTo(false)
	}
	if picked := f.Multi["sales_types"]; len(picked) > 0 {
		in.SalesTypeIDs = slices.Clone(picked)
	}
	err := p.errs.Err()
	if err == nil {
		err = h.settings.SaveOutlet(r.Context(), tenantOf(r), in)
	}
	if err == nil {
		toast(w, "Pengaturan outlet disimpan.")
	} else if !absorb(&f, err) && h.failed(w, r, err, settings.ErrNotFound) {
		return
	}
	types, groups, loadErr := h.outletSettingsOptions(r)
	if loadErr != nil {
		h.serverError(w, r, loadErr)
		return
	}
	h.render(w, r, views.OutletSettingsForm(id, f, types, groups))
}

func (h *Handler) setOutletPricingModel(w http.ResponseWriter, r *http.Request) {
	f, ok := h.parseForm(w, r)
	if !ok {
		return
	}
	id := chi.URLParam(r, "id")
	err := h.settings.SetPricingModel(r.Context(), tenantOf(r), id, f.V("model"))
	var notReady *settings.ErrDevicesNotReady
	switch {
	case errors.As(err, &notReady):
		f.Errors["pricing_model"] = strconv.Itoa(len(notReady.Devices)) + " perangkat belum siap. Perbarui aplikasinya dulu."
	case err == nil:
		toast(w, "Model harga diperbarui. Till menerimanya pada sinkron berikutnya.")
	case !absorb(&f, err) && h.failed(w, r, err, settings.ErrNotFound):
		return
	}
	o, err := h.settings.OutletSettings(r.Context(), tenantOf(r), id)
	if h.failed(w, r, err, settings.ErrNotFound) {
		return
	}
	stale, err := h.incompatible(r, id)
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	h.render(w, r, views.PricingModelCard(o, stale, f))
}

func ptrTo[T any](v T) *T { return &v }

// ---- sales types --------------------------------------------------------------

func (h *Handler) salesTypesPage(w http.ResponseWriter, r *http.Request) {
	types, err := h.catalogue.ListSalesTypes(r.Context(), tenantOf(r))
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	h.render(w, r, views.SalesTypesPage(h.sessionView(r), types, views.NewForm()))
}

func (h *Handler) renderSalesTypes(w http.ResponseWriter, r *http.Request, f views.Form) {
	types, err := h.catalogue.ListSalesTypes(r.Context(), tenantOf(r))
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	h.render(w, r, views.SalesTypesSection(types, f))
}

func (h *Handler) createSalesType(w http.ResponseWriter, r *http.Request) {
	f, ok := h.parseForm(w, r)
	if !ok {
		return
	}
	p := newParser(f)
	_, err := h.catalogue.SaveSalesType(r.Context(), tenantOf(r), catalogue.SalesType{
		Name: p.text("name"), UsesTable: p.check("uses_table"), Active: true, SortOrder: 10,
	})
	if err == nil {
		f = views.NewForm()
		toast(w, "Jenis penjualan ditambahkan.")
	} else if !absorb(&f, err) {
		h.serverError(w, r, err)
		return
	}
	h.renderSalesTypes(w, r, f)
}

func (h *Handler) toggleSalesType(w http.ResponseWriter, r *http.Request) {
	types, err := h.catalogue.ListSalesTypes(r.Context(), tenantOf(r))
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	id := chi.URLParam(r, "id")
	for _, st := range types {
		if st.ID == id {
			st.Active = !st.Active
			if _, err := h.catalogue.SaveSalesType(r.Context(), tenantOf(r), st); err != nil {
				h.serverError(w, r, err)
				return
			}
		}
	}
	h.renderSalesTypes(w, r, views.NewForm())
}

func (h *Handler) deleteSalesType(w http.ResponseWriter, r *http.Request) {
	err := h.catalogue.DeleteSalesType(r.Context(), tenantOf(r), chi.URLParam(r, "id"))
	if errors.Is(err, catalogue.ErrSystemSalesType) {
		toastError(w, "Jenis bawaan tidak bisa dihapus; nonaktifkan saja.")
	} else if h.failed(w, r, err, catalogue.ErrNotFound) {
		return
	}
	h.renderSalesTypes(w, r, views.NewForm())
}

// ---- payments -----------------------------------------------------------------

func (h *Handler) paymentsPage(w http.ResponseWriter, r *http.Request) {
	methods, err := h.payments.Methods(r.Context(), tenantOf(r))
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	groups, err := h.payments.Groups(r.Context(), tenantOf(r))
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	mf := views.NewForm()
	mf.Values["kind"] = "card"
	h.render(w, r, views.PaymentsPage(h.sessionView(r), methods, groups, mf, views.NewForm()))
}

func (h *Handler) renderPaymentMethods(w http.ResponseWriter, r *http.Request, f views.Form) {
	methods, err := h.payments.Methods(r.Context(), tenantOf(r))
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	h.render(w, r, views.PaymentMethodsSection(methods, f))
}

func (h *Handler) createPaymentMethod(w http.ResponseWriter, r *http.Request) {
	f, ok := h.parseForm(w, r)
	if !ok {
		return
	}
	p := newParser(f)
	_, err := h.payments.SaveMethod(r.Context(), tenantOf(r), payments.Method{
		Name: p.text("name"), Kind: p.text("kind"), RequiresReference: p.check("requires_reference"), Active: true, SortOrder: 10,
	})
	if err == nil {
		f = views.NewForm()
		f.Values["kind"] = "card"
		toast(w, "Metode ditambahkan.")
	} else if !absorb(&f, err) {
		h.serverError(w, r, err)
		return
	}
	h.renderPaymentMethods(w, r, f)
}

func (h *Handler) togglePaymentMethod(w http.ResponseWriter, r *http.Request) {
	methods, err := h.payments.Methods(r.Context(), tenantOf(r))
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	for _, m := range methods {
		if m.ID == chi.URLParam(r, "id") {
			m.Active = !m.Active
			if _, err := h.payments.SaveMethod(r.Context(), tenantOf(r), m); err != nil {
				h.serverError(w, r, err)
				return
			}
		}
	}
	h.renderPaymentMethods(w, r, views.NewForm())
}

func (h *Handler) deletePaymentMethod(w http.ResponseWriter, r *http.Request) {
	err := h.payments.DeleteMethod(r.Context(), tenantOf(r), chi.URLParam(r, "id"))
	if errors.Is(err, payments.ErrSystemMethod) {
		toastError(w, "Metode bawaan tidak bisa dihapus; nonaktifkan saja.")
	} else if h.failed(w, r, err, payments.ErrNotFound) {
		return
	}
	h.renderPaymentMethods(w, r, views.NewForm())
}

func (h *Handler) renderPaymentGroups(w http.ResponseWriter, r *http.Request, f views.Form) {
	methods, err := h.payments.Methods(r.Context(), tenantOf(r))
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	groups, err := h.payments.Groups(r.Context(), tenantOf(r))
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	h.render(w, r, views.PaymentGroupsSection(methods, groups, f))
}

func (h *Handler) createPaymentGroup(w http.ResponseWriter, r *http.Request) {
	f, ok := h.parseForm(w, r, "methods")
	if !ok {
		return
	}
	p := newParser(f)
	_, err := h.payments.SaveGroup(r.Context(), tenantOf(r), payments.Group{
		Name: p.text("name"), MethodIDs: f.Multi["methods"], Active: true,
	})
	if err == nil {
		f = views.NewForm()
		toast(w, "Grup ditambahkan.")
	} else if !absorb(&f, err) {
		h.serverError(w, r, err)
		return
	}
	h.renderPaymentGroups(w, r, f)
}

func (h *Handler) deletePaymentGroup(w http.ResponseWriter, r *http.Request) {
	err := h.payments.DeleteGroup(r.Context(), tenantOf(r), chi.URLParam(r, "id"))
	if errors.Is(err, payments.ErrGroupInUse) {
		toastError(w, "Grup masih dipakai outlet. Ganti grup outletnya dulu.")
	} else if h.failed(w, r, err, payments.ErrNotFound) {
		return
	}
	h.renderPaymentGroups(w, r, views.NewForm())
}

// ---- discounts ----------------------------------------------------------------

func (h *Handler) discountsPage(w http.ResponseWriter, r *http.Request) {
	rows, err := h.promos.Discounts(r.Context(), tenantOf(r))
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	h.render(w, r, views.DiscountsPage(h.sessionView(r), rows, views.NewForm()))
}

func (h *Handler) renderDiscounts(w http.ResponseWriter, r *http.Request, f views.Form) {
	rows, err := h.promos.Discounts(r.Context(), tenantOf(r))
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	h.render(w, r, views.DiscountsSection(rows, f))
}

func (h *Handler) createDiscount(w http.ResponseWriter, r *http.Request) {
	f, ok := h.parseForm(w, r)
	if !ok {
		return
	}
	p := newParser(f)
	in := promos.Discount{
		Name: p.text("name"), Scope: p.text("scope"), Kind: p.text("kind"),
		RequiresAuthorization: p.check("requires_authorization"), Active: true,
	}
	if p.text("value") != "" {
		var v int64
		if in.Kind == "percent" {
			if bp := p.optionalPercentBP("value"); bp != nil {
				v = int64(*bp)
			}
		} else {
			v = p.money("value")
		}
		in.Value = &v
	}
	err := p.errs.Err()
	if err == nil {
		_, err = h.promos.SaveDiscount(r.Context(), tenantOf(r), in)
	}
	if err == nil {
		f = views.NewForm()
		toast(w, "Diskon ditambahkan.")
	} else if !absorb(&f, err) {
		h.serverError(w, r, err)
		return
	}
	h.renderDiscounts(w, r, f)
}

func (h *Handler) toggleDiscount(w http.ResponseWriter, r *http.Request) {
	rows, err := h.promos.Discounts(r.Context(), tenantOf(r))
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	for _, d := range rows {
		if d.ID == chi.URLParam(r, "id") {
			d.Active = !d.Active
			if _, err := h.promos.SaveDiscount(r.Context(), tenantOf(r), d); err != nil {
				h.serverError(w, r, err)
				return
			}
		}
	}
	h.renderDiscounts(w, r, views.NewForm())
}

func (h *Handler) deleteDiscount(w http.ResponseWriter, r *http.Request) {
	err := h.promos.DeleteDiscount(r.Context(), tenantOf(r), chi.URLParam(r, "id"))
	if h.failed(w, r, err, promos.ErrNotFound) {
		return
	}
	h.renderDiscounts(w, r, views.NewForm())
}

// ---- product prices -------------------------------------------------------------

func (h *Handler) priceGrid(r *http.Request) (views.PriceGrid, error) {
	types, err := h.catalogue.ListSalesTypes(r.Context(), tenantOf(r))
	if err != nil {
		return views.PriceGrid{}, err
	}
	outlets, err := h.outlets.List(r.Context(), tenantOf(r))
	if err != nil {
		return views.PriceGrid{}, err
	}
	grid := views.PriceGrid{}
	for _, st := range types {
		if st.Active {
			grid.SalesTypes = append(grid.SalesTypes, st)
		}
	}
	for _, o := range outlets {
		if o.Active {
			grid.Outlets = append(grid.Outlets, views.Option{Value: o.ID, Label: o.Name})
		}
	}
	return grid, nil
}

func (h *Handler) productPricesCard(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	prices, err := h.catalogue.ProductPrices(r.Context(), tenantOf(r), id)
	if h.failed(w, r, err, catalogue.ErrNotFound) {
		return
	}
	grid, err := h.priceGrid(r)
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	f := views.NewForm()
	for _, p := range prices {
		key := "price." + p.SalesTypeID
		if p.OutletID != nil {
			key += "." + *p.OutletID
		}
		f.Values[key] = views.Rupiah(p.Price)[3:]
	}
	h.render(w, r, views.ProductPricesCard(id, grid, f))
}

func (h *Handler) saveProductPrices(w http.ResponseWriter, r *http.Request) {
	f, ok := h.parseForm(w, r)
	if !ok {
		return
	}
	id := chi.URLParam(r, "id")
	p := newParser(f)
	var want []catalogue.Price
	for key := range f.Values {
		rest, found := strings.CutPrefix(key, "price.")
		if !found || strings.TrimSpace(f.V(key)) == "" {
			continue
		}
		st, outlet, _ := strings.Cut(rest, ".")
		price := catalogue.Price{SalesTypeID: st, Price: p.money(key)}
		if outlet != "" {
			price.OutletID = ptrTo(outlet)
		}
		want = append(want, price)
	}
	err := p.errs.Err()
	if fields, ok := validation.As(err); ok {
		for k := range fields {
			f.Errors["prices"] = "Ada harga yang tidak valid: " + fields[k]
			break
		}
		err = nil
	} else if err == nil {
		err = h.catalogue.SetProductPrices(r.Context(), tenantOf(r), id, want)
		if err == nil {
			toast(w, "Harga disimpan.")
		}
	}
	if err != nil && !absorb(&f, err) && h.failed(w, r, err, catalogue.ErrNotFound) {
		return
	}
	grid, loadErr := h.priceGrid(r)
	if loadErr != nil {
		h.serverError(w, r, loadErr)
		return
	}
	h.render(w, r, views.ProductPricesCard(id, grid, f))
}

// ---- account ------------------------------------------------------------------

func (h *Handler) accountPage(w http.ResponseWriter, r *http.Request) {
	me := employeeFrom(r.Context())
	p, err := h.staff.Profile(r.Context(), tenantOf(r), me.ID)
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	f := views.NewForm()
	f.Values["name"] = p.Name
	f.Values["phone"] = optionalString(p.Phone)
	h.render(w, r, views.AccountPage(h.sessionView(r), f, views.NewForm(), me.Email))
}

func (h *Handler) saveAccount(w http.ResponseWriter, r *http.Request) {
	f, ok := h.parseForm(w, r)
	if !ok {
		return
	}
	p := newParser(f)
	err := h.staff.UpdateOwnAccount(r.Context(), tenantOf(r), employeeFrom(r.Context()).ID, p.text("name"), p.optionalText("phone"))
	if err == nil {
		toast(w, "Profil disimpan.")
	} else if !absorb(&f, err) {
		h.serverError(w, r, err)
		return
	}
	h.render(w, r, views.AccountProfileForm(f))
}

func (h *Handler) changeOwnPassword(w http.ResponseWriter, r *http.Request) {
	f, ok := h.parseForm(w, r)
	if !ok {
		return
	}
	err := h.staff.ChangeOwnPassword(r.Context(), tenantOf(r), employeeFrom(r.Context()).ID, f.V("current_password"), f.V("password"))
	if err == nil {
		toast(w, "Kata sandi diganti.")
	} else if !absorb(&f, err) {
		h.serverError(w, r, err)
		return
	}
	// Never echo a password back into the page.
	delete(f.Values, "current_password")
	delete(f.Values, "password")
	h.render(w, r, views.AccountPasswordForm(f))
}
