// Package api owns the frozen device wire contract.
package api

import _ "embed"

//go:generate go run github.com/oapi-codegen/oapi-codegen/v2/cmd/oapi-codegen@v2.8.0 --config oapi-codegen.yaml openapi.yaml

//go:embed openapi.yaml
var Specification []byte
