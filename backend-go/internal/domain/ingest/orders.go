package ingest

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/devices"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/httpapi/wire"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/jobs"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/store"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
)

func (s *Service) ingestOrder(ctx context.Context, tx pgx.Tx, b devices.Binding, in wire.Order, result *wire.PushResult) error {
	q := store.New(tx)
	day, _ := time.Parse(time.DateOnly, in.BusinessDate) // validated before entering
	date := pgtype.Date{Time: day, Valid: true}
	n, err := q.ReserveOrderID(ctx, store.ReserveOrderIDParams{ID: in.Id, TenantID: b.Tenant.ID, OutletID: b.Outlet.ID, PosRegisterID: b.Register.ID, DeviceID: b.Device.ID, BusinessDate: date})
	if err != nil {
		return err
	}
	reservation, err := q.GetOrderReservation(ctx, in.Id)
	if errors.Is(err, pgx.ErrNoRows) {
		return reject("duplicate", "Order identifier is unavailable.")
	}
	if err != nil {
		return err
	}
	if reservation.DeviceID != b.Device.ID || reservation.PosRegisterID != b.Register.ID {
		return reject("duplicate", "Order belongs to a different device.")
	}
	date = reservation.BusinessDate
	in.BusinessDate = date.Time.Format(time.DateOnly)
	result.BusinessDate = &in.BusinessDate
	inserted := n == 1
	result.Inserted = &inserted
	if !inserted {
		old, err := q.GetOrder(ctx, store.GetOrderParams{BusinessDate: date, ID: in.Id})
		if errors.Is(err, pgx.ErrNoRows) {
			return reject("archived", "Order is archived; it cannot be inserted again.")
		}
		if err != nil {
			return err
		}
		var previous wire.Order
		if err := json.Unmarshal(old.Payload, &previous); err != nil {
			return err
		}
		if in.Revision == old.Revision && bytes.Equal(encode(in), encode(previous)) {
			return nil
		}
		if old.SettledAt.Valid {
			return reject("settled", "A settled order cannot be changed.")
		}
		if in.Revision < old.Revision {
			return reject("stale_revision", "A newer order revision is already stored.")
		}
		if in.Revision == old.Revision {
			return reject("duplicate", "This revision already names different data.")
		}
		if !bytes.Equal(immutableOrder(in), immutableOrder(previous)) {
			return reject("schema_rejected", "The original receipt amounts and lines are immutable.")
		}
		// Kitchen statuses are not payment progression. Revision orders their
		// updates; only cancelled/refunded are irreversible business states.
		n, err := q.UpdateUnsettledOrder(ctx, store.UpdateUnsettledOrderParams{BusinessDate: date, ID: in.Id, Column3: encode(in)})
		if err != nil {
			return err
		}
		if n != 1 {
			return retry("server_unavailable", "Order changed concurrently; retry.")
		}
	} else {
		// Closed sessions still accept late offline sales. Identity, not the
		// current drawer status, decides which session a receipt belongs to.
		var registerID string
		err := tx.QueryRow(ctx, "SELECT pos_register_id::text FROM pos_sessions WHERE id=$1", in.PosSessionId).Scan(&registerID)
		if errors.Is(err, pgx.ErrNoRows) {
			return retry("dependency_pending", "Push the session before this order.")
		}
		if err != nil {
			return err
		}
		if registerID != b.Register.ID {
			return reject("schema_rejected", "Session belongs to another register.")
		}
		if err := q.InsertOrder(ctx, store.InsertOrderParams{BusinessDate: date, TenantID: b.Tenant.ID, OutletID: b.Outlet.ID, PosRegisterID: b.Register.ID, DeviceID: b.Device.ID, Column6: encode(in)}); err != nil {
			return err
		}
		items := encode(in.Items)
		if err := q.InsertOrderItems(ctx, store.InsertOrderItemsParams{BusinessDate: date, TenantID: b.Tenant.ID, OrderID: in.Id, Column4: items}); err != nil {
			return err
		}
		if err := q.InsertOrderModifiers(ctx, store.InsertOrderModifiersParams{BusinessDate: date, TenantID: b.Tenant.ID, Column3: items}); err != nil {
			return err
		}
	}
	if err := q.MarkReportDirty(ctx, store.MarkReportDirtyParams{TenantID: b.Tenant.ID, OutletID: b.Outlet.ID, BusinessDate: date}); err != nil {
		return err
	}
	return jobs.EnqueueReport(ctx, tx, s.queue, jobs.ReportSlice{TenantID: b.Tenant.ID, OutletID: b.Outlet.ID, BusinessDate: in.BusinessDate})
}
