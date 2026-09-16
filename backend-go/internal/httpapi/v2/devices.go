package v2

import (
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"regexp"
	"strings"
	"time"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/devices"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/entitlements"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/httpapi/render"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/httpapi/wire"
)

var codePattern = regexp.MustCompile(`^[A-Z2-9]{12}$`)

func (h *Handler) activate(w http.ResponseWriter, r *http.Request) {
	var req wire.ActivateRequest

	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 8<<10))
	// Unknown fields are refused rather than ignored. tenant_id, outlet_id and
	// pos_register_id are the ones that matter: accepting any of them from an
	// unauthenticated request would let anyone bind a tablet to any business,
	// and quietly dropping them would leave that looking like it worked.
	decoder.DisallowUnknownFields()

	if err := decoder.Decode(&req); err != nil {
		render.Error(w, h.logger, http.StatusBadRequest, "malformed_request",
			"The request body could not be read.")
		return
	}
	if decoder.Decode(new(any)) != io.EOF || (req.Label != nil && len(*req.Label) > 120) || (req.Platform != nil && len(*req.Platform) > 32) {
		render.Error(w, h.logger, 400, "malformed_request", "Exactly one bounded JSON object is required.")
		return
	}

	code := strings.ToUpper(strings.TrimSpace(req.Code))
	if !codePattern.MatchString(code) {
		render.Error(w, h.logger, http.StatusUnprocessableEntity, "invalid_code",
			"The activation code is invalid or expired.")
		return
	}

	deviceUUID := strings.TrimSpace(req.DeviceUuid)
	if deviceUUID == "" || len(deviceUUID) > 128 {
		render.Error(w, h.logger, http.StatusBadRequest, "malformed_request",
			"A device_uuid is required.")
		return
	}

	activation, err := h.devices.Activate(r.Context(), devices.ActivateInput{
		Code:       code,
		DeviceUUID: deviceUUID,
		Label:      req.Label,
		Platform:   req.Platform,
	})

	switch {
	case errors.Is(err, devices.ErrInvalidCode):
		render.Error(w, h.logger, http.StatusUnprocessableEntity, "invalid_code",
			"The activation code is invalid or expired.")
		return
	case errors.Is(err, devices.ErrBoundToAnother):
		render.Error(w, h.logger, http.StatusUnprocessableEntity, "bound_to_another_register",
			"This installation is already bound to another register.")
		return
	case errors.Is(err, entitlements.ErrLimitReached):
		// 422 like the other refusals: the till already reads 422 as "this code
		// did not activate, get another", and the code itself stays unconsumed.
		render.Error(w, h.logger, http.StatusUnprocessableEntity, "device_limit_reached",
			"This business has reached its active device limit.")
		return
	case err != nil:
		h.logger.Error("activate device", slog.Any("error", err))
		render.Error(w, h.logger, http.StatusInternalServerError, "server_error",
			"Activation could not be completed.")
		return
	}

	// The token is returned exactly once and never stored in plaintext, so the
	// response must not be cacheable anywhere along the way.
	w.Header().Set("Cache-Control", "no-store, private")

	b := wireBinding(activation.Binding)
	response := wire.ActivateResponse{}
	response.Data.Device = b.Device
	response.Data.Outlet = b.Outlet
	response.Data.PosRegister = b.PosRegister
	response.Data.Tenant = b.Tenant
	response.Data.Token = activation.Token
	response.Data.TokenExpiresAtMs = epochMillis(activation.TokenExpiresAt)
	render.JSON(w, h.logger, http.StatusOK, response)
}

func (h *Handler) me(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store, private")
	render.JSON(w, h.logger, http.StatusOK, wire.MeResponse{Data: wireBinding(bindingFrom(r.Context()))})
}

func wireBinding(b devices.Binding) wire.Binding {
	return wire.Binding{
		Device:      wire.Device{Id: b.Device.ID, DeviceUuid: b.Device.UUID, Label: b.Device.Label, Platform: b.Device.Platform},
		Tenant:      wire.Tenant{Id: b.Tenant.ID, Name: b.Tenant.Name},
		Outlet:      wire.Outlet{Id: b.Outlet.ID, Name: b.Outlet.Name, Address: b.Outlet.Address, Phone: b.Outlet.Phone},
		PosRegister: wire.Register{Id: b.Register.ID, OutletId: b.Register.OutletID, Name: b.Register.Name, TableService: b.Register.TableService},
	}
}

func epochMillis(t time.Time) int64 {
	return t.UnixMilli()
}
