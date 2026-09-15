// Package v2 serves the device API.
//
// Contract rules that hold everywhere in here:
//   - every 2xx body is a JSON object, never an array or a scalar;
//   - every timestamp is epoch milliseconds, int64;
//   - money is integer rupiah;
//   - identity comes from the token, never from the payload.
package v2

import (
	"context"
	"log/slog"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/redis/go-redis/v9"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/devices"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/ingest"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
)

// DeviceService is satisfied by both the plain service and the Redis-backed
// wrapper around it.
//
// Handlers are given the wrapper, and both methods live on one interface for a
// reason: activation rotates a token, so a handler that reached past the cache
// to activate would leave the cache serving a credential the database has
// already replaced.
type DeviceService interface {
	Authenticate(ctx context.Context, plainToken string) (devices.Binding, error)
	Activate(ctx context.Context, in devices.ActivateInput) (devices.Activation, error)
}

type Handler struct {
	ingest  *ingest.Service
	devices DeviceService
	sync    *syncfeed.Service
	rdb     *redis.Client
	logger  *slog.Logger
	// pollInterval is handed to every till in /sync/changes, so widening the
	// fleet's polling during an incident is a restart rather than a release.
	pollInterval time.Duration
}

type Deps struct {
	Ingest       *ingest.Service
	Devices      DeviceService
	Sync         *syncfeed.Service
	Redis        *redis.Client
	Logger       *slog.Logger
	PollInterval time.Duration
}

func NewHandler(d Deps) *Handler {
	return &Handler{
		ingest:       d.Ingest,
		devices:      d.Devices,
		sync:         d.Sync,
		rdb:          d.Redis,
		logger:       d.Logger,
		pollInterval: d.PollInterval,
	}
}

func (h *Handler) Routes() chi.Router {
	r := chi.NewRouter()

	r.With(h.limitActivation).Post("/devices/activate", h.activate)
	r.Get("/time", h.serverTime)

	r.Group(func(r chi.Router) {
		r.Use(h.authenticate)

		r.Get("/devices/me", h.me)

		r.Get("/sync/manifest", h.syncManifest)
		r.Get("/sync/changes", h.syncChanges)
		r.Get("/sync/pull", h.syncPull)
		r.Post("/sync/push", h.syncPush)
	})

	return r
}
