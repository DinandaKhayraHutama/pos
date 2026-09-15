package v2

import (
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
)

func TestSyncRoutesRejectMissingAndOutdatedSchemas(t *testing.T) {
	h := &Handler{logger: slog.Default()}
	for name, handler := range map[string]http.HandlerFunc{
		"manifest": h.syncManifest, "changes": h.syncChanges, "pull": h.syncPull,
	} {
		t.Run(name, func(t *testing.T) {
			for _, tc := range []struct {
				header string
				status int
				code   string
			}{
				{"", 409, "device_schema_outdated"},
				{strconv.Itoa(syncfeed.MinDeviceSchemaVersion - 1), 409, "device_schema_outdated"},
				{"invalid", 400, "malformed_request"},
			} {
				w := httptest.NewRecorder()
				r := httptest.NewRequest(http.MethodGet, "/api/v2/sync/"+name, nil)
				r.Header.Set("X-Schema-Version", tc.header)
				handler(w, r)
				require.Equal(t, tc.status, w.Code)
				require.Contains(t, w.Body.String(), tc.code)
			}
		})
	}
	for _, version := range []int{syncfeed.MinDeviceSchemaVersion, syncfeed.SchemaVersion + 1} {
		r := httptest.NewRequest(http.MethodGet, "/", nil)
		r.Header.Set("X-Schema-Version", strconv.Itoa(version))
		require.True(t, h.schemaIsCurrent(httptest.NewRecorder(), r))
	}
}
