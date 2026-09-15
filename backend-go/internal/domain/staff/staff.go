// Package staff owns employee accounts and the Backoffice sign-in.
package staff

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5"
	"golang.org/x/crypto/bcrypt"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/auth"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/store/unscoped"
)

// BcryptCost must stay 10. The same hashing is used for PINs, which the Flutter
// till verifies on-device so a cashier can sign in with no network; raising the
// cost would make sign-in on a cheap tablet visibly slow.
const BcryptCost = 10

var (
	ErrInvalidCredentials = errors.New("staff: email or password is incorrect")
	ErrEmailTaken         = errors.New("staff: that email already belongs to an account")
)

type Employee struct {
	ID       string
	TenantID string
	Name     string
	Email    string
	Role     auth.Role
	Active   bool
	// BusinessName is the merchant this account belongs to, loaded with the
	// account so every Backoffice page can name it without a second query.
	BusinessName string
}

func (e Employee) Can(p auth.Permission) bool { return e.Role.Grants(p) }

type Service struct {
	pools pg.Pools
	feed  *syncfeed.Service
}

func NewService(pools pg.Pools, feed *syncfeed.Service) *Service {
	return &Service{pools: pools, feed: feed}
}

// Authenticate resolves a Backoffice sign-in.
//
// The lookup is unscoped because email is globally unique and no tenant is
// known yet — that is the whole reason sign-in cannot be tenant-scoped. Three
// independent conditions then gate access, and they answer different
// questions: is the password real, does this role use the Backoffice at all,
// and does this person still work here.
func (s *Service) Authenticate(ctx context.Context, email, password string) (Employee, error) {
	email = strings.ToLower(strings.TrimSpace(email))

	var (
		emp  Employee
		hash string
		role string
	)

	err := unscoped.Tx(ctx, s.pools.Unscoped, func(ctx context.Context, tx pgx.Tx) error {
		return tx.QueryRow(ctx, `
			SELECT e.id, e.tenant_id, e.name, e.email, e.role, e.active, COALESCE(e.password, '')
			FROM employees e
			JOIN tenants t ON t.id = e.tenant_id
			WHERE lower(e.email) = $1
			  AND e.deleted_at IS NULL
			  AND t.status = 'active'`,
			email,
		).Scan(&emp.ID, &emp.TenantID, &emp.Name, &emp.Email, &role, &emp.Active, &hash)
	})
	if errors.Is(err, pgx.ErrNoRows) {
		// Spend the time anyway: returning instantly for an unknown address
		// turns this endpoint into a way to enumerate who has an account.
		bcrypt.CompareHashAndPassword([]byte("$2a$10$"+strings.Repeat("x", 53)), []byte(password))
		return Employee{}, ErrInvalidCredentials
	}
	if err != nil {
		return Employee{}, err
	}

	if bcrypt.CompareHashAndPassword([]byte(hash), []byte(password)) != nil {
		return Employee{}, ErrInvalidCredentials
	}

	parsed, err := auth.ParseRole(role)
	if err != nil {
		return Employee{}, err
	}
	emp.Role = parsed

	// Checked after the password, because this is the difference between
	// "these credentials are real" and "this person still works here".
	if !emp.Active || !emp.Role.UsesBackoffice() || hash == "" {
		return Employee{}, ErrInvalidCredentials
	}

	return emp, nil
}

// ByID reloads an employee for a request that arrives with a session. The role
// and active flag are re-read every time, so revoking access takes effect on
// the next request rather than when the session expires.
func (s *Service) ByID(ctx context.Context, tenantID, employeeID string) (Employee, error) {
	var (
		emp  Employee
		role string
	)

	err := pg.InTenantTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		return tx.QueryRow(ctx, `
			SELECT e.id, e.tenant_id, e.name, COALESCE(e.email, ''), e.role, e.active, t.name
			FROM employees e
			JOIN tenants t ON t.id = e.tenant_id
			WHERE e.id = $1 AND e.deleted_at IS NULL AND t.status = 'active'`,
			employeeID,
		).Scan(&emp.ID, &emp.TenantID, &emp.Name, &emp.Email, &role, &emp.Active, &emp.BusinessName)
	})
	if err != nil {
		return Employee{}, err
	}

	parsed, err := auth.ParseRole(role)
	if err != nil {
		return Employee{}, err
	}
	emp.Role = parsed

	return emp, nil
}

func HashPassword(plain string) (string, error) {
	hash, err := bcrypt.GenerateFromPassword([]byte(plain), BcryptCost)
	if err != nil {
		return "", fmt.Errorf("hash password: %w", err)
	}

	return string(hash), nil
}
