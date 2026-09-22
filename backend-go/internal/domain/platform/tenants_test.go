package platform_test

import (
	"context"
	"errors"
	"io"
	"io/fs"
	"log/slog"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/stretchr/testify/require"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/devices"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/entitlements"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/outlets"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/platform"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/staff"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/validation"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/mailer"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pgtest"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/redisx"
	"github.com/daniryckidinata/nti_pos/backend-go/migrations"
)

const ownerPassword = "owner-password-12345"

type fakeMail struct {
	mu         sync.Mutex
	configured bool
	fail       bool
	sent       []mailer.Message
}

func (m *fakeMail) Configured() bool { return m.configured }

func (m *fakeMail) Send(_ context.Context, msg mailer.Message) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.fail {
		return errors.New("smtp down")
	}
	m.sent = append(m.sent, msg)
	return nil
}

type tenantFixture struct {
	db      pgtest.DB
	svc     *platform.Service
	staff   *staff.Service
	feed    *syncfeed.Service
	devices *devices.Service
	cache   *devices.CachedAuthenticator
	outlets *outlets.Service
	mail    *fakeMail
	actor   platform.Actor
}

func newTenantFixture(t *testing.T) tenantFixture {
	t.Helper()
	db := pgtest.New(t)
	ctx := context.Background()

	rdb, err := redisx.Open(ctx, os.Getenv("REDIS_URL"))
	require.NoError(t, err, "REDIS_URL must point at a real Redis")
	t.Cleanup(func() { rdb.Close() })

	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	feed := syncfeed.NewService(db.Pools, rdb, logger)
	deviceSvc := devices.NewService(db.Pools, "test-app-key")
	cache := devices.NewCachedAuthenticator(deviceSvc, rdb, logger)
	mail := &fakeMail{}

	svc := platform.NewService(db.Pools, platform.Options{
		Auth: cache, Mail: mail, LinkBaseURL: "https://pos.test", Redis: rdb, Logger: logger,
	})
	admin, err := svc.CreateAdmin(ctx, "Support", "support@justclick.test", adminPassword)
	require.NoError(t, err)

	return tenantFixture{
		db: db, svc: svc, staff: staff.NewService(db.Pools, feed), feed: feed,
		devices: deviceSvc, cache: cache, outlets: outlets.NewService(db.Pools, feed, cache),
		mail: mail, actor: platform.Actor{AdminID: admin.ID, IP: "127.0.0.1"},
	}
}

func intp(n int) *int { return &n }

func (f tenantFixture) onboard(t *testing.T, slug string) platform.Onboarded {
	t.Helper()
	out, err := f.svc.Onboard(context.Background(), f.actor, platform.OnboardInput{
		BusinessName: "Warung " + slug, Slug: slug,
		OwnerName: "Owner " + slug, OwnerEmail: slug + "@owner.test",
	})
	require.NoError(t, err)
	return out
}

func splitLink(t *testing.T, link string) (id, token string) {
	t.Helper()
	u, err := url.Parse(link)
	require.NoError(t, err)
	require.True(t, strings.HasPrefix(u.Path, "/backoffice/welcome/"), link)
	return strings.TrimPrefix(u.Path, "/backoffice/welcome/"), u.Query().Get("token")
}

// signedUp onboards a merchant and uses its link, returning a merchant whose
// owner can sign in.
func (f tenantFixture) signedUp(t *testing.T, slug string) platform.Onboarded {
	t.Helper()
	out := f.onboard(t, slug)
	id, token := splitLink(t, out.Link)
	_, err := f.svc.CompleteSetup(context.Background(), id, token, ownerPassword)
	require.NoError(t, err)
	return out
}

func (f tenantFixture) count(t *testing.T, sql string, args ...any) int {
	t.Helper()
	var n int
	require.NoError(t, f.db.Owner.QueryRow(context.Background(), sql, args...).Scan(&n))
	return n
}

func requireFields(t *testing.T, err error, fields ...string) {
	t.Helper()
	got, ok := validation.As(err)
	require.True(t, ok, "expected field errors, got %v", err)
	for _, field := range fields {
		require.Contains(t, got, field)
	}
}

func TestOnboardingCreatesAMerchantWhoseOwnerSetsTheirOwnPassword(t *testing.T) {
	f := newTenantFixture(t)
	ctx := context.Background()

	out, err := f.svc.Onboard(ctx, f.actor, platform.OnboardInput{
		BusinessName: "Warung Alpha", Slug: "warung-alpha", OwnerName: "Bu Ani",
		OwnerEmail: "Ani@Alpha.test", Timezone: "Asia/Makassar", MaxOutlets: intp(2),
	})
	require.NoError(t, err)
	require.False(t, out.Mailed, "no SMTP: the link is handed to the admin instead")
	require.NotEmpty(t, out.Link)

	// Nobody knows a password yet, the admin included.
	_, err = f.staff.Authenticate(ctx, "ani@alpha.test", "")
	require.ErrorIs(t, err, staff.ErrInvalidCredentials)

	page, err := f.feed.Pull(ctx, out.TenantID, "categories", 0, 100)
	require.NoError(t, err)
	require.Len(t, page.Rows, 3, "the starter menu reaches a fresh till from cursor zero")

	require.Equal(t, 2, f.count(t, `SELECT max_outlets FROM tenant_limits WHERE tenant_id = $1`, out.TenantID))
	require.Equal(t, 1, f.count(t, `SELECT count(*) FROM tenants WHERE id = $1 AND timezone = 'Asia/Makassar'`, out.TenantID))
	require.Equal(t, 1, f.count(t, `SELECT count(*) FROM platform_audit_log WHERE action = 'tenant.create' AND tenant_id = $1`, out.TenantID))

	id, token := splitLink(t, out.Link)
	account, err := f.svc.SetupAccount(ctx, id, token)
	require.NoError(t, err)
	require.Equal(t, "ani@alpha.test", account.Email)

	_, err = f.svc.CompleteSetup(ctx, id, token, "short")
	requireFields(t, err, "password")

	_, err = f.svc.CompleteSetup(ctx, id, token, ownerPassword)
	require.NoError(t, err)
	owner, err := f.staff.Authenticate(ctx, "ani@alpha.test", ownerPassword)
	require.NoError(t, err)
	require.Equal(t, out.OwnerID, owner.ID)

	_, err = f.svc.CompleteSetup(ctx, id, token, "another-password-123")
	require.ErrorIs(t, err, platform.ErrSetupLinkInvalid, "a link is spent by its first use")
	_, err = f.svc.SetupAccount(ctx, id, token+"x")
	require.ErrorIs(t, err, platform.ErrSetupLinkInvalid)
}

func TestOnboardingIsAllOrNothing(t *testing.T) {
	f := newTenantFixture(t)
	ctx := context.Background()
	f.onboard(t, "alpha")

	_, err := f.svc.Onboard(ctx, f.actor, platform.OnboardInput{
		BusinessName: "Warung Beta", Slug: "beta", OwnerName: "Owner", OwnerEmail: "alpha@owner.test",
	})
	requireFields(t, err, "owner_email")
	require.Zero(t, f.count(t, `SELECT count(*) FROM tenants WHERE slug = 'beta'`),
		"a merchant nobody can open must not survive a refused owner")
	require.Equal(t, 1, f.count(t, `SELECT count(*) FROM password_setup_tokens`))
	require.Equal(t, 1, f.count(t, `SELECT count(*) FROM platform_audit_log WHERE action = 'tenant.create'`))

	_, err = f.svc.Onboard(ctx, f.actor, platform.OnboardInput{
		BusinessName: "Warung Alpha 2", Slug: "alpha", OwnerName: "Owner", OwnerEmail: "other@owner.test",
	})
	requireFields(t, err, "slug")

	_, err = f.svc.Onboard(ctx, f.actor, platform.OnboardInput{
		BusinessName: "", Slug: "Warung Gamma", OwnerName: "Owner", OwnerEmail: "not-an-email",
		Timezone: "Mars/Olympus", MaxOutlets: intp(-1),
	})
	requireFields(t, err, "business_name", "slug", "owner_email", "timezone", "max_outlets")
}

func TestASetupLinkSetsAPasswordExactlyOnceUnderConcurrency(t *testing.T) {
	f := newTenantFixture(t)
	id, token := splitLink(t, f.onboard(t, "alpha").Link)

	results := make(chan error, 4)
	for i := range 4 {
		go func() {
			_, err := f.svc.CompleteSetup(context.Background(), id, token, ownerPassword+strings.Repeat("!", i))
			results <- err
		}()
	}
	wins := 0
	for range 4 {
		if err := <-results; err == nil {
			wins++
		} else {
			require.ErrorIs(t, err, platform.ErrSetupLinkInvalid)
		}
	}
	require.Equal(t, 1, wins)
}

func TestReissuingASetupLinkCancelsTheOldOneAndMailsTheNew(t *testing.T) {
	f := newTenantFixture(t)
	ctx := context.Background()
	out := f.onboard(t, "alpha")
	oldID, oldToken := splitLink(t, out.Link)

	f.mail.configured = true
	link, err := f.svc.ReissueSetupLink(ctx, f.actor, out.TenantID, out.OwnerID)
	require.NoError(t, err)
	require.True(t, link.Mailed)
	require.Len(t, f.mail.sent, 1)
	require.Equal(t, []string{"alpha@owner.test"}, f.mail.sent[0].To)
	require.Contains(t, f.mail.sent[0].Text, link.Link)

	_, err = f.svc.SetupAccount(ctx, oldID, oldToken)
	require.ErrorIs(t, err, platform.ErrSetupLinkInvalid, "only one link for an account is ever live")

	newID, newToken := splitLink(t, link.Link)
	_, err = f.svc.CompleteSetup(ctx, newID, newToken, ownerPassword)
	require.NoError(t, err)

	f.mail.fail = true
	link, err = f.svc.ReissueSetupLink(ctx, f.actor, out.TenantID, out.OwnerID)
	require.NoError(t, err, "a mail failure still issues the link")
	require.False(t, link.Mailed)
	require.NotEmpty(t, link.MailError)

	_, err = f.svc.ReissueSetupLink(ctx, f.actor, out.TenantID, out.TenantID)
	require.ErrorIs(t, err, platform.ErrNotFound)
}

// The gate for suspension: tills stop NOW, through a warm cache, and come back
// with the token they already hold.
func TestSuspendingSignsTillsOutNowAndReactivatingRestoresTheSameToken(t *testing.T) {
	f := newTenantFixture(t)
	ctx := context.Background()
	out := f.signedUp(t, "alpha")

	outletID, err := f.outlets.SaveOutlet(ctx, out.TenantID, outlets.Outlet{Name: "Bintaro", Active: true})
	require.NoError(t, err)
	registerID, err := f.outlets.SaveRegister(ctx, out.TenantID, outlets.Register{OutletID: outletID, Name: "Kasir 1", Active: true})
	require.NoError(t, err)
	code, err := f.devices.Issue(ctx, out.TenantID, registerID, nil)
	require.NoError(t, err)
	act, err := f.cache.Activate(ctx, devices.ActivateInput{Code: code.Code, DeviceUUID: "tablet-1"})
	require.NoError(t, err)
	_, err = f.cache.Authenticate(ctx, act.Token)
	require.NoError(t, err, "warm the cached binding")

	err = f.svc.Suspend(ctx, f.actor, out.TenantID, "Tagihan belum dibayar", "alfa")
	requireFields(t, err, "confirm_slug")
	err = f.svc.Suspend(ctx, f.actor, out.TenantID, "short", "alpha")
	requireFields(t, err, "reason")
	_, err = f.cache.Authenticate(ctx, act.Token)
	require.NoError(t, err, "a refused suspension changes nothing")

	require.NoError(t, f.svc.Suspend(ctx, f.actor, out.TenantID, "Tagihan belum dibayar", "alpha"))

	_, err = f.cache.Authenticate(ctx, act.Token)
	require.ErrorIs(t, err, devices.ErrUnauthenticated, "the cached binding must stop being served at once")
	_, err = f.staff.ByID(ctx, out.TenantID, out.OwnerID)
	require.ErrorIs(t, err, pgx.ErrNoRows, "the owner's next click signs them out")
	_, err = f.staff.Authenticate(ctx, "alpha@owner.test", ownerPassword)
	require.ErrorIs(t, err, staff.ErrInvalidCredentials)

	require.NoError(t, f.svc.Suspend(ctx, f.actor, out.TenantID, "Tagihan belum dibayar", "alpha"))
	require.Equal(t, 1, f.count(t, `SELECT count(*) FROM platform_audit_log WHERE action = 'tenant.suspend'`),
		"suspending a suspended merchant is not an event")

	require.NoError(t, f.svc.Reactivate(ctx, f.actor, out.TenantID))
	_, err = f.cache.Authenticate(ctx, act.Token)
	require.NoError(t, err, "no re-activation needed: the till's token works again")
	require.Equal(t, 1, f.count(t, `SELECT count(*) FROM tenants WHERE id = $1 AND suspended_at IS NULL AND suspended_reason IS NULL`, out.TenantID))
}

func (f tenantFixture) impersonate(t *testing.T, out platform.Onboarded) platform.Impersonation {
	t.Helper()
	ctx := context.Background()
	h, err := f.svc.StartImpersonation(ctx, f.actor, out.TenantID, out.OwnerID, "Tiket #123: menu tidak muncul")
	require.NoError(t, err)
	imp, err := f.svc.ConsumeHandoff(ctx, h.Token, "127.0.0.1")
	require.NoError(t, err)
	return imp
}

func (f tenantFixture) active(imp platform.Impersonation) error {
	_, err := f.svc.ActiveImpersonation(context.Background(), imp.ID, imp.TenantID, imp.EmployeeID)
	return err
}

func TestAHandoffSignsInExactlyOneBrowserWithinAMinute(t *testing.T) {
	f := newTenantFixture(t)
	ctx := context.Background()
	out := f.signedUp(t, "alpha")

	_, err := f.svc.StartImpersonation(ctx, f.actor, out.TenantID, out.OwnerID, "cek")
	requireFields(t, err, "reason")
	_, err = f.svc.StartImpersonation(ctx, f.actor, out.TenantID, out.TenantID, "Tiket #123: menu tidak muncul")
	require.ErrorIs(t, err, platform.ErrNotFound, "only an owner of that merchant can be impersonated")

	h, err := f.svc.StartImpersonation(ctx, f.actor, out.TenantID, out.OwnerID, "Tiket #123: menu tidak muncul")
	require.NoError(t, err)

	results := make(chan error, 3)
	for range 3 {
		go func() {
			_, err := f.svc.ConsumeHandoff(ctx, h.Token, "")
			results <- err
		}()
	}
	wins := 0
	for range 3 {
		if err := <-results; err == nil {
			wins++
		} else {
			require.ErrorIs(t, err, platform.ErrImpersonationInvalid)
		}
	}
	require.Equal(t, 1, wins)
	require.NoError(t, f.active(platform.Impersonation{ID: h.ID, TenantID: out.TenantID, EmployeeID: out.OwnerID}))

	stale, err := f.svc.StartImpersonation(ctx, f.actor, out.TenantID, out.OwnerID, "Tiket #124: cek laporan")
	require.NoError(t, err)
	require.ErrorIs(t, f.active(platform.Impersonation{ID: h.ID, TenantID: out.TenantID, EmployeeID: out.OwnerID}),
		platform.ErrImpersonationInvalid, "starting another impersonation ends the first")

	_, err = f.db.Owner.Exec(ctx, `UPDATE impersonation_sessions SET handoff_expires_at = now() - interval '1 second' WHERE id = $1`, stale.ID)
	require.NoError(t, err)
	_, err = f.svc.ConsumeHandoff(ctx, stale.Token, "")
	require.ErrorIs(t, err, platform.ErrImpersonationInvalid)
}

func TestAnImpersonationEndsWhenItExpiresTheMerchantIsSuspendedOrTheAdminLeaves(t *testing.T) {
	f := newTenantFixture(t)
	ctx := context.Background()
	out := f.signedUp(t, "alpha")

	expiring := f.impersonate(t, out)
	_, err := f.db.Owner.Exec(ctx, `UPDATE impersonation_sessions SET expires_at = now() - interval '1 second' WHERE id = $1`, expiring.ID)
	require.NoError(t, err)
	require.ErrorIs(t, f.active(expiring), platform.ErrImpersonationInvalid)
	require.Equal(t, 1, f.count(t, `SELECT count(*) FROM impersonation_sessions WHERE id = $1 AND ended_by = 'expired'`, expiring.ID))
	require.Equal(t, 1, f.count(t, `SELECT count(*) FROM platform_audit_log WHERE action = 'impersonation.end' AND impersonation_id = $1`, expiring.ID))

	suspended := f.impersonate(t, out)
	require.NoError(t, f.svc.Suspend(ctx, f.actor, out.TenantID, "Uji penghentian", "alpha"))
	require.ErrorIs(t, f.active(suspended), platform.ErrImpersonationInvalid)
	require.Equal(t, 1, f.count(t, `SELECT count(*) FROM impersonation_sessions WHERE id = $1 AND ended_by = 'suspended'`, suspended.ID))
	require.NoError(t, f.svc.Reactivate(ctx, f.actor, out.TenantID))

	departing := f.impersonate(t, out)
	require.NoError(t, f.svc.SetAdminActive(ctx, "support@justclick.test", false))
	require.ErrorIs(t, f.active(departing), platform.ErrImpersonationInvalid)
}

func TestEveryImpersonatedChangeIsAuditedAgainstItsImpersonation(t *testing.T) {
	f := newTenantFixture(t)
	ctx := context.Background()
	imp := f.impersonate(t, f.signedUp(t, "alpha"))

	require.NoError(t, f.svc.RecordImpersonatedRequest(ctx, imp, "POST", "/backoffice/catalogue/categories", "10.0.0.1"))

	rows, err := f.svc.Audit(ctx, platform.AuditFilter{ImpersonationID: imp.ID, Action: "impersonation.request"})
	require.NoError(t, err)
	require.Len(t, rows, 1)
	require.Equal(t, "POST", rows[0].Detail["method"])
	require.Equal(t, "/backoffice/catalogue/categories", rows[0].Detail["path"])
	require.Equal(t, "Support", rows[0].AdminName)

	require.NoError(t, f.svc.EndImpersonation(ctx, imp.ID, "admin", ""))
	require.NoError(t, f.svc.EndImpersonation(ctx, imp.ID, "admin", ""))
	require.Equal(t, 1, f.count(t, `SELECT count(*) FROM platform_audit_log WHERE action = 'impersonation.end' AND impersonation_id = $1`, imp.ID))
}

func TestLimitsAndFlagsAreWrittenAndAuditedOnlyWhenTheyChange(t *testing.T) {
	f := newTenantFixture(t)
	ctx := context.Background()
	out := f.onboard(t, "alpha")

	limits := entitlements.Limits{MaxOutlets: intp(3), MaxActiveDevices: intp(10)}
	require.NoError(t, f.svc.SetLimits(ctx, f.actor, out.TenantID, limits))
	require.NoError(t, f.svc.SetLimits(ctx, f.actor, out.TenantID, limits))
	require.Equal(t, 1, f.count(t, `SELECT count(*) FROM platform_audit_log WHERE action = 'tenant.limits'`))

	requireFields(t, f.svc.SetLimits(ctx, f.actor, out.TenantID, entitlements.Limits{MaxRegisters: intp(-2)}), "max_registers")
	require.ErrorIs(t, f.svc.SetLimits(ctx, f.actor, "00000000-0000-0000-0000-000000000000", limits), platform.ErrNotFound)

	require.NoError(t, f.svc.SetLimits(ctx, f.actor, out.TenantID, entitlements.Limits{}))
	require.Zero(t, f.count(t, `SELECT count(*) FROM tenant_limits WHERE tenant_id = $1`, out.TenantID), "no bound at all is no row")

	allOn := map[entitlements.Flag]bool{}
	for _, flag := range entitlements.AllFlags {
		allOn[flag] = true
	}
	withoutStock := map[entitlements.Flag]bool{}
	for flag, on := range allOn {
		withoutStock[flag] = on
	}
	withoutStock[entitlements.Stock] = false

	require.NoError(t, f.svc.SetFlags(ctx, f.actor, out.TenantID, allOn))
	require.Zero(t, f.count(t, `SELECT count(*) FROM platform_audit_log WHERE action = 'tenant.flags'`), "defaults are not a change")

	require.NoError(t, f.svc.SetFlags(ctx, f.actor, out.TenantID, withoutStock))
	require.Equal(t, 1, f.count(t, `SELECT count(*) FROM tenant_feature_flags WHERE tenant_id = $1 AND flag = 'stock' AND NOT enabled`, out.TenantID))

	require.NoError(t, f.svc.SetFlags(ctx, f.actor, out.TenantID, allOn))
	require.Zero(t, f.count(t, `SELECT count(*) FROM tenant_feature_flags WHERE tenant_id = $1`, out.TenantID),
		"back at the default is no row, so a later default change still reaches this merchant")
	require.Equal(t, 2, f.count(t, `SELECT count(*) FROM platform_audit_log WHERE action = 'tenant.flags'`))
}

func TestUsageComesFromDevicesAndTheSalesRollup(t *testing.T) {
	f := newTenantFixture(t)
	ctx := context.Background()
	alpha := f.onboard(t, "alpha")
	beta := f.onboard(t, "beta")

	outletID, err := f.outlets.SaveOutlet(ctx, alpha.TenantID, outlets.Outlet{Name: "Bintaro", Active: true})
	require.NoError(t, err)
	registerID, err := f.outlets.SaveRegister(ctx, alpha.TenantID, outlets.Register{OutletID: outletID, Name: "Kasir 1", Active: true})
	require.NoError(t, err)
	code, err := f.devices.Issue(ctx, alpha.TenantID, registerID, nil)
	require.NoError(t, err)
	_, err = f.cache.Activate(ctx, devices.ActivateInput{Code: code.Code, DeviceUUID: "tablet-1"})
	require.NoError(t, err)

	for offset, orders := range map[int]int{0: 12, 3: 30, 9: 500} {
		_, err := f.db.Owner.Exec(ctx, `
			INSERT INTO daily_sales_rollup (tenant_id, outlet_id, business_date, order_count, subtotal, discount,
				tax, service_charge, revenue, items_sold, cost_of_goods, costed_items, discounted_orders,
				cancelled_count, cancelled_amount, refunded_count, refunded_amount)
			VALUES ($1, $2, (now() AT TIME ZONE 'Asia/Jakarta')::date - $3::int, $4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)`,
			alpha.TenantID, outletID, offset, orders)
		require.NoError(t, err)
	}

	require.NoError(t, f.svc.Suspend(ctx, f.actor, beta.TenantID, "Uji daftar status", "beta"))

	list, more, err := f.svc.Tenants(ctx, platform.TenantFilter{Search: "alp"})
	require.NoError(t, err)
	require.False(t, more)
	require.Len(t, list, 1)
	u := list[0].Usage
	require.Equal(t, 1, u.ActiveOutlets)
	require.Equal(t, 1, u.ActiveRegisters)
	require.Equal(t, 1, u.ActiveDevices)
	require.Equal(t, 1, u.DevicesSeen5m, "activation counts as being seen")
	require.EqualValues(t, 12, u.OrdersToday)
	require.EqualValues(t, 42, u.OrdersLast7Days, "a day outside the week is not counted")
	require.NotNil(t, u.RollupAsOf)

	suspended, _, err := f.svc.Tenants(ctx, platform.TenantFilter{Status: platform.StatusSuspended})
	require.NoError(t, err)
	require.Len(t, suspended, 1)
	require.Equal(t, "beta", suspended[0].Slug)
	require.Equal(t, "Uji daftar status", suspended[0].SuspendedReason)

	wildcard, _, err := f.svc.Tenants(ctx, platform.TenantFilter{Search: "%"})
	require.NoError(t, err)
	require.Empty(t, wildcard, "a typed % is a character, not a wildcard")

	detail, err := f.svc.Tenant(ctx, alpha.TenantID)
	require.NoError(t, err)
	require.Len(t, detail.Owners, 1)
	require.False(t, detail.Owners[0].HasPassword)
	require.True(t, detail.Owners[0].PendingSetup)
	require.NotEmpty(t, detail.Activity)
	require.True(t, detail.Flags.Has(entitlements.Stock))
}

func TestTheOpsReportSeesThisSchemaAsCurrent(t *testing.T) {
	f := newTenantFixture(t)

	r := f.svc.Ops(context.Background())
	require.Equal(t, "ok", r.Database)
	require.Equal(t, "ok", r.Redis)
	require.Empty(t, r.Migrations.Pending, "the test template ran every embedded migration")
	require.Empty(t, r.Migrations.Unknown)
	// Derived, not written down. A literal here made every new migration fail
	// a test about the ops page, which teaches people to edit the assertion
	// rather than read it.
	require.EqualValues(t, newestEmbeddedMigration(t), r.Migrations.Latest)
	require.Empty(t, r.OccupiedDefaultPartitions)
	require.WithinDuration(t, time.Now(), r.CheckedAt, time.Minute)
}

// newestEmbeddedMigration is the highest version this binary would apply: the
// numeric prefix of the last SQL file, or a Go step if one is newer.
func newestEmbeddedMigration(t *testing.T) int64 {
	t.Helper()

	names, err := fs.Glob(migrations.FS, "*.sql")
	require.NoError(t, err)

	var newest int64
	for _, name := range names {
		prefix, _, ok := strings.Cut(name, "_")
		require.True(t, ok, "migration %s has no version prefix", name)
		version, err := strconv.ParseInt(prefix, 10, 64)
		require.NoError(t, err)
		newest = max(newest, version)
	}
	for _, m := range migrations.GoMigrations() {
		newest = max(newest, m.Version)
	}
	require.Positive(t, newest, "no embedded migrations were found")
	return newest
}
