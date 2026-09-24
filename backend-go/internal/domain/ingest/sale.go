package ingest

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/devices"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/stock"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/httpapi/wire"
	"github.com/jackc/pgx/v5"
	"strings"
)

// One receipt and all its stock effects share one database transaction. A
// malformed effect rolls back the receipt, dedupe reservation and report job.
func (s *Service) ingestSale(ctx context.Context, w *syncfeed.Writer, b devices.Binding, raw json.RawMessage, result *wire.PushResult) error {
	return s.ingestSaleForRecovery(ctx, w, b, raw, result, "")
}

// ingestSaleForRecovery bypasses only the force-closed-session guard when the
// caller holds the matching recovery case. All receipt, cashier, ownership,
// amount and stock validations below remain authoritative.
func (s *Service) ingestSaleForRecovery(ctx context.Context, w *syncfeed.Writer, b devices.Binding, raw json.RawMessage, result *wire.PushResult, allowedRecoveryID string) error {
	if err := s.conform("orders", raw); err != nil {
		return err
	}
	var in wire.Order
	if err := json.Unmarshal(raw, &in); err != nil {
		return reject("schema_rejected", "Invalid receipt.")
	}
	in.Id, in.PosSessionId = strings.ToLower(in.Id), strings.ToLower(in.PosSessionId)
	if err := validateOrder(in); err != nil {
		return err
	}
	var owner string
	var closed *int64
	var claimed bool
	var closeKind string
	var recoveryID *string
	err := w.Tx.QueryRow(ctx, `SELECT p.device_id::text,p.closed_at_ms,
		EXISTS(SELECT 1 FROM till_claims c WHERE c.session_id=p.id),p.close_kind,p.forced_recovery_id::text
		FROM pos_sessions p WHERE p.id=$1 FOR SHARE`, in.PosSessionId).Scan(&owner, &closed, &claimed, &closeKind, &recoveryID)
	if errors.Is(err, pgx.ErrNoRows) {
		return retry("dependency_pending", "Upload or recover the session first.")
	}
	if err != nil {
		return err
	}
	if claimed {
		if owner != b.Device.ID || in.StockMovements == nil || in.CashierId == nil {
			return reject("schema_rejected", "Receipt does not own the coordinated session.")
		}
		var allowed bool
		err = w.Tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM till_operators WHERE session_id=$1 AND employee_id=$2)`, in.PosSessionId, *in.CashierId).Scan(&allowed)
		if err != nil {
			return err
		}
		if !allowed {
			return reject("schema_rejected", "Cashier was not assigned to this session.")
		}
		if closed != nil {
			var exists bool
			if err = w.Tx.QueryRow(ctx, "SELECT EXISTS(SELECT 1 FROM order_dedupe WHERE id=$1)", in.Id).Scan(&exists); err != nil {
				return err
			}
			if !exists {
				if closeKind == "forced" && recoveryID != nil {
					if allowedRecoveryID == *recoveryID {
						// The manager decision owns this exceptional path.
					} else {
						return recoverRequired(*recoveryID)
					}
				} else {
					return reject("session_closed", "Closing already acknowledged every receipt. Recover this unexpected sale.")
				}
			}
		}
	}
	// A receipt that settles a saved bill (Fase 4) is checked against the bill
	// before it is written: the bill is locked, and a receipt for a bill this
	// till does not own, or one with lines not yet sent to the kitchen, never
	// reaches the orders table.
	var settlement *billSettlement
	if in.BillId != nil {
		if settlement, err = s.prepareSettlement(ctx, w, b, in, allowedRecoveryID != ""); err != nil {
			return err
		}
	}
	if err = s.ingestOrder(ctx, w.Tx, b, in, result); err != nil {
		return err
	}
	if settlement != nil {
		if err = settlement.close(ctx, w.Tx, in, result); err != nil {
			return err
		}
	}
	if in.StockMovements == nil {
		return nil
	}
	// Effects are uniquely attached to a receipt, not its human-readable number.
	//
	// What a receipt may move is bounded by its own lines — or, for one that
	// settles a bill, by what that bill's dispatches actually consumed: the
	// kitchen took the stock, and the receipt itself takes none.
	seen := map[string]bool{}
	bound := map[string]int64{}
	if settlement != nil {
		bound = settlement.consumed
	} else {
		for _, line := range in.Items {
			if line.ProductId != nil {
				bound[strings.ToLower(*line.ProductId)] += int64(line.Quantity)
			}
		}
	}
	sales, returns := map[string]int64{}, map[string]int64{}
	movements := make([]stock.DeviceMovement, 0, len(*in.StockMovements))
	for _, effect := range *in.StockMovements {
		var movement stock.DeviceMovement
		if err = json.Unmarshal(encode(effect), &movement); err != nil {
			return err
		}
		movement.ID, movement.ProductID = strings.ToLower(movement.ID), strings.ToLower(movement.ProductID)
		if seen[movement.ID] {
			return reject("schema_rejected", "Duplicate movement in receipt.")
		}
		seen[movement.ID] = true
		switch movement.Reason {
		case stock.ReasonSale:
			if settlement != nil {
				return reject("schema_rejected", "A bill's stock was consumed by its dispatches, not by its receipt.")
			}
			sales[movement.ProductID] -= movement.DeltaQty
		case stock.ReasonVoidReturn:
			if in.Status != "cancelled" && in.Status != "refunded" {
				return reject("schema_rejected", "Only a settlement can return stock.")
			}
			returns[movement.ProductID] += movement.DeltaQty
		default:
			return reject("schema_rejected", "Only sale and return movements belong to a receipt.")
		}
		if bound[movement.ProductID] == 0 || sales[movement.ProductID] > bound[movement.ProductID] || returns[movement.ProductID] > bound[movement.ProductID] {
			return reject("schema_rejected", "Stock quantity exceeds the receipt lines.")
		}
		movements = append(movements, movement)
	}
	applied, err := s.stock.RecordBatchFromDevice(ctx, w, b, movements, "order", in.Id)
	if err != nil {
		var rejection *stock.Rejection
		if errors.As(err, &rejection) {
			return reject(rejection.Code, rejection.Message)
		}
		return err
	}
	// A subsequent revision cannot omit a previously committed effect. Its
	// canonical payload is checked by RecordBatchFromDevice above.
	var stored int
	if err = w.Tx.QueryRow(ctx, "SELECT count(*) FROM stock_movements WHERE ref_type='order' AND ref_id=$1", in.Id).Scan(&stored); err != nil {
		return err
	}
	if stored != len(seen) {
		return reject("schema_rejected", "Receipt omitted an existing stock effect.")
	}
	result.Effects = effectsOf(applied)
	return nil
}

// effectsOf is what a push result says about the movements a row committed,
// or nil when it committed none.
func effectsOf(applied []stock.Applied) *[]wire.PushEffect {
	if len(applied) == 0 {
		return nil
	}
	out := make([]wire.PushEffect, len(applied))
	for i, a := range applied {
		out[i] = wire.PushEffect{Id: a.ID, StockSeq: a.StockSeq, BalanceAfter: a.BalanceAfter}
	}
	return &out
}
