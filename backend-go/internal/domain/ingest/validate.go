package ingest

import (
	"encoding/json"
	"math/big"
	"regexp"
	"strings"
	"time"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/httpapi/wire"
)

var uuidPattern = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

func validUUID(id string) bool { return uuidPattern.MatchString(id) }
func optionalUUIDs(ids ...*string) bool {
	for _, id := range ids {
		if id != nil && !validUUID(*id) {
			return false
		}
	}
	return true
}

const maxMillis int64 = 253402300799999 // last millisecond of year 9999

func validateSession(in wire.Session) error {
	if strings.TrimSpace(in.EmployeeName) == "" || in.OpenedAtMs > maxMillis || !optionalUUIDs(in.EmployeeId, in.ClosedById) {
		return reject("schema_rejected", "Invalid session identity or timestamp.")
	}
	if in.ClosedAtMs != nil && (*in.ClosedAtMs < in.OpenedAtMs || *in.ClosedAtMs > maxMillis || in.CountedCash == nil || in.ExpectedCash == nil) {
		return reject("schema_rejected", "Closing requires a valid timestamp and both cash counts.")
	}
	return nil
}

func validateOrder(in wire.Order) error {
	if _, err := time.Parse(time.DateOnly, in.BusinessDate); err != nil {
		return reject("schema_rejected", "Invalid business date.")
	}
	if in.BusinessDate < "1970-01-01" || in.PlacedAtMs > maxMillis || strings.TrimSpace(in.Number) == "" || strings.TrimSpace(in.CashierName) == "" || !optionalUUIDs(in.CashierId, in.TableId) {
		return reject("schema_rejected", "Invalid order identity or timestamp.")
	}
	if in.Discount > in.Subtotal || in.Total != in.Subtotal-in.Discount+in.Tax+in.ServiceChargeAmount {
		return reject("schema_rejected", "Header amounts do not reconcile.")
	}
	if in.RefundedAmount != nil && *in.RefundedAmount > in.Total {
		return reject("schema_rejected", "Refund exceeds total.")
	}
	if in.Status == "cancelled" || in.Status == "refunded" {
		if in.AuthorizedBy == nil || strings.TrimSpace(*in.AuthorizedBy) == "" || in.VoidReason == nil || strings.TrimSpace(*in.VoidReason) == "" {
			return reject("schema_rejected", "Settlement requires authorizer and reason.")
		}
		if in.Status == "refunded" && in.RefundedAmount == nil {
			return reject("schema_rejected", "Refund amount is required.")
		}
	}
	ids := map[string]bool{strings.ToLower(in.Id): true}
	sum := new(big.Int)
	for _, item := range in.Items {
		if !optionalUUIDs(item.ProductId, item.CategoryId) || strings.TrimSpace(item.ProductName) == "" {
			return reject("schema_rejected", "Invalid item snapshot.")
		}
		id := strings.ToLower(item.Id)
		if ids[id] {
			return reject("duplicate", "Repeated nested identifier.")
		}
		ids[id] = true
		unit := big.NewInt(item.UnitPrice)
		for _, modifier := range item.Modifiers {
			id := strings.ToLower(modifier.Id)
			if ids[id] {
				return reject("duplicate", "Repeated nested identifier.")
			}
			ids[id] = true
		}
		// Flutter CartLine.unitPrice already includes variant and modifier
		// deltas. Modifier rows are an audit breakdown, not an extra charge.
		sum.Add(sum, unit.Mul(unit, big.NewInt(int64(item.Quantity))))
	}
	if sum.Cmp(big.NewInt(in.Subtotal)) != 0 {
		return reject("schema_rejected", "Item amounts do not reconcile with subtotal.")
	}
	return nil
}

func encode(value any) []byte {
	// Callers pass generated DTOs that contain only JSON-safe primitive values.
	b, err := json.Marshal(value)
	if err != nil {
		panic(err)
	}
	return b
}

func immutableSession(in wire.Session) []byte {
	in.Revision = 0
	in.ClosedAtMs, in.CountedCash, in.ExpectedCash = nil, nil, nil
	in.ClosedById, in.ClosedByName, in.Note = nil, nil, nil
	return encode(in)
}
func immutableOrder(in wire.Order) []byte {
	in.Revision, in.Status = 0, ""
	in.AuthorizedBy, in.VoidReason, in.RefundedAmount = nil, nil, nil
	return encode(in)
}
