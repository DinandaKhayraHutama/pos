package customer

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"

	"github.com/jackc/pgx/v5"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/reporting"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/validation"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
)

var CustomerColumns = []string{"id", "name", "phone", "email", "address", "note", "active"}

type ImportRow struct {
	Line   int
	Fields map[string]string
}
type ImportError struct {
	Line    int
	Message string
}
type ImportErrors []ImportError

func (e ImportErrors) Error() string { return "customer import contains invalid rows" }

type ImportResult struct{ Created, Updated, Unchanged int }

func (s *Service) ExportCSV(ctx context.Context, tenantID, actorID string) ([]byte, error) {
	var rows []Customer
	err := pg.InTenantTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		r, err := tx.Query(ctx, `SELECT id,name,phone,email,address,note,active FROM customers WHERE tenant_id=$1 AND deleted_at IS NULL ORDER BY name,id`, tenantID)
		if err != nil {
			return err
		}
		rows, err = pgx.CollectRows(r, func(row pgx.CollectableRow) (Customer, error) {
			var c Customer
			err := row.Scan(&c.ID, &c.Name, &c.Phone, &c.Email, &c.Address, &c.Note, &c.Active)
			return c, err
		})
		if err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `INSERT INTO customer_export_events(tenant_id,actor_id,row_count) VALUES($1,$2,$3)`, tenantID, actorID, len(rows))
		return err
	})
	if err != nil {
		return nil, err
	}
	t := reporting.Table{Header: CustomerColumns}
	for _, c := range rows {
		t.Rows = append(t.Rows, []reporting.Cell{reporting.TextCell(c.ID), reporting.TextCell(c.Name), reporting.TextCell(derefOr(c.Phone)), reporting.TextCell(derefOr(c.Email)), reporting.TextCell(derefOr(c.Address)), reporting.TextCell(derefOr(c.Note)), reporting.TextCell(map[bool]string{true: "ya", false: "tidak"}[c.Active])})
	}
	return reporting.RenderFlatCSV(t)
}

func (s *Service) Import(ctx context.Context, tenantID string, rows []ImportRow, commit bool) (ImportResult, error) {
	var result ImportResult
	var problems ImportErrors
	run := func(ctx context.Context, w *syncfeed.Writer) error {
		if _, err := w.Tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext($1)::bigint)`, "customers:"+tenantID); err != nil {
			return err
		}
		for _, r := range rows {
			id, name := strings.TrimSpace(r.Fields["id"]), strings.TrimSpace(r.Fields["name"])
			if name == "" {
				problems = append(problems, ImportError{r.Line, "name wajib diisi."})
				continue
			}
			if id != "" && !validation.UUID(id) {
				problems = append(problems, ImportError{r.Line, "id bukan UUID yang sah."})
				continue
			}
			var current Customer
			err := w.Tx.QueryRow(ctx, `SELECT id,name,phone,email,address,note,active FROM customers WHERE tenant_id=$1 AND id=NULLIF($2,'')::uuid AND deleted_at IS NULL FOR UPDATE`, tenantID, id).Scan(&current.ID, &current.Name, &current.Phone, &current.Email, &current.Address, &current.Note, &current.Active)
			if id != "" && errors.Is(err, pgx.ErrNoRows) {
				problems = append(problems, ImportError{r.Line, "id tidak dikenal; pelanggan ini tidak ada."})
				continue
			}
			if err != nil && !errors.Is(err, pgx.ErrNoRows) {
				return err
			}
			phone, email, address, note := validation.Trimmed(r.Fields["phone"]), validation.Trimmed(r.Fields["email"]), validation.Trimmed(r.Fields["address"]), validation.Trimmed(r.Fields["note"])
			active := strings.ToLower(strings.TrimSpace(r.Fields["active"])) != "tidak"
			in := Customer{ID: id, Name: name, Phone: phone, Email: email, Address: address, Note: note, Active: active}
			if err := validateCustomer(in); err != nil {
				problems = append(problems, ImportError{r.Line, err.Error()})
				continue
			}
			if current.ID != "" && current.Name == in.Name && derefOr(current.Phone) == derefOr(in.Phone) && derefOr(current.Email) == derefOr(in.Email) && derefOr(current.Address) == derefOr(in.Address) && derefOr(current.Note) == derefOr(in.Note) && current.Active == active {
				result.Unchanged++
				continue
			}
			seq, err := w.Seq(ctx, "customers")
			if err != nil {
				return err
			}
			_, err = w.Tx.Exec(ctx, `INSERT INTO customers(id,tenant_id,name,phone,email,address,note,phone_norm,email_norm,active,sync_seq) VALUES(COALESCE(NULLIF($1,'')::uuid,gen_random_uuid()),$2,$3,$4,$5,$6,$7,$8,$9,$10,$11) ON CONFLICT(id) DO UPDATE SET name=EXCLUDED.name,phone=EXCLUDED.phone,email=EXCLUDED.email,address=EXCLUDED.address,note=EXCLUDED.note,phone_norm=EXCLUDED.phone_norm,email_norm=EXCLUDED.email_norm,active=EXCLUDED.active,sync_seq=EXCLUDED.sync_seq,updated_at=now()`, id, tenantID, name, phone, email, address, note, normalizePhone(derefOr(phone)), normalizeEmail(derefOr(email)), active, seq)
			if err != nil {
				return err
			}
			if current.ID == "" {
				result.Created++
			} else {
				result.Updated++
			}
		}
		sort.SliceStable(problems, func(i, j int) bool { return problems[i].Line < problems[j].Line })
		if len(problems) > 0 {
			return problems
		}
		if !commit {
			return fmt.Errorf("preview rollback")
		}
		return nil
	}
	err := s.feed.Write(ctx, tenantID, run)
	if !commit && err != nil && err.Error() == "preview rollback" {
		return result, nil
	}
	return result, err
}
