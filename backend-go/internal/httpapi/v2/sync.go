package v2

import (
	"errors"
	"log/slog"
	"net/http"
	"strconv"
	"time"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/httpapi/render"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/httpapi/wire"
)

func (h *Handler) syncManifest(w http.ResponseWriter, r *http.Request) {
	if !h.schemaIsCurrent(w, r) {
		return
	}

	render.JSON(w, h.logger, http.StatusOK, syncfeed.BuildManifest())
}

func (h *Handler) syncChanges(w http.ResponseWriter, r *http.Request) {
	if !h.schemaIsCurrent(w, r) {
		return
	}

	binding := bindingFrom(r.Context())

	// The company feeds plus this till's own branch's outlet feeds.
	cursors, err := h.sync.DeviceCursors(r.Context(), binding.Tenant.ID, binding.Outlet.ID)
	if err != nil {
		h.logger.Error("read sync cursors",
			slog.String("tenant_id", binding.Tenant.ID), slog.Any("error", err))
		render.Error(w, h.logger, http.StatusInternalServerError, "server_error",
			"Changes could not be read.")
		return
	}

	render.JSON(w, h.logger, http.StatusOK, wire.Changes{
		Cursors:        cursors,
		DeviceRevision: binding.RevisionMs,
		ServerTimeMs:   time.Now().UnixMilli(),
		NextPollMs:     h.pollInterval.Milliseconds(),
	})
}

func (h *Handler) syncPull(w http.ResponseWriter, r *http.Request) {
	if !h.schemaIsCurrent(w, r) {
		return
	}

	binding := bindingFrom(r.Context())
	query := r.URL.Query()

	afterSeq, ok := parseSeq(query.Get("after_seq"))
	if !ok {
		render.Error(w, h.logger, http.StatusBadRequest, "malformed_request",
			"after_seq must be a whole number.")
		return
	}

	// An unreadable limit falls back to the default rather than failing the
	// request: the parameter is a hint about page size, and refusing to sync
	// over one is a till that stops working for a cosmetic reason.
	limit, _ := strconv.Atoi(query.Get("limit"))

	// The outlet comes from the token: a till pages its own branch's stock and
	// can name no other.
	page, err := h.sync.PullOutlet(r.Context(), binding.Tenant.ID, binding.Outlet.ID, query.Get("entity"), afterSeq, limit)
	switch {
	case errors.Is(err, syncfeed.ErrUnknownEntity):
		// Named rather than described: the till's dead-letter codes are a
		// closed set, and this is the one it records against a feed its build
		// knows about but this server does not.
		render.Error(w, h.logger, http.StatusNotFound, "unknown_entity",
			"This server publishes no such entity.")
		return
	case err != nil:
		h.logger.Error("pull sync entity",
			slog.String("tenant_id", binding.Tenant.ID),
			slog.String("entity", query.Get("entity")),
			slog.Any("error", err))
		render.Error(w, h.logger, http.StatusInternalServerError, "server_error",
			"The page could not be read.")
		return
	}

	// page.Entity, never the query string: an unknown entity was already
	// refused above, but labelling a metric with something a device chooses is
	// how a registry grows a series per request until the process runs out of
	// memory.
	h.metrics.PullRows(page.Entity, len(page.Rows))
	render.JSON(w, h.logger, http.StatusOK, page)
}

// serverTime is public and touches nothing.
//
// A till uses it to learn its own clock offset, and it has to be able to do so
// before it trusts anything else: business_date is chosen on the device, and a
// tablet a day out files a whole shift's sales into the wrong day's report.
func (h *Handler) serverTime(w http.ResponseWriter, r *http.Request) {
	render.JSON(w, h.logger, http.StatusOK, wire.ServerTime{ServerTimeMs: time.Now().UnixMilli()})
}

// schemaIsCurrent refuses a client too old to read what this server publishes.
//
// Every sync request must declare X-Schema-Version. Treat absence as outdated,
// so a client cannot bypass a future minimum-version increase by omitting it.
func (h *Handler) schemaIsCurrent(w http.ResponseWriter, r *http.Request) bool {
	raw := r.Header.Get("X-Schema-Version")
	if raw == "" {
		render.Error(w, h.logger, http.StatusConflict, "device_schema_outdated",
			"Declare X-Schema-Version to sync. Update this app if it cannot do so.")
		return false
	}

	version, err := strconv.Atoi(raw)
	if err != nil {
		render.Error(w, h.logger, http.StatusBadRequest, "malformed_request",
			"X-Schema-Version must be a whole number.")
		return false
	}

	if version < syncfeed.MinDeviceSchemaVersion {
		render.Error(w, h.logger, http.StatusConflict, "device_schema_outdated",
			"This app version is too old to sync. Update it to continue.")
		return false
	}

	return true
}

// parseSeq reads a cursor. Empty means "from the beginning", and a negative
// number is clamped there too — re-sending everything costs one page, where
// refusing the request costs the till its sync.
func parseSeq(raw string) (int64, bool) {
	if raw == "" {
		return 0, true
	}

	seq, err := strconv.ParseInt(raw, 10, 64)
	if err != nil {
		return 0, false
	}
	if seq < 0 {
		return 0, true
	}

	return seq, true
}
