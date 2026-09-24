package customer

// The push side: a till creating a customer at the counter. See the package
// doc and migrations/…_customers.sql for why this is insert-only rather than
// an ordinary revisioned write — there is no base-revision concept in the
// wire protocol for a till and the Backoffice to race over, so this entity
// simply never lets a till overwrite an existing row.

import (
	"context"
	"errors"
	"strings"

	"github.com/jackc/pgx/v5"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/validation"
)

// DeviceCustomer is a customer as a till pushes it (the Customer schema in
// openapi.yaml). The OpenAPI schema has already checked shape and length by
// the time this reaches CreateFromDevice — see ingest.go's conform — but the
// UUID format is re-checked here anyway, the same defensive posture
// stock.validateDevice takes for an id used directly as a primary key.
type DeviceCustomer struct {
	ID      string  `json:"id"`
	Name    string  `json:"name"`
	Phone   *string `json:"phone"`
	Email   *string `json:"email"`
	Address *string `json:"address"`
	Note    *string `json:"note"`
}

// Rejection is a customer push's refusal, mirroring stock.Rejection: a code
// ingest.go can act on, and a message the device may show.
type Rejection struct{ Code, Message string }

func (r *Rejection) Error() string { return r.Message }

func reject(code, message string) error { return &Rejection{Code: code, Message: message} }

// CreateFromDevice inserts a customer a till created. An id that already
// exists is left exactly as it is — not overwritten, not reported as an
// error — because a till pushes one fixed snapshot per customer it created
// and retries that same snapshot verbatim on ack loss; there is no
// legitimate case where a second push of the same id carries different
// content, so unlike stock's RecordFromDevice this needs no
// canonical-payload comparison to tell a genuine retry from a collision.
//
// The existence check runs before Seq is called, not after: numbering a
// no-op retry would wake every other till in the company to pull a row that
// was never going to be there — the same "only a real difference gets a
// sequence number" rule every other writer in this codebase already keeps.
func (s *Service) CreateFromDevice(ctx context.Context, w *syncfeed.Writer, tenantID string, in DeviceCustomer) error {
	in.ID = strings.ToLower(in.ID)
	if !validation.UUID(in.ID) {
		return reject("schema_rejected", "Customer identifier must be a UUID.")
	}
	name := strings.TrimSpace(in.Name)
	if name == "" {
		return reject("schema_rejected", "Customer name is required.")
	}

	var exists bool
	err := w.Tx.QueryRow(ctx, `SELECT true FROM customers WHERE tenant_id = $1 AND id = $2`,
		tenantID, in.ID).Scan(&exists)
	switch {
	case errors.Is(err, pgx.ErrNoRows):
		// falls through to insert
	case err != nil:
		return err
	case exists:
		return nil
	}

	var phoneNorm, emailNorm *string
	if in.Phone != nil {
		phoneNorm = normalizePhone(*in.Phone)
	}
	if in.Email != nil {
		emailNorm = normalizeEmail(*in.Email)
	}

	seq, err := w.Seq(ctx, "customers")
	if err != nil {
		return err
	}

	var inserted bool
	err = w.Tx.QueryRow(ctx, `
		INSERT INTO customers
			(id, tenant_id, name, phone, email, address, note, phone_norm, email_norm, active, sync_seq)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, true, $10)
		ON CONFLICT (id) DO NOTHING
		RETURNING true`,
		in.ID, tenantID, name, in.Phone, in.Email, in.Address, in.Note, phoneNorm, emailNorm, seq).Scan(&inserted)
	if errors.Is(err, pgx.ErrNoRows) {
		// The tenant-scoped lookup above already proved this is not an exact
		// retry. The only remaining primary-key collision belongs to another
		// tenant and must never be reported as accepted.
		return reject("schema_rejected", "Customer identifier is already in use.")
	}
	return err
}
