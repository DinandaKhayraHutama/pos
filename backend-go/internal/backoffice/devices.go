package backoffice

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"regexp"
	"time"

	"github.com/a-h/templ"
	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/backoffice/views"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/devices"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/entitlements"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
)

func (h *Handler) devicesPage(w http.ResponseWriter, r *http.Request) {
	employee := employeeFrom(r.Context())

	var (
		registers []views.Register
		bound     []views.Device
	)

	err := pg.InTenantTx(r.Context(), h.pools.Tenant, employee.TenantID, func(ctx context.Context, tx pgx.Tx) error {
		var err error
		if registers, err = loadRegisters(ctx, tx); err != nil {
			return err
		}

		bound, err = loadDevices(ctx, tx, "")
		return err
	})
	if err != nil {
		h.serverError(w, r, err)
		return
	}

	h.render(w, r, views.DevicesPage(h.sessionView(r), registers, bound))
}

func (h *Handler) issueActivationCode(w http.ResponseWriter, r *http.Request) {
	employee := employeeFrom(r.Context())
	registerID := chi.URLParam(r, "registerID")

	issued, err := h.devices.Issue(r.Context(), employee.TenantID, registerID, &employee.ID)
	if errors.Is(err, devices.ErrRegisterInactive) {
		h.renderStatus(w, r, http.StatusUnprocessableEntity,
			views.ErrorCard("Till atau outletnya tidak aktif."))
		return
	}
	var limit *entitlements.LimitError
	if errors.As(err, &limit) {
		h.renderStatus(w, r, http.StatusUnprocessableEntity, views.ErrorCard(limit.Message()))
		return
	}
	if err != nil {
		h.serverError(w, r, err)
		return
	}

	var registerName string
	if err := pg.InTenantTx(r.Context(), h.pools.Tenant, employee.TenantID, func(ctx context.Context, tx pgx.Tx) error {
		return tx.QueryRow(ctx, `SELECT name FROM pos_registers WHERE id = $1`, registerID).Scan(&registerName)
	}); err != nil {
		h.serverError(w, r, err)
		return
	}

	// The plaintext reaches the browser and nothing else: it is not logged, not
	// flashed into the session, and not written back to the row it came from.
	w.Header().Set("Cache-Control", "no-store, private")

	h.render(w, r, views.IssuedCodeCard(views.IssuedCode{
		RegisterName: registerName,
		Code:         issued.Code,
		ExpiresIn:    "10 menit",
	}))
}

var uuidPattern = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

func (h *Handler) revokeDevice(w http.ResponseWriter, r *http.Request) {
	employee := employeeFrom(r.Context())
	deviceID := chi.URLParam(r, "deviceID")

	// A malformed id is the caller's mistake, not the server's: without this
	// it reaches PostgreSQL as invalid uuid input and surfaces as a 500 plus a
	// logged error, which buries real failures in noise.
	if !uuidPattern.MatchString(deviceID) {
		h.renderStatus(w, r, http.StatusNotFound, views.ErrorCard("Perangkat tidak ditemukan."))
		return
	}

	// Through the cache so the binding stops being servable now, rather than
	// when its cached entry happens to expire.
	err := h.auth.Revoke(r.Context(), employee.TenantID, deviceID)
	if errors.Is(err, pgx.ErrNoRows) {
		h.renderStatus(w, r, http.StatusNotFound, views.ErrorCard("Perangkat tidak ditemukan."))
		return
	}
	if err != nil {
		h.serverError(w, r, err)
		return
	}

	var updated []views.Device
	if err := pg.InTenantTx(r.Context(), h.pools.Tenant, employee.TenantID, func(ctx context.Context, tx pgx.Tx) error {
		var err error
		updated, err = loadDevices(ctx, tx, deviceID)
		return err
	}); err != nil {
		h.serverError(w, r, err)
		return
	}

	if len(updated) == 0 {
		h.renderStatus(w, r, http.StatusNotFound, views.ErrorCard("Perangkat tidak ditemukan."))
		return
	}

	h.render(w, r, views.DeviceRow(updated[0]))
}

func loadRegisters(ctx context.Context, tx pgx.Tx) ([]views.Register, error) {
	rows, err := tx.Query(ctx, `
		SELECT r.id, r.name, o.name, r.active, r.table_service,
		       (SELECT count(*) FROM devices d WHERE d.pos_register_id = r.id)
		FROM pos_registers r
		JOIN outlets o ON o.tenant_id = r.tenant_id AND o.id = r.outlet_id
		ORDER BY o.name, r.name`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []views.Register
	for rows.Next() {
		var (
			reg   views.Register
			count int64
		)
		if err := rows.Scan(&reg.ID, &reg.Name, &reg.OutletName, &reg.Active, &reg.TableService, &count); err != nil {
			return nil, err
		}
		reg.DeviceCount = int(count)
		out = append(out, reg)
	}

	return out, rows.Err()
}

// loadDevices returns every device, or just one when id is set — the revoke
// handler swaps a single row rather than the whole table.
func loadDevices(ctx context.Context, tx pgx.Tx, id string) ([]views.Device, error) {
	rows, err := tx.Query(ctx, `
		SELECT d.id, COALESCE(d.label, ''), COALESCE(d.platform, ''),
		       r.name, o.name, d.last_seen_at, d.revoked_at
		FROM devices d
		JOIN pos_registers r ON r.tenant_id = d.tenant_id AND r.id = d.pos_register_id
		JOIN outlets o ON o.tenant_id = d.tenant_id AND o.id = d.outlet_id
		WHERE $1 = '' OR d.id = $1::uuid
		ORDER BY d.created_at DESC`, id)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []views.Device
	for rows.Next() {
		var (
			dev       views.Device
			lastSeen  *time.Time
			revokedAt *time.Time
		)
		if err := rows.Scan(&dev.ID, &dev.Label, &dev.Platform,
			&dev.RegisterName, &dev.OutletName, &lastSeen, &revokedAt); err != nil {
			return nil, err
		}

		if dev.Label == "" {
			dev.Label = "(tanpa label)"
		}
		if dev.Platform == "" {
			dev.Platform = "—"
		}
		dev.LastSeen = "belum pernah"
		if lastSeen != nil {
			dev.LastSeen = lastSeen.Local().Format("2 Jan 2006 15:04")
		}
		dev.Revoked = revokedAt != nil

		out = append(out, dev)
	}

	return out, rows.Err()
}

func (h *Handler) render(w http.ResponseWriter, r *http.Request, c templ.Component) {
	h.renderStatus(w, r, http.StatusOK, c)
}

func (h *Handler) renderStatus(w http.ResponseWriter, r *http.Request, status int, c templ.Component) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(status)

	if err := c.Render(r.Context(), w); err != nil {
		h.logger.Error("render backoffice view", slog.Any("error", err))
	}
}

func (h *Handler) serverError(w http.ResponseWriter, r *http.Request, err error) {
	h.logger.Error("backoffice request failed", slog.Any("error", err))
	h.renderStatus(w, r, http.StatusInternalServerError, views.ErrorCard("Terjadi kesalahan di server."))
}
