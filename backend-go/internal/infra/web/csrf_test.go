package web_test

import (
	"bytes"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"github.com/gorilla/csrf"
	"github.com/stretchr/testify/require"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/web"
)

// panel builds the middleware chain both browser panels install, so the test
// exercises the real interaction between the scheme declaration and
// gorilla/csrf rather than a description of it.
func panel(logger *slog.Logger) http.Handler {
	protect := csrf.Protect(make([]byte, 32),
		csrf.Secure(false),
		csrf.ErrorHandler(web.CSRFFailure(logger)),
	)
	return web.DeclareRequestScheme(protect(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet {
			_, _ = w.Write([]byte(csrf.Token(r)))
			return
		}
		w.WriteHeader(http.StatusNoContent)
	})))
}

// form fetches a token the way a browser does, then posts it back with the
// headers the caller wants to try.
func form(t *testing.T, h http.Handler, overTLS bool, headers map[string]string) *httptest.ResponseRecorder {
	t.Helper()

	get := httptest.NewRequest(http.MethodGet, "http://panel.test/login", nil)
	if overTLS {
		get.Header.Set("X-Forwarded-Proto", "https")
	}
	page := httptest.NewRecorder()
	h.ServeHTTP(page, get)
	require.Equal(t, http.StatusOK, page.Code)

	post := httptest.NewRequest(http.MethodPost, "http://panel.test/login",
		// Encoded, never concatenated: a masked token contains "+", which a
		// form body decodes as a space.
		strings.NewReader(url.Values{"gorilla.csrf.Token": {page.Body.String()}}.Encode()))
	post.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	for _, c := range page.Result().Cookies() {
		post.AddCookie(c)
	}
	if overTLS {
		post.Header.Set("X-Forwarded-Proto", "https")
	}
	for name, value := range headers {
		post.Header.Set(name, value)
	}
	out := httptest.NewRecorder()
	h.ServeHTTP(out, post)
	return out
}

// The bug this pins: behind a TLS terminator the browser sends an https
// Origin while the process sees plain HTTP on the wire. If the scheme is taken
// from the connection instead of X-Forwarded-Proto, gorilla/csrf compares
// https against http and refuses every form POST the panel makes — the login
// included — with "origin invalid" and nothing in the log.
func TestAnHTTPSOriginIsAcceptedWhenTheProxySaysTheBrowserUsedHTTPS(t *testing.T) {
	out := form(t, panel(quiet()), true, map[string]string{"Origin": "https://panel.test"})
	require.Equal(t, http.StatusNoContent, out.Code, "a same-origin POST behind TLS must be accepted: %s", out.Body)
}

func TestAPlainHTTPOriginIsAcceptedWhenNothingClaimsTLS(t *testing.T) {
	out := form(t, panel(quiet()), false, map[string]string{"Origin": "http://panel.test"})
	require.Equal(t, http.StatusNoContent, out.Code, "a same-origin POST without TLS must be accepted: %s", out.Body)
}

// The other direction has to keep failing, or the fix would be "accept
// everything": this is the attack the whole mechanism exists for.
func TestACrossSiteOriginIsStillRefused(t *testing.T) {
	out := form(t, panel(quiet()), true, map[string]string{"Origin": "https://attacker.example"})
	require.Equal(t, http.StatusForbidden, out.Code)
	require.Contains(t, out.Body.String(), "Formulir ini ditolak")
}

// A refusal used to be a bare line of text with nothing written anywhere. The
// three headers that decide the verdict, and the conclusion the server drew
// from them, are the whole diagnosis — the browser can show you the first
// three and never the fourth.
func TestARefusalIsLoggedWithWhatDecidedIt(t *testing.T) {
	var buf bytes.Buffer
	logger := slog.New(slog.NewTextHandler(&buf, &slog.HandlerOptions{Level: slog.LevelWarn}))

	out := form(t, panel(logger), true, map[string]string{"Origin": "https://attacker.example"})
	require.Equal(t, http.StatusForbidden, out.Code)

	logged := buf.String()
	for _, want := range []string{
		"CSRF refused a request",
		`origin=https://attacker.example`,
		"host=panel.test",
		"x_forwarded_proto=https",
		"server_read_it_as_https=true",
		"reason=",
	} {
		require.Contains(t, logged, want)
	}
}

// Nothing a person can read should be a 200: a refused form must not look like
// a successful one to anything downstream.
func TestTheRefusalPageIsA403AndTellsThePersonWhatToDo(t *testing.T) {
	out := form(t, panel(quiet()), false, map[string]string{"Origin": "http://elsewhere.example"})
	require.Equal(t, http.StatusForbidden, out.Code)
	require.Equal(t, "text/html; charset=utf-8", out.Header().Get("Content-Type"))
	require.Equal(t, "no-store", out.Header().Get("Cache-Control"))
	body := out.Body.String()
	require.Contains(t, body, "Muat ulang halaman")
	require.Contains(t, body, "TRUST_PROXY")
}

func TestOverTLSReadsTheProxyHeaderAndNothingElse(t *testing.T) {
	plain := httptest.NewRequest(http.MethodGet, "http://panel.test/", nil)
	require.False(t, web.OverTLS(plain))

	forwarded := httptest.NewRequest(http.MethodGet, "http://panel.test/", nil)
	forwarded.Header.Set("X-Forwarded-Proto", "HTTPS")
	require.True(t, web.OverTLS(forwarded), "the comparison is case-insensitive")

	other := httptest.NewRequest(http.MethodGet, "http://panel.test/", nil)
	other.Header.Set("X-Forwarded-Proto", "http")
	require.False(t, web.OverTLS(other))
}

func quiet() *slog.Logger {
	return slog.New(slog.NewTextHandler(&bytes.Buffer{}, nil))
}

// Not every browser sends Origin on a same-site form POST — several have
// historically sent only Referer. gorilla/csrf accommodates that, and this
// pair is why `Referrer-Policy` on a panel is a functional decision and not
// only a privacy one:
//
//	Referer present  -> accepted   (the panel says same-origin)
//	Referer withheld -> refused    (the panel said no-referrer)
//
// The second case is the sign-in that failed, and the header the panel set on
// itself is what produced it.
func TestABrowserThatSendsOnlyARefererIsAccepted(t *testing.T) {
	out := form(t, panel(quiet()), true, map[string]string{"Referer": "https://panel.test/login"})
	require.Equal(t, http.StatusNoContent, out.Code,
		"a same-origin POST identified by Referer alone must be accepted: %s", out.Body)
}

func TestABrowserToldToWithholdBothHeadersIsRefusedOverTLS(t *testing.T) {
	out := form(t, panel(quiet()), true, nil)
	require.Equal(t, http.StatusForbidden, out.Code,
		"with neither Origin nor Referer there is nothing left to check")
	require.Contains(t, out.Body.String(), "Formulir ini ditolak")
}
