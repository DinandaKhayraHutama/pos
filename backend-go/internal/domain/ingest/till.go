package ingest

// Online coordination is deliberately separate from offline financial ingest.
// A till remains reserved during a network outage; there is no heartbeat expiry.
import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"time"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/devices"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/httpapi/wire"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"golang.org/x/crypto/bcrypt"
)

type TillError struct{ Code string }

func (e *TillError) Error() string { return e.Code }
func tillError(code string) error  { return &TillError{Code: code} }

type TillAccess struct {
	Token       string `json:"token"`
	ExpiresAtMs int64  `json:"expires_at_ms"`
}

// Login runs after the HTTP per-device AND per-employee PIN limiter.
func (s *Service) TillLogin(ctx context.Context, b devices.Binding, employee, pin string) (TillAccess, error) {
	var out TillAccess
	if !validUUID(employee) || len(pin) != 4 {
		return out, tillError("invalid_pin")
	}
	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		return out, err
	}
	out.Token = hex.EncodeToString(secret)
	out.ExpiresAtMs = time.Now().Add(24 * time.Hour).UnixMilli()
	digest := sha256.Sum256([]byte(out.Token))
	err := pg.InTenantTx(ctx, s.pools.Tenant, b.Tenant.ID, func(ctx context.Context, tx pgx.Tx) error {
		var hash string
		err := tx.QueryRow(ctx, `SELECT pin_hash FROM employees WHERE id=$1 AND active AND deleted_at IS NULL`, employee).Scan(&hash)
		if errors.Is(err, pgx.ErrNoRows) {
			return tillError("invalid_pin")
		}
		if err != nil {
			return err
		}
		if bcrypt.CompareHashAndPassword([]byte(hash), []byte(pin)) != nil {
			return tillError("invalid_pin")
		}
		_, err = tx.Exec(ctx, `INSERT INTO till_access(token_hash,tenant_id,device_id,employee_id,pin_hash,expires_at) VALUES($1,$2,$3,$4,$5,to_timestamp($6::double precision/1000))`, digest[:], b.Tenant.ID, b.Device.ID, employee, hash, out.ExpiresAtMs)
		return err
	})
	return out, err
}

type tillActor struct{ ID, Name, Role string }

// TillActor is who a cashier token names, for callers outside this package.
type TillActor struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Role string `json:"role"`
}

// WhoIsAtTheTill resolves a cashier token to the employee behind it.
//
// It exists so other surfaces — the report endpoints, say — can ask for the
// SAME identity the sale path uses, rather than trusting an employee id in a
// query string. Every check the token carries still applies: expiry, the
// device it was minted on, the account still being active, and the PIN hash it
// was minted against, so changing a PIN revokes it.
func (s *Service) WhoIsAtTheTill(ctx context.Context, b devices.Binding, token string) (TillActor, error) {
	var out TillActor
	err := pg.InTenantReadTx(ctx, s.pools.Tenant, b.Tenant.ID, func(ctx context.Context, tx pgx.Tx) error {
		a, err := tillEmployee(ctx, tx, b, token)
		out = TillActor{ID: a.ID, Name: a.Name, Role: a.Role}
		return err
	})
	return out, err
}

func tillEmployee(ctx context.Context, tx pgx.Tx, b devices.Binding, token string) (tillActor, error) {
	var a tillActor
	h := sha256.Sum256([]byte(token))
	err := tx.QueryRow(ctx, `SELECT e.id::text,e.name,e.role FROM till_access a JOIN employees e ON e.tenant_id=a.tenant_id AND e.id=a.employee_id WHERE a.token_hash=$1 AND a.device_id=$2 AND a.expires_at>now() AND e.active AND e.deleted_at IS NULL AND e.pin_hash=a.pin_hash`, h[:], b.Device.ID).Scan(&a.ID, &a.Name, &a.Role)
	if errors.Is(err, pgx.ErrNoRows) {
		return a, tillError("cashier_auth_required")
	}
	return a, err
}

type TillSession struct {
	Session           wire.Session `json:"session"`
	ReceiptStart      int64        `json:"receipt_start"`
	ReceiptEnd        int64        `json:"receipt_end"`
	CurrentEmployeeID *string      `json:"current_employee_id"`
}

func readTillSession(ctx context.Context, tx pgx.Tx, b devices.Binding, id string) (TillSession, error) {
	var out TillSession
	var payload []byte
	err := tx.QueryRow(ctx, `SELECT p.payload,c.receipt_start,c.receipt_end,c.active_employee_id::text FROM pos_sessions p JOIN till_claims c ON c.session_id=p.id AND c.tenant_id=p.tenant_id WHERE p.id=$1 AND p.device_id=$2 AND p.pos_register_id=$3`, id, b.Device.ID, b.Register.ID).Scan(&payload, &out.ReceiptStart, &out.ReceiptEnd, &out.CurrentEmployeeID)
	if err != nil {
		return out, err
	}
	err = json.Unmarshal(payload, &out.Session)
	return out, err
}

// Open uses a client-generated, durably stored session ID as its idempotency key.
// Claiming a busy till commits no local financial snapshot and changes no owner.
func (s *Service) OpenTill(ctx context.Context, b devices.Binding, token string, in wire.Session) (TillSession, error) {
	var out TillSession
	if !validUUID(in.Id) || in.Revision != 1 || in.ClosedAtMs != nil || in.OpeningCash < 0 || in.OpenedAtMs < 0 || in.OpenedAtMs > maxMillis {
		return out, tillError("invalid_session")
	}
	err := pg.InTenantTx(ctx, s.pools.Tenant, b.Tenant.ID, func(ctx context.Context, tx pgx.Tx) error {
		a, err := tillEmployee(ctx, tx, b, token)
		if err != nil {
			return err
		}
		if a.Role != "cashier" {
			return tillError("cashier_required")
		}
		if in.EmployeeId == nil || *in.EmployeeId != a.ID {
			return tillError("cashier_required")
		}
		// Same lock order for open/handover/close: register then session/claim.
		if _, err = tx.Exec(ctx, `SELECT id FROM pos_registers WHERE id=$1 FOR UPDATE`, b.Register.ID); err != nil {
			return err
		}
		old, e := readTillSession(ctx, tx, b, in.Id)
		if e == nil {
			if old.Session.EmployeeId == nil || *old.Session.EmployeeId != a.ID || old.Session.OpeningCash != in.OpeningCash || old.Session.OpenedAtMs != in.OpenedAtMs {
				return tillError("idempotency_conflict")
			}
			out = old
			return nil
		}
		if !errors.Is(e, pgx.ErrNoRows) {
			return e
		}
		var busy bool
		if err = tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM pos_sessions WHERE pos_register_id=$1 AND closed_at_ms IS NULL)`, b.Register.ID).Scan(&busy); err != nil {
			return err
		}
		if busy {
			return tillError("register_busy")
		}
		in.EmployeeName = a.Name
		payload := encode(in)
		_, err = tx.Exec(ctx, `INSERT INTO pos_sessions(id,tenant_id,outlet_id,pos_register_id,device_id,revision,employee_name,opened_at_ms,opening_cash,payload) VALUES($1,$2,$3,$4,$5,1,$6,$7,$8,$9)`, in.Id, b.Tenant.ID, b.Outlet.ID, b.Register.ID, b.Device.ID, a.Name, in.OpenedAtMs, in.OpeningCash, payload)
		if err != nil {
			return err
		}
		var end int64
		err = tx.QueryRow(ctx, `UPDATE pos_registers SET coordinated_sessions=true,receipt_counter=receipt_counter+100000 WHERE id=$1 RETURNING receipt_counter`, b.Register.ID).Scan(&end)
		if err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `INSERT INTO till_claims(session_id,tenant_id,outlet_id,register_id,device_id,active_employee_id,receipt_start,receipt_end) VALUES($1,$2,$3,$4,$5,$6,$7,$8)`, in.Id, b.Tenant.ID, b.Outlet.ID, b.Register.ID, b.Device.ID, a.ID, end-99999, end)
		if err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `INSERT INTO till_operators(tenant_id,session_id,employee_id) VALUES($1,$2,$3)`, b.Tenant.ID, in.Id, a.ID)
		if err != nil {
			return err
		}
		out = TillSession{Session: in, ReceiptStart: end - 99999, ReceiptEnd: end, CurrentEmployeeID: &a.ID}
		return nil
	})
	return out, tillDBError(err)
}

func tillDBError(err error) error {
	var p *pgconn.PgError
	if errors.As(err, &p) && p.Code == "23505" {
		if p.ConstraintName == "till_one_active_cashier" {
			return tillError("cashier_busy")
		}
		if p.ConstraintName == "pos_sessions_one_open_register" {
			return tillError("register_busy")
		}
		return tillError("idempotency_conflict")
	}
	return err
}

func (s *Service) HandoverTill(ctx context.Context, b devices.Binding, token, id string) (TillSession, error) {
	var out TillSession
	if !validUUID(id) {
		return out, tillError("invalid_session")
	}
	err := pg.InTenantTx(ctx, s.pools.Tenant, b.Tenant.ID, func(ctx context.Context, tx pgx.Tx) error {
		a, err := tillEmployee(ctx, tx, b, token)
		if err != nil {
			return err
		}
		if a.Role != "cashier" {
			return tillError("cashier_required")
		}
		if _, err = tx.Exec(ctx, `SELECT id FROM pos_registers WHERE id=$1 FOR UPDATE`, b.Register.ID); err != nil {
			return err
		}
		out, err = readTillSession(ctx, tx, b, id)
		if errors.Is(err, pgx.ErrNoRows) {
			return tillError("session_not_owned")
		}
		if err != nil {
			return err
		}
		if out.Session.ClosedAtMs != nil {
			return tillError("session_closed")
		}
		_, err = tx.Exec(ctx, `UPDATE till_claims SET active_employee_id=$2 WHERE session_id=$1`, id, a.ID)
		if err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `INSERT INTO till_operators(tenant_id,session_id,employee_id) VALUES($1,$2,$3) ON CONFLICT DO NOTHING`, b.Tenant.ID, id, a.ID)
		out.CurrentEmployeeID = &a.ID
		return err
	})
	return out, tillDBError(err)
}

// Current only returns this installation's open claim. Another installation
// may read receipts, but can never adopt someone else's open drawer as its own.
func (s *Service) CurrentTill(ctx context.Context, b devices.Binding, token string) (*TillSession, error) {
	var out *TillSession
	err := pg.InTenantReadTx(ctx, s.pools.Tenant, b.Tenant.ID, func(ctx context.Context, tx pgx.Tx) error {
		a, err := tillEmployee(ctx, tx, b, token)
		if err != nil {
			return err
		}
		var id string
		err = tx.QueryRow(ctx, `SELECT c.session_id::text FROM till_claims c JOIN pos_sessions p ON p.id=c.session_id WHERE c.device_id=$1 AND c.register_id=$2 AND p.closed_at_ms IS NULL AND c.active_employee_id=$3`, b.Device.ID, b.Register.ID, a.ID).Scan(&id)
		if errors.Is(err, pgx.ErrNoRows) {
			return nil
		}
		if err != nil {
			return err
		}
		value, err := readTillSession(ctx, tx, b, id)
		out = &value
		return err
	})
	return out, err
}

// Receipt history lives in till_history.go.
