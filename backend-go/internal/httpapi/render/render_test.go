package render_test

import (
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/httpapi/render"
)

type scalarMarshaler struct{}

func (scalarMarshaler) MarshalJSON() ([]byte, error) { return []byte(`"ok"`), nil }

func TestJSONRejectsNonObjectsBeforeWritingSuccess(t *testing.T) {
	var nilObject *struct{ Status string }
	for name, body := range map[string]any{
		"array": []string{}, "string": "ok", "number": 1, "bool": true,
		"nil": nil, "nil pointer": nilObject, "nil map": map[string]string(nil),
		"unsupported": make(chan int), "invalid raw": json.RawMessage(`{bad`),
		"raw array": json.RawMessage(`[]`), "custom scalar": scalarMarshaler{},
	} {
		t.Run(name, func(t *testing.T) {
			w := httptest.NewRecorder()
			render.JSON(w, slog.New(slog.NewTextHandler(io.Discard, nil)), http.StatusOK, body)
			require.Equal(t, http.StatusInternalServerError, w.Code)
			require.JSONEq(t, `{"error":{"code":"server_error","message":"The response could not be encoded."}}`, w.Body.String())
		})
	}
}

func TestJSONPreservesAnObjectAndItsStatus(t *testing.T) {
	w := httptest.NewRecorder()
	render.JSON(w, slog.Default(), http.StatusOK, struct {
		Rows []string `json:"rows"`
	}{Rows: []string{}})
	require.Equal(t, http.StatusOK, w.Code)
	require.Equal(t, "application/json; charset=utf-8", w.Header().Get("Content-Type"))
	require.JSONEq(t, `{"rows":[]}`, w.Body.String())
}
