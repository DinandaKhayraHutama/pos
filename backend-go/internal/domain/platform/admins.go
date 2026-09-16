package platform

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"golang.org/x/crypto/bcrypt"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/staff"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/validation"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/store/unscoped"
)

// RecoveryCodeCount is how many one-time codes enrolment hands out.
const RecoveryCodeCount = 10

type Admin struct {
	ID          string
	Name        string
	Email       string
	Active      bool
	TOTPEnabled bool
	LastLoginAt *time.Time
}

// Authenticate checks the first factor. A correct password alone signs nobody
// in: the caller must follow with SignInWithTOTP or SignInWithRecoveryCode, or
// with enrolment when TOTPEnabled is false.
func (s *Service) Authenticate(ctx context.Context, email, password string) (Admin, error) {
	email = strings.ToLower(strings.TrimSpace(email))

	var (
		a    Admin
		hash string
	)
	err := unscoped.Tx(ctx, s.pools.Unscoped, func(ctx context.Context, tx pgx.Tx) error {
		return tx.QueryRow(ctx, `
			SELECT id::text, name, email, password, active, totp_enabled_at IS NOT NULL, last_login_at
			FROM super_admins WHERE lower(email) = $1`, email,
		).Scan(&a.ID, &a.Name, &a.Email, &hash, &a.Active, &a.TOTPEnabled, &a.LastLoginAt)
	})
	if errors.Is(err, pgx.ErrNoRows) {
		// Spend the time anyway, so an unknown address is not faster to refuse.
		_ = bcrypt.CompareHashAndPassword([]byte("$2a$10$"+strings.Repeat("x", 53)), []byte(password))
		return Admin{}, ErrInvalidCredentials
	}
	if err != nil {
		return Admin{}, err
	}
	if bcrypt.CompareHashAndPassword([]byte(hash), []byte(password)) != nil || !a.Active {
		return Admin{}, ErrInvalidCredentials
	}
	return a, nil
}

// Admin reloads an account for a request that arrives with a session, so a
// deactivation takes effect on the next click.
func (s *Service) Admin(ctx context.Context, id string) (Admin, error) {
	if !validation.UUID(id) {
		return Admin{}, ErrNotFound
	}
	var a Admin
	err := unscoped.Tx(ctx, s.pools.Unscoped, func(ctx context.Context, tx pgx.Tx) error {
		return tx.QueryRow(ctx, `
			SELECT id::text, name, email, active, totp_enabled_at IS NOT NULL, last_login_at
			FROM super_admins WHERE id = $1`, id,
		).Scan(&a.ID, &a.Name, &a.Email, &a.Active, &a.TOTPEnabled, &a.LastLoginAt)
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return Admin{}, ErrNotFound
	}
	return a, err
}

// BeginEnrollment returns the secret an admin types into an authenticator app.
// Reloading the page returns the same pending secret rather than a new one, so
// a phone that already has it does not silently fall out of step.
func (s *Service) BeginEnrollment(ctx context.Context, adminID string) (string, error) {
	fresh, err := NewTOTPSecret()
	if err != nil {
		return "", err
	}

	var secret string
	err = unscoped.Tx(ctx, s.pools.Unscoped, func(ctx context.Context, tx pgx.Tx) error {
		var (
			pending *string
			enabled bool
		)
		err := tx.QueryRow(ctx, `
			SELECT totp_secret, totp_enabled_at IS NOT NULL FROM super_admins
			WHERE id = $1 AND active FOR UPDATE`, adminID).Scan(&pending, &enabled)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		switch {
		case err != nil:
			return err
		case enabled:
			return ErrTOTPAlreadyEnabled
		case pending != nil:
			secret = *pending
			return nil
		}
		secret = fresh
		_, err = tx.Exec(ctx,
			`UPDATE super_admins SET totp_secret = $2, updated_at = now() WHERE id = $1`, adminID, secret)
		return err
	})
	return secret, err
}

// ConfirmEnrollment turns two-factor sign-in on once the admin proves the phone
// has the secret, and returns the recovery codes — shown once, stored hashed.
// Confirming is also the admin's first complete sign-in, so the code's step is
// recorded and cannot be replayed at the next sign-in.
func (s *Service) ConfirmEnrollment(ctx context.Context, adminID, code, ip string) ([]string, error) {
	codes, hashes, err := newRecoveryCodes()
	if err != nil {
		return nil, err
	}

	err = unscoped.Tx(ctx, s.pools.Unscoped, func(ctx context.Context, tx pgx.Tx) error {
		var secret *string
		err := tx.QueryRow(ctx, `
			SELECT totp_secret FROM super_admins
			WHERE id = $1 AND active AND totp_enabled_at IS NULL FOR UPDATE`, adminID).Scan(&secret)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrInvalidCode
		}
		if err != nil {
			return err
		}
		if secret == nil {
			return ErrInvalidCode
		}
		step, ok := VerifyTOTP(*secret, code, s.now())
		if !ok {
			return ErrInvalidCode
		}

		if _, err := tx.Exec(ctx, `
			UPDATE super_admins
			SET totp_enabled_at = now(), totp_last_step = GREATEST(totp_last_step, $2),
			    last_login_at = now(), updated_at = now()
			WHERE id = $1`, adminID, step); err != nil {
			return err
		}
		if err := replaceRecoveryCodes(ctx, tx, adminID, hashes); err != nil {
			return err
		}
		return Record(ctx, tx, AuditEntry{AdminID: adminID, Action: "admin.totp_enabled", IP: ip})
	})
	if err != nil {
		return nil, err
	}
	return codes, nil
}

// SignInWithTOTP completes a sign-in with an authenticator code.
//
// A code is accepted only for a step strictly later than the last one accepted,
// and that is a compare-and-swap in one UPDATE — never read-then-write — so two
// requests carrying the same observed code cannot both get in. The cost is that
// one admin cannot complete two sign-ins inside the same thirty seconds.
func (s *Service) SignInWithTOTP(ctx context.Context, adminID, code, ip string) error {
	return unscoped.Tx(ctx, s.pools.Unscoped, func(ctx context.Context, tx pgx.Tx) error {
		var secret string
		err := tx.QueryRow(ctx, `
			SELECT totp_secret FROM super_admins
			WHERE id = $1 AND active AND totp_enabled_at IS NOT NULL`, adminID).Scan(&secret)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrInvalidCode
		}
		if err != nil {
			return err
		}

		step, ok := VerifyTOTP(secret, code, s.now())
		if !ok {
			return ErrInvalidCode
		}
		tag, err := tx.Exec(ctx, `
			UPDATE super_admins SET totp_last_step = $2, last_login_at = now()
			WHERE id = $1 AND totp_last_step < $2`, adminID, step)
		if err != nil {
			return err
		}
		if tag.RowsAffected() != 1 {
			return ErrInvalidCode
		}
		return Record(ctx, tx, AuditEntry{AdminID: adminID, Action: "admin.sign_in", IP: ip,
			Detail: map[string]any{"factor": "totp"}})
	})
}

// SignInWithRecoveryCode completes a sign-in with a one-time code, for a lost
// phone. Claimed with a compare-and-swap on used_at.
func (s *Service) SignInWithRecoveryCode(ctx context.Context, adminID, code, ip string) error {
	normalized := normalizeRecoveryCode(code)
	if len(normalized) != recoveryCodeLength {
		return ErrInvalidCode
	}

	return unscoped.Tx(ctx, s.pools.Unscoped, func(ctx context.Context, tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `
			UPDATE super_admin_recovery_codes c SET used_at = now()
			FROM super_admins a
			WHERE c.super_admin_id = $1 AND c.code_sha256 = $2 AND c.used_at IS NULL
			  AND a.id = c.super_admin_id AND a.active AND a.totp_enabled_at IS NOT NULL`,
			adminID, hashToken(normalized))
		if err != nil {
			return err
		}
		if tag.RowsAffected() != 1 {
			return ErrInvalidCode
		}

		var remaining int
		if err := tx.QueryRow(ctx, `
			SELECT count(*) FROM super_admin_recovery_codes
			WHERE super_admin_id = $1 AND used_at IS NULL`, adminID).Scan(&remaining); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE super_admins SET last_login_at = now() WHERE id = $1`, adminID); err != nil {
			return err
		}
		return Record(ctx, tx, AuditEntry{AdminID: adminID, Action: "admin.sign_in", IP: ip,
			Detail: map[string]any{"factor": "recovery_code", "remaining": remaining}})
	})
}

// CreateAdmin is run from the CLI: the first admin cannot be created from a
// panel that needs an admin to sign in to it.
func (s *Service) CreateAdmin(ctx context.Context, name, email, password string) (Admin, error) {
	name = strings.TrimSpace(name)
	email = strings.ToLower(strings.TrimSpace(email))
	switch {
	case name == "" || len(name) > 120:
		return Admin{}, fmt.Errorf("platform: a name of at most 120 characters is required")
	case !strings.Contains(email, "@") || len(email) > 254:
		return Admin{}, fmt.Errorf("platform: a valid email is required")
	case len(password) < 12 || len(password) > 72:
		return Admin{}, fmt.Errorf("platform: the password must be 12 to 72 bytes")
	}

	hash, err := staff.HashPassword(password)
	if err != nil {
		return Admin{}, err
	}

	a := Admin{Name: name, Email: email, Active: true}
	err = unscoped.Tx(ctx, s.pools.Unscoped, func(ctx context.Context, tx pgx.Tx) error {
		err := tx.QueryRow(ctx, `
			INSERT INTO super_admins (name, email, password) VALUES ($1, $2, $3) RETURNING id::text`,
			name, email, hash).Scan(&a.ID)
		if isUniqueViolation(err) {
			return ErrAdminExists
		}
		if err != nil {
			return err
		}
		return Record(ctx, tx, AuditEntry{Action: "admin.create",
			Detail: map[string]any{"via": "cli", "admin_id": a.ID, "email": email}})
	})
	return a, err
}

// ResetTOTP is the break-glass for a lost phone and spent recovery codes. The
// next sign-in enrols again. totp_last_step is kept, so no code from before the
// reset can ever be accepted again.
func (s *Service) ResetTOTP(ctx context.Context, email string) error {
	return s.adminCommand(ctx, email, "admin.totp_reset", func(ctx context.Context, tx pgx.Tx, id string) error {
		if _, err := tx.Exec(ctx, `
			UPDATE super_admins SET totp_secret = NULL, totp_enabled_at = NULL, updated_at = now()
			WHERE id = $1`, id); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `DELETE FROM super_admin_recovery_codes WHERE super_admin_id = $1`, id)
		return err
	})
}

// SetAdminActive switches an account on or off. Switching it off also ends any
// impersonation it holds, so a departed engineer is not still inside a
// merchant's Backoffice.
func (s *Service) SetAdminActive(ctx context.Context, email string, active bool) error {
	action := "admin.deactivate"
	if active {
		action = "admin.activate"
	}
	return s.adminCommand(ctx, email, action, func(ctx context.Context, tx pgx.Tx, id string) error {
		if _, err := tx.Exec(ctx,
			`UPDATE super_admins SET active = $2, updated_at = now() WHERE id = $1`, id, active); err != nil {
			return err
		}
		if active {
			return nil
		}
		_, err := tx.Exec(ctx, `
			UPDATE impersonation_sessions SET ended_at = now(), ended_by = 'admin'
			WHERE super_admin_id = $1 AND ended_at IS NULL`, id)
		return err
	})
}

func (s *Service) adminCommand(ctx context.Context, email, action string, fn func(context.Context, pgx.Tx, string) error) error {
	email = strings.ToLower(strings.TrimSpace(email))
	return unscoped.Tx(ctx, s.pools.Unscoped, func(ctx context.Context, tx pgx.Tx) error {
		var id string
		err := tx.QueryRow(ctx, `SELECT id::text FROM super_admins WHERE lower(email) = $1 FOR UPDATE`, email).Scan(&id)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		if err := fn(ctx, tx, id); err != nil {
			return err
		}
		return Record(ctx, tx, AuditEntry{Action: action, Detail: map[string]any{"via": "cli", "admin_id": id}})
	})
}

// Recovery codes: ten symbols from the same unambiguous 32-symbol alphabet as
// activation codes (no I, O, 0 or 1), 50 bits each, shown as XXXXX-XXXXX. The
// alphabet length divides 256, so reducing a random byte modulo it is unbiased.
const (
	recoveryAlphabet   = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	recoveryCodeLength = 10
)

func newRecoveryCodes() (codes []string, hashes [][]byte, err error) {
	raw := make([]byte, RecoveryCodeCount*recoveryCodeLength)
	if _, err := rand.Read(raw); err != nil {
		return nil, nil, err
	}
	for i := range RecoveryCodeCount {
		symbols := make([]byte, recoveryCodeLength)
		for j := range recoveryCodeLength {
			symbols[j] = recoveryAlphabet[int(raw[i*recoveryCodeLength+j])%len(recoveryAlphabet)]
		}
		plain := string(symbols)
		codes = append(codes, plain[:5]+"-"+plain[5:])
		hashes = append(hashes, hashToken(plain))
	}
	return codes, hashes, nil
}

func normalizeRecoveryCode(code string) string {
	return strings.ToUpper(strings.NewReplacer("-", "", " ", "").Replace(strings.TrimSpace(code)))
}

func replaceRecoveryCodes(ctx context.Context, tx pgx.Tx, adminID string, hashes [][]byte) error {
	if _, err := tx.Exec(ctx, `DELETE FROM super_admin_recovery_codes WHERE super_admin_id = $1`, adminID); err != nil {
		return err
	}
	for _, h := range hashes {
		if _, err := tx.Exec(ctx,
			`INSERT INTO super_admin_recovery_codes (super_admin_id, code_sha256) VALUES ($1, $2)`, adminID, h); err != nil {
			return err
		}
	}
	return nil
}
