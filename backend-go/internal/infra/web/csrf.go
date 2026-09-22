package web

import (
	"html"
	"log/slog"
	"net/http"

	"github.com/gorilla/csrf"
)

// CSRFFailure is what a person sees, and what the log says, when a
// state-changing request is refused.
//
// gorilla/csrf's default is a bare "Forbidden - origin invalid" with nothing
// written anywhere. That one line has four very different causes and no way to
// tell them apart from the outside:
//
//   - a genuinely cross-site POST, which is the attack this exists to stop;
//   - a form left open until its token expired;
//   - the browser sending no Origin AND no Referer, which is what a
//     `Referrer-Policy: no-referrer` on the panel itself produces;
//   - the server and the browser disagreeing about which scheme the request
//     arrived over — X-Forwarded-Proto stripped or never set — which is the
//     one that costs a day, because nothing about the page looks wrong.
//
// The last two are configuration, not attacks, and they must never again be
// indistinguishable from each other. Everything that decides the verdict is
// logged; the person gets a page that says what to do.
func CSRFFailure(logger *slog.Logger) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		reason := csrf.FailureReason(r)

		logger.Warn("CSRF refused a request",
			slog.String("path", r.URL.Path),
			slog.String("method", r.Method),
			slog.Any("reason", reason),
			slog.String("origin", r.Header.Get("Origin")),
			slog.String("referer", r.Header.Get("Referer")),
			slog.String("host", r.Host),
			slog.String("x_forwarded_proto", r.Header.Get("X-Forwarded-Proto")),
			// What the server concluded, which is the half a browser cannot
			// show you. Origin https + scheme http is the classic mismatch.
			slog.Bool("server_read_it_as_https", OverTLS(r)),
		)

		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Cache-Control", "no-store")
		w.WriteHeader(http.StatusForbidden)

		detail := ""
		if reason != nil {
			detail = html.EscapeString(reason.Error())
		}
		_, _ = w.Write([]byte(`<!doctype html><meta charset="utf-8">` +
			`<title>Formulir ditolak</title>` +
			`<style>body{font:16px/1.6 system-ui,sans-serif;margin:10vh auto;max-width:34rem;padding:0 1.5rem;color:#1f2430}` +
			`h1{font-size:1.3rem;margin:0 0 .75rem}code{background:#f1f2f6;padding:.1rem .35rem;border-radius:.25rem;font-size:.9em}` +
			`p{margin:0 0 .75rem}</style>` +
			`<h1>Formulir ini ditolak</h1>` +
			`<p>Muat ulang halaman lalu kirim sekali lagi. Kalau terus berulang, ` +
			`kemungkinan besar alamat yang dibuka berbeda dengan yang dikenali server ` +
			`&mdash; buka panel lewat satu alamat saja, dan periksa <code>TRUST_PROXY</code> ` +
			`bila ada proxy TLS di depannya.</p>` +
			`<p><small>Alasan: <code>` + detail + `</code></small></p>`))
	})
}
