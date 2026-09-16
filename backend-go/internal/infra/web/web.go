// Package web holds what both browser panels — the merchant Backoffice and the
// platform panel — need from the HTTP layer and must not get wrong separately.
package web

import (
	"context"
	"net/http"
	"strings"

	"github.com/gorilla/csrf"
)

// DeclareRequestScheme tells gorilla/csrf which scheme the BROWSER used, which
// is what decides how it validates the Origin header.
//
// The connection is not the authority: behind Caddy this process always sees
// plain HTTP even when the browser used HTTPS, so X-Forwarded-Proto has to be
// consulted. Getting it wrong in either direction rejects every POST — assume
// HTTPS on a developer's machine and the http Origin is refused; assume HTTP
// behind TLS and the https Origin is refused.
//
// Only safe because Caddy is the sole ingress and overwrites this header; an
// app reachable directly must not trust it (httpapi strips it unless
// TRUST_PROXY is set).
func DeclareRequestScheme(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ctx := context.WithValue(r.Context(), csrf.PlaintextHTTPContextKey, !OverTLS(r))
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

// OverTLS reports whether the browser reached this request over HTTPS.
func OverTLS(r *http.Request) bool {
	return r.TLS != nil || strings.EqualFold(r.Header.Get("X-Forwarded-Proto"), "https")
}

// SameOrigin reports whether a state-changing request came from a page on this
// host. For the few POSTs that cannot carry a CSRF token — a handoff arriving
// from another panel's page — it is the cross-site check that remains.
func SameOrigin(r *http.Request) bool {
	origin := r.Header.Get("Origin")
	if origin == "" {
		return false
	}
	scheme := "http"
	if OverTLS(r) {
		scheme = "https"
	}
	return strings.EqualFold(origin, scheme+"://"+r.Host)
}
