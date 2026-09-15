package ingest

import (
	"testing"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/httpapi/wire"
	"github.com/stretchr/testify/require"
)

func TestModifierBreakdownMustNotBeChargedTwice(t *testing.T) {
	// Matches mobile CartLine.unitPrice and OrderItem.lineTotal: final unit
	// price already includes the selected modifier. The row is audit detail.
	order := wire.Order{
		Id: "00000000-0000-4000-8000-000000000001", BusinessDate: "2026-09-13",
		Number: "RECEIPT", CashierName: "Sari", Subtotal: 20000, Total: 20000,
		Items: []wire.OrderItem{{Id: "00000000-0000-4000-8000-000000000002", ProductName: "Coffee", Quantity: 2, UnitPrice: 10000,
			Modifiers: []wire.OrderItemModifier{{Id: "00000000-0000-4000-8000-000000000003", PriceDelta: 1000}},
		}},
	}
	require.NoError(t, validateOrder(order))
	order.Subtotal, order.Total = 22000, 22000
	require.Error(t, validateOrder(order), "counting modifier twice must not reconcile")
}
