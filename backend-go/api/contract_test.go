package api_test

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/daniryckidinata/nti_pos/backend-go/api"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/httpapi/wire"
	"github.com/getkin/kin-openapi/openapi3"
	"github.com/stretchr/testify/require"
)

func TestFrozenContractHasOnlyObjectSuccessResponses(t *testing.T) {
	doc, err := openapi3.NewLoader().LoadFromData(api.Specification)
	require.NoError(t, err)
	require.NoError(t, doc.Validate(context.Background()))
	checked := 0
	for path, item := range doc.Paths.Map() {
		for method, op := range item.Operations() {
			for status, response := range op.Responses.Map() {
				if !strings.HasPrefix(status, "2") {
					continue
				}
				checked++
				schema := response.Value.Content.Get("application/json").Schema
				require.NotNil(t, schema, "%s %s %s", method, path, status)
				require.True(t, schema.Value.Type.Is("object"), "%s %s %s must return an object", method, path, status)
			}
		}
	}
	// Two more since 2.5.0: the till's summary and sales reports.
	require.Equal(t, 16, checked)
}

func TestGeneratedTillSuccessModelsValidateAgainstOpenAPI(t *testing.T) {
	doc, err := openapi3.NewLoader().LoadFromData(api.Specification)
	require.NoError(t, err)
	id := wire.UUID("00000000-0000-4000-8000-000000000001")
	session := wire.Session{Id: string(id), Revision: 1, EmployeeName: "Sari", OpenedAtMs: 1, OpeningCash: 0}
	models := map[string]any{
		"TillLoginResponse":    wire.TillLoginResponse{Data: wire.TillLoginData{Token: strings.Repeat("a", 64), ExpiresAtMs: 2}},
		"TillSessionResponse":  wire.TillSessionResponse{Data: wire.TillSessionData{Session: session, ReceiptStart: 1, ReceiptEnd: 100}},
		"TillCurrentResponse":  wire.TillCurrentResponse{Data: nil},
		// The history page always carries the scope and range the server
		// actually applied, so the model is only valid with them filled in.
		"TillHistoryResponse": wire.TillHistoryResponse{Data: wire.TillHistoryPage{
			Rows: []map[string]any{}, Next: "", ServerTimeMs: 3,
			Scope: wire.TillHistoryPageScopeRegister, From: "2026-09-22", To: "2026-09-22",
		}},
		"TillRecoveryResponse": wire.TillRecoveryResponse{Data: wire.TillRecovery{Id: id, SessionId: id, Status: wire.RecoveryOpen, ForcedAtMs: 4, Items: []wire.TillRecoveryItem{}}},
		"TillReportResponse": wire.TillReportResponse{Data: wire.TillReport{
			Period:             wire.TillReportPeriod{From: "2026-09-01", To: "2026-09-22", Days: 22},
			Scope:              wire.TillReportScope{OutletId: string(id), OutletName: "Kemang", AllOutlets: false},
			Timezone:           "Asia/Jakarta",
			CalculationVersion: 2,
			PendingSlices:      0,
			Incomplete:         false,
			ServerTimeMs:       5,
			Sales: wire.TillReportSales{
				GrossSales: 90000, Discounts: 5500, SalesReturns: 15000, NetSales: 69500,
				Tax: 6950, ServiceCharge: 1000, Revenue: 77450,
				OrderCount: 2, AverageSale: 34750, ItemsSold: 5,
			},
		}},
	}
	for schema, model := range models {
		raw, marshalErr := json.Marshal(model)
		require.NoError(t, marshalErr)
		var value any
		require.NoError(t, json.Unmarshal(raw, &value))
		require.NoError(t, doc.Components.Schemas[schema].Value.VisitJSON(value), schema)
	}
}

func TestTillSurfaceIsLockedInTheContract(t *testing.T) {
	doc, err := openapi3.NewLoader().LoadFromData(api.Specification)
	require.NoError(t, err)
	require.NoError(t, doc.Validate(context.Background()))

	want := map[string]string{
		"/till/login":                    "POST",
		"/till/sessions/open":            "POST",
		"/till/sessions/handover":        "POST",
		"/till/sessions/current":         "GET",
		"/till/orders":                   "GET",
		"/till/recoveries/{recovery_id}": "GET",
		"/till/reports/summary":          "GET",
		"/till/reports/sales":            "GET",
	}
	for path, method := range want {
		item := doc.Paths.Find(path)
		require.NotNil(t, item, path)
		require.NotNil(t, item.GetOperation(method), "%s %s", method, path)
	}
}

func TestManifestFitsTheFrozenContract(t *testing.T) {
	doc, err := openapi3.NewLoader().LoadFromData(api.Specification)
	require.NoError(t, err)
	raw, err := json.Marshal(syncfeed.BuildManifest())
	require.NoError(t, err)
	var value any
	require.NoError(t, json.Unmarshal(raw, &value))
	require.NoError(t, doc.Components.Schemas["Manifest"].Value.VisitJSON(value))
}
