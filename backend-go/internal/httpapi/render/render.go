// Package render is the only way a handler writes a body.
//
// Every response is a JSON object. The Flutter till parses any 2xx body that is
// not an object as SyncFailure.malformed, and a malformed push response makes
// it delete the queued sale from its outbox permanently — so a top-level array
// here is a money-loss bug, not a style choice.
package render

import (
	"bytes"
	"encoding/json"
	"log/slog"
	"net/http"
)

type ErrorBody struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

type errorEnvelope struct {
	Error ErrorBody `json:"error"`
}

func JSON(w http.ResponseWriter, logger *slog.Logger, status int, body any) {
	// Marshal before committing the status: invalid payloads must not leave a
	// successful response with an empty/truncated body. Inspect the encoded
	// shape too, since a struct's MarshalJSON can return a scalar or array.
	payload, err := json.Marshal(body)
	if err != nil || !bytes.HasPrefix(bytes.TrimSpace(payload), []byte("{")) {
		logger.Error("invalid JSON response object", slog.Any("error", err))
		status = http.StatusInternalServerError
		payload = []byte(`{"error":{"code":"server_error","message":"The response could not be encoded."}}`)
	}

	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)

	if _, err := w.Write(append(payload, '\n')); err != nil {
		logger.Error("write response body", slog.Any("error", err))
	}
}

func Error(w http.ResponseWriter, logger *slog.Logger, status int, code, message string) {
	JSON(w, logger, status, errorEnvelope{Error: ErrorBody{Code: code, Message: message}})
}
