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
	return nil
}
