// Package ingest accepts device-owned snapshots, never client-chosen identity.
// The received payload commits first. Each domain row then commits separately;
// no rejection, malformed response, or uncertain commit authorizes data loss.
package ingest

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"time"

	"github.com/daniryckidinata/nti_pos/backend-go/api"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/devices"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/stock"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/tables"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/httpapi/wire"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/jobs"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/store"
	"github.com/getkin/kin-openapi/openapi3"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/riverqueue/river"
)

type Service struct {
	pools   pg.Pools
	logger  *slog.Logger
	schemas map[string]*openapi3.SchemaRef
	queue   *river.Client[pgx.Tx]
	feed    *syncfeed.Service
	stock   *stock.Service
	tables  *tables.Service
}

// NewService needs the sync feed because stock movements and table status
// events number the outlet feeds tills pull: their rows are numbered inside
// their own transaction and announced after it commits, through the same
// service the API reads.
func NewService(pools pg.Pools, feed *syncfeed.Service, logger *slog.Logger) (*Service, error) {
	if feed == nil {
		return nil, errors.New("ingest: a sync feed is required to publish device-written feeds")
	}
	doc, err := openapi3.NewLoader().LoadFromData(api.Specification)
	if err != nil {
		return nil, err
	}
	queue, err := jobs.NewInserter(pools.Tenant, logger)
	if err != nil {
		return nil, err
	}
	return &Service{
		pools: pools, logger: logger, queue: queue, feed: feed,
		stock:  stock.NewService(pools, feed),
		tables: tables.NewService(pools, feed),
		schemas: map[string]*openapi3.SchemaRef{
			"pos_sessions":     doc.Components.Schemas["Session"],
			"orders":           doc.Components.Schemas["Order"],
			stock.Entity:       doc.Components.Schemas["StockMovement"],
			tables.EventEntity: doc.Components.Schemas["TableStatusEvent"],
		},
	}, nil
}

type rejection struct {
	code, message string
	retry         bool
}

func (r *rejection) Error() string      { return r.message }
func reject(code, message string) error { return &rejection{code: code, message: message} }
func retry(code, message string) error  { return &rejection{code: code, message: message, retry: true} }

func (s *Service) Push(ctx context.Context, binding devices.Binding, req wire.PushRequest) wire.PushResponse {
	out := wire.PushResponse{Results: []wire.PushResult{}, ServerTimeMs: time.Now().UnixMilli()}
	for bi, batch := range req.Batches {
		for ri, raw := range batch.Rows {
			result := wire.PushResult{BatchIndex: bi, RowIndex: ri, Entity: batch.Entity, Status: "retry"}
			// Correlation does not depend on an invalid/missing row id. Only
			// validated identifiers and revisions are echoed to the device.
			var identity struct {
				Id       string `json:"id"`
				Revision int64  `json:"revision"`
			}
			if json.Unmarshal(raw, &identity) == nil {
				if validUUID(identity.Id) {
					result.Id = &identity.Id
				}
				if identity.Revision > 0 {
					result.Revision = &identity.Revision
				}
			}
			err := pg.InTenantTx(ctx, s.pools.Tenant, binding.Tenant.ID, func(ctx context.Context, tx pgx.Tx) error {
				return store.New(tx).AppendIngestLog(ctx, store.AppendIngestLogParams{
					TenantID: binding.Tenant.ID, DeviceID: binding.Device.ID, Entity: batch.Entity, Payload: raw,
				})
			})
			if err != nil {
				s.logger.Error("ingest audit unavailable", "tenant_id", binding.Tenant.ID, "device_id", binding.Device.ID, "error", err)
				err = retry("server_unavailable", "The received row could not be durably logged; keep it and retry.")
			}
			if err == nil {
				err = s.domain(ctx, binding, batch.Entity, raw, &result)
			}
			if err == nil {
				result.Status = "accepted"
			} else {
				s.failure(ctx, binding, err, &result)
			}
			out.Results = append(out.Results, result)
		}
	}
	return out
}

// domain runs one row in its own transaction. A blocked till cannot hold the
// rest of the batch forever, so every row carries short lock and statement
// timeouts; hitting one is a retry, never a rejection.
func (s *Service) domain(ctx context.Context, b devices.Binding, entity string, raw json.RawMessage, result *wire.PushResult) error {
	guard := func(ctx context.Context, tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, "SET LOCAL lock_timeout = '2s'"); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, "SET LOCAL statement_timeout = '5s'")
		return err
	}

	if entity == stock.Entity || entity == tables.EventEntity {
		// Numbered inside this transaction, announced after it commits.
		return s.feed.Write(ctx, b.Tenant.ID, func(ctx context.Context, w *syncfeed.Writer) error {
			if err := guard(ctx, w.Tx); err != nil {
				return err
			}
			if entity == tables.EventEntity {
				return s.ingestTableStatus(ctx, w, b, raw, result)
			}
			return s.ingestStock(ctx, w, b, raw, result)
		})
	}

	return pg.InTenantTx(ctx, s.pools.Tenant, b.Tenant.ID, func(ctx context.Context, tx pgx.Tx) error {
		if err := guard(ctx, tx); err != nil {
			return err
		}
		return s.ingestRow(ctx, tx, b, entity, raw, result)
	})
}

// conform checks a raw row against the frozen schema for its entity.
func (s *Service) conform(entity string, raw json.RawMessage) error {
	schema, ok := s.schemas[entity]
	if !ok {
		return reject("unknown_entity", "This entity is not device-writable.")
	}
	var value any
	if err := json.Unmarshal(raw, &value); err != nil {
		return reject("schema_rejected", "Row is not valid JSON.")
	}
	if err := schema.Value.VisitJSON(value); err != nil {
		return reject("schema_rejected", "Row does not match the declared schema.")
	}
	return nil
}

func (s *Service) ingestRow(ctx context.Context, tx pgx.Tx, b devices.Binding, entity string, raw json.RawMessage, result *wire.PushResult) error {
	if err := s.conform(entity, raw); err != nil {
		return err
	}
	switch entity {
	case "pos_sessions":
		var in wire.Session
		if json.Unmarshal(raw, &in) != nil {
			return reject("schema_rejected", "Invalid session values.")
		}
		in.Id = strings.ToLower(in.Id)
		if err := validateSession(in); err != nil {
			return err
		}
		return ingestSession(ctx, tx, b, in, result)
	case "orders":
		var in wire.Order
		if json.Unmarshal(raw, &in) != nil {
			return reject("schema_rejected", "Invalid order values.")
		}
		in.Id, in.PosSessionId = strings.ToLower(in.Id), strings.ToLower(in.PosSessionId)
		if err := validateOrder(in); err != nil {
			return err
		}
		return s.ingestOrder(ctx, tx, b, in, result)
	}
	return fmt.Errorf("unhandled entity %q", entity)
}

// ingestStock applies one pushed ledger movement at the device's bound outlet.
// The result carries the projection sequence it was applied at, which is what
// lets the till stop counting its own movement once its snapshot includes it.
func (s *Service) ingestStock(ctx context.Context, w *syncfeed.Writer, b devices.Binding, raw json.RawMessage, result *wire.PushResult) error {
	if err := s.conform(stock.Entity, raw); err != nil {
		return err
	}
	var in stock.DeviceMovement
	if json.Unmarshal(raw, &in) != nil {
		return reject("schema_rejected", "Invalid stock movement values.")
	}
	applied, err := s.stock.RecordFromDevice(ctx, w, b, in)
	var refused *stock.Rejection
	if errors.As(err, &refused) {
		return reject(refused.Code, refused.Message)
	}
	if err != nil {
		return err
	}
	inserted, stockSeq, balance := applied.Inserted, applied.StockSeq, applied.BalanceAfter
	result.Inserted, result.StockSeq, result.BalanceAfter = &inserted, &stockSeq, &balance
	return nil
}

// ingestTableStatus applies one pushed table status change at the device's
// bound outlet. The result carries the status sequence it was recorded at and
// whether the projection took it, which is how the till stops showing its own
// change once its snapshot reflects it — or stops showing one that lost.
func (s *Service) ingestTableStatus(ctx context.Context, w *syncfeed.Writer, b devices.Binding, raw json.RawMessage, result *wire.PushResult) error {
	if err := s.conform(tables.EventEntity, raw); err != nil {
		return err
	}
	var in tables.DeviceEvent
	if json.Unmarshal(raw, &in) != nil {
		return reject("schema_rejected", "Invalid table status values.")
	}
	applied, err := s.tables.RecordFromDevice(ctx, w, b, in)
	var refused *tables.Rejection
	if errors.As(err, &refused) {
		return reject(refused.Code, refused.Message)
	}
	if err != nil {
		return err
	}
	inserted, statusSeq, outcome := applied.Inserted, applied.StatusSeq, wire.PushResultOutcome(applied.Outcome)
	result.Inserted, result.StatusSeq, result.Outcome = &inserted, &statusSeq, &outcome
	return nil
}

func (s *Service) failure(ctx context.Context, b devices.Binding, err error, result *wire.PushResult) {
	var reason *rejection
	var dbErr *pgconn.PgError
	if !errors.As(err, &reason) {
		if errors.As(err, &dbErr) {
			switch dbErr.Code {
			case "23505":
				if dbErr.ConstraintName == "pos_sessions_one_open_register" {
					reason = &rejection{code: "register_busy", message: "Another session holds this register."}
					_ = pg.InTenantReadTx(ctx, s.pools.Tenant, b.Tenant.ID, func(ctx context.Context, tx pgx.Tx) error {
						holder, e := store.New(tx).OpenSessionHolder(ctx, b.Register.ID)
						if e == nil {
							result.HolderSessionId = &holder.ID
							result.HolderEmployeeName = &holder.EmployeeName
						}
						return e
					})
				} else {
					reason = &rejection{code: "duplicate", message: "An identifier is already reserved for different data."}
				}
			case "23503", "23514", "22P02", "22003", "22008":
				reason = &rejection{code: "schema_rejected", message: "Row violates identity or data constraints."}
			}
		}
		if reason == nil {
			reason = &rejection{code: "server_unavailable", message: "Keep the row and retry.", retry: true}
			s.logger.Error("ingest unavailable", "tenant_id", b.Tenant.ID, "outlet_id", b.Outlet.ID, "device_id", b.Device.ID, "entity", result.Entity, "error", err)
		}
	}
	result.Status = "rejected"
	if reason.retry {
		result.Status = "retry"
	}
	code := wire.PushResultCode(reason.code)
	result.Code, result.Message = &code, &reason.message
	// Rolled back or commit outcome unknown: nothing about the write is echoed.
	result.Inserted, result.StockSeq, result.BalanceAfter = nil, nil, nil
	result.StatusSeq, result.Outcome = nil, nil
}
