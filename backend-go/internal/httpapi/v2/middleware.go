package v2

import (
	"context"
	"errors"
	"github.com/go-chi/chi/v5/middleware"
	"net"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/devices"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/httpapi/render"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/redisx"
)

type ctxKey int

const bindingKey ctxKey = iota

// Activation is unauthenticated, so it is limited by source address and twice
// over: a per-minute burst stops a scripted sweep, an hourly ceiling stops a
// patient one.
var (
	activationPerMinute = redisx.Limit{Burst: 5, Window: time.Minute}
	activationPerHour   = redisx.Limit{Burst: 30, Window: time.Hour}
	devicePerMinute     = redisx.Limit{Burst: 120, Window: time.Minute}
)

func bindingFrom(ctx context.Context) devices.Binding {
	b, _ := ctx.Value(bindingKey).(devices.Binding)
	return b
}

func (h *Handler) limitActivation(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ip := clientIP(r)

		for _, bucket := range []struct {
			key   string
			limit redisx.Limit
		}{
			{"act:m:" + ip, activationPerMinute},
			{"act:h:" + ip, activationPerHour},
		} {
			if ok, retry := redisx.Allow(r.Context(), h.rdb, bucket.key, bucket.limit); !ok {
				h.tooManyRequests(w, retry)
				return
			}
		}

		next.ServeHTTP(w, r)
	})
}

func (h *Handler) authenticate(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		token := bearerToken(r)
		if token == "" {
			h.unauthorised(w)
			return
		}

		binding, err := h.devices.Authenticate(r.Context(), token)
		if err != nil {
			if !errors.Is(err, devices.ErrUnauthenticated) {
				h.logger.Error("device authentication unavailable", "error", err)
				w.Header().Set("Retry-After", "5")
				render.Error(w, h.logger, http.StatusServiceUnavailable, "server_unavailable", "Authentication is temporarily unavailable. Retry with the same token.")
				return
			}
			// Unknown, expired, revoked, or a branch that has since closed.
			// The till treats all of these as "re-activate", never "retry".
			h.unauthorised(w)
			return
		}

		if ok, retry := redisx.Allow(r.Context(), h.rdb, "dev:"+binding.Device.ID, devicePerMinute); !ok {
			h.tooManyRequests(w, retry)
			return
		}

		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), bindingKey, binding)))
	})
}

func (h *Handler) unauthorised(w http.ResponseWriter) {
	render.Error(w, h.logger, http.StatusUnauthorized, "unauthenticated",
		"This device is not authorised. Activate it again.")
}

func (h *Handler) tooManyRequests(w http.ResponseWriter, retryAfter time.Duration) {
	seconds := int(retryAfter.Seconds())
	if seconds < 1 {
		seconds = 1
	}

	w.Header().Set("Retry-After", strconv.Itoa(seconds))
	render.Error(w, h.logger, http.StatusTooManyRequests, "rate_limited",
		"Too many requests. Try again shortly.")
}

func bearerToken(r *http.Request) string {
	header := r.Header.Get("Authorization")
	if len(header) < 7 || !strings.EqualFold(header[:7], "bearer ") {
		return ""
	}

	return strings.TrimSpace(header[7:])
}

func clientIP(r *http.Request) string {
	if ip := middleware.GetClientIP(r.Context()); ip != "" {
		return ip
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}

	return host
}
