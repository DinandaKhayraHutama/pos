package httpapi

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"log/slog"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
	"github.com/redis/go-redis/v9"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/backoffice"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/catalogue"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/devices"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/ingest"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/outlets"
	domainplatform "github.com/daniryckidinata/nti_pos/backend-go/internal/domain/platform"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/promos"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/staff"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/stock"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/tables"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/httpapi/render"
	v2 "github.com/daniryckidinata/nti_pos/backend-go/internal/httpapi/v2"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/httpapi/wire"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/media"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/platform"
)

type Deps struct {
	TrustProxy bool
	Pools      pg.Pools
	// SessionDB is a database/sql handle on the same PostgreSQL: the session
	// store predates pgx and takes only that interface.
	SessionDB *sql.DB
	Redis     *redis.Client
	Logger    *slog.Logger
	AppKey    string
	// SecureCookies must be true wherever the panel is served over TLS.
	SecureCookies bool
	// SyncPollInterval is what every till is told to wait between polls.
	SyncPollInterval time.Duration
	// Media stores uploaded product images and serves them under /media.
	Media *media.Store
	// Reports serves the Backoffice sales report, dashboard and exports; nil
	// leaves those sections out.
	Reports backoffice.ReportService
	// PlatformSessionDB stores platform panel sessions. It must be on the
	// UNSCOPED credential — platform_sessions is not granted to the merchant
	// one — and nil leaves /platform unmounted.
	PlatformSessionDB *sql.DB
	// Mail sends an owner's first sign-in link; nil shows the link on the
	// platform panel instead.
	Mail domainplatform.Mailer
	// LinkBaseURL is the origin e-mailed links start with.
	LinkBaseURL string
}

func NewRouter(d Deps) http.Handler {
	r := chi.NewRouter()
	r.Use(middleware.RequestID, middleware.Recoverer)
	if d.TrustProxy {
		// Caddy overwrites this private header; the API port is not published.
		r.Use(middleware.ClientIPFromHeader("X-Justclick-Client-IP"))
	} else {
		r.Use(middleware.ClientIPFromRemoteAddr)
		r.Use(func(next http.Handler) http.Handler {
			return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { r.Header.Del("X-Forwarded-Proto"); next.ServeHTTP(w, r) })
		})
	}

	r.Get("/health", health(d))
	r.Get("/api/v2/health", health(d))

	// Served here for deployments with nothing in front; behind Caddy the same
	// files are served straight off the shared volume and never reach this
	// process. Either way the URL and the headers are identical.
	// A nil *media.Store must not become a non-nil ImageStore interface.
	var images catalogue.ImageStore
	if d.Media != nil {
		images = d.Media
		r.Handle("/media/*", http.StripPrefix("/media", d.Media.Handler()))
	}

	svc := devices.NewService(d.Pools, d.AppKey)
	cachedAuth := devices.NewCachedAuthenticator(svc, d.Redis, d.Logger)
	feed := syncfeed.NewService(d.Pools, d.Redis, d.Logger)
	push, err := ingest.NewService(d.Pools, feed, d.Logger)
	if err != nil {
		panic("initialize ingest: " + err.Error())
	}

	// The cached wrapper, never the bare service: it is what keeps the auth
	// cache honest when activation rotates a token.
	r.Mount("/api/v2", v2.NewHandler(v2.Deps{
		Ingest:       push,
		Devices:      cachedAuth,
		Sync:         feed,
		Redis:        d.Redis,
		Logger:       d.Logger,
		PollInterval: d.SyncPollInterval,
	}).Routes())

	// The platform invalidates through the same auth cache the API
	// authenticates with, so suspending a merchant signs its tills out now.
	platformSvc := domainplatform.NewService(d.Pools, domainplatform.Options{
		Auth:        cachedAuth,
		Mail:        d.Mail,
		LinkBaseURL: d.LinkBaseURL,
		Redis:       d.Redis,
		Logger:      d.Logger,
	})

	// Every Backoffice writer publishes through the same feed service the API
	// reads from, and the outlet writer invalidates through the same cache the
	// API authenticates with — one of each, so the two surfaces cannot disagree.
	r.Mount("/backoffice", backoffice.New(backoffice.Deps{
		Pools:          d.Pools,
		SessionDB:      d.SessionDB,
		Staff:          staff.NewService(d.Pools, feed),
		Catalogue:      catalogue.NewService(d.Pools, feed, images),
		Promos:         promos.NewService(d.Pools, feed),
		Outlets:        outlets.NewService(d.Pools, feed, cachedAuth),
		Stock:          stock.NewService(d.Pools, feed),
		Tables:         tables.NewService(d.Pools, feed),
		Reports:        d.Reports,
		Devices:        svc,
		CachedAuth:     cachedAuth,
		Impersonations: platformSvc,
		Setup:          platformSvc,
		Logger:         d.Logger,
		CSRFKey:        csrfKey(d.AppKey),
		SecureCookies:  d.SecureCookies,
	}).Routes())

	if d.PlatformSessionDB != nil {
		r.Mount("/platform", platform.New(platform.Deps{
			Service:       platformSvc,
			SessionDB:     d.PlatformSessionDB,
			Redis:         d.Redis,
			Logger:        d.Logger,
			AppKey:        d.AppKey,
			SecureCookies: d.SecureCookies,
		}).Routes())
	}

	r.Get("/", func(w http.ResponseWriter, req *http.Request) {
		http.Redirect(w, req, "/backoffice", http.StatusSeeOther)
	})

	return r
}

// csrfKey is derived rather than configured separately, so there is one secret
// to rotate rather than two to keep in step. Rotating APP_KEY invalidates
// in-flight forms, which is the intended blast radius.
func csrfKey(appKey string) []byte {
	sum := sha256.Sum256([]byte(appKey + "|backoffice-csrf"))
	return sum[:]
}

func health(d Deps) http.HandlerFunc {
	return func(w http.ResponseWriter, req *http.Request) {
		ctx, cancel := context.WithTimeout(req.Context(), 2*time.Second)
		defer cancel()

		body := wire.Health{Status: "ok", Service: "justclick-api", Database: "ok", Cache: "ok"}
		status := http.StatusOK

		if err := d.Pools.Tenant.Ping(ctx); err != nil {
			d.Logger.Error("health: database unreachable", slog.Any("error", err))
			body.Status = "degraded"
			body.Database = "unreachable"
			status = http.StatusServiceUnavailable
		}

		// Redis being down costs latency, not correctness, so it never makes
		// the service unhealthy — it only shows up here.
		if err := d.Redis.Ping(ctx).Err(); err != nil {
			d.Logger.Warn("health: cache unreachable", slog.Any("error", err))
			body.Cache = "unreachable"
		}

		render.JSON(w, d.Logger, status, body)
	}
}
