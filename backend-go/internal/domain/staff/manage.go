package staff

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"golang.org/x/crypto/bcrypt"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/auth"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/devices"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/validation"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
)

var ErrNotFound = errors.New("staff: no such employee")

// pinPattern is the till's own rule: the login pad verifies the moment the
// fourth digit lands, so a PIN of any other length could never be typed.
var pinPattern = regexp.MustCompile(`^[0-9]{4}$`)

// phonePattern is loose on purpose: a contact number, not a login.
var phonePattern = regexp.MustCompile(`^[0-9+()\- ]{6,32}$`)

// Profile is an employee as the Backoffice manages them. Credentials never
// leave the domain: a screen learns only whether one is set.
type Profile struct {
	ID    string
	Name  string
	Email *string
	Phone *string
	// Role is the employees.role text (a system role, or auth.Custom);
	// RoleID and RoleName name the role row; Access is what it grants.
	Role        auth.Role
	RoleID      string
	RoleName    string
	Access      auth.Access
	Active      bool
	SortOrder   int
	HasPIN      bool
	HasPassword bool
}

// ProfileInput names the role by RoleID. A caller that only knows a system
// role may leave RoleID empty and set Role; the system row is looked up.
type ProfileInput struct {
	ID        string
	Name      string
	Email     *string
	Phone     *string
	Role      auth.Role
	RoleID    string
	SortOrder int
}

// List returns every employee, active or not.
func (s *Service) List(ctx context.Context, tenantID string) ([]Profile, error) {
	var out []Profile

	err := pg.InTenantReadTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		rows, err := tx.Query(ctx, profileSelect+`
			WHERE e.tenant_id = $1 AND e.deleted_at IS NULL
			ORDER BY e.active DESC, e.sort_order, e.name`, tenantID)
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
			WHERE e.tenant_id = $1 AND e.id = $2 AND e.deleted_at IS NULL`, tenantID, id))
		return err
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return Profile{}, ErrNotFound
	}

	return p, err
}

const profileSelect = `
	SELECT e.id::text, e.name, e.email, e.phone, e.role, e.role_id::text, r.name,
	       r.system_key, r.permissions, r.pos_access, r.backoffice_access,
	       e.active, e.sort_order, e.pin_hash IS NOT NULL, COALESCE(e.password, '') <> ''
	FROM employees e
	JOIN roles r ON r.tenant_id = e.tenant_id AND r.id = e.role_id`

func scanProfile(row pgx.Row) (Profile, error) {
	var (
		p    Profile
		role roleRow
	)
	if err := row.Scan(&p.ID, &p.Name, &p.Email, &p.Phone, &role.text, &p.RoleID, &p.RoleName,
		&role.systemKey, &role.permissions, &role.pos, &role.backoffice,
		&p.Active, &p.SortOrder, &p.HasPIN, &p.HasPassword); err != nil {
		return Profile{}, err
	}
	p.Role, p.Access = role.resolve()
	return p, nil
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
	if in.Phone != nil {
		trimmed := strings.TrimSpace(*in.Phone)
		in.Phone = &trimmed
		if trimmed == "" {
			in.Phone = nil
		}
	}

	errs := validation.Errors{}
	errs.Name("name", in.Name, 120)
	switch {
	case in.RoleID != "":
		if !validation.UUID(in.RoleID) {
			errs.Add("role", "Pilih peran.")
		}
	default:
		if _, err := auth.ParseRole(string(in.Role)); err != nil {
			errs.Add("role", "Pilih peran.")
		}
	}
	if in.Email != nil && (!strings.Contains(*in.Email, "@") || len(*in.Email) > 254) {
		errs.Add("email", "Alamat email tidak valid.")
	}
	if in.Phone != nil && !phonePattern.MatchString(*in.Phone) {
		errs.Add("phone", "Nomor telepon tidak valid.")
	}

	return errs
}

// Create adds an employee with their first PIN, in one transaction.
//
// The PIN is required because the till's form requires it: an account that
// cannot sign in anywhere is a row someone will later have to explain.
//
// actorID is who is creating the account; they may only hand out a role
// their own access covers. An empty actorID is the system itself (the CLI and
// fixtures) and skips that check — every Backoffice path names its actor.
func (s *Service) Create(ctx context.Context, tenantID, actorID string, in ProfileInput, pin string) (string, error) {
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
		role, err := resolveRole(ctx, w.Tx, tenantID, in)
		if err != nil {
			return err
		}
		if err := mayAssign(ctx, w.Tx, tenantID, actorID, role); err != nil {
			return err
		}

		seq, err := w.Seq(ctx, "employees")
		if err != nil {
			return err
		}

		err = w.Tx.QueryRow(ctx, `
			INSERT INTO employees
				(tenant_id, name, email, phone, role_id, role, sort_order, active, pin_hash, sync_seq)
			VALUES ($1, $2, $3, $4, $5, $6, $7, true, $8, $9)
			RETURNING id::text`,
			tenantID, in.Name, in.Email, in.Phone, role.id, role.text(), in.SortOrder,
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
		current, err := readEmployee(ctx, w.Tx, tenantID, in.ID, false)
		if err != nil {
			return err
		}
		if err := mayManage(ctx, w.Tx, tenantID, actorID, current); err != nil {
			return fieldError(err, "role")
		}
		role, err := resolveRole(ctx, w.Tx, tenantID, in)
		if err != nil {
			return err
		}

		if current.roleID != role.id {
			// An owner changing their own role is how a merchant locks itself
			// out of its own staff screen; someone else has to do it.
			if in.ID == actorID {
				return validation.Errors{"role": "Anda tidak bisa mengubah peran akun sendiri."}
			}
			if err := mayAssign(ctx, w.Tx, tenantID, actorID, role); err != nil {
				return err
			}
			if current.access.IsOwner() && !role.access.IsOwner() {
				if err := guardLastOwner(ctx, w.Tx, tenantID, in.ID); err != nil {
					if errors.Is(err, errLastOwner) {
						return validation.Errors{"role": lastOwnerMessage}
					}
					return err
				}
			}
		}

		if err := relock(ctx, w.Tx, tenantID, in.ID, current, "role"); err != nil {
			return err
		}

		seq, err := w.Seq(ctx, "employees")
		if err != nil {
			return err
		}

		_, err = w.Tx.Exec(ctx, `
			UPDATE employees
			SET name = $3, email = $4, phone = $5, role_id = $6, role = $7, sort_order = $8,
			    sync_seq = $9, updated_at = now()
			WHERE tenant_id = $1 AND id = $2`,
			tenantID, in.ID, in.Name, in.Email, in.Phone, role.id, role.text(), in.SortOrder, seq)
		return mapConstraint(err)
	})
}

// SetPIN replaces someone's till PIN.
//
// PINs are deliberately NOT unique, even among active staff. The till signs
// someone in by account first and PIN second, so two people sharing four
// digits never sign in as each other — and a 4-digit PIN has only 10,000
// values, so a large company could not keep them unique if it tried.
//
// Setting a PIN is signing in as that person on a till, so the actor must be
// allowed to manage them (mayManage): a custom role with manageEmployees may
// not reset an owner's PIN.
func (s *Service) SetPIN(ctx context.Context, tenantID, actorID, id, pin string) error {
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
		target, err := readEmployee(ctx, w.Tx, tenantID, id, true)
		if err != nil {
			return err
		}
		if err := mayManage(ctx, w.Tx, tenantID, actorID, target); err != nil {
			return fieldError(err, "pin")
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
func (s *Service) SetPassword(ctx context.Context, tenantID, actorID, id, password string) error {
	if !validation.UUID(id) {
		return ErrNotFound
	}
	if err := validatePassword(password); err != nil {
		return err
	}

	hash, err := HashPassword(password)
	if err != nil {
		return err
	}

	return pg.InTenantTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		target, err := readEmployee(ctx, tx, tenantID, id, true)
		if err != nil {
			return err
		}
		if err := mayManage(ctx, tx, tenantID, actorID, target); err != nil {
			return fieldError(err, "password")
		}
		if !target.access.Backoffice {
			return validation.Errors{"password": "Peran ini tidak masuk ke Backoffice, jadi tidak perlu kata sandi."}
		}

		_, err = tx.Exec(ctx, `
			UPDATE employees SET password = $3, updated_at = now()
			WHERE tenant_id = $1 AND id = $2`, tenantID, id, hash)
		return err
	})
}

func validatePassword(password string) error {
	switch {
	case len(password) < 12:
		return validation.Errors{"password": "Kata sandi minimal 12 karakter."}
	case len(password) > 72:
		// bcrypt reads at most 72 bytes. Accepting more would let two
		// different passwords that share a prefix both sign in.
		return validation.Errors{"password": "Kata sandi maksimal 72 byte."}
	}
	return nil
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
		current, err := readEmployee(ctx, w.Tx, tenantID, id, false)
		if err != nil || current.active == active {
			return err
		}
		if err := mayManage(ctx, w.Tx, tenantID, actorID, current); err != nil {
			return fieldError(err, "active")
		}

		if !active && current.access.IsOwner() {
			if err := guardLastOwner(ctx, w.Tx, tenantID, id); err != nil {
				if errors.Is(err, errLastOwner) {
					return validation.Errors{"active": lastOwnerMessage}
				}
				return err
			}
		}

		if err := relock(ctx, w.Tx, tenantID, id, current, "active"); err != nil {
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
// employees.role is derived from role_id by trigger, so 'owner' here is the
// system owner role and nothing else.
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

// employeeState is what a guard decides against.
type employeeState struct {
	roleID string
	access auth.Access
	active bool
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
func readEmployee(ctx context.Context, tx pgx.Tx, tenantID, id string, lock bool) (employeeState, error) {
	query := `
		SELECT e.role_id::text, e.role, r.system_key, r.permissions, r.pos_access, r.backoffice_access, e.active
		FROM employees e
		JOIN roles r ON r.tenant_id = e.tenant_id AND r.id = e.role_id
		WHERE e.tenant_id = $1 AND e.id = $2 AND e.deleted_at IS NULL`
	if lock {
		query += ` FOR UPDATE OF e`
	}

	var (
		st   employeeState
		role roleRow
	)
	err := tx.QueryRow(ctx, query, tenantID, id).Scan(&st.roleID, &role.text, &role.systemKey,
		&role.permissions, &role.pos, &role.backoffice, &st.active)
	if errors.Is(err, pgx.ErrNoRows) {
		return employeeState{}, ErrNotFound
	}
	if err != nil {
		return employeeState{}, err
	}
	_, st.access = role.resolve()
	return st, nil
}

// relock takes the target's row lock after any owner guard, and refuses if the
// row moved since it was first read: the guard was decided against what was
// read, and applying it to something else would be deciding blind.
func relock(ctx context.Context, tx pgx.Tx, tenantID, id string, was employeeState, field string) error {
	locked, err := readEmployee(ctx, tx, tenantID, id, true)
	if err != nil {
		return err
	}
	if locked.roleID != was.roleID || locked.active != was.active {
		return validation.Errors{field: "Data karyawan ini baru saja diubah orang lain. Muat ulang halaman."}
	}

	return nil
}

// assignableRole is a role row an employee is about to be given.
type assignableRole struct {
	id     string
	system *string
	access auth.Access
}

func (r assignableRole) text() string {
	if r.system != nil {
		return *r.system
	}
	return string(auth.Custom)
}

func resolveRole(ctx context.Context, tx pgx.Tx, tenantID string, in ProfileInput) (assignableRole, error) {
	var (
		out  assignableRole
		role roleRow
		err  error
	)
	query := `SELECT id::text, system_key, permissions, pos_access, backoffice_access FROM roles
		WHERE tenant_id = $1 AND deleted_at IS NULL AND `
	if in.RoleID != "" {
		err = tx.QueryRow(ctx, query+`id = $2 FOR KEY SHARE`, tenantID, in.RoleID).
			Scan(&out.id, &role.systemKey, &role.permissions, &role.pos, &role.backoffice)
	} else {
		err = tx.QueryRow(ctx, query+`system_key = $2 FOR KEY SHARE`, tenantID, string(in.Role)).
			Scan(&out.id, &role.systemKey, &role.permissions, &role.pos, &role.backoffice)
	}
	if errors.Is(err, pgx.ErrNoRows) {
		return assignableRole{}, validation.Errors{"role": "Peran ini tidak ada lagi. Pilih peran lain."}
	}
	if err != nil {
		return assignableRole{}, err
	}
	out.system = role.systemKey
	_, out.access = role.resolve()
	return out, nil
}

// actorAccess reads what the person making a change may do. An empty id is
// the system (CLI, fixtures), which may do anything.
func actorAccess(ctx context.Context, tx pgx.Tx, tenantID, actorID string) (auth.Access, bool, error) {
	if actorID == "" {
		return auth.Access{}, true, nil
	}
	st, err := readEmployee(ctx, tx, tenantID, actorID, false)
	if err != nil {
		return auth.Access{}, false, err
	}
	return st.access, false, nil
}

// mayAssign is the rule that stops anyone handing out more than they hold:
// the role's permissions (the till set aside, which the people who run the
// till need and an owner does not hold) must be covered by the actor's own,
// only an owner may make someone an owner, and a custom role may not be
// assigned while any active till in the business would read it as a cashier.
func mayAssign(ctx context.Context, tx pgx.Tx, tenantID, actorID string, role assignableRole) error {
	actor, system, err := actorAccess(ctx, tx, tenantID, actorID)
	if err != nil {
		return err
	}
	if !system {
		if role.access.IsOwner() && !actor.IsOwner() {
			return validation.Errors{"role": "Hanya pemilik yang bisa menjadikan orang lain pemilik."}
		}
		if !actor.Covers(role.access) {
			return validation.Errors{"role": "Anda tidak bisa memberikan peran dengan izin yang tidak Anda miliki."}
		}
	}
	if role.system == nil {
		stale, err := devices.IncompatibleDevices(ctx, tx, "", devices.CapabilityRolesV1)
		if err != nil {
			return err
		}
		if len(stale) > 0 {
			return validation.Errors{"role": fmt.Sprintf(
				"%d perangkat kasir aktif belum mendukung peran kustom. Perbarui aplikasinya atau cabut perangkatnya dulu.", len(stale))}
		}
	}
	return nil
}

// errNotYours is refused beside whichever field the actor was changing.
var errNotYours = errors.New("staff: the actor may not manage this person")

// mayManage refuses a change to someone whose access the actor does not
// cover, and to an owner by anyone but an owner. Without it a custom role
// holding manageEmployees could reset an owner's PIN or password and become
// them.
func mayManage(ctx context.Context, tx pgx.Tx, tenantID, actorID string, target employeeState) error {
	actor, system, err := actorAccess(ctx, tx, tenantID, actorID)
	if err != nil || system {
		return err
	}
	if (target.access.IsOwner() && !actor.IsOwner()) || !actor.Covers(target.access) {
		return errNotYours
	}
	return nil
}

func fieldError(err error, field string) error {
	if errors.Is(err, errNotYours) {
		return validation.Errors{field: "Anda tidak bisa mengubah akun dengan akses yang lebih luas dari akses Anda."}
	}
	return err
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
