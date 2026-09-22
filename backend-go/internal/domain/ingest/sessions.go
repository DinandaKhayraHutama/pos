package ingest

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/devices"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/httpapi/wire"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/store"
	"github.com/jackc/pgx/v5"
)

func ingestSession(ctx context.Context, tx pgx.Tx, b devices.Binding, in wire.Session, result *wire.PushResult) error {
	q := store.New(tx)
	old, err := q.GetSessionForUpdate(ctx, in.Id)
	inserted := false
	if errors.Is(err, pgx.ErrNoRows) {
		var coordinated bool
		if err := tx.QueryRow(ctx, "SELECT coordinated_sessions FROM pos_registers WHERE id=$1 FOR SHARE", b.Register.ID).Scan(&coordinated); err != nil {
			return err
		}
		if coordinated {
			return reject("register_busy", "Open this session online before selling; legacy sessions require recovery.")
		}
		n, err := q.InsertSession(ctx, store.InsertSessionParams{TenantID: b.Tenant.ID, OutletID: b.Outlet.ID, PosRegisterID: b.Register.ID, DeviceID: b.Device.ID, Column5: encode(in)})
		if err != nil {
			return err
		}
		if n == 1 {
			inserted = true
			result.Inserted = &inserted
			return nil
		}
		// A concurrent insert committed after our first snapshot. A fresh
		// statement now sees it; a CTE single-snapshot read would not.
		old, err = q.GetSessionForUpdate(ctx, in.Id)
		if errors.Is(err, pgx.ErrNoRows) {
			return reject("duplicate", "Session identifier is unavailable.")
		}
	}
	if err != nil {
		return err
	}
	if old.DeviceID != b.Device.ID || old.PosRegisterID != b.Register.ID {
		return reject("duplicate", "Session belongs to a different device.")
	}
	var claimed bool
	if err := tx.QueryRow(ctx, "SELECT EXISTS(SELECT 1 FROM till_claims WHERE session_id=$1)", in.Id).Scan(&claimed); err != nil {
		return err
	}
	if claimed && in.ClosedAtMs != nil && !old.ClosedAtMs.Valid {
		if in.OrderCount == nil {
			return retry("dependency_pending", "Closing requires the acknowledged order count.")
		}
		var count int64
		if err := tx.QueryRow(ctx, "SELECT count(*) FROM orders WHERE pos_session_id=$1", in.Id).Scan(&count); err != nil {
			return err
		}
		if count != *in.OrderCount {
			return retry("dependency_pending", "Upload every receipt before closing this drawer.")
		}
	}
	var previous wire.Session
	if err := json.Unmarshal(old.Payload, &previous); err != nil {
		return err
	}
	result.Inserted = &inserted
	if in.Revision == old.Revision && bytes.Equal(encode(in), encode(previous)) {
		return nil
	}
	if old.ClosedAtMs.Valid {
		return reject("session_closed", "A closed session cannot be changed.")
	}
	if in.Revision < old.Revision {
		return reject("stale_revision", "A newer session revision is already stored.")
	}
	if in.Revision == old.Revision {
		return reject("duplicate", "This revision already names different data.")
	}
	if !bytes.Equal(immutableSession(in), immutableSession(previous)) {
		return reject("schema_rejected", "Opening snapshot is immutable.")
	}
	n, err := q.UpdateOpenSession(ctx, store.UpdateOpenSessionParams{ID: in.Id, Column2: encode(in)})
	if err != nil {
		return err
	}
	if n != 1 {
		return retry("server_unavailable", "Session changed concurrently; retry.")
	}
	if claimed && in.ClosedAtMs != nil {
		_, err = tx.Exec(ctx, "UPDATE till_claims SET active_employee_id=NULL WHERE session_id=$1", in.Id)
		if err != nil {
			return err
		}
	}
	return nil
}
