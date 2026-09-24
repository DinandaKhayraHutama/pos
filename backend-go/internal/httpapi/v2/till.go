package v2

import (
	"encoding/json"
	"errors"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/ingest"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/httpapi/render"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/httpapi/wire"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/redisx"
	"github.com/go-chi/chi/v5"
	"io"
	"net/http"
	"time"
)

func (h *Handler) tillBody(w http.ResponseWriter, r *http.Request, v any) bool {
	d := json.NewDecoder(http.MaxBytesReader(w, r.Body, 32768))
	d.DisallowUnknownFields()
	err := d.Decode(v)
	if err == nil {
		var tail any
		if d.Decode(&tail) != io.EOF {
			err = errors.New("trailing value")
		}
	}
	if err != nil {
		render.Error(w, h.logger, 400, "malformed_request", "Expected one valid request object.")
		return false
	}
	return true
}
func (h *Handler) tillReply(w http.ResponseWriter, v any, err error) {
	w.Header().Set("Cache-Control", "no-store")
	if err != nil {
		var domain *ingest.TillError
		if errors.As(err, &domain) {
			render.Error(w, h.logger, 409, domain.Code, domain.Code)
			return
		}
		h.logger.Error("till operation failed", "error", err)
		render.Error(w, h.logger, 503, "server_unavailable", "Keep the operation ID and retry.")
		return
	}
	render.JSON(w, h.logger, 200, map[string]any{"data": v})
}
func (h *Handler) tillLogin(w http.ResponseWriter, r *http.Request) {
	var in wire.TillLoginRequest
	if !h.tillBody(w, r, &in) {
		return
	}
	b := bindingFrom(r.Context())
	for _, key := range []string{"pin:device:" + b.Device.ID, "pin:employee:" + b.Tenant.ID + ":" + string(in.EmployeeId)} {
		if ok, retry := redisx.Allow(r.Context(), h.rdb, key, redisx.Limit{Burst: 5, Window: time.Minute}); !ok {
			h.tooManyRequests(w, retry)
			return
		}
	}
	out, err := h.ingest.TillLogin(r.Context(), b, string(in.EmployeeId), in.Pin)
	h.tillReply(w, out, err)
}
func (h *Handler) tillOpen(w http.ResponseWriter, r *http.Request) {
	var in wire.Session
	if !h.tillBody(w, r, &in) {
		return
	}
	out, err := h.ingest.OpenTill(r.Context(), bindingFrom(r.Context()), r.Header.Get("X-Cashier-Token"), in)
	h.tillReply(w, out, err)
}
func (h *Handler) tillHandover(w http.ResponseWriter, r *http.Request) {
	var in wire.TillHandoverRequest
	if !h.tillBody(w, r, &in) {
		return
	}
	out, err := h.ingest.HandoverTill(r.Context(), bindingFrom(r.Context()), r.Header.Get("X-Cashier-Token"), string(in.Id))
	h.tillReply(w, out, err)
}
func (h *Handler) tillCurrent(w http.ResponseWriter, r *http.Request) {
	out, err := h.ingest.CurrentTill(r.Context(), bindingFrom(r.Context()), r.Header.Get("X-Cashier-Token"))
	if err != nil {
		h.tillReply(w, nil, err)
		return
	}
	recovery, err := h.ingest.RecoveryForSession(r.Context(), bindingFrom(r.Context()), r.URL.Query().Get("local_session_id"))
	if err != nil {
		h.tillReply(w, nil, err)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	render.JSON(w, h.logger, http.StatusOK, map[string]any{"data": out, "recovery": recovery})
}
// tillHistory reads the additive filters straight through to the domain,
// which decides what this cashier may actually have. Nothing is narrowed here:
// a handler that quietly dropped a parameter it disliked would make the
// server's scope rules impossible to read in one place.
func (h *Handler) tillHistory(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	out, err := h.ingest.TillHistory(r.Context(), bindingFrom(r.Context()), r.Header.Get("X-Cashier-Token"),
		ingest.HistoryQuery{
			Day:       q.Get("day"),
			From:      q.Get("from"),
			To:        q.Get("to"),
			Scope:     q.Get("scope"),
			Status:    q.Get("status"),
			Receipt:   q.Get("receipt_number"),
			CashierID: q.Get("cashier_id"),
			Before:    q.Get("before"),
		})
	h.tillReply(w, out, err)
}

func (h *Handler) tillRecovery(w http.ResponseWriter, r *http.Request) {
	out, err := h.ingest.RecoveryStatus(r.Context(), bindingFrom(r.Context()), r.Header.Get("X-Cashier-Token"), chi.URLParam(r, "recoveryID"))
	h.tillReply(w, out, err)
}

// Fase 4: saved bills and table seatings. Each handler only translates; the
// domain decides who may do what and answers a refusal as a 409 with its code.

func (h *Handler) tillBillBoard(w http.ResponseWriter, r *http.Request) {
	out, err := h.ingest.BillBoard(r.Context(), bindingFrom(r.Context()), r.Header.Get("X-Cashier-Token"))
	h.tillReply(w, out, err)
}

func (h *Handler) tillBillDetail(w http.ResponseWriter, r *http.Request) {
	out, err := h.ingest.BillDetail(r.Context(), bindingFrom(r.Context()), r.Header.Get("X-Cashier-Token"), chi.URLParam(r, "billID"))
	h.tillReply(w, out, err)
}

func (h *Handler) tillBillPark(w http.ResponseWriter, r *http.Request) {
	var in wire.TillBillParkRequest
	if !h.tillBody(w, r, &in) {
		return
	}
	out, err := h.ingest.ParkBill(r.Context(), bindingFrom(r.Context()), r.Header.Get("X-Cashier-Token"), chi.URLParam(r, "billID"), in)
	h.tillReply(w, out, err)
}

func (h *Handler) tillBillClaim(w http.ResponseWriter, r *http.Request) {
	var in wire.TillOperationRequest
	if !h.tillBody(w, r, &in) {
		return
	}
	out, err := h.ingest.ClaimBill(r.Context(), bindingFrom(r.Context()), r.Header.Get("X-Cashier-Token"), chi.URLParam(r, "billID"), in.OperationId)
	h.tillReply(w, out, err)
}

func (h *Handler) tillTableOpen(w http.ResponseWriter, r *http.Request) {
	var in wire.TableSessionOpenRequest
	if !h.tillBody(w, r, &in) {
		return
	}
	out, err := h.ingest.OpenTableSession(r.Context(), bindingFrom(r.Context()), r.Header.Get("X-Cashier-Token"), in)
	h.tillReply(w, out, err)
}

func (h *Handler) tillTableClose(w http.ResponseWriter, r *http.Request) {
	var in wire.TillOperationRequest
	if !h.tillBody(w, r, &in) {
		return
	}
	out, err := h.ingest.CloseTableSession(r.Context(), bindingFrom(r.Context()), r.Header.Get("X-Cashier-Token"), chi.URLParam(r, "sessionID"), in.OperationId)
	h.tillReply(w, out, err)
}
