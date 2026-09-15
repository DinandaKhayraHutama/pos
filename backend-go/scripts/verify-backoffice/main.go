// Command verify-backoffice drives the real Backoffice against a running
// server: it signs in through the actual form, issues an activation code the
// way an Owner would, and then activates a device with that code through the
// device API.
//
// That last step is the point. A unit test can prove each half works; only this
// proves the panel and the till agree about the same credential.
//
// It creates a disposable merchant and deletes it in a defer.
//
//	justclick serve &
//	go run ./scripts/verify-backoffice
package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"os"
	"regexp"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/auth"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/staff"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/tenancy"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/redisx"
)

var (
	failures  int
	csrfRE    = regexp.MustCompile(`name="gorilla\.csrf\.Token" value="([^"]+)"`)
	codeRE    = regexp.MustCompile(`<div class="code">([A-Z2-9]{12})</div>`)
	deviceRE  = regexp.MustCompile(`id="device-([0-9a-f-]{36})"`)
	ownerPass = "verify-owner-password-1"
	cashPass  = "verify-cashier-password-1"
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
	baseURL := envOr("VERIFY_BASE_URL", "http://127.0.0.1:9000")

	// Seeding and cleanup run on the owner credential, the way a platform tool
	// would; provisioning gets the same two pools the server uses.
	pool, err := pgxpool.New(ctx, os.Getenv("MIGRATE_DATABASE_URL"))
	if err != nil {
		return err
	}
	defer pool.Close()

	pools, err := pg.OpenPools(ctx, os.Getenv("DATABASE_URL"), os.Getenv("UNSCOPED_DATABASE_URL"))
	if err != nil {
		return err
	}
	defer pools.Close()

	slug := fmt.Sprintf("vbo-%d", time.Now().UnixNano())
	ownerEmail := slug + "-owner@justclick.test"
	cashierEmail := slug + "-cashier@justclick.test"

	provisioned, err := tenancy.Provision(ctx, pools, tenancy.Input{
		BusinessName:  "Verify Backoffice",
		Slug:          slug,
		OwnerName:     "Owner Verify",
		OwnerEmail:    ownerEmail,
		OwnerPassword: ownerPass,
	})
	if err != nil {
		return err
	}
	defer func() {
		if _, err := pool.Exec(context.Background(),
			`DELETE FROM tenants WHERE id = $1`, provisioned.TenantID); err != nil {
			fmt.Fprintln(os.Stderr, "cleanup failed:", err)
		}
	}()

	outletID, registerID, err := seedInfrastructure(ctx, pool, provisioned.TenantID)
	if err != nil {
		return err
	}
	if err := seedCashier(ctx, pool, provisioned.TenantID, cashierEmail); err != nil {
		return err
	}
	_ = outletID

	jar, _ := cookiejar.New(nil)
	client := &http.Client{
		Jar:     jar,
		Timeout: 10 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}

	// Caddy issues from its own local CA in development, which no system trust
	// store knows about. Only ever set this against localhost.
	if os.Getenv("VERIFY_INSECURE_TLS") == "1" {
		client.Transport = &http.Transport{
			TLSClientConfig: &tls.Config{InsecureSkipVerify: true}, //nolint:gosec // dev-only, localhost
		}
	}

	status, _ := get(client, baseURL+"/backoffice/devices", "")
	check("an anonymous visitor is sent to the login form",
		status == http.StatusSeeOther, "got %d", status)

	status, body := get(client, baseURL+"/backoffice/login", "")
	check("login form renders", status == http.StatusOK, "got %d", status)
	token := firstMatch(csrfRE, body)
	check("login form carries a CSRF token", token != "", "no token in the form")

	status, _ = postForm(client, baseURL+"/backoffice/login", token, url.Values{
		"email": {ownerEmail}, "password": {"wrong-password"},
	})
	check("a wrong password is refused", status == http.StatusUnauthorized, "got %d", status)

	status, _ = postForm(client, baseURL+"/backoffice/login", token, url.Values{
		"email": {ownerEmail}, "password": {ownerPass},
	})
	check("the Owner signs in", status == http.StatusSeeOther, "got %d", status)

	status, _ = postHX(client, baseURL+"/backoffice/registers/"+registerID+"/activation-code", "")
	check("a state-changing request with no CSRF token is refused",
		status == http.StatusForbidden, "got %d", status)

	status, body = get(client, baseURL+"/backoffice/devices", "")
	check("the devices page renders for the Owner", status == http.StatusOK, "got %d", status)
	check("the seeded till is listed", strings.Contains(body, "Kasir Verify"), "register not shown")
	token = firstMatch(csrfRE, body)

	status, body = postHX(client, baseURL+"/backoffice/registers/"+registerID+"/activation-code", token)
	check("an activation code is issued", status == http.StatusOK, "got %d: %s", status, truncate(body))
	code := firstMatch(codeRE, body)
	check("the issued code is shown once, in plaintext", code != "", "no code in the fragment")
	check("the fragment says the code is not stored",
		strings.Contains(body, "tidak disimpan"), "missing the warning")

	// Activation is rate limited per source address, and verify-activation
	// deliberately spends that allowance testing 429. Start this phase from a
	// clean bucket so the two scripts can run back to back.
	clearActivationLimiter(ctx)

	// The real proof: a code minted in the browser activates a till.
	status, actBody := postJSON(client, baseURL+"/api/v2/devices/activate", map[string]any{
		"code": code, "device_uuid": "verify-backoffice-tablet", "platform": "android",
	})
	check("the browser-issued code activates a device", status == http.StatusOK,
		"got %d: %s", status, truncate(string(actBody)))

	var activated struct {
		Data struct {
			Token string `json:"token"`
		} `json:"data"`
	}
	json.Unmarshal(actBody, &activated)
	check("activation returned a token", activated.Data.Token != "", "empty token")

	status, body = get(client, baseURL+"/backoffice/devices", "")
	deviceID := firstMatch(deviceRE, body)
	check("device list reload succeeds", status == http.StatusOK, "got %d", status)
	check("the new device appears in the panel", deviceID != "", "device row not found")
	token = firstMatch(csrfRE, body)

	status, body = postHX(client, baseURL+"/backoffice/devices/"+deviceID+"/revoke", token)
	check("revoke returns the updated row", status == http.StatusOK, "got %d", status)
	check("the row now reads revoked", strings.Contains(body, "dicabut"), "got %s", truncate(body))

	status, _ = getBearer(client, baseURL+"/api/v2/devices/me", activated.Data.Token)
	check("the revoked token stops working immediately",
		status == http.StatusUnauthorized, "got %d", status)

	status, _ = postForm(client, baseURL+"/backoffice/logout", token, url.Values{})
	check("logout succeeds", status == http.StatusSeeOther, "got %d", status)

	status, _ = get(client, baseURL+"/backoffice/devices", "")
	check("the panel is closed after logout", status == http.StatusSeeOther, "got %d", status)

	// A cashier with a real password still must not reach the panel: the gate
	// is the role, not a missing credential.
	_, body = get(client, baseURL+"/backoffice/login", "")
	token = firstMatch(csrfRE, body)
	status, _ = postForm(client, baseURL+"/backoffice/login", token, url.Values{
		"email": {cashierEmail}, "password": {cashPass},
	})
	check("a cashier cannot sign in to the Backoffice",
		status == http.StatusUnauthorized, "got %d", status)

	return nil
}

func clearActivationLimiter(ctx context.Context) {
	rdb, err := redisx.Open(ctx, os.Getenv("REDIS_URL"))
	if err != nil {
		return
	}
	defer rdb.Close()

	iter := rdb.Scan(ctx, 0, "rl:act:*", 100).Iterator()
	for iter.Next(ctx) {
		rdb.Del(ctx, iter.Val())
	}
}

func seedInfrastructure(ctx context.Context, pool *pgxpool.Pool, tenantID string) (outletID, registerID string, err error) {
	if err = pool.QueryRow(ctx,
		`INSERT INTO outlets (tenant_id, name) VALUES ($1, 'Outlet Verify') RETURNING id`,
		tenantID).Scan(&outletID); err != nil {
		return
	}

	err = pool.QueryRow(ctx,
		`INSERT INTO pos_registers (tenant_id, outlet_id, name) VALUES ($1, $2, 'Kasir Verify') RETURNING id`,
		tenantID, outletID).Scan(&registerID)
	return
}

func seedCashier(ctx context.Context, pool *pgxpool.Pool, tenantID, email string) error {
	hash, err := staff.HashPassword(cashPass)
	if err != nil {
		return err
	}

	_, err = pool.Exec(ctx, `
		INSERT INTO employees (tenant_id, name, email, password, role, active)
		VALUES ($1, 'Kasir Verify', $2, $3, $4, true)`,
		tenantID, email, hash, string(auth.Cashier))
	return err
}

func get(c *http.Client, target, _ string) (int, string) {
	req, _ := http.NewRequest(http.MethodGet, target, nil)
	return send(c, req)
}

func getBearer(c *http.Client, target, token string) (int, string) {
	req, _ := http.NewRequest(http.MethodGet, target, nil)
	req.Header.Set("Authorization", "Bearer "+token)
	return send(c, req)
}

func postForm(c *http.Client, target, csrfToken string, values url.Values) (int, string) {
	values.Set("gorilla.csrf.Token", csrfToken)

	req, _ := http.NewRequest(http.MethodPost, target, strings.NewReader(values.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	browserHeaders(req)
	return send(c, req)
}

// postHX mimics what HTMX sends: the token as a header, taken from hx-headers
// on <body>, rather than as a form field.
func postHX(c *http.Client, target, csrfToken string) (int, string) {
	req, _ := http.NewRequest(http.MethodPost, target, nil)
	req.Header.Set("X-CSRF-Token", csrfToken)
	req.Header.Set("HX-Request", "true")
	browserHeaders(req)
	return send(c, req)
}

// browserHeaders supplies what a real browser sends on a same-origin POST.
// Without them the CSRF middleware refuses the request before it ever reaches
// a handler — correctly, since a missing Origin is how a cross-site post
// arrives.
func browserHeaders(req *http.Request) {
	origin := req.URL.Scheme + "://" + req.URL.Host
	req.Header.Set("Origin", origin)
	req.Header.Set("Referer", origin+"/backoffice/")
}

func postJSON(c *http.Client, target string, body map[string]any) (int, []byte) {
	raw, _ := json.Marshal(body)
	req, _ := http.NewRequest(http.MethodPost, target, bytes.NewReader(raw))
	req.Header.Set("Content-Type", "application/json")

	status, text := send(c, req)
	return status, []byte(text)
}

func send(c *http.Client, req *http.Request) (int, string) {
	resp, err := c.Do(req)
	if err != nil {
		return 0, err.Error()
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(body)
}

func firstMatch(re *regexp.Regexp, body string) string {
	if m := re.FindStringSubmatch(body); len(m) > 1 {
		return m[1]
	}
	return ""
}

func truncate(s string) string {
	if len(s) > 200 {
		return s[:200] + "…"
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
