package api_test

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/daniryckidinata/nti_pos/backend-go/api"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
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
	require.Equal(t, 8, checked)
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
