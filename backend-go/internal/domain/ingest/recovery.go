package ingest

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/devices"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/httpapi/wire"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
	"github.com/jackc/pgx/v5"
)

var ErrRecoveryNotFound = errors.New("recovery not found")

type RecoveryActor struct {
	ID   string
	Name string
}

type ForceTakeoverInput struct {
	OperationID       string
	SessionID         string
	DeviceID          string
	ConfirmedRegister string
	Reason            string
	CountedCash       *int64
	Actor             RecoveryActor
}

type TakeoverResult struct {
	RecoveryID string
	RegisterID string
	TokenHash  []byte
	Idempotent bool
}

type RecoveryItem struct {
	ID             string          `json:"id"`
	Entity         string          `json:"entity"`
	EntityID       string          `json:"entity_id"`
	Revision       int64           `json:"revision"`
	Status         string          `json:"status"`
	Payload        json.RawMessage `json:"-"`
	DecisionReason *string         `json:"decision_reason"`
	CreatedAtMs    int64           `json:"created_at_ms"`
	DecidedAtMs    *int64          `json:"decided_at_ms"`
}

type Recovery struct {
	ID                   string         `json:"id"`
	SessionID            string         `json:"session_id"`
	RegisterID           string         `json:"-"`
	RegisterName         string         `json:"-"`
	OutletName           string         `json:"-"`
	DeviceID             string         `json:"-"`
	DeviceLabel          string         `json:"-"`
	Status               string         `json:"status"`
	Reason               string         `json:"-"`
	ActorName            string         `json:"-"`
	ForcedAtMs           int64          `json:"forced_at_ms"`
	OrderCountAtTakeover int64          `json:"-"`
	ExpectedCash         int64          `json:"-"`
	CountedCash          *int64         `json:"-"`
	ReconciliationBasis  *string        `json:"reconciliation_basis"`
	Items                []RecoveryItem `json:"items"`
}

type RecoveryPointer struct {
	ID         string `json:"id"`
	SessionID  string `json:"session_id"`
	ForcedAtMs int64  `json:"forced_at_ms"`
}

type DiagnosticFinding struct {
	Classification string `json:"classification"`
	Code           string `json:"code"`
	Entity         string `json:"entity"`
	EntityID       string `json:"entity_id"`
	Action         string `json:"action"`
}

type DiagnosticReport struct {
	Status   string              `json:"status"`
	Findings []DiagnosticFinding `json:"findings"`
}

// ForceTakeover closes the drawer, creates its durable recovery case, clears
// the active cashier and revokes the old installation in one transaction.
func (s *Service) ForceTakeover(ctx context.Context, tenantID string, in ForceTakeoverInput) (TakeoverResult, error) {
	var out TakeoverResult
	in.Reason = strings.TrimSpace(in.Reason)
	if !validUUID(in.OperationID) || !validUUID(in.SessionID) || !validUUID(in.DeviceID) || !validUUID(in.Actor.ID) || in.Reason == "" || len(in.Reason) > 2000 || in.CountedCash != nil && *in.CountedCash < 0 {
		return out, tillError("invalid_takeover")
	}
	err := pg.InTenantTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		// A completed retry returns the same case even though the session is no
		// longer open and the token is already gone.
		if err := tx.QueryRow(ctx, `SELECT id::text,register_id::text FROM till_recoveries WHERE operation_id=$1`, in.OperationID).Scan(&out.RecoveryID, &out.RegisterID); err == nil {
			out.Idempotent = true
			return nil
		} else if !errors.Is(err, pgx.ErrNoRows) {
			return err
		}

		var registerName string
		if err := tx.QueryRow(ctx, `SELECT r.id::text,r.name FROM pos_registers r
			JOIN pos_sessions p ON p.pos_register_id=r.id AND p.tenant_id=r.tenant_id
			WHERE p.id=$1 FOR UPDATE OF r`, in.SessionID).Scan(&out.RegisterID, &registerName); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrRecoveryNotFound
			}
			return err
		}
		if strings.TrimSpace(in.ConfirmedRegister) != registerName {
			return tillError("register_confirmation_mismatch")
		}

		var outletID, ownerDevice, employeeName string
		var opening, sessionRevision int64
		if err := tx.QueryRow(ctx, `SELECT outlet_id::text,device_id::text,employee_name,opening_cash
			,revision FROM pos_sessions WHERE id=$1 AND pos_register_id=$2 AND closed_at_ms IS NULL FOR UPDATE`, in.SessionID, out.RegisterID).
			Scan(&outletID, &ownerDevice, &employeeName, &opening, &sessionRevision); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return tillError("takeover_conflict")
			}
			return err
		}
		if ownerDevice != in.DeviceID {
			return tillError("takeover_conflict")
		}
		// A claim row is deliberately NOT required here. An open session can
		// legitimately have none — one that reached the server through the
		// legacy push path never gets a `till_claims` row, which is exactly
		// what `DiagnoseTill` reports as `open_session_without_claim` — and
		// that drawer is the one that most needs a controlled close: the till
		// cannot resume it and cannot close it either, so a manager is the
		// only way out. Requiring the claim would lock a merchant out of their
		// own stuck register.
		//
		// Concurrency is already handled: this transaction holds
		// `pos_registers FOR UPDATE OF r` and `pos_sessions … FOR UPDATE`
		// above, which is what makes two simultaneous takeovers produce one
		// winner. An earlier `tx.Exec("SELECT … FOR UPDATE")` here looked like
		// a third guard and enforced nothing — `Exec` discards rows, so zero
		// rows is not an error and its `ErrNoRows` branch could never run.
		if err := tx.QueryRow(ctx, `SELECT COALESCE(token_sha256,''::bytea) FROM devices WHERE id=$1 FOR UPDATE`, in.DeviceID).Scan(&out.TokenHash); err != nil {
			return err
		}

		var count, cashSales int64
		if err := tx.QueryRow(ctx, `SELECT count(*),COALESCE(sum(CASE WHEN payment_method='cash' AND status NOT IN ('cancelled','refunded') THEN total ELSE 0 END),0)
			FROM orders WHERE pos_session_id=$1`, in.SessionID).Scan(&count, &cashSales); err != nil {
			return err
		}
		expected, forcedAt := opening+cashSales, time.Now()
		if err := tx.QueryRow(ctx, `INSERT INTO till_recoveries
			(tenant_id,outlet_id,register_id,session_id,device_id,operation_id,actor_employee_id,actor_name,reason,forced_at,order_count_at_takeover,expected_cash_at_takeover,counted_cash)
			VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13) RETURNING id::text`,
			tenantID, outletID, out.RegisterID, in.SessionID, in.DeviceID, in.OperationID, in.Actor.ID, in.Actor.Name, in.Reason, forcedAt, count, expected, in.CountedCash).Scan(&out.RecoveryID); err != nil {
			return err
		}
		closedMs := forcedAt.UnixMilli()
		payloadPatch := map[string]any{"revision": sessionRevision + 1, "closed_at_ms": closedMs, "expected_cash": expected, "closed_by_id": in.Actor.ID, "closed_by_name": in.Actor.Name, "note": "Forced takeover: " + in.Reason}
		if in.CountedCash != nil {
			payloadPatch["counted_cash"] = *in.CountedCash
		}
		if _, err := tx.Exec(ctx, `UPDATE pos_sessions SET closed_at_ms=$2,counted_cash=$3,expected_cash=$4,
			close_kind='forced',forced_recovery_id=$5,revision=revision+1,
			payload=payload || $6::jsonb,updated_at=now() WHERE id=$1`, in.SessionID, closedMs, in.CountedCash, expected, out.RecoveryID, encode(payloadPatch)); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE till_claims SET active_employee_id=NULL WHERE session_id=$1`, in.SessionID); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `DELETE FROM till_access WHERE device_id=$1`, in.DeviceID); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE devices SET token_sha256=NULL,token_expires_at=NULL,revoked_at=now(),updated_at=now() WHERE id=$1`, in.DeviceID); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE activation_codes SET cancelled_at=now() WHERE pos_register_id=$1 AND consumed_at IS NULL AND cancelled_at IS NULL`, out.RegisterID); err != nil {
			return err
		}
		detail := encode(map[string]any{"register_name": registerName, "device_id": in.DeviceID, "session_id": in.SessionID, "employee_name": employeeName, "order_count": count, "expected_cash": expected})
		_, err := tx.Exec(ctx, `INSERT INTO till_recovery_events(tenant_id,recovery_id,event_type,actor_employee_id,actor_name,detail) VALUES($1,$2,'takeover',$3,$4,$5)`, tenantID, out.RecoveryID, in.Actor.ID, in.Actor.Name, detail)
		return err
	})
	return out, tillDBError(err)
}

// quarantineLate copies the exact already-audited payload into a case. The
// unique key makes an exact retry one item while ingest_log remains an audit of
// every received attempt.
func (s *Service) quarantineLate(ctx context.Context, b devices.Binding, entity string, raw json.RawMessage, audit ingestAudit, domainErr error, result *wire.PushResult) error {
	var reason *rejection
	if !errors.As(domainErr, &reason) || reason.code != "recovery_required" || reason.recoveryID == "" {
		return nil
	}
	if audit.ID == "" {
		return errors.New("missing ingest audit reference")
	}
	var identity struct {
		ID        string `json:"id"`
		Revision  int64  `json:"revision"`
		SessionID string `json:"pos_session_id"`
	}
	if json.Unmarshal(raw, &identity) != nil || !validUUID(identity.ID) || identity.Revision < 1 {
		return errors.New("invalid recovery identity")
	}
	sum := sha256.Sum256(raw)
	var itemID string
	err := pg.InTenantTx(ctx, s.pools.Tenant, b.Tenant.ID, func(ctx context.Context, tx pgx.Tx) error {
		var inserted bool
		err := tx.QueryRow(ctx, `WITH i AS (
			INSERT INTO till_recovery_items(tenant_id,recovery_id,entity,entity_id,revision,payload,payload_sha256,source_ingest_date,source_ingest_id)
			SELECT $1,r.id,$2,$3,$4,$5,$6,$7,$8 FROM till_recoveries r
			WHERE r.id=$9 AND r.device_id=$10 AND r.session_id=$11
			ON CONFLICT (recovery_id,entity,entity_id,revision) DO NOTHING RETURNING id)
			SELECT id::text,true FROM i UNION ALL
			SELECT id::text,false FROM till_recovery_items WHERE recovery_id=$9 AND entity=$2 AND entity_id=$3 AND revision=$4 LIMIT 1`,
			b.Tenant.ID, entity, identity.ID, identity.Revision, raw, sum[:], audit.Date, audit.ID, reason.recoveryID, b.Device.ID, identity.SessionID).Scan(&itemID, &inserted)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrRecoveryNotFound
		}
		if err != nil {
			return err
		}
		if inserted {
			_, err = tx.Exec(ctx, `INSERT INTO till_recovery_events(tenant_id,recovery_id,event_type,detail) VALUES($1,$2,'item_found',$3)`, b.Tenant.ID, reason.recoveryID, encode(map[string]any{"item_id": itemID, "entity": entity, "entity_id": identity.ID, "revision": identity.Revision}))
		}
		return err
	})
	if err == nil {
		id := wire.UUID(reason.recoveryID)
		result.RecoveryId = &id
	}
	return err
}

func (s *Service) listRecoveries(ctx context.Context, tenantID, deviceID, recoveryID string, includePayload bool) ([]Recovery, error) {
	var out []Recovery
	err := pg.InTenantReadTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `SELECT r.id::text,r.session_id::text,r.register_id::text,pr.name,o.name,r.device_id::text,
			COALESCE(d.label,'(tanpa label)'),r.status,r.reason,r.actor_name,(extract(epoch from r.forced_at)*1000)::bigint,
			r.order_count_at_takeover,r.expected_cash_at_takeover,r.counted_cash,r.reconciliation_basis
			FROM till_recoveries r JOIN pos_registers pr ON pr.id=r.register_id JOIN outlets o ON o.id=r.outlet_id JOIN devices d ON d.id=r.device_id
			WHERE (NULLIF($1,'') IS NULL OR r.device_id=NULLIF($1,'')::uuid) AND (NULLIF($2,'') IS NULL OR r.id=NULLIF($2,'')::uuid) ORDER BY r.forced_at DESC`, deviceID, recoveryID)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var v Recovery
			if err = rows.Scan(&v.ID, &v.SessionID, &v.RegisterID, &v.RegisterName, &v.OutletName, &v.DeviceID, &v.DeviceLabel, &v.Status, &v.Reason, &v.ActorName, &v.ForcedAtMs, &v.OrderCountAtTakeover, &v.ExpectedCash, &v.CountedCash, &v.ReconciliationBasis); err != nil {
				return err
			}
			v.Items = []RecoveryItem{}
			out = append(out, v)
		}
		if err = rows.Err(); err != nil {
			return err
		}
		for i := range out {
			itemRows, e := tx.Query(ctx, `SELECT id::text,entity,entity_id::text,revision,status,payload,decision_reason,(extract(epoch from created_at)*1000)::bigint,CASE WHEN decided_at IS NULL THEN NULL ELSE (extract(epoch from decided_at)*1000)::bigint END FROM till_recovery_items WHERE recovery_id=$1 ORDER BY created_at,id`, out[i].ID)
			if e != nil {
				return e
			}
			for itemRows.Next() {
				var it RecoveryItem
				if e = itemRows.Scan(&it.ID, &it.Entity, &it.EntityID, &it.Revision, &it.Status, &it.Payload, &it.DecisionReason, &it.CreatedAtMs, &it.DecidedAtMs); e != nil {
					itemRows.Close()
					return e
				}
				if !includePayload {
					it.Payload = nil
				}
				out[i].Items = append(out[i].Items, it)
			}
			e = itemRows.Err()
			itemRows.Close()
			if e != nil {
				return e
			}
		}
		return nil
	})
	return out, err
}

func (s *Service) ListRecoveries(ctx context.Context, tenantID string) ([]Recovery, error) {
	return s.listRecoveries(ctx, tenantID, "", "", true)
}

func (s *Service) RecoveryStatus(ctx context.Context, b devices.Binding, token, id string) (Recovery, error) {
	var none Recovery
	if !validUUID(id) {
		return none, tillError("invalid_recovery")
	}
	err := pg.InTenantReadTx(ctx, s.pools.Tenant, b.Tenant.ID, func(ctx context.Context, tx pgx.Tx) error { _, err := tillEmployee(ctx, tx, b, token); return err })
	if err != nil {
		return none, err
	}
	rows, err := s.listRecoveries(ctx, b.Tenant.ID, b.Device.ID, id, false)
	if err != nil {
		return none, err
	}
	if len(rows) != 1 {
		return none, tillError("recovery_not_found")
	}
	return rows[0], nil
}

// RecoveryForSession lets a reactivated installation connect a local active
// drawer to the server's forced closure without exposing another device's
// cases. The caller has already authenticated the cashier through CurrentTill.
func (s *Service) RecoveryForSession(ctx context.Context, b devices.Binding, sessionID string) (*RecoveryPointer, error) {
	if sessionID == "" {
		return nil, nil
	}
	if !validUUID(sessionID) {
		return nil, tillError("invalid_session")
	}
	var out RecoveryPointer
	err := pg.InTenantReadTx(ctx, s.pools.Tenant, b.Tenant.ID, func(ctx context.Context, tx pgx.Tx) error {
		return tx.QueryRow(ctx, `SELECT id::text,session_id::text,(extract(epoch from forced_at)*1000)::bigint
			FROM till_recoveries WHERE session_id=$1 AND device_id=$2 AND register_id=$3`, sessionID, b.Device.ID, b.Register.ID).
			Scan(&out.ID, &out.SessionID, &out.ForcedAtMs)
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &out, nil
}

func (s *Service) AcceptRecoveryItem(ctx context.Context, tenantID string, actor RecoveryActor, recoveryID, itemID string) error {
	if !validUUID(recoveryID) || !validUUID(itemID) || !validUUID(actor.ID) {
		return tillError("invalid_recovery")
	}
	return s.feed.Write(ctx, tenantID, func(ctx context.Context, w *syncfeed.Writer) error {
		var raw []byte
		var loadedRecoveryID, entity, status, sessionID string
		var b devices.Binding
		err := w.Tx.QueryRow(ctx, `SELECT i.payload,i.recovery_id::text,i.entity,i.status,r.session_id::text,
			d.id::text,d.device_uuid,d.label,d.platform,t.id::text,t.name,o.id::text,o.name,o.address,o.phone,pr.id::text,pr.outlet_id::text,pr.name,pr.table_service
			FROM till_recovery_items i JOIN till_recoveries r ON r.id=i.recovery_id
			JOIN devices d ON d.id=r.device_id JOIN tenants t ON t.id=r.tenant_id JOIN outlets o ON o.id=r.outlet_id JOIN pos_registers pr ON pr.id=r.register_id
			WHERE i.id=$1 AND i.recovery_id=$2 FOR UPDATE OF i`, itemID, recoveryID).Scan(&raw, &loadedRecoveryID, &entity, &status, &sessionID, &b.Device.ID, &b.Device.UUID, &b.Device.Label, &b.Device.Platform, &b.Tenant.ID, &b.Tenant.Name, &b.Outlet.ID, &b.Outlet.Name, &b.Outlet.Address, &b.Outlet.Phone, &b.Register.ID, &b.Register.OutletID, &b.Register.Name, &b.Register.TableService)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrRecoveryNotFound
		}
		if err != nil {
			return err
		}
		if status == "accepted" {
			return nil
		}
		if status != "pending" {
			return tillError("recovery_already_decided")
		}
		if entity != "orders" {
			return tillError("unsupported_recovery_entity")
		}
		var identity struct {
			SessionID string `json:"pos_session_id"`
		}
		if json.Unmarshal(raw, &identity) != nil || identity.SessionID != sessionID {
			return tillError("recovery_payload_mismatch")
		}
		result := wire.PushResult{Entity: entity, Status: "retry"}
		if err = s.ingestSaleForRecovery(ctx, w, b, raw, &result, loadedRecoveryID); err != nil {
			return err
		}
		_, err = w.Tx.Exec(ctx, `UPDATE till_recovery_items SET status='accepted',decision_reason='Validated and applied',decided_at=now(),decided_by_employee_id=$2,updated_at=now() WHERE id=$1`, itemID, actor.ID)
		if err != nil {
			return err
		}
		_, err = w.Tx.Exec(ctx, `INSERT INTO till_recovery_events(tenant_id,recovery_id,event_type,actor_employee_id,actor_name,detail) VALUES($1,$2,'item_accepted',$3,$4,$5)`, tenantID, loadedRecoveryID, actor.ID, actor.Name, encode(map[string]any{"item_id": itemID}))
		return err
	})
}

func (s *Service) DiscardRecoveryItem(ctx context.Context, tenantID string, actor RecoveryActor, recoveryID, itemID, reason string) error {
	reason = strings.TrimSpace(reason)
	if !validUUID(recoveryID) || !validUUID(itemID) || !validUUID(actor.ID) || reason == "" || len(reason) > 2000 {
		return tillError("invalid_recovery_decision")
	}
	return pg.InTenantTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		var loadedRecoveryID, status string
		if err := tx.QueryRow(ctx, `SELECT recovery_id::text,status FROM till_recovery_items WHERE id=$1 AND recovery_id=$2 FOR UPDATE`, itemID, recoveryID).Scan(&loadedRecoveryID, &status); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrRecoveryNotFound
			}
			return err
		}
		if status == "discarded" {
			return nil
		}
		if status != "pending" {
			return tillError("recovery_already_decided")
		}
		if _, err := tx.Exec(ctx, `UPDATE till_recovery_items SET status='discarded',decision_reason=$2,decided_at=now(),decided_by_employee_id=$3,updated_at=now() WHERE id=$1`, itemID, reason, actor.ID); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `INSERT INTO till_recovery_events(tenant_id,recovery_id,event_type,actor_employee_id,actor_name,detail) VALUES($1,$2,'item_discarded',$3,$4,$5)`, tenantID, loadedRecoveryID, actor.ID, actor.Name, encode(map[string]any{"item_id": itemID, "reason": reason}))
		return err
	})
}

func (s *Service) ReconcileRecovery(ctx context.Context, tenantID string, actor RecoveryActor, recoveryID, basis, reason string) error {
	reason = strings.TrimSpace(reason)
	if !validUUID(recoveryID) || !validUUID(actor.ID) || (basis != "device_checked" && basis != "device_unavailable") || reason == "" || len(reason) > 2000 {
		return tillError("invalid_reconciliation")
	}
	return pg.InTenantTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		var status string
		if err := tx.QueryRow(ctx, `SELECT status FROM till_recoveries WHERE id=$1 FOR UPDATE`, recoveryID).Scan(&status); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrRecoveryNotFound
			}
			return err
		}
		if status == "reconciled" {
			return nil
		}
		var pending int
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM till_recovery_items WHERE recovery_id=$1 AND status='pending'`, recoveryID).Scan(&pending); err != nil {
			return err
		}
		if pending > 0 {
			return tillError("recovery_items_pending")
		}
		if _, err := tx.Exec(ctx, `UPDATE till_recoveries SET status='reconciled',reconciliation_basis=$2,reconciliation_reason=$3,reconciled_at=now(),reconciled_by_employee_id=$4,updated_at=now() WHERE id=$1`, recoveryID, basis, reason, actor.ID); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `INSERT INTO till_recovery_events(tenant_id,recovery_id,event_type,actor_employee_id,actor_name,detail) VALUES($1,$2,'reconciled',$3,$4,$5)`, tenantID, recoveryID, actor.ID, actor.Name, encode(map[string]any{"basis": basis, "reason": reason}))
		return err
	})
}

// DiagnoseTill is deliberately read-only and is shared by the Backoffice and
// the command-line diagnostic. It reports evidence and a safe next action.
func (s *Service) DiagnoseTill(ctx context.Context, tenantID string) (DiagnosticReport, error) {
	out := DiagnosticReport{Status: "healthy", Findings: []DiagnosticFinding{}}
	err := pg.InTenantReadTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		checks := []struct{ classification, code, entity, action, query string }{
			{"conflict", "open_session_without_claim", "pos_session", "Inspect the register and create a controlled recovery before assigning another device.", `SELECT p.id::text FROM pos_sessions p LEFT JOIN till_claims c ON c.session_id=p.id WHERE p.closed_at_ms IS NULL AND c.session_id IS NULL`},
			{"conflict", "claim_on_closed_session", "pos_session", "Inspect close metadata and clear the active cashier through recovery tooling.", `SELECT p.id::text FROM pos_sessions p JOIN till_claims c ON c.session_id=p.id WHERE p.closed_at_ms IS NOT NULL AND c.active_employee_id IS NOT NULL`},
			{"recovery_required", "revoked_device_holds_session", "device", "Run controlled takeover for the active session.", `SELECT d.id::text FROM devices d JOIN till_claims c ON c.device_id=d.id JOIN pos_sessions p ON p.id=c.session_id WHERE d.revoked_at IS NOT NULL AND p.closed_at_ms IS NULL`},
			{"conflict", "cashier_has_multiple_claims", "employee", "Inspect the claims before allowing another handover.", `SELECT active_employee_id::text FROM till_claims WHERE active_employee_id IS NOT NULL GROUP BY active_employee_id HAVING count(*)>1`},
			{"conflict", "order_context_mismatch", "order", "Quarantine the order and inspect its device/register/session identity.", `SELECT o.id::text FROM orders o JOIN pos_sessions p ON p.id=o.pos_session_id WHERE o.device_id<>p.device_id OR o.pos_register_id<>p.pos_register_id OR o.outlet_id<>p.outlet_id`},
			{"recovery_required", "order_stock_effect_missing", "order", "Compare the immutable receipt payload with its stock ledger effects.", `SELECT o.id::text FROM orders o WHERE jsonb_typeof(o.payload->'stock_movements')='array' AND jsonb_array_length(o.payload->'stock_movements')<>(SELECT count(*) FROM stock_movements sm WHERE sm.ref_type='order' AND sm.ref_id=o.id)`},
			{"conflict", "sale_movement_without_order", "stock_movement", "Inspect the durable ingest payload; do not recreate stock automatically.", `SELECT sm.id::text FROM stock_movements sm WHERE sm.ref_type='order' AND (sm.ref_id IS NULL OR NOT EXISTS(SELECT 1 FROM order_dedupe od WHERE od.id=sm.ref_id))`},
			{"pending", "open_recovery", "till_recovery", "Review every pending item, then close the recovery explicitly.", `SELECT id::text FROM till_recoveries WHERE status='open'`},
		}
		for _, c := range checks {
			rows, err := tx.Query(ctx, c.query)
			if err != nil {
				return fmt.Errorf("diagnostic %s: %w", c.code, err)
			}
			for rows.Next() {
				var id string
				if err = rows.Scan(&id); err != nil {
					rows.Close()
					return err
				}
				out.Findings = append(out.Findings, DiagnosticFinding{c.classification, c.code, c.entity, id, c.action})
			}
			err = rows.Err()
			rows.Close()
			if err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		return out, err
	}
	for _, f := range out.Findings {
		if f.Classification == "recovery_required" {
			out.Status = "recovery_required"
			break
		}
		if f.Classification == "conflict" {
			out.Status = "conflict"
		} else if out.Status == "healthy" {
			out.Status = "pending"
		}
	}
	return out, nil
}
