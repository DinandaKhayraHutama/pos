package staff_test

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"golang.org/x/crypto/bcrypt"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/auth"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/staff"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/tenancy"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/validation"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pgtest"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/redisx"
)

type fixture struct {
	db       pgtest.DB
	feed     *syncfeed.Service
	svc      *staff.Service
	tenantID string
	ownerID  string
}

func newFixture(t *testing.T) fixture {
	t.Helper()

	db := pgtest.New(t)
	ctx := context.Background()

	rdb, err := redisx.Open(ctx, os.Getenv("REDIS_URL"))
	require.NoError(t, err, "REDIS_URL must point at a real Redis")
	t.Cleanup(func() { rdb.Close() })

	feed := syncfeed.NewService(db.Pools, rdb, slog.New(slog.NewTextHandler(io.Discard, nil)))
	f := fixture{db: db, feed: feed, svc: staff.NewService(db.Pools, feed)}
	f.tenantID, f.ownerID = f.provision(t, "alpha")

	return f
}

func (f fixture) provision(t *testing.T, slug string) (tenantID, ownerID string) {
	t.Helper()

	out, err := tenancy.Provision(context.Background(), f.db.Pools, tenancy.Input{
		BusinessName: "Warung " + slug, Slug: slug, OwnerName: "Owner " + slug,
		OwnerEmail: slug + "-owner@example.test", OwnerPassword: "a-long-enough-password",
	})
	require.NoError(t, err)

	return out.TenantID, out.OwnerID
}

func (f fixture) create(t *testing.T, tenantID, name string, role auth.Role, pin string) string {
	t.Helper()

	id, err := f.svc.Create(context.Background(), tenantID, "", staff.ProfileInput{Name: name, Role: role}, pin)
	require.NoError(t, err)

	return id
}

// row pulls one employee as a till receives it.
func (f fixture) row(t *testing.T, tenantID, id string) map[string]any {
	t.Helper()

	page, err := f.feed.Pull(context.Background(), tenantID, "employees", 0, 1000)
	require.NoError(t, err)

	for _, raw := range page.Rows {
		var row map[string]any
		require.NoError(t, json.Unmarshal(raw, &row))
		if row["id"] == id {
			return row
		}
	}

	t.Fatalf("employee %s never reached the feed", id)
	return nil
}

func (f fixture) counter(t *testing.T, entity string) int64 {
	t.Helper()

	var seq int64
	err := f.db.Owner.QueryRow(context.Background(),
		`SELECT COALESCE(max(last_seq), 0) FROM sync_counters WHERE scope_key = $1`,
		syncfeed.CompanyScope(f.tenantID, entity)).Scan(&seq)
	require.NoError(t, err)

	return seq
}

func requireField(t *testing.T, err error, field string) {
	t.Helper()

	fields, ok := validation.As(err)
	require.True(t, ok, "expected a validation error on %q, got %v", field, err)
	require.Contains(t, fields, field)
}

// The till verifies PINs itself so a cashier can sign in offline. What it
// receives must therefore be a bcrypt hash at cost 10 — and nothing a browser
// would use.
func TestANewEmployeeReachesTheTillWithAHashedPIN(t *testing.T) {
	f := newFixture(t)

	id := f.create(t, f.tenantID, "Sari", auth.Cashier, "1234")
	row := f.row(t, f.tenantID, id)

	hash, _ := row["pin_hash"].(string)
	require.True(t, strings.HasPrefix(hash, "$2a$10$"), "cost 10 — a cheap tablet feels every extra round")
	require.NoError(t, bcrypt.CompareHashAndPassword([]byte(hash), []byte("1234")))
	require.Positive(t, row["sync_seq"], "a row at zero never reaches a till pulling from zero")

	for _, secret := range []string{"password", "email"} {
		require.NotContains(t, row, secret)
	}
}

func TestAPINMustBeExactlyFourDigits(t *testing.T) {
	f := newFixture(t)

	for _, pin := range []string{"", "123", "12345", "12a4", " 1234"} {
		_, err := f.svc.Create(context.Background(), f.tenantID, "",
			staff.ProfileInput{Name: "Sari", Role: auth.Cashier}, pin)
		requireField(t, err, "pin")
	}
}

// A product decision, pinned so nobody re-adds the constraint by instinct: PINs
// are not unique. The till signs someone in by account first and PIN second,
// and a 4-digit PIN has only 10,000 values — a large company could not keep
// them unique if it tried. Each shared PIN still verifies as its own hash.
func TestStaffMayShareAPIN(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	sari := f.create(t, f.tenantID, "Sari", auth.Cashier, "1234")
	budi := f.create(t, f.tenantID, "Budi", auth.Cashier, "1234")

	departed := f.create(t, f.tenantID, "Dewi", auth.Cashier, "5678")
	require.NoError(t, f.svc.SetActive(ctx, f.tenantID, f.ownerID, departed, false))
	require.NoError(t, f.svc.SetPIN(ctx, f.tenantID, f.ownerID, departed, "1234"))
	require.NoError(t, f.svc.SetActive(ctx, f.tenantID, f.ownerID, departed, true),
		"coming back with a PIN someone else uses is fine")

	for _, id := range []string{sari, budi, departed} {
		hash, _ := f.row(t, f.tenantID, id)["pin_hash"].(string)
		require.NoError(t, bcrypt.CompareHashAndPassword([]byte(hash), []byte("1234")))
	}
}

// Nobody left who can manage staff, the menu or the reports is a merchant that
// needs a support call to get back into its own business.
func TestTheLastOwnerCannotBeDemotedOrDeactivated(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	manager := f.create(t, f.tenantID, "Manajer", auth.Manager, "1111")

	requireField(t, f.svc.Update(ctx, f.tenantID, manager, staff.ProfileInput{
		ID: f.ownerID, Name: "Owner alpha", Role: auth.Manager,
	}), "role")
	requireField(t, f.svc.SetActive(ctx, f.tenantID, manager, f.ownerID, false), "active")

	// With a second owner, either may step down.
	second := f.create(t, f.tenantID, "Owner Dua", auth.Owner, "2222")
	require.NoError(t, f.svc.Update(ctx, f.tenantID, second, staff.ProfileInput{
		ID: f.ownerID, Name: "Owner alpha", Role: auth.Manager,
	}))
}

// Two owners demoting each other at the same moment. Without the owner rows
// locked — in one order, before either target — both see the other still there
// and both succeed, leaving nobody; with the locks taken in the wrong order,
// PostgreSQL breaks the deadlock by failing one with an error nobody can act on.
// Either way the answer must be: exactly one wins, and the other is told why.
func TestTwoOwnersDemotingEachOtherLeaveExactlyOne(t *testing.T) {
	f := newFixture(t)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	for round := range 8 {
		tenantID, first := f.provision(t, fmt.Sprintf("race-%d", round))
		second, err := f.svc.Create(ctx, tenantID, "",
			staff.ProfileInput{Name: "Owner Dua", Role: auth.Owner}, "2222")
		require.NoError(t, err)

		var (
			wg    sync.WaitGroup
			start = make(chan struct{})
			errs  = make([]error, 2)
		)
		for i, pair := range [][2]string{{first, second}, {second, first}} {
			wg.Add(1)
			go func() {
				defer wg.Done()
				<-start
				errs[i] = f.svc.Update(ctx, tenantID, pair[0], staff.ProfileInput{
					ID: pair[1], Name: "Diturunkan", Role: auth.Manager,
				})
			}()
		}
		close(start)
		wg.Wait()

		failed := 0
		for _, err := range errs {
			if err == nil {
				continue
			}
			failed++
			fields, ok := validation.As(err)
			require.True(t, ok, "round %d: the loser must be told why, not handed a database error: %v", round, err)
			require.Contains(t, fields, "role")
		}
		require.Equal(t, 1, failed, "round %d: exactly one demotion may succeed", round)

		var owners int
		require.NoError(t, f.db.Owner.QueryRow(ctx,
			`SELECT count(*) FROM employees WHERE tenant_id = $1 AND role = 'owner' AND active`,
			tenantID).Scan(&owners))
		require.Equal(t, 1, owners, "round %d", round)
	}
}

func TestNobodyCanDeactivateOrDemoteThemselves(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	f.create(t, f.tenantID, "Owner Dua", auth.Owner, "2222")

	requireField(t, f.svc.SetActive(ctx, f.tenantID, f.ownerID, f.ownerID, false), "active")
	requireField(t, f.svc.Update(ctx, f.tenantID, f.ownerID, staff.ProfileInput{
		ID: f.ownerID, Name: "Owner alpha", Role: auth.Manager,
	}), "role")

	// Renaming yourself is fine; it is the role and the switch that lock
	// people out.
	require.NoError(t, f.svc.Update(ctx, f.tenantID, f.ownerID, staff.ProfileInput{
		ID: f.ownerID, Name: "Pemilik", Role: auth.Owner,
	}))
}

func TestABackofficePasswordIsOnlyForRolesThatUseIt(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	cashier := f.create(t, f.tenantID, "Sari", auth.Cashier, "1234")
	requireField(t, f.svc.SetPassword(ctx, f.tenantID, f.ownerID, cashier, "a-long-enough-password"), "password")

	email := "manajer@example.test"
	manager, err := f.svc.Create(ctx, f.tenantID, "",
		staff.ProfileInput{Name: "Manajer", Role: auth.Manager, Email: &email}, "5678")
	require.NoError(t, err)

	requireField(t, f.svc.SetPassword(ctx, f.tenantID, f.ownerID, manager, "short"), "password")
	requireField(t, f.svc.SetPassword(ctx, f.tenantID, f.ownerID, manager, strings.Repeat("x", 73)), "password")

	require.NoError(t, f.svc.SetPassword(ctx, f.tenantID, f.ownerID, manager, "a-long-enough-password"))

	signedIn, err := f.svc.Authenticate(ctx, "MANAJER@example.test", "a-long-enough-password")
	require.NoError(t, err, "the password set here is the one the sign-in form accepts")
	require.Equal(t, manager, signedIn.ID)
}

// Sign-in finds an account by address alone, so an address belongs to exactly
// one account on the whole platform — whatever its case.
func TestAnEmailBelongsToOneAccount(t *testing.T) {
	f := newFixture(t)

	taken := "Alpha-Owner@Example.test"
	_, err := f.svc.Create(context.Background(), f.tenantID, "",
		staff.ProfileInput{Name: "Tiruan", Role: auth.Manager, Email: &taken}, "9999")

	requireField(t, err, "email")
}

func TestDeactivationReachesTheTill(t *testing.T) {
	f := newFixture(t)

	sari := f.create(t, f.tenantID, "Sari", auth.Cashier, "1234")
	before := f.row(t, f.tenantID, sari)["sync_seq"].(float64)

	require.NoError(t, f.svc.SetActive(context.Background(), f.tenantID, f.ownerID, sari, false))

	row := f.row(t, f.tenantID, sari)
	require.Equal(t, false, row["active"], "the till must stop accepting her PIN")
	require.Greater(t, row["sync_seq"].(float64), before, "tills already past the old number must pull again")
}

// Flipping a switch to where it already is must not wake every till in the
// company to pull a row that did not change.
func TestASwitchLeftWhereItWasWakesNobody(t *testing.T) {
	f := newFixture(t)

	sari := f.create(t, f.tenantID, "Sari", auth.Cashier, "1234")
	before := f.counter(t, "employees")

	require.NoError(t, f.svc.SetActive(context.Background(), f.tenantID, f.ownerID, sari, true))

	require.Equal(t, before, f.counter(t, "employees"))
}

// A password change is invisible to a till, so it must not cost one either.
func TestAPasswordChangeWakesNobody(t *testing.T) {
	f := newFixture(t)
	before := f.counter(t, "employees")

	require.NoError(t, f.svc.SetPassword(context.Background(), f.tenantID, f.ownerID, f.ownerID, "another-long-password"))

	require.Equal(t, before, f.counter(t, "employees"))
}

func TestStaffAreTenantIsolated(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	other, _ := f.provision(t, "beta")
	theirs := f.create(t, other, "Rahasia", auth.Cashier, "1234")

	_, err := f.svc.Profile(ctx, f.tenantID, theirs)
	require.ErrorIs(t, err, staff.ErrNotFound)
	require.ErrorIs(t, f.svc.SetPIN(ctx, f.tenantID, f.ownerID, theirs, "4321"), staff.ErrNotFound)
	require.ErrorIs(t, f.svc.SetActive(ctx, f.tenantID, f.ownerID, theirs, false), staff.ErrNotFound)

	mine, err := f.svc.List(ctx, f.tenantID)
	require.NoError(t, err)
	for _, p := range mine {
		require.NotEqual(t, theirs, p.ID)
	}
}
