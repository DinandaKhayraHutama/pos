package ingest

import (
	"context"
	"encoding/json"
	"errors"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/customer"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/devices"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/httpapi/wire"
)

// ingestCustomer accepts the create-only customer snapshot published by a
// till. It runs inside the feed writer transaction so the row and its sync
// sequence become visible atomically to every other till.
func (s *Service) ingestCustomer(ctx context.Context, w *syncfeed.Writer, b devices.Binding, raw json.RawMessage, _ *wire.PushResult) error {
	if err := s.conform("customers", raw); err != nil {
		return err
	}
	var in customer.DeviceCustomer
	if err := json.Unmarshal(raw, &in); err != nil {
		return reject("schema_rejected", "Invalid customer values.")
	}
	if err := s.customers.CreateFromDevice(ctx, w, b.Tenant.ID, in); err != nil {
		var refused *customer.Rejection
		if errors.As(err, &refused) {
			return reject(refused.Code, refused.Message)
		}
		return err
	}
	return nil
}
