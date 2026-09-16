// Package platform is how JustClick itself is run: the super admins who operate
// the SaaS, the merchants they onboard and suspend, what each merchant is sold,
// support impersonation, and the audit trail all of that leaves.
//
// Everything here reads across merchants, so it is one of the few legitimate
// importers of internal/store/unscoped. Two rules keep that honest:
//
//   - Every action writes its audit row in the SAME transaction as the change.
//     An action that committed without its row, or a row for an action that
//     rolled back, would make the trail a guess.
//   - Platform tables are unreachable from the merchant credential (see
//     migrations/20260917000018_platform.sql). A Backoffice bug cannot read a
//     super admin's secret or raise its own merchant's limits.
package platform

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/redis/go-redis/v9"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/mailer"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
)

var (
	ErrNotFound = errors.New("platform: not found")
	// ErrInvalidCredentials covers every sign-in failure alike — unknown email,
	// wrong password, deactivated account — so the form cannot enumerate who
	// has an account.
	ErrInvalidCredentials = errors.New("platform: email or password is incorrect")
	// ErrInvalidCode is a wrong, expired or already-used one-time code.
	ErrInvalidCode        = errors.New("platform: the code is incorrect or already used")
	ErrTOTPAlreadyEnabled = errors.New("platform: two-factor sign-in is already enabled")
	ErrAdminExists        = errors.New("platform: an admin with that email already exists")
)

// Invalidator is the device-auth cache. Suspending a merchant must sign its
// tills out now, not when their cached bindings expire.
type Invalidator interface {
	Bump(ctx context.Context, kind, id string)
}

// Mailer sends the first sign-in link to a new owner.
type Mailer interface {
	Configured() bool
	Send(ctx context.Context, msg mailer.Message) error
}

type Options struct {
	Auth Invalidator
	Mail Mailer
	// LinkBaseURL is the origin a sign-in link starts with (config.LinkBaseURL).
	LinkBaseURL string
	// Redis is only pinged by the ops page; nil reports it as not configured.
	Redis  *redis.Client
	Logger *slog.Logger
	// Now is the clock TOTP and expiry use; tests move it.
	Now func() time.Time
}

type Service struct {
	pools    pg.Pools
	auth     Invalidator
	mail     Mailer
	linkBase string
	rdb      *redis.Client
	logger   *slog.Logger
	now      func() time.Time
}

func NewService(pools pg.Pools, opts Options) *Service {
	s := &Service{
		pools: pools, auth: opts.Auth, mail: opts.Mail, linkBase: opts.LinkBaseURL,
		rdb: opts.Redis, logger: opts.Logger, now: opts.Now,
	}
	if s.now == nil {
		s.now = time.Now
	}
	if s.logger == nil {
		s.logger = slog.Default()
	}
	return s
}

// newToken is 32 random bytes for a link or a handoff, returned once in plain
// form alongside the SHA-256 that is the only thing stored. High entropy, so a
// fast hash is enough — the same rule as device tokens.
func newToken() (plain string, hash []byte, err error) {
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return "", nil, err
	}
	plain = base64.RawURLEncoding.EncodeToString(raw)
	return plain, hashToken(plain), nil
}

func hashToken(plain string) []byte {
	sum := sha256.Sum256([]byte(plain))
	return sum[:]
}

func isUniqueViolation(err error) bool {
	var pgErr *pgconn.PgError
	return errors.As(err, &pgErr) && pgErr.Code == "23505"
}
