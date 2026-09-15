package v2

import (
	"bytes"
	"log/slog"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestPushEnvelopeFailuresNeverReturnSuccessOr422(t *testing.T) {
	for _, tc := range []struct {
		name, body string
		status     int
	}{
		{"array", "[]", 400}, {"null", "null", 400}, {"scalar", `"ok"`, 400},
		{"empty", `{}`, 400}, {"trailing", `{"batches":[{"entity":"orders","rows":[{}]}]} {}`, 400},
		{"oversize", strings.Repeat(" ", maxPushBytes+1), 413},
		{"oversize_trailing", `{"batches":[{"entity":"orders","rows":[{}]}]}` + strings.Repeat(" ", maxPushBytes+1), 413},
		{"too_many", `{"batches":[{"entity":"orders","rows":[` + strings.Repeat(`{},`, 200) + `{}]}]}`, 413},
		{"raw_invalid_row_is_not_envelope_error", `{"batches":[{"entity":"orders","rows":[[],"ok",null]}]}`, 503},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h := &Handler{logger: slog.Default()}
			r := httptest.NewRequest("POST", "/sync/push", bytes.NewBufferString(tc.body))
			r.Header.Set("X-Schema-Version", "1")
			w := httptest.NewRecorder()
			h.syncPush(w, r)
			require.Equal(t, tc.status, w.Code)
			require.True(t, strings.HasPrefix(w.Body.String(), "{"))
			require.NotEqual(t, 422, w.Code)
		})
	}
}
