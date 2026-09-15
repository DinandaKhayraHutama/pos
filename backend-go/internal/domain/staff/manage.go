package staff

import (
	"context"
	"errors"
	"regexp"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"golang.org/x/crypto/bcrypt"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/auth"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/validation"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
)

var ErrNotFound = errors.New("staff: no such employee")

// pinPattern is the till's own rule: the login pad verifies the moment the
// fourth digit lands, so a PIN of any other length could never be typed.
var pinPattern = regexp.MustCompile(`^[0-9]{4}$`)

// Profile is an employee as the Backoffice manages them. Credentials never
// leave the domain: a screen learns only whether one is set.
type Profile struct {
	ID          string
	Name        string
	Email       *string
	Role        auth.Role
	Active      bool
	SortOrder   int
	HasPIN      bool
	HasPassword bool
}

type ProfileInput struct {
	ID        string
	Name      string
	Email     *string
	Role      auth.Role
	SortOrder int
}

// List returns every employee, active or not.
func (s *Service) List(ctx context.Context, tenantID string) ([]Profile, error) {
	var out []Profile

	err := pg.InTenantReadTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		rows, err := tx.Query(ctx, profileSelect+`
			WHERE tenant_id = $1 AND deleted_at IS NULL
			ORDER BY active DESC, sort_order, name`, tenantID)
		if err != nil {
			return err
		}

		out, err = pgx.CollectRows(rows, func(row pgx.CollectableRow) (Profile, error) { return scanProfile(row) })
		return err
	})

	return out, err
}

// Profile returns one employee.
func (s *Service) Profile(ctx context.Context, tenantID, id string) (Profile, error) {
	if !validation.UUID(id) {
		return Profile{}, ErrNotFound
	}

	var p Profile
	err := pg.InTenantReadTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		var err error
		p, err = scanProfile(tx.QueryRow(ctx, profileSelect+`
			WHERE tenant_id = $1 AND id = $2 AND deleted_at IS NULL`, tenantID, id))
		return err
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return Profile{}, ErrNotFound
	}

	return p, err
}

const profileSelect = `
	SELECT id::text, name, email, role, active, sort_order,
	       pin_hash IS NOT NULL, COALESCE(password, '') <> ''
	FROM employees`

func scanProfile(row pgx.Row) (Profile, error) {
	var (
		p    Profile
		role string
	)
	if err := row.Scan(&p.ID, &p.Name, &p.Email, &role, &p.Active, &p.SortOrder, &p.HasPIN, &p.HasPassword); err != nil {
		return Profile{}, err
	}

	parsed, err := auth.ParseRole(role)
	p.Role = parsed
	return p, err
}

func validateProfile(in *ProfileInput) validation.Errors {
	in.Name = strings.TrimSpace(in.Name)
	if in.Email != nil {
		// Stored lower-case: sign-in compares lower(email), and two rows that
		// differ only by case would be one account to a person and two to the
		// unique index.
		lowered := strings.ToLower(strings.TrimSpace(*in.Email))
		in.Email = &lowered
		if lowered == "" {
			in.Email = nil
		}
	}

	errs := validation.Errors{}
	errs.Name("name", in.Name, 120)
	if _, err := auth.ParseRole(string(in.Role)); err != nil {
		errs.Add("role", "Pilih peran.")
	}
	if in.Email != nil && (!strings.Contains(*in.Email, "@") || len(*in.Email) > 254) {
		errs.Add("email", "Alamat email tidak valid.")
	}

	return errs
}

// Create adds an employee with their first PIN, in one transaction.
//
// The PIN is required because the till's form requires it: an account that
// cannot sign in anywhere is a row someone will later have to explain.
func (s *Service) Create(ctx context.Context, tenantID string, in ProfileInput, pin string) (string, error) {
	in.ID = ""
	errs := validateProfile(&in)
	if !pinPattern.MatchString(pin) {
		errs.Add("pin", "PIN harus tepat 4 angka.")
	}
	if err := errs.Err(); err != nil {
		return "", err
	}

	pinHash, err := bcrypt.GenerateFromPassword([]byte(pin), BcryptCost)
	if err != nil {
		return "", err
	}

	var id string
	err = s.feed.Write(ctx, tenantID, func(ctx context.Context, w *syncfeed.Writer) error {
		seq, err := w.Seq(ctx, "employees")
		if err != nil {
			return err
		}

		err = w.Tx.QueryRow(ctx, `
			INSERT INTO employees
				(tenant_id, name, email, role, sort_order, active, pin_hash, sync_seq)
			VALUES ($1, $2, $3, $4, $5, true, $6, $7)
			RETURNING id::text`,
			tenantID, in.Name, in.Email, string(in.Role), in.SortOrder,
			string(pinHash), seq,
		).Scan(&id)
		return mapConstraint(err)
	})
	if err != nil {
		return "", err
	}

	return id, nil
}

// Update changes who someone is and what they may do. Credentials and the
// active switch have their own calls, because each carries its own rules.
func (s *Service) Update(ctx context.Context, tenantID, actorID string, in ProfileInput) error {
	if !validation.UUID(in.ID) {
		return ErrNotFound
	}
	if err := validateProfile(&in).Err(); err != nil {
		return err
	}

	return s.feed.Write(ctx, tenantID, func(ctx context.Context, w *syncfeed.Writer) error {
		current, active, err := readEmployee(ctx, w.Tx, tenantID, in.ID, false)
		if err != nil {
			return err
		}

		if current != in.Role {
			// An owner changing their own role is how a merchant locks itself
			// out of its own staff screen; someone else has to do it.
			if in.ID == actorID {
				return validation.Errors{"role": "Anda tidak bisa mengubah peran akun sendiri."}
			}
			if current == auth.Owner {
				if err := guardLastOwner(ctx, w.Tx, tenantID, in.ID); err != nil {
					if errors.Is(err, errLastOwner) {
						return validation.Errors{"role": lastOwnerMessage}
					}
					return err
				}
			}
		}

		if err := relock(ctx, w.Tx, tenantID, in.ID, current, active, "role"); err != nil {
			return err
		}

		seq, err := w.Seq(ctx, "employees")
		if err != nil {
			return err
		}

		_, err = w.Tx.Exec(ctx, `
			UPDATE employees
			SET name = $3, email = $4, role = $5, sort_order = $6, sync_seq = $7, updated_at = now()
			WHERE tenant_id = $1 AND id = $2`,
			tenantID, in.ID, in.Name, in.Email, string(in.Role), in.SortOrder, seq)
		return mapConstraint(err)
	})
}

// SetPIN replaces someone's till PIN.
//
// PINs are deliberately NOT unique, even among active staff. The till signs
// someone in by account first and PIN second, so two people sharing four
// digits never sign in as each other — and a 4-digit PIN has only 10,000
// values, so a large company could not keep them unique if it tried.
func (s *Service) SetPIN(ctx context.Context, tenantID, id, pin string) error {
	if !validation.UUID(id) {
		return ErrNotFound
	}
	if !pinPattern.MatchString(pin) {
		return validation.Errors{"pin": "PIN harus tepat 4 angka."}
	}

	pinHash, err := bcrypt.GenerateFromPassword([]byte(pin), BcryptCost)
	if err != nil {
		return err
	}

	return s.feed.Write(ctx, tenantID, func(ctx context.Context, w *syncfeed.Writer) error {
		if _, _, err := readEmployee(ctx, w.Tx, tenantID, id, true); err != nil {
			return err
		}

		seq, err := w.Seq(ctx, "employees")
		if err != nil {
			return err
		}

		_, err = w.Tx.Exec(ctx, `
			UPDATE employees
			SET pin_hash = $3, sync_seq = $4, updated_at = now()
			WHERE tenant_id = $1 AND id = $2`,
			tenantID, id, string(pinHash), seq)
		return err
	})
}

// SetPassword sets the Backoffice password.
//
// Not published: the password is not in the employees feed, and a till has no
// use for a browser credential. So no sequence number is taken and no till is
// woken for a change none of them can see.
func (s *Service) SetPassword(ctx context.Context, tenantID, id, password string) error {
	if !validation.UUID(id) {
		return ErrNotFound
	}

	switch {
	case len(password) < 12:
		return validation.Errors{"password": "Kata sandi minimal 12 karakter."}
	case len(password) > 72:
		// bcrypt reads at most 72 bytes. Accepting more would let two
		// different passwords that share a prefix both sign in.
		return validation.Errors{"password": "Kata sandi maksimal 72 byte."}
	}

	hash, err := HashPassword(password)
	if err != nil {
		return err
	}

	return pg.InTenantTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		var role string
		err := tx.QueryRow(ctx, `
			SELECT role FROM employees
			WHERE tenant_id = $1 AND id = $2 AND deleted_at IS NULL
			FOR UPDATE`, tenantID, id).Scan(&role)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		if !auth.Role(role).UsesBackoffice() {
			return validation.Errors{"password": "Kasir tidak masuk ke Backoffice, jadi tidak perlu kata sandi."}
		}

		_, err = tx.Exec(ctx, `
			UPDATE employees SET password = $3, updated_at = now()
			WHERE tenant_id = $1 AND id = $2`, tenantID, id, hash)
		return err
	})
}

// SetActive signs someone in or out of every till and the Backoffice at once.
//
// Deactivation is published, so tills refuse the PIN after their next pull,
// and the Backoffice re-reads the account on every request, so a deactivated
// manager's open tab stops working on the next click.
func (s *Service) SetActive(ctx context.Context, tenantID, actorID, id string, active bool) error {
	if !validation.UUID(id) {
		return ErrNotFound
	}
	if id == actorID && !active {
		return validation.Errors{"active": "Anda tidak bisa menonaktifkan akun sendiri."}
	}

	return s.feed.Write(ctx, tenantID, func(ctx context.Context, w *syncfeed.Writer) error {
		role, current, err := readEmployee(ctx, w.Tx, tenantID, id, false)
		if err != nil || current == active {
			return err
		}

		if !active && role == auth.Owner {
			if err := guardLastOwner(ctx, w.Tx, tenantID, id); err != nil {
				if errors.Is(err, errLastOwner) {
					return validation.Errors{"active": lastOwnerMessage}
				}
				return err
			}
		}

		if err := relock(ctx, w.Tx, tenantID, id, role, current, "active"); err != nil {
			return err
		}

		seq, err := w.Seq(ctx, "employees")
		if err != nil {
			return err
		}

		_, err = w.Tx.Exec(ctx, `
			UPDATE employees SET active = $3, sync_seq = $4, updated_at = now()
			WHERE tenant_id = $1 AND id = $2`, tenantID, id, active, seq)
		return err
	})
}

// lastOwnerMessage is shown beside whichever field would have removed the last
// owner — the role select or the active switch.
const lastOwnerMessage = "Harus tetap ada minimal satu owner aktif."

var errLastOwner = errors.New("staff: this would leave no active owner")

// guardLastOwner refuses a change that would leave the merchant with no active
// owner — nobody left who can manage staff, the menu or the reports.
//
// It locks every active owner's row, and only those: they are the rows whose
// invariant this protects. Two owners demoting each other at once then
// serialise here, and the second re-reads after the first commits and finds
// itself the last — which a check without the lock would not.
//
// Always in id order, and always before the target's own row is locked (see
// readEmployee), so two guards can never each hold what the other waits for.
func guardLastOwner(ctx context.Context, tx pgx.Tx, tenantID, leavingID string) error {
	rows, err := tx.Query(ctx, `
		SELECT id::text FROM employees
		WHERE tenant_id = $1 AND role = 'owner' AND active AND deleted_at IS NULL
		ORDER BY id
		FOR UPDATE`, tenantID)
	if err != nil {
		return err
	}

	owners, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return err
	}

	for _, id := range owners {
		if id != leavingID {
			return nil
		}
	}

	return errLastOwner
}

// readEmployee reads someone's role and active switch, taking the row lock only
// when asked.
//
// A change that might remove an owner reads first WITHOUT the lock, takes
// every owner's lock in id order through guardLastOwner, and only then locks
// its target through relock. Locking the target first deadlocks two owners
// demoting each other: each holds its own target and waits for the other's,
// and PostgreSQL resolves that by failing one of them with an error nobody can
// act on.
func readEmployee(ctx context.Context, tx pgx.Tx, tenantID, id string, lock bool) (auth.Role, bool, error) {
	query := `
		SELECT role, active FROM employees
		WHERE tenant_id = $1 AND id = $2 AND deleted_at IS NULL`
	if lock {
		query += ` FOR UPDATE`
	}

	var (
		role   string
		active bool
	)
	err := tx.QueryRow(ctx, query, tenantID, id).Scan(&role, &active)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", false, ErrNotFound
	}
	if err != nil {
		return "", false, err
	}

	return auth.Role(role), active, nil
}

// relock takes the target's row lock after any owner guard, and refuses if the
// row moved since it was first read: the guard was decided against what was
// read, and applying it to something else would be deciding blind.
func relock(ctx context.Context, tx pgx.Tx, tenantID, id string, role auth.Role, active bool, field string) error {
	lockedRole, lockedActive, err := readEmployee(ctx, tx, tenantID, id, true)
	if err != nil {
		return err
	}
	if lockedRole != role || lockedActive != active {
		return validation.Errors{field: "Data karyawan ini baru saja diubah orang lain. Muat ulang halaman."}
	}

	return nil
}

// mapConstraint turns the unique violations a person can cause from a form
// into messages beside the field that caused them.
func mapConstraint(err error) error {
	var pgErr *pgconn.PgError
	if !errors.As(err, &pgErr) || pgErr.Code != "23505" {
		return err
	}

	switch pgErr.ConstraintName {
	case "employees_email_key":
		return validation.Errors{"email": "Email ini sudah dipakai akun lain."}
	default:
		return err
	}
}
