// Command verify-platform drives the platform panel and the Backoffice against a
// running server, the way a support engineer and a new merchant would:
//
//   - a super admin enrols two-factor sign-in in the browser, and a replayed
//     code is refused;
//   - a merchant is created from the panel and its owner sets their own
//     password through the one-time link;
//   - plan limits and module switches are enforced where the merchant works;
//   - impersonation hands off to the Backoffice, shows its banner, audits every
//     change and refuses a password change;
//   - suspension signs a live till out at once, and reactivation lets the same
//     token back in.
//
// It creates a disposable admin and merchant and deletes both in a defer.
//
//	justclick serve &
//	go run ./scripts/verify-platform
package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"os"
	"regexp"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/platform"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/redisx"
)

var (
	failures     int
	csrfRE       = regexp.MustCompile(`name="gorilla\.csrf\.Token" value="([^"]+)"`)
	secretRE     = regexp.MustCompile(`id="totp-secret" class="secret">([A-Z2-7 ]+)<`)
	recoveryRE   = regexp.MustCompile(`class="recovery-code">([A-Z2-9]{5}-[A-Z2-9]{5})<`)
	setupLinkRE  = regexp.MustCompile(`id="setup-link"[^>]*value="([^"]+)"`)
	tenantLinkRE = regexp.MustCompile(`href="/platform/tenants/([0-9a-f-]{36})"`)
	ownerRE      = regexp.MustCompile(`<option value="([0-9a-f-]{36})"`)
	handoffRE    = regexp.MustCompile(`name="token" value="([^"]+)"`)
	codeRE       = regexp.MustCompile(`<div class="code">([A-Z2-9]{12})</div>`)
)

const (
	adminPassword = "verify-platform-password-1"
	ownerPassword = "verify-owner-password-12"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "fatal:", err)
		os.Exit(1)
	}
	if failures > 0 {
		fmt.Printf("\n%d check(s) FAILED\n", failures)
		os.Exit(1)
	}
	fmt.Println("\nall checks passed")
}

func run() error {
	ctx := context.Background()
	base := strings.TrimRight(envOr("VERIFY_BASE_URL", "http://127.0.0.1:9000"), "/")

	owner, err := pgxpool.New(ctx, os.Getenv("MIGRATE_DATABASE_URL"))
	if err != nil {
		return err
	}
	defer owner.Close()
	pools, err := pg.OpenPools(ctx, os.Getenv("DATABASE_URL"), os.Getenv("UNSCOPED_DATABASE_URL"))
	if err != nil {
		return err
	}
	defer pools.Close()

	suffix := time.Now().UnixNano()
	slug := fmt.Sprintf("vplat-%d", suffix)
	adminEmail := fmt.Sprintf("vplat-%d@justclick.test", suffix)
	ownerEmail := fmt.Sprintf("vplat-owner-%d@justclick.test", suffix)

	// The first admin comes from the CLI's own code path, as in production.
	admin, err := platform.NewService(pools, platform.Options{}).CreateAdmin(ctx, "Verify Platform", adminEmail, adminPassword)
	if err != nil {
		return err
	}
	var tenantID string
	defer cleanup(owner, admin.ID, &tenantID)
	clearLimiters(ctx)

	support := newClient()
	merchant := newClient()

	// --- Two-factor sign-in -------------------------------------------------

	status, _ := support.get(base + "/platform/tenants")
	check("an anonymous visitor is sent away from the panel", status == http.StatusSeeOther, "got %d", status)

	status, body := support.get(base + "/platform/login")
	token := firstMatch(csrfRE, body)
	check("the platform login form renders with a CSRF token", status == http.StatusOK && token != "", "got %d", status)

	status, _ = support.post(base+"/platform/logout", "", url.Values{})
	check("a platform POST without a CSRF token is refused", status == http.StatusForbidden, "got %d", status)

	status, _ = support.post(base+"/platform/login", token, url.Values{"email": {adminEmail}, "password": {"wrong-password-123"}})
	check("a wrong admin password is refused", status == http.StatusUnauthorized, "got %d", status)

	status, _ = support.post(base+"/platform/login", token, url.Values{"email": {adminEmail}, "password": {adminPassword}})
	check("the password moves a new admin to enrolment, not into the panel",
		status == http.StatusSeeOther && support.location == "/platform/enroll", "got %d → %s", status, support.location)

	status, _ = support.get(base + "/platform/tenants")
	check("a password alone does not open the panel", status == http.StatusSeeOther, "got %d", status)

	status, body = support.get(base + "/platform/enroll")
	secret := strings.ReplaceAll(firstMatch(secretRE, body), " ", "")
	token = firstMatch(csrfRE, body)
	check("enrolment shows a TOTP secret to type into an app", status == http.StatusOK && len(secret) == 32, "got %d, secret %q", status, secret)

	status, _ = support.post(base+"/platform/enroll", token, url.Values{"code": {"000000"}})
	check("a wrong enrolment code is refused", status == http.StatusUnauthorized, "got %d", status)

	enrolCode, err := platform.TOTPCode(secret, time.Now())
	if err != nil {
		return err
	}
	status, body = support.post(base+"/platform/enroll", token, url.Values{"code": {enrolCode}})
	recovery := allMatches(recoveryRE, body)
	check("confirming enrolment shows ten recovery codes once",
		status == http.StatusOK && len(recovery) == platform.RecoveryCodeCount, "got %d with %d codes", status, len(recovery))

	status, _ = support.get(base + "/platform/tenants")
	check("the enrolled admin reaches the panel", status == http.StatusOK, "got %d", status)

	_, body = support.get(base + "/platform/tenants")
	status, _ = support.post(base+"/platform/logout", firstMatch(csrfRE, body), url.Values{})
	check("the admin signs out", status == http.StatusSeeOther, "got %d", status)

	_, body = support.get(base + "/platform/login")
	token = firstMatch(csrfRE, body)
	support.post(base+"/platform/login", token, url.Values{"email": {adminEmail}, "password": {adminPassword}})
	check("a second sign-in asks for a code", support.location == "/platform/login/verify", "went to %s", support.location)

	_, body = support.get(base + "/platform/login/verify")
	token = firstMatch(csrfRE, body)
	status, _ = support.post(base+"/platform/login/verify", token, url.Values{"code": {enrolCode}})
	check("the code already used at enrolment cannot be replayed", status == http.StatusUnauthorized, "got %d", status)

	if len(recovery) > 0 {
		status, _ = support.post(base+"/platform/login/verify", token, url.Values{"recovery_code": {recovery[0]}})
		check("a recovery code signs in", status == http.StatusSeeOther && support.location == "/platform/tenants",
			"got %d → %s", status, support.location)
	}

	for _, c := range support.jar.Cookies(mustParse(base + "/backoffice/")) {
		check("the platform session cookie is never sent to the Backoffice", c.Name != "justclick_platform", "found %s", c.Name)
	}

	// --- Onboarding ---------------------------------------------------------

	_, body = support.get(base + "/platform/tenants/new")
	token = firstMatch(csrfRE, body)
	status, body = support.post(base+"/platform/tenants", token, url.Values{
		"business_name": {"Verify Platform"}, "slug": {"Bukan Slug"}, "owner_name": {"Owner Verify"},
		"owner_email": {ownerEmail}, "timezone": {"Asia/Jakarta"},
	})
	check("an invalid slug is refused beside its field", status == http.StatusOK && strings.Contains(body, "huruf kecil"), "got %d", status)

	status, body = support.post(base+"/platform/tenants", token, url.Values{
		"business_name": {"Verify Platform"}, "slug": {slug}, "owner_name": {"Owner Verify"},
		"owner_email": {ownerEmail}, "timezone": {"Asia/Jakarta"}, "max_outlets": {"1"},
	})
	link := html(firstMatch(setupLinkRE, body))
	tenantID = firstMatch(tenantLinkRE, body)
	check("the merchant is created and, with no mail configured, its link is shown once",
		status == http.StatusOK && link != "" && tenantID != "", "got %d: %s", status, truncate(body))
	if tenantID == "" || link == "" {
		return errors.New("cannot continue without a merchant")
	}

	var categories int
	_ = owner.QueryRow(ctx, `SELECT count(*) FROM categories WHERE tenant_id = $1 AND sync_seq > 0`, tenantID).Scan(&categories)
	check("the starter menu is numbered for the feed", categories == 3, "got %d", categories)

	setup := mustParse(link)
	setupURL := base + setup.Path + "?" + setup.RawQuery
	status, body = merchant.get(setupURL)
	token = firstMatch(csrfRE, body)
	check("the owner's link opens the password form", status == http.StatusOK && strings.Contains(body, ownerEmail), "got %d", status)

	status, body = merchant.postTo(setupURL, token, url.Values{"password": {"short"}})
	check("a short password is refused on the form", status == http.StatusOK && strings.Contains(body, "minimal 12"), "got %d", status)

	status, _ = merchant.postTo(setupURL, token, url.Values{"password": {ownerPassword}})
	check("setting the password signs the owner in", status == http.StatusSeeOther, "got %d", status)

	status, body = merchant.get(base + "/backoffice/devices")
	check("the owner is inside the Backoffice", status == http.StatusOK, "got %d", status)
	boToken := firstMatch(csrfRE, body)

	status, _ = newClient().get(setupURL)
	check("the link is spent after one use", status == http.StatusGone, "got %d", status)

	// --- Limits ---------------------------------------------------------------

	status, _ = merchant.hx(base+"/backoffice/outlets", boToken, url.Values{"name": {"Outlet Verify"}})
	check("the first outlet fits the plan", status == http.StatusOK, "got %d", status)
	status, body = merchant.hx(base+"/backoffice/outlets", boToken, url.Values{"name": {"Outlet Kedua"}})
	check("a second outlet is refused at max_outlets=1", status == http.StatusOK && strings.Contains(body, "Batas paket"), "got %d: %s", status, truncate(body))

	var outletID string
	_ = owner.QueryRow(ctx, `SELECT id FROM outlets WHERE tenant_id = $1`, tenantID).Scan(&outletID)
	merchant.hx(base+"/backoffice/outlets/"+outletID+"/registers", boToken, url.Values{"name": {"Kasir 1"}})
	merchant.hx(base+"/backoffice/outlets/"+outletID+"/registers", boToken, url.Values{"name": {"Kasir 2"}})
	var first, second string
	_ = owner.QueryRow(ctx, `SELECT id FROM pos_registers WHERE tenant_id = $1 AND name = 'Kasir 1'`, tenantID).Scan(&first)
	_ = owner.QueryRow(ctx, `SELECT id FROM pos_registers WHERE tenant_id = $1 AND name = 'Kasir 2'`, tenantID).Scan(&second)
	check("two tills exist", first != "" && second != "", "first %q second %q", first, second)

	_, body = merchant.hx(base+"/backoffice/registers/"+first+"/activation-code", boToken, url.Values{})
	tillToken := activate(base, firstMatch(codeRE, body), "verify-platform-tablet-1")
	check("a till activates with a code minted in the Backoffice", tillToken != "", "no token")

	_, body = merchant.hx(base+"/backoffice/registers/"+second+"/activation-code", boToken, url.Values{})
	pendingCode := firstMatch(codeRE, body)

	_, body = support.get(base + "/platform/tenants/" + tenantID)
	token = firstMatch(csrfRE, body)
	status, _ = support.post(base+"/platform/tenants/"+tenantID+"/limits", token, url.Values{
		"max_outlets": {"1"}, "max_active_devices": {"1"},
	})
	check("the platform lowers the device limit", status == http.StatusSeeOther, "got %d", status)

	status, body = merchant.hx(base+"/backoffice/registers/"+first+"/activation-code", boToken, url.Values{})
	check("issuing a code at the device limit is refused in the panel",
		status == http.StatusUnprocessableEntity && strings.Contains(body, "Batas paket"), "got %d", status)

	status, errCode := activateStatus(base, pendingCode, "verify-platform-tablet-2")
	check("activating with a code issued before the limit answers 422 device_limit_reached",
		status == http.StatusUnprocessableEntity && errCode == "device_limit_reached", "got %d %s", status, errCode)

	// --- Modules --------------------------------------------------------------

	status, _ = support.post(base+"/platform/tenants/"+tenantID+"/flags", token, url.Values{
		"flag_tables": {"on"}, "flag_promos": {"on"}, "flag_report_exports": {"on"},
	})
	check("the platform switches the stock module off", status == http.StatusSeeOther, "got %d", status)

	status, _ = merchant.get(base + "/backoffice/stock")
	check("the switched-off module is not found", status == http.StatusNotFound, "got %d", status)
	_, body = merchant.get(base + "/backoffice/devices")
	check("and is gone from the nav", !strings.Contains(body, `href="/backoffice/stock"`), "stock still linked")

	// --- Impersonation ----------------------------------------------------------

	_, body = support.get(base + "/platform/tenants/" + tenantID)
	token = firstMatch(csrfRE, body)
	ownerID := firstMatch(ownerRE, body)

	status, body = support.post(base+"/platform/tenants/"+tenantID+"/impersonate", token, url.Values{"employee_id": {ownerID}, "reason": {"cek"}})
	check("impersonation needs a real reason", status == http.StatusOK && strings.Contains(body, "Tulis alasan"), "got %d", status)

	status, body = support.post(base+"/platform/tenants/"+tenantID+"/impersonate", token, url.Values{
		"employee_id": {ownerID}, "reason": {"Verifikasi otomatis Fase 8"},
	})
	handoff := firstMatch(handoffRE, body)
	check("starting impersonation renders a self-submitting handoff", status == http.StatusOK && handoff != "", "got %d", status)

	status, _ = support.postWithOrigin(base+"/backoffice/impersonate", "https://evil.example", url.Values{"token": {handoff}})
	check("a handoff from another origin is refused", status == http.StatusForbidden, "got %d", status)

	status, _ = support.post(base+"/backoffice/impersonate", "", url.Values{"token": {handoff}})
	check("the handoff signs the support browser in as the owner", status == http.StatusSeeOther, "got %d", status)

	status, _ = newClient().post(base+"/backoffice/impersonate", "", url.Values{"token": {handoff}})
	check("a handoff works exactly once", status == http.StatusForbidden, "got %d", status)

	status, body = support.get(base + "/backoffice/devices")
	check("every page carries the support banner", status == http.StatusOK && strings.Contains(body, "MODE SUPPORT"), "got %d", status)
	impToken := firstMatch(csrfRE, body)

	status, _ = support.hx(base+"/backoffice/catalogue/categories", impToken, url.Values{"name": {"Kategori Support"}})
	check("support can change the merchant's data", status == http.StatusOK, "got %d", status)

	var audited int
	_ = owner.QueryRow(ctx, `
		SELECT count(*) FROM platform_audit_log
		WHERE tenant_id = $1 AND action = 'impersonation.request' AND detail->>'path' = '/backoffice/catalogue/categories'`,
		tenantID).Scan(&audited)
	check("that change is in the platform audit log", audited == 1, "got %d rows", audited)

	status, _ = support.hx(base+"/backoffice/staff/"+ownerID+"/password", impToken, url.Values{"password": {"taken-over-password-1"}})
	check("support cannot set the owner's password", status == http.StatusForbidden, "got %d", status)

	status, _ = support.post(base+"/backoffice/impersonation/end", impToken, url.Values{})
	check("ending impersonation returns to the platform", status == http.StatusSeeOther &&
		support.location == "/platform/tenants/"+tenantID, "got %d → %s", status, support.location)
	status, _ = support.get(base + "/backoffice/devices")
	check("the Backoffice session is gone afterwards", status == http.StatusSeeOther, "got %d", status)

	// --- Suspension -------------------------------------------------------------

	status, _ = getBearer(base+"/api/v2/devices/me", tillToken)
	check("the till is working before suspension", status == http.StatusOK, "got %d", status)

	_, body = support.get(base + "/platform/tenants/" + tenantID)
	token = firstMatch(csrfRE, body)
	status, body = support.post(base+"/platform/tenants/"+tenantID+"/suspend", token, url.Values{
		"reason": {"Verifikasi suspend otomatis"}, "confirm_slug": {"salah"},
	})
	check("suspension needs the slug typed", status == http.StatusOK && strings.Contains(body, "Ketik slug"), "got %d", status)

	status, _ = support.post(base+"/platform/tenants/"+tenantID+"/suspend", token, url.Values{
		"reason": {"Verifikasi suspend otomatis"}, "confirm_slug": {slug},
	})
	check("the merchant is suspended", status == http.StatusSeeOther, "got %d", status)

	status, _ = getBearer(base+"/api/v2/devices/me", tillToken)
	check("its till is signed out at once, through the auth cache", status == http.StatusUnauthorized, "got %d", status)
	status, _ = merchant.get(base + "/backoffice/devices")
	check("its owner is signed out on the next click", status == http.StatusSeeOther, "got %d", status)

	_, body = support.get(base + "/platform/tenants/" + tenantID)
	status, _ = support.post(base+"/platform/tenants/"+tenantID+"/reactivate", firstMatch(csrfRE, body), url.Values{})
	check("the merchant is reactivated", status == http.StatusSeeOther, "got %d", status)
	status, _ = getBearer(base+"/api/v2/devices/me", tillToken)
	check("the same till token works again", status == http.StatusOK, "got %d", status)

	// --- Audit, ops, credentials ------------------------------------------------

	status, body = support.get(base + "/platform/audit?tenant=" + tenantID)
	for _, action := range []string{"tenant.create", "tenant.limits", "tenant.flags", "impersonation.start", "impersonation.request", "impersonation.end", "tenant.suspend", "tenant.reactivate"} {
		check("the audit page lists "+action, status == http.StatusOK && strings.Contains(body, `data-action="`+action+`"`), "missing")
	}

	status, body = support.get(base + "/platform/ops")
	check("the ops page sees every migration applied", status == http.StatusOK && strings.Contains(body, `id="migrations-current"`), "got %d", status)

	_, err = pools.Tenant.Exec(ctx, "SELECT 1 FROM super_admins")
	var pgErr *pgconn.PgError
	check("the merchant credential cannot read super_admins", errors.As(err, &pgErr) && pgErr.Code == "42501", "got %v", err)

	return nil
}

func cleanup(owner *pgxpool.Pool, adminID string, tenantID *string) {
	ctx := context.Background()
	stmts := []struct {
		sql  string
		args []any
	}{
		{`DELETE FROM platform_audit_log WHERE super_admin_id = $1 OR tenant_id = NULLIF($2, '')::uuid`, []any{adminID, *tenantID}},
		{`DELETE FROM tenants WHERE id = NULLIF($1, '')::uuid`, []any{*tenantID}},
		{`DELETE FROM impersonation_sessions WHERE super_admin_id = $1`, []any{adminID}},
		{`DELETE FROM platform_audit_log WHERE super_admin_id = $1`, []any{adminID}},
		{`DELETE FROM super_admins WHERE id = $1`, []any{adminID}},
	}
	for _, s := range stmts {
		if _, err := owner.Exec(ctx, s.sql, s.args...); err != nil {
			fmt.Fprintln(os.Stderr, "cleanup failed:", err)
		}
	}
}

// clearLimiters starts from clean buckets: verify-activation spends the
// activation allowance on purpose, and this script signs in several times.
func clearLimiters(ctx context.Context) {
	rdb, err := redisx.Open(ctx, os.Getenv("REDIS_URL"))
	if err != nil {
		return
	}
	defer rdb.Close()
	for _, pattern := range []string{"rl:act:*", "rl:pl:*"} {
		iter := rdb.Scan(ctx, 0, pattern, 100).Iterator()
		for iter.Next(ctx) {
			rdb.Del(ctx, iter.Val())
		}
	}
}

type client struct {
	http     *http.Client
	jar      *cookiejar.Jar
	location string
}

func newClient() *client {
	jar, _ := cookiejar.New(nil)
	c := &http.Client{
		Jar:     jar,
		Timeout: 15 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	if os.Getenv("VERIFY_INSECURE_TLS") == "1" {
		c.Transport = &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true}} //nolint:gosec // dev-only, localhost
	}
	return &client{http: c, jar: jar}
}

func (c *client) get(target string) (int, string) {
	req, _ := http.NewRequest(http.MethodGet, target, nil)
	return c.send(req)
}

func (c *client) post(target, csrfToken string, values url.Values) (int, string) {
	return c.postTo(target, csrfToken, values)
}

// postTo posts a form the way a browser does from a page on this origin.
func (c *client) postTo(target, csrfToken string, values url.Values) (int, string) {
	u := mustParse(target)
	return c.postWithOrigin(target, u.Scheme+"://"+u.Host, withToken(values, csrfToken))
}

func (c *client) postWithOrigin(target, origin string, values url.Values) (int, string) {
	req, _ := http.NewRequest(http.MethodPost, target, strings.NewReader(values.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Origin", origin)
	req.Header.Set("Referer", origin+"/")
	return c.send(req)
}

// hx posts what HTMX sends: the token as a header, taken from hx-headers.
func (c *client) hx(target, csrfToken string, values url.Values) (int, string) {
	u := mustParse(target)
	req, _ := http.NewRequest(http.MethodPost, target, strings.NewReader(values.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("HX-Request", "true")
	req.Header.Set("X-CSRF-Token", csrfToken)
	req.Header.Set("Origin", u.Scheme+"://"+u.Host)
	req.Header.Set("Referer", u.Scheme+"://"+u.Host+"/backoffice/")
	return c.send(req)
}

func (c *client) send(req *http.Request) (int, string) {
	resp, err := c.http.Do(req)
	if err != nil {
		return 0, err.Error()
	}
	defer resp.Body.Close()
	c.location = resp.Header.Get("Location")
	body, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(body)
}

func withToken(values url.Values, token string) url.Values {
	if token != "" {
		values.Set("gorilla.csrf.Token", token)
	}
	return values
}

func activate(base, code, deviceUUID string) string {
	status, body := activateRaw(base, code, deviceUUID)
	if status != http.StatusOK {
		return ""
	}
	var out struct {
		Data struct {
			Token string `json:"token"`
		} `json:"data"`
	}
	_ = json.Unmarshal([]byte(body), &out)
	return out.Data.Token
}

func activateStatus(base, code, deviceUUID string) (int, string) {
	status, body := activateRaw(base, code, deviceUUID)
	var out struct {
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	_ = json.Unmarshal([]byte(body), &out)
	return status, out.Error.Code
}

func activateRaw(base, code, deviceUUID string) (int, string) {
	raw, _ := json.Marshal(map[string]any{"code": code, "device_uuid": deviceUUID, "platform": "android"})
	req, _ := http.NewRequest(http.MethodPost, base+"/api/v2/devices/activate", strings.NewReader(string(raw)))
	req.Header.Set("Content-Type", "application/json")
	return newClient().send(req)
}

func getBearer(target, token string) (int, string) {
	req, _ := http.NewRequest(http.MethodGet, target, nil)
	req.Header.Set("Authorization", "Bearer "+token)
	return newClient().send(req)
}

func mustParse(raw string) *url.URL {
	u, err := url.Parse(raw)
	if err != nil {
		return &url.URL{}
	}
	return u
}

// html undoes the entity escaping templ applies inside an attribute value.
func html(s string) string {
	return strings.NewReplacer("&amp;", "&", "&#34;", `"`, "&#39;", "'", "&lt;", "<", "&gt;", ">").Replace(s)
}

func firstMatch(re *regexp.Regexp, body string) string {
	if m := re.FindStringSubmatch(body); len(m) > 1 {
		return m[1]
	}
	return ""
}

func allMatches(re *regexp.Regexp, body string) []string {
	var out []string
	for _, m := range re.FindAllStringSubmatch(body, -1) {
		out = append(out, m[1])
	}
	return out
}

func truncate(s string) string {
	if len(s) > 300 {
		return s[:300] + "…"
	}
	return s
}

func check(name string, ok bool, format string, args ...any) {
	if ok {
		fmt.Printf("  PASS  %s\n", name)
		return
	}
	failures++
	fmt.Printf("  FAIL  %s: %s\n", name, fmt.Sprintf(format, args...))
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
