package v2

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/httpapi/render"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/httpapi/wire"
)

const maxPushBytes = 4 << 20

func (h *Handler) syncPush(w http.ResponseWriter, r *http.Request) {
	if !h.schemaIsCurrent(w, r) {
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxPushBytes))
	decoder.DisallowUnknownFields() // envelope only; raw rows are validated independently
	var req wire.PushRequest
	err := decoder.Decode(&req)
	if err == nil {
		var extra any
		if tailErr := decoder.Decode(&extra); tailErr != io.EOF {
			err = tailErr
			if err == nil {
				err = errors.New("multiple JSON values")
			}
		}
	}
	if err != nil {
		var tooLarge *http.MaxBytesError
		if errors.As(err, &tooLarge) {
			render.Error(w, h.logger, 413, "payload_too_large", "Limit push to 4 MiB.")
			return
		}
		render.Error(w, h.logger, 400, "malformed_request", "Expected one push object with batches.")
		return
	}
	count := 0
	if len(req.Batches) == 0 || len(req.Batches) > 200 {
		render.Error(w, h.logger, 400, "malformed_request", "Supply between 1 and 200 non-empty batches.")
		return
	}
	for _, batch := range req.Batches {
		if strings.TrimSpace(batch.Entity) == "" || len(batch.Entity) > 128 || len(batch.Rows) == 0 {
			render.Error(w, h.logger, 400, "malformed_request", "Each batch requires an entity and rows.")
			return
		}
		count += len(batch.Rows)
	}
	if count > 200 {
		render.Error(w, h.logger, 413, "payload_too_large", "Limit push to 200 rows total.")
		return
	}
	if h.ingest == nil {
		render.Error(w, h.logger, 503, "server_unavailable", "Push is temporarily unavailable.")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()
	response := h.ingest.Push(ctx, bindingFrom(r.Context()), req)
	h.countPushRows(response)
	render.JSON(w, h.logger, 200, response)
}

// countPushRows is where the rejection rate comes from.
//
// It is counted here rather than inside the domain because the per-row results
// are exactly what the till is told, so the metric and the device's own view of
// what happened to a sale cannot drift apart. A rate that climbs on one code is
// the earliest visible sign of a client build losing money.
func (h *Handler) countPushRows(response wire.PushResponse) {
	if h.metrics == nil {
		return
	}
	for _, result := range response.Results {
		code := ""
		if result.Code != nil {
			code = string(*result.Code)
		}
		h.metrics.PushRow(result.Entity, string(result.Status), code)
	}
}
