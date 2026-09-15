package ingest

import (
	"context"
	"sync/atomic"
	"testing"
	"time"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/httpapi/wire"
	"github.com/stretchr/testify/require"
)

func (f *fixture) diningTable(t *testing.T) string {
	t.Helper()
	ctx := context.Background()
	var id string
	require.NoError(t, f.db.Owner.QueryRow(ctx,
		"INSERT INTO tables (tenant_id, outlet_id, name) VALUES ($1, $2, 'Meja 1') RETURNING id::text",
		f.binding.Tenant.ID, f.binding.Outlet.ID).Scan(&id))
	_, err := f.db.Owner.Exec(ctx,
		"INSERT INTO table_status (tenant_id, table_id, outlet_id, sync_seq) VALUES ($1, $2, $3, 1)",
		f.binding.Tenant.ID, id, f.binding.Outlet.ID)
	require.NoError(t, err)
	return id
}

var tableClientSequence atomic.Int64

func (f *fixture) statusEvent(t *testing.T, table, status string, basis int64) map[string]any {
	return map[string]any{
		"id": f.id(t), "revision": 1, "table_id": table, "status": status, "basis_seq": basis,
		"client_seq":     tableClientSequence.Add(1),
		"occurred_at_ms": time.Now().UnixMilli(), "employee_name": "Sari",
	}
}

// Table status events ride the same push contract as money and stock: logged
// before domain processing, one result per row, an exact retry accepted
// without a second event, and a bad row refused without failing its
// neighbours.
func TestTableStatusEventsPushThroughTheSameContract(t *testing.T) {
	f := setup(t)
	table := f.diningTable(t)

	seated := f.statusEvent(t, table, "occupied", 1)
	var first int64
	for attempt := 0; attempt < 3; attempt++ {
		rows := f.push("table_status_events", seated)
		accepted(t, rows)
		require.NotNil(t, rows[0].StatusSeq)
		require.NotNil(t, rows[0].Outcome)
		require.Equal(t, "applied", string(*rows[0].Outcome))
		require.Equal(t, attempt == 0, *rows[0].Inserted)
		if attempt == 0 {
			first = *rows[0].StatusSeq
		}
		require.Equal(t, first, *rows[0].StatusSeq)
	}
	require.EqualValues(t, 1, f.count(t, "table_status_events"))
	require.EqualValues(t, 3, f.count(t, "ingest_log"))

	// Identity comes from the token: an outlet in the row is not in the schema.
	withOutlet := f.statusEvent(t, table, "available", first)
	withOutlet["outlet_id"] = f.binding.Outlet.ID
	unknownStatus := f.statusEvent(t, table, "dirty", first)
	foreignTable := f.statusEvent(t, f.id(t), "available", first)
	cleared := f.statusEvent(t, table, "available", first)

	rows := f.push("table_status_events", withOutlet, unknownStatus, foreignTable, cleared)
	require.Len(t, rows, 4)
	for _, row := range rows[:3] {
		require.Equal(t, wire.PushResultStatus("rejected"), row.Status)
		require.Equal(t, wire.PushResultCode("schema_rejected"), *row.Code)
		require.Nil(t, row.StatusSeq)
		require.Nil(t, row.Outcome)
	}
	require.Equal(t, wire.PushResultStatus("accepted"), rows[3].Status)
	require.Greater(t, *rows[3].StatusSeq, first)

	var status string
	require.NoError(t, f.db.Owner.QueryRow(context.Background(),
		"SELECT status FROM table_status WHERE table_id = $1", table).Scan(&status))
	require.Equal(t, "available", status)
}
