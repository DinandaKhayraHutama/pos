package v2

import (
	"context"
	"errors"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/devices"
	"github.com/stretchr/testify/require"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
)

type failingAuth struct{ err error }

func (f failingAuth) Authenticate(context.Context, string) (devices.Binding, error) {
	return devices.Binding{}, f.err
}
func (f failingAuth) Activate(context.Context, devices.ActivateInput) (devices.Activation, error) {
	return devices.Activation{}, f.err
}
func TestUnavailableAuthenticationDoesNotRevokeTheDevice(t *testing.T) {
	for _, tc := range []struct {
		err    error
		status int
	}{{devices.ErrUnauthenticated, 401}, {errors.New("connection refused"), 503}} {
		h := &Handler{devices: failingAuth{tc.err}, logger: slog.Default()}
		r := httptest.NewRequest("GET", "/", nil)
		r.Header.Set("Authorization", "Bearer token")
		w := httptest.NewRecorder()
		h.authenticate(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { t.Fatal("handler reached") })).ServeHTTP(w, r)
		require.Equal(t, tc.status, w.Code)
	}
}
