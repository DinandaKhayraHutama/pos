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
	if err = s.ingestOrder(ctx, w.Tx, b, in, result); err != nil {
		return err
	}
	if in.StockMovements == nil {
		return nil
	}
	// Effects are uniquely attached to a receipt, not its human-readable number.
	seen := map[string]bool{}
	quantities := map[string]int64{}
	for _, line := range in.Items {
		if line.ProductId != nil {
			quantities[*line.ProductId] += int64(line.Quantity)
		}
	}
	sales, returns := map[string]int64{}, map[string]int64{}
	for _, effect := range *in.StockMovements {
		var movement stock.DeviceMovement
		if err = json.Unmarshal(encode(effect), &movement); err != nil {
			return err
		}
		if seen[movement.ID] {
			return reject("schema_rejected", "Duplicate movement in receipt.")
		}
		seen[movement.ID] = true
		switch movement.Reason {
		case stock.ReasonSale:
			sales[movement.ProductID] -= movement.DeltaQty
		case stock.ReasonVoidReturn:
			if in.Status != "cancelled" && in.Status != "refunded" {
				return reject("schema_rejected", "Only a settlement can return stock.")
			}
			returns[movement.ProductID] += movement.DeltaQty
		default:
			return reject("schema_rejected", "Only sale and return movements belong to a receipt.")
		}
		if quantities[movement.ProductID] == 0 || sales[movement.ProductID] > quantities[movement.ProductID] || returns[movement.ProductID] > quantities[movement.ProductID] {
			return reject("schema_rejected", "Stock quantity exceeds the receipt lines.")
		}
		var ref *string
		err = w.Tx.QueryRow(ctx, "SELECT ref_id::text FROM stock_movements WHERE id=$1", movement.ID).Scan(&ref)
		if err == nil && (ref == nil || *ref != in.Id) {
			return reject("duplicate", "Movement belongs to another operation.")
		}
		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
		if _, err = s.stock.RecordFromDevice(ctx, w, b, movement); err != nil {
			var rejection *stock.Rejection
			if errors.As(err, &rejection) {
				return reject(rejection.Code, rejection.Message)
			}
			return err
		}
		if _, err = w.Tx.Exec(ctx, "UPDATE stock_movements SET ref_type='order',ref_id=$2 WHERE id=$1", movement.ID, in.Id); err != nil {
			return err
		}
	}
	// A subsequent revision cannot omit a previously committed effect. Its
	// canonical payload is checked by RecordFromDevice above.
	var stored int
	if err = w.Tx.QueryRow(ctx, "SELECT count(*) FROM stock_movements WHERE ref_type='order' AND ref_id=$1", in.Id).Scan(&stored); err != nil {
		return err
	}
	if stored != len(seen) {
		return reject("schema_rejected", "Receipt omitted an existing stock effect.")
	}
	return nil
}
