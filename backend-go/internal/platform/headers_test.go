package platform

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/stretchr/testify/require"
)

// The panel refused its own login for a while, and this header is why.
//
// gorilla/csrf accepts a form POST on the strength of the Origin header, and
// falls back to Referer when a browser sends none. `no-referrer` instructed
// browsers to withhold exactly that fallback, so a legitimate sign-in came
// back as "Forbidden - referer not supplied" — a panel telling the truth about
// a rule it had imposed on itself.
//
// `same-origin` keeps the privacy property that mattered (several pages here
// show a credential once, and no other site learns those URLs) while leaving
// the panel's own requests able to identify themselves.
func TestThePanelDoesNotWithholdItsOwnReferer(t *testing.T) {
	recorder := httptest.NewRecorder()
	securityHeaders(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	})).ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/platform/login", nil))

	require.Equal(t, "same-origin", recorder.Header().Get("Referrer-Policy"))
	require.NotEqual(t, "no-referrer", recorder.Header().Get("Referrer-Policy"),
		"no-referrer disables the fallback gorilla/csrf needs when a browser sends no Origin")

	// The rest of the header set is not weakened by that change.
	require.Equal(t, "DENY", recorder.Header().Get("X-Frame-Options"))
	require.Equal(t, "no-store", recorder.Header().Get("Cache-Control"))
	require.Equal(t, "nosniff", recorder.Header().Get("X-Content-Type-Options"))
}
