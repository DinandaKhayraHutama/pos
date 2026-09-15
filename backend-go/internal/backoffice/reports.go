package backoffice

import (
	"context"
	"errors"
	"mime"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/backoffice/views"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/reporting"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/validation"
)

// ReportService is the reporting domain as the panel uses it.
type ReportService interface {
	Report(ctx context.Context, tenantID string, f reporting.Filter) (reporting.Report, error)
	Today(ctx context.Context, tenantID string) (time.Time, error)
	Location(ctx context.Context, tenantID string) (*time.Location, error)
	RequestRecompute(ctx context.Context, tenantID string, f reporting.Filter) (int, error)
	RequestExport(ctx context.Context, tenantID, employeeID string, f reporting.Filter, format string) (string, error)
	Exports(ctx context.Context, tenantID string, limit int) ([]reporting.Export, error)
	OpenExport(ctx context.Context, tenantID, exportID string) (reporting.File, error)
	OpenExportByToken(ctx context.Context, exportID, token string) (reporting.File, error)
	Schedules(ctx context.Context, tenantID string) ([]reporting.Schedule, error)
	CreateSchedule(ctx context.Context, tenantID, employeeID string, in reporting.ScheduleInput) (string, error)
	SetScheduleActive(ctx context.Context, tenantID, id string, active bool) error
	DeleteSchedule(ctx context.Context, tenantID, id string) error
}

// reportFilter reads a range and outlet, defaulting to this month so far on the
// merchant's clock. A typed date that does not parse stays empty, so the
// validation message says so instead of the page quietly showing another range.
func (h *Handler) reportFilter(r *http.Request, value func(string) string) (reporting.Filter, error) {
	today, err := h.reports.Today(r.Context(), tenantOf(r))
	if err != nil {
		return reporting.Filter{}, err
	}
	f := reporting.Filter{
		From:     reporting.ParseDate(value("from")),
		To:       reporting.ParseDate(value("to")),
		OutletID: strings.TrimSpace(value("outlet")),
	}
	if value("from") == "" {
		f.From = time.Date(today.Year(), today.Month(), 1, 0, 0, 0, 0, time.UTC)
	}
	if value("to") == "" {
		f.To = today
	}
	return f, nil
}

func (h *Handler) reportsPage(w http.ResponseWriter, r *http.Request) {
	f, err := h.reportFilter(r, r.URL.Query().Get)
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	v, err := h.reportView(r, f)
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	h.render(w, r, views.ReportsPage(h.sessionView(r), v))
}

func (h *Handler) reportView(r *http.Request, f reporting.Filter) (views.ReportView, error) {
	ctx, tenantID := r.Context(), tenantOf(r)
	v := views.ReportView{Filter: f, Form: views.NewForm()}
	v.Form.Values["from"] = views.DateValue(f.From)
	v.Form.Values["to"] = views.DateValue(f.To)
	v.Form.Values["outlet"] = f.OutletID

	var err error
	if v.Outlets, err = h.outletOptions(r); err != nil {
		return v, err
	}
	if v.Location, err = h.reports.Location(ctx, tenantID); err != nil {
		return v, err
	}

	report, err := h.reports.Report(ctx, tenantID, f)
	switch {
	case err == nil:
		v.Report, v.HasReport = report, true
	case errors.Is(err, reporting.ErrNotFound):
		absorb(&v.Form, validation.Errors{"outlet": "Outlet tidak dikenal."})
	case !absorb(&v.Form, err):
		return v, err
	}

	v.Exports, err = h.reports.Exports(ctx, tenantID, 10)
	return v, err
}

// recomputeReport marks the range dirty and lets the jobs recompute it. The
// page never reads the order tables itself.
func (h *Handler) recomputeReport(w http.ResponseWriter, r *http.Request) {
	form, ok := h.parseForm(w, r)
	if !ok {
		return
	}
	f, err := h.reportFilter(r, form.V)
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	n, err := h.reports.RequestRecompute(r.Context(), tenantOf(r), f)
	if problems, invalid := validation.As(err); invalid {
		h.render(w, r, views.RecomputeNotice(firstProblem(problems)))
		return
	}
	if h.failed(w, r, err, reporting.ErrNotFound) {
		return
	}
	toast(w, "Perhitungan ulang dijadwalkan.")
	h.render(w, r, views.RecomputeNotice(strconv.Itoa(n)+
		" hari-outlet dijadwalkan dihitung ulang. Muat ulang halaman dalam beberapa menit untuk melihat hasilnya."))
}

func firstProblem(problems validation.Errors) string {
	keys := make([]string, 0, len(problems))
	for k := range problems {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	if len(keys) == 0 {
		return "Periksa isian."
	}
	return problems[keys[0]]
}

func (h *Handler) requestExport(w http.ResponseWriter, r *http.Request) {
	form, ok := h.parseForm(w, r)
	if !ok {
		return
	}
	f, err := h.reportFilter(r, form.V)
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	_, err = h.reports.RequestExport(r.Context(), tenantOf(r), employeeFrom(r.Context()).ID, f, form.V("format"))
	if problems, invalid := validation.As(err); invalid {
		toastError(w, firstProblem(problems))
	} else if h.failed(w, r, err, reporting.ErrNotFound) {
		return
	} else {
		toast(w, "Ekspor sedang disiapkan.")
	}
	h.renderExports(w, r)
}

func (h *Handler) exportsList(w http.ResponseWriter, r *http.Request) {
	h.renderExports(w, r)
}

func (h *Handler) renderExports(w http.ResponseWriter, r *http.Request) {
	ctx, tenantID := r.Context(), tenantOf(r)
	list, err := h.reports.Exports(ctx, tenantID, 10)
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	loc, err := h.reports.Location(ctx, tenantID)
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	h.render(w, r, views.ExportsCard(list, loc))
}

func (h *Handler) downloadExport(w http.ResponseWriter, r *http.Request) {
	file, err := h.reports.OpenExport(r.Context(), tenantOf(r), chi.URLParam(r, "id"))
	if errors.Is(err, reporting.ErrExportNotReady) {
		h.renderStatus(w, r, http.StatusConflict, views.MessagePage(h.sessionView(r),
			"Belum siap", "Ekspor ini belum selesai atau gagal dibuat."))
		return
	}
	if h.failed(w, r, err, reporting.ErrNotFound) {
		return
	}
	serveExport(w, r, file)
}

// downloadByToken is the e-mailed link. It needs no session: the token is the
// credential, and it expires.
func (h *Handler) downloadByToken(w http.ResponseWriter, r *http.Request) {
	file, err := h.reports.OpenExportByToken(r.Context(), chi.URLParam(r, "id"), r.URL.Query().Get("token"))
	switch {
	case err == nil:
		serveExport(w, r, file)
	case errors.Is(err, reporting.ErrLinkExpired):
		h.renderStatus(w, r, http.StatusGone, views.PublicMessage("Tautan kedaluwarsa",
			"Tautan unduhan ini sudah tidak berlaku. Laporan tetap bisa diunduh dari Backoffice."))
	case errors.Is(err, reporting.ErrExportNotReady):
		h.renderStatus(w, r, http.StatusConflict, views.PublicMessage("Belum siap", "Laporan ini belum selesai dibuat."))
	case errors.Is(err, reporting.ErrNotFound):
		h.renderStatus(w, r, http.StatusNotFound, views.PublicMessage("Tidak ditemukan", "Tautan unduhan ini tidak dikenal."))
	default:
		h.logger.Error("report download failed", "error", err)
		h.renderStatus(w, r, http.StatusInternalServerError, views.PublicMessage("Gagal", "Laporan tidak bisa diunduh saat ini."))
	}
}

func serveExport(w http.ResponseWriter, r *http.Request, file reporting.File) {
	f, err := os.Open(file.Path)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", file.ContentType)
	w.Header().Set("Content-Disposition", mime.FormatMediaType("attachment", map[string]string{"filename": file.Name}))
	w.Header().Set("Cache-Control", "private, no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	http.ServeContent(w, r, "", info.ModTime(), f)
}

func (h *Handler) schedulesPage(w http.ResponseWriter, r *http.Request) {
	v, err := h.scheduleView(r, views.NewForm())
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	h.render(w, r, views.SchedulesPage(h.sessionView(r), v))
}

func (h *Handler) scheduleView(r *http.Request, f views.Form) (views.ScheduleView, error) {
	ctx, tenantID := r.Context(), tenantOf(r)
	v := views.ScheduleView{Form: f}
	var err error
	if v.Outlets, err = h.outletOptions(r); err != nil {
		return v, err
	}
	if v.Location, err = h.reports.Location(ctx, tenantID); err != nil {
		return v, err
	}
	v.Schedules, err = h.reports.Schedules(ctx, tenantID)
	return v, err
}

func (h *Handler) renderSchedules(w http.ResponseWriter, r *http.Request, f views.Form) {
	v, err := h.scheduleView(r, f)
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	h.render(w, r, views.SchedulesCard(v))
}

func (h *Handler) createSchedule(w http.ResponseWriter, r *http.Request) {
	form, ok := h.parseForm(w, r)
	if !ok {
		return
	}
	_, err := h.reports.CreateSchedule(r.Context(), tenantOf(r), employeeFrom(r.Context()).ID, reporting.ScheduleInput{
		Frequency: form.V("frequency"), Format: form.V("format"),
		OutletID: strings.TrimSpace(form.V("outlet")), Recipients: form.V("recipients"),
	})
	if !absorb(&form, err) && h.failed(w, r, err, reporting.ErrNotFound) {
		return
	}
	if err == nil {
		form = views.NewForm()
		toast(w, "Jadwal kirim disimpan.")
	}
	h.renderSchedules(w, r, form)
}

func (h *Handler) setScheduleActive(w http.ResponseWriter, r *http.Request) {
	form, ok := h.parseForm(w, r)
	if !ok {
		return
	}
	err := h.reports.SetScheduleActive(r.Context(), tenantOf(r), chi.URLParam(r, "id"), form.Checked("active"))
	if h.failed(w, r, err, reporting.ErrNotFound) {
		return
	}
	if form.Checked("active") {
		toast(w, "Jadwal diaktifkan.")
	} else {
		toast(w, "Jadwal dijeda.")
	}
	h.renderSchedules(w, r, views.NewForm())
}

func (h *Handler) deleteSchedule(w http.ResponseWriter, r *http.Request) {
	if _, ok := h.parseForm(w, r); !ok {
		return
	}
	err := h.reports.DeleteSchedule(r.Context(), tenantOf(r), chi.URLParam(r, "id"))
	if h.failed(w, r, err, reporting.ErrNotFound) {
		return
	}
	toast(w, "Jadwal dihapus.")
	h.renderSchedules(w, r, views.NewForm())
}

func (h *Handler) dashboardPage(w http.ResponseWriter, r *http.Request) {
	v, err := h.dashboardView(r)
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	h.render(w, r, views.DashboardPage(h.sessionView(r), v))
}

func (h *Handler) dashboardTiles(w http.ResponseWriter, r *http.Request) {
	v, err := h.dashboardView(r)
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	h.render(w, r, views.DashboardTiles(v))
}

// dashboardView is today against yesterday on the merchant's clock, from the
// same rollups the report reads.
func (h *Handler) dashboardView(r *http.Request) (views.DashboardView, error) {
	ctx, tenantID := r.Context(), tenantOf(r)
	today, err := h.reports.Today(ctx, tenantID)
	if err != nil {
		return views.DashboardView{}, err
	}
	yesterday := today.AddDate(0, 0, -1)
	v := views.DashboardView{}
	if v.Today, err = h.reports.Report(ctx, tenantID, reporting.Filter{From: today, To: today}); err != nil {
		return v, err
	}
	if v.Yesterday, err = h.reports.Report(ctx, tenantID, reporting.Filter{From: yesterday, To: yesterday}); err != nil {
		return v, err
	}
	v.Location, err = h.reports.Location(ctx, tenantID)
	return v, err
}
