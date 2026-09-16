package platform_test

import (
	"context"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/platform"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pgtest"
)

const adminPassword = "platform-admin-password-1"

// clock is the service's time, moved by tests so a code for a later step can be
// produced without sleeping thirty seconds.
type clock struct {
	mu sync.Mutex
	at time.Time
}

func (c *clock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.at
}

func (c *clock) Advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.at = c.at.Add(d)
}

type adminFixture struct {
	db    pgtest.DB
	svc   *platform.Service
	clock *clock
}

func newAdminFixture(t *testing.T) adminFixture {
	t.Helper()
	db := pgtest.New(t)
	c := &clock{at: time.Now()}
	return adminFixture{db: db, clock: c, svc: platform.NewService(db.Pools, platform.Options{Now: c.Now})}
}

// enrolled creates an admin with two-factor sign-in on, and returns its secret.
func (f adminFixture) enrolled(t *testing.T, email string) (platform.Admin, string, []string) {
	t.Helper()
	ctx := context.Background()

	admin, err := f.svc.CreateAdmin(ctx, "Ops", email, adminPassword)
	require.NoError(t, err)
	secret, err := f.svc.BeginEnrollment(ctx, admin.ID)
	require.NoError(t, err)
	code, err := platform.TOTPCode(secret, f.clock.Now())
	require.NoError(t, err)
	recovery, err := f.svc.ConfirmEnrollment(ctx, admin.ID, code, "127.0.0.1")
	require.NoError(t, err)
	return admin, secret, recovery
}

func (f adminFixture) audited(t *testing.T, action string) int {
	t.Helper()
	var n int
	require.NoError(t, f.db.Owner.QueryRow(context.Background(),
		`SELECT count(*) FROM platform_audit_log WHERE action = $1`, action).Scan(&n))
	return n
}

func TestEnrolmentTurnsOnOnlyAfterTheAppProvesItHasTheSecret(t *testing.T) {
	f := newAdminFixture(t)
	ctx := context.Background()

	admin, err := f.svc.CreateAdmin(ctx, "Ops", "ops@justclick.test", adminPassword)
	require.NoError(t, err)

	signedIn, err := f.svc.Authenticate(ctx, "OPS@justclick.test ", adminPassword)
	require.NoError(t, err)
	require.False(t, signedIn.TOTPEnabled, "a password alone must leave enrolment still to do")

	secret, err := f.svc.BeginEnrollment(ctx, admin.ID)
	require.NoError(t, err)
	again, err := f.svc.BeginEnrollment(ctx, admin.ID)
	require.NoError(t, err)
	require.Equal(t, secret, again, "reloading the page must not replace a secret the phone may already hold")

	_, err = f.svc.ConfirmEnrollment(ctx, admin.ID, "000000", "")
	require.ErrorIs(t, err, platform.ErrInvalidCode)
	reloaded, err := f.svc.Admin(ctx, admin.ID)
	require.NoError(t, err)
	require.False(t, reloaded.TOTPEnabled)

	code, err := platform.TOTPCode(secret, f.clock.Now())
	require.NoError(t, err)
	recovery, err := f.svc.ConfirmEnrollment(ctx, admin.ID, code, "")
	require.NoError(t, err)
	require.Len(t, recovery, platform.RecoveryCodeCount)

	_, err = f.svc.BeginEnrollment(ctx, admin.ID)
	require.ErrorIs(t, err, platform.ErrTOTPAlreadyEnabled, "enrolment must not be a way to swap the secret")
	require.Equal(t, 1, f.audited(t, "admin.totp_enabled"))
}

// The code typed to confirm enrolment is observed on the way in; it must not
// also be good for the next sign-in.
func TestTheEnrolmentCodeCannotBeReplayedToSignIn(t *testing.T) {
	f := newAdminFixture(t)
	admin, secret, _ := f.enrolled(t, "ops@justclick.test")

	code, err := platform.TOTPCode(secret, f.clock.Now())
	require.NoError(t, err)
	require.ErrorIs(t, f.svc.SignInWithTOTP(context.Background(), admin.ID, code, ""), platform.ErrInvalidCode)
}

// Two requests carrying one observed code race; the compare-and-swap on the
// step lets exactly one in, and the code is dead afterwards.
func TestTheSameCodeSignsInExactlyOnceUnderConcurrency(t *testing.T) {
	f := newAdminFixture(t)
	ctx := context.Background()
	admin, secret, _ := f.enrolled(t, "ops@justclick.test")

	f.clock.Advance(90 * time.Second)
	code, err := platform.TOTPCode(secret, f.clock.Now())
	require.NoError(t, err)

	const racers = 8
	results := make(chan error, racers)
	var start sync.WaitGroup
	start.Add(1)
	for range racers {
		go func() {
			start.Wait()
			results <- f.svc.SignInWithTOTP(ctx, admin.ID, code, "")
		}()
	}
	start.Done()

	wins := 0
	for range racers {
		err := <-results
		if err == nil {
			wins++
			continue
		}
		require.ErrorIs(t, err, platform.ErrInvalidCode)
	}
	require.Equal(t, 1, wins)
	require.ErrorIs(t, f.svc.SignInWithTOTP(ctx, admin.ID, code, ""), platform.ErrInvalidCode)

	// The next step's code is a new code, and works.
	f.clock.Advance(30 * time.Second)
	next, err := platform.TOTPCode(secret, f.clock.Now())
	require.NoError(t, err)
	require.NoError(t, f.svc.SignInWithTOTP(ctx, admin.ID, next, ""))
}

func TestARecoveryCodeWorksExactlyOnce(t *testing.T) {
	f := newAdminFixture(t)
	ctx := context.Background()
	admin, _, recovery := f.enrolled(t, "ops@justclick.test")

	results := make(chan error, 2)
	for range 2 {
		go func() { results <- f.svc.SignInWithRecoveryCode(ctx, admin.ID, recovery[0], "") }()
	}
	wins := 0
	for range 2 {
		if err := <-results; err == nil {
			wins++
		} else {
			require.ErrorIs(t, err, platform.ErrInvalidCode)
		}
	}
	require.Equal(t, 1, wins)

	// Typed in lower case without the dash, a different code still works.
	lower := []byte(recovery[1])
	for i, b := range lower {
		if b >= 'A' && b <= 'Z' {
			lower[i] = b + ('a' - 'A')
		}
	}
	require.NoError(t, f.svc.SignInWithRecoveryCode(ctx, admin.ID, string(lower[:5])+string(lower[6:]), ""))

	var remaining int
	require.NoError(t, f.db.Owner.QueryRow(ctx,
		`SELECT count(*) FROM super_admin_recovery_codes WHERE super_admin_id = $1 AND used_at IS NULL`,
		admin.ID).Scan(&remaining))
	require.Equal(t, platform.RecoveryCodeCount-2, remaining)
}

// Unknown address, wrong password and a deactivated account read identically,
// so the form cannot be used to find out who operates the platform.
func TestEverySignInFailureLooksTheSame(t *testing.T) {
	f := newAdminFixture(t)
	ctx := context.Background()
	admin, secret, recovery := f.enrolled(t, "ops@justclick.test")

	_, err := f.svc.Authenticate(ctx, "nobody@justclick.test", adminPassword)
	require.ErrorIs(t, err, platform.ErrInvalidCredentials)
	_, err = f.svc.Authenticate(ctx, "ops@justclick.test", "wrong-password-123")
	require.ErrorIs(t, err, platform.ErrInvalidCredentials)

	require.NoError(t, f.svc.SetAdminActive(ctx, "ops@justclick.test", false))
	_, err = f.svc.Authenticate(ctx, "ops@justclick.test", adminPassword)
	require.ErrorIs(t, err, platform.ErrInvalidCredentials)

	// A session that passed the password before the switch must not finish.
	f.clock.Advance(90 * time.Second)
	code, err := platform.TOTPCode(secret, f.clock.Now())
	require.NoError(t, err)
	require.ErrorIs(t, f.svc.SignInWithTOTP(ctx, admin.ID, code, ""), platform.ErrInvalidCode)
	require.ErrorIs(t, f.svc.SignInWithRecoveryCode(ctx, admin.ID, recovery[0], ""), platform.ErrInvalidCode)
}

func TestResettingTOTPRetiresTheRecoveryCodesAndRequiresEnrolment(t *testing.T) {
	f := newAdminFixture(t)
	ctx := context.Background()
	admin, _, recovery := f.enrolled(t, "ops@justclick.test")

	require.NoError(t, f.svc.ResetTOTP(ctx, "ops@justclick.test"))

	reloaded, err := f.svc.Admin(ctx, admin.ID)
	require.NoError(t, err)
	require.False(t, reloaded.TOTPEnabled)
	require.ErrorIs(t, f.svc.SignInWithRecoveryCode(ctx, admin.ID, recovery[0], ""), platform.ErrInvalidCode)
	require.Equal(t, 1, f.audited(t, "admin.totp_reset"))

	fresh, err := f.svc.BeginEnrollment(ctx, admin.ID)
	require.NoError(t, err)
	require.NotEmpty(t, fresh)

	_, err = f.svc.CreateAdmin(ctx, "Ops lagi", "OPS@justclick.test", adminPassword)
	require.ErrorIs(t, err, platform.ErrAdminExists)
}
