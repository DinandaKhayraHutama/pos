// Command verify-history drives the Fase 1 paritas surfaces over real HTTP:
// the extended till receipt history, the two till report endpoints, and the
// read-only Backoffice transaction and shift screens.
//
// Unit tests exercise the domain services directly. This script exercises what
// a tablet and a browser actually touch — the handlers, the cashier-token
// header, the permission split, the status codes and the rendered HTML — which
// is where the two failures that matter most live:
//
//   - a scope or a period somebody may not have, quietly NARROWED instead of
//     refused, so a list looks empty rather than forbidden;
//   - cost and profit reaching an account that may not see them, through JSON
//     or through a page.
//
// Credentials and financial payloads are never printed.
package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"os"
	"regexp"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"golang.org/x/crypto/bcrypt"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/devices"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/httpapi/wire"
)

var (
	failures int
	csrfRE   = regexp.MustCompile(`name="gorilla\.csrf\.Token" value="([^"]+)"`)
)

func check(name string, ok bool, format string, args ...any) {
	if ok {
		fmt.Println("  PASS ", name)
		return
	}
	failures++
	fmt.Printf("  FAIL  %s: %s\n", name, fmt.Sprintf(format, args...))
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if failures > 0 {
		fmt.Printf("\n%d check(s) FAILED\n", failures)
		os.Exit(1)
	}
	fmt.Println("\nall history checks passed")
}

func uuid() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(err)
	}
	b[6], b[8] = (b[6]&15)|64, (b[8]&63)|128
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[:4], b[4:6], b[6:8], b[8:10], b[10:])
}

func baseURL() string {
	if base := os.Getenv("VERIFY_BASE_URL"); base != "" {
		return base
	}
	return "http://127.0.0.1:9000"
}

func newClient() *http.Client {
	client := &http.Client{Timeout: 30 * time.Second}
	if os.Getenv("VERIFY_INSECURE_TLS") == "1" {
		// Caddy issues from its own local CA in development. localhost only.
		client.Transport = &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true}} //nolint:gosec
	}
	return client
}

// ---- the till side ----------------------------------------------------------

type till struct {
	client  *http.Client
	token   string
	cashier string
}

func (t till) get(path string) (int, http.Header, map[string]any) {
	req, err := http.NewRequest(http.MethodGet, baseURL()+path, nil)
	if err != nil {
		panic(err)
	}
	req.Header.Set("Authorization", "Bearer "+t.token)
	req.Header.Set("X-Schema-Version", "1")
	if t.cashier != "" {
		req.Header.Set("X-Cashier-Token", t.cashier)
	}
	resp, err := t.client.Do(req)
	if err != nil {
		panic(err)
	}
	defer resp.Body.Close()
	var out map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&out)
	return resp.StatusCode, resp.Header, out
}

func (t till) post(path string, body any) (int, map[string]any) {
	payload, err := json.Marshal(body)
	if err != nil {
		panic(err)
	}
	req, err := http.NewRequest(http.MethodPost, baseURL()+path, bytes.NewReader(payload))
	if err != nil {
		panic(err)
	}
	req.Header.Set("Authorization", "Bearer "+t.token)
	req.Header.Set("X-Schema-Version", "1")
	req.Header.Set("Content-Type", "application/json")
	if t.cashier != "" {
		req.Header.Set("X-Cashier-Token", t.cashier)
	}
	resp, err := t.client.Do(req)
	if err != nil {
		panic(err)
	}
	defer resp.Body.Close()
	var out map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&out)
	return resp.StatusCode, out
}

func data(body map[string]any) map[string]any {
	d, _ := body["data"].(map[string]any)
	return d
}

func errorCode(body map[string]any) string {
	e, ok := body["error"].(map[string]any)
	if !ok {
		return ""
	}
	code, _ := e["code"].(string)
	return code
}

func rows(body map[string]any) []map[string]any {
	raw, _ := data(body)["rows"].([]any)
	out := make([]map[string]any, 0, len(raw))
	for _, r := range raw {
		if row, ok := r.(map[string]any); ok {
			out = append(out, row)
		}
	}
	return out
}

func money(section map[string]any, key string) int64 {
	v, _ := section[key].(float64)
	return int64(v)
}

// ---- the panel side ---------------------------------------------------------

type session struct {
	client *http.Client
	csrf   string
}

func signIn(email, password string) (*session, error) {
	jar, err := cookiejar.New(nil)
	if err != nil {
		return nil, err
	}
	client := newClient()
	client.Jar = jar
	client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }

	s := &session{client: client}
	_, body := s.get("/backoffice/login")
	s.csrf = firstMatch(csrfRE, body)

	form := url.Values{"email": {email}, "password": {password}, "gorilla.csrf.Token": {s.csrf}}
	req, _ := http.NewRequest(http.MethodPost, baseURL()+"/backoffice/login", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	origin := req.URL.Scheme + "://" + req.URL.Host
	req.Header.Set("Origin", origin)
	req.Header.Set("Referer", origin+"/backoffice/")
	resp, err := s.client.Do(req)
	if err != nil {
		return nil, err
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusSeeOther {
		return nil, fmt.Errorf("sign in as %s: got %d", email, resp.StatusCode)
	}
	return s, nil
}

func (s *session) get(path string) (int, string) {
	req, _ := http.NewRequest(http.MethodGet, baseURL()+path, nil)
	resp, err := s.client.Do(req)
	if err != nil {
		panic(err)
	}
	defer resp.Body.Close()
	var buf bytes.Buffer
	_, _ = buf.ReadFrom(resp.Body)
	return resp.StatusCode, buf.String()
}

func firstMatch(re *regexp.Regexp, body string) string {
	if m := re.FindStringSubmatch(body); len(m) == 2 {
		return m[1]
	}
	return ""
}

// ---- the fixture ------------------------------------------------------------

// fixture is one disposable merchant: two branches, two tills in the first,
// a cashier, a manager and an owner. Everything it creates is deleted on the
// way out, so the script can run against a database that holds real data.
type fixture struct {
	pool                             *pgxpool.Pool
	tenant, outletA, outletB         string
	registerA1, registerA2           string
	cashier, manager, owner          string
	cashierName                      string
	product, category                string
	ownerEmail, managerEmail, secret string
}

const pin = "2468"

func provision(ctx context.Context, pool *pgxpool.Pool) (*fixture, error) {
	f := &fixture{
		pool: pool, tenant: uuid(), outletA: uuid(), outletB: uuid(),
		registerA1: uuid(), registerA2: uuid(), cashierName: "Sari",
		secret: "verify-history-" + uuid(),
	}
	f.ownerEmail = "owner-" + f.tenant + "@verify.local"
	f.managerEmail = "manager-" + f.tenant + "@verify.local"

	exec := func(sql string, args ...any) error {
		_, err := pool.Exec(ctx, sql, args...)
		return err
	}
	if err := exec("INSERT INTO tenants(id,name,slug) VALUES($1::uuid,'History verification',$1::uuid::text)", f.tenant); err != nil {
		return nil, err
	}
	if err := exec("INSERT INTO outlets(id,tenant_id,name) VALUES($1,$2,'Kemang')", f.outletA, f.tenant); err != nil {
		return nil, err
	}
	if err := exec("INSERT INTO outlets(id,tenant_id,name) VALUES($1,$2,'Bintaro')", f.outletB, f.tenant); err != nil {
		return nil, err
	}
	if err := exec("INSERT INTO pos_registers(id,tenant_id,outlet_id,name) VALUES($1,$2,$3,'Kasir 1')", f.registerA1, f.tenant, f.outletA); err != nil {
		return nil, err
	}
	if err := exec("INSERT INTO pos_registers(id,tenant_id,outlet_id,name) VALUES($1,$2,$3,'Kasir 2')", f.registerA2, f.tenant, f.outletA); err != nil {
		return nil, err
	}

	pinHash, err := bcrypt.GenerateFromPassword([]byte(pin), 10)
	if err != nil {
		return nil, err
	}
	password, err := bcrypt.GenerateFromPassword([]byte(f.secret), 10)
	if err != nil {
		return nil, err
	}
	if err := pool.QueryRow(ctx,
		"INSERT INTO employees(tenant_id,name,role,pin_hash) VALUES($1,$2,'cashier',$3) RETURNING id::text",
		f.tenant, f.cashierName, string(pinHash)).Scan(&f.cashier); err != nil {
		return nil, err
	}
	// The manager and owner hold a PIN too: the report endpoints take a cashier
	// token, and somebody has to be able to mint one for an account that may
	// actually read a report.
	if err := pool.QueryRow(ctx,
		"INSERT INTO employees(tenant_id,name,role,pin_hash,email,password) VALUES($1,'Mira','manager',$2,$3,$4) RETURNING id::text",
		f.tenant, string(pinHash), f.managerEmail, string(password)).Scan(&f.manager); err != nil {
		return nil, err
	}
	if err := pool.QueryRow(ctx,
		"INSERT INTO employees(tenant_id,name,role,pin_hash,email,password) VALUES($1,'Farhan','owner',$2,$3,$4) RETURNING id::text",
		f.tenant, string(pinHash), f.ownerEmail, string(password)).Scan(&f.owner); err != nil {
		return nil, err
	}
	if err := pool.QueryRow(ctx, "INSERT INTO categories(tenant_id,name) VALUES($1,'Minuman') RETURNING id::text", f.tenant).Scan(&f.category); err != nil {
		return nil, err
	}
	if err := pool.QueryRow(ctx, "INSERT INTO products(tenant_id,category_id,name,price) VALUES($1,$2,'Kopi',10000) RETURNING id::text", f.tenant, f.category).Scan(&f.product); err != nil {
		return nil, err
	}
	return f, nil
}

func (f *fixture) cleanup() {
	ctx := context.Background()
	// Created by this invocation, never supplied by a user.
	if _, err := f.pool.Exec(ctx, "DELETE FROM jobs.river_job WHERE args->>'tenant_id'=$1", f.tenant); err != nil {
		fmt.Fprintln(os.Stderr, "job cleanup:", err)
	}
	if _, err := f.pool.Exec(ctx, "DELETE FROM tenants WHERE id=$1", f.tenant); err != nil {
		fmt.Fprintln(os.Stderr, "fixture cleanup:", err)
	}
}

func (f *fixture) device(ctx context.Context, outlet, register string) till {
	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		panic(err)
	}
	token := hex.EncodeToString(secret)
	id := uuid()
	if _, err := f.pool.Exec(ctx,
		"INSERT INTO devices(id,tenant_id,outlet_id,pos_register_id,device_uuid,token_sha256,token_expires_at) "+
			"VALUES($1::uuid,$2,$3,$4,$1::uuid::text,$5,now()+interval '1 hour')",
		id, f.tenant, outlet, register, devices.HashToken(token)); err != nil {
		panic(err)
	}
	return till{client: newClient(), token: token}
}

// signInCashier mints a cashier token for an employee on one device.
func (t *till) signInCashier(employee string) error {
	status, body := t.post("/api/v2/till/login", map[string]any{"employee_id": employee, "pin": pin})
	if status != http.StatusOK {
		return fmt.Errorf("till login: got %d %s", status, errorCode(body))
	}
	t.cashier, _ = data(body)["token"].(string)
	return nil
}

func run() error {
	ctx := context.Background()
	pool, err := pgxpool.New(ctx, os.Getenv("MIGRATE_DATABASE_URL"))
	if err != nil {
		return err
	}
	defer pool.Close()

	f, err := provision(ctx, pool)
	if err != nil {
		return err
	}
	defer f.cleanup()

	today := time.Now().UTC()
	yesterday := today.AddDate(0, 0, -1)

	// Two tills in Kemang, so "one outlet" is never accidentally "one till".
	first := f.device(ctx, f.outletA, f.registerA1)
	second := f.device(ctx, f.outletA, f.registerA2)
	if err := first.signInCashier(f.cashier); err != nil {
		return err
	}
	if err := second.signInCashier(f.cashier); err != nil {
		return err
	}

	fmt.Println("selling on two tills across two days")
	// Yesterday's drawer is closed and counted; today's two are still open, so
	// the shifts screen has both states to render.
	if err := f.sell(ctx, first, f.registerA1, yesterday, 2, "RY", true); err != nil {
		return err
	}
	if err := f.sell(ctx, first, f.registerA1, today, 3, "R1", false); err != nil {
		return err
	}
	if err := f.sell(ctx, second, f.registerA2, today, 2, "R2", false); err != nil {
		return err
	}
	check("receipts landed on both tills and both days", true, "")

	verifyHistory(f, first, today, yesterday)
	verifyReports(ctx, f, first)
	return verifyPanel(f)
}

// sell pushes n receipts through the legacy ingest path — no coordinated
// session, so the fixture stays about history rather than about claiming a
// drawer. Each carries a distinct receipt number so the prefix search has
// something to find.
//
// [closed] leaves the drawer counted and shut. Only one may stay open per
// till, and the shifts screen has to show both states, so the caller decides.
func (f *fixture) sell(ctx context.Context, t till, register string, day time.Time, n int, prefix string, closed bool) error {
	session := uuid()
	opened := day.Add(7 * time.Hour).UnixMilli()
	var closedAt, counted *int64
	payload := fmt.Sprintf(`{"id":%q,"revision":1,"employee_name":%q,"opened_at_ms":%d,"opening_cash":0}`,
		session, f.cashierName, opened)
	if closed {
		shut, cash := day.Add(20*time.Hour).UnixMilli(), int64(0)
		closedAt, counted = &shut, &cash
		payload = fmt.Sprintf(
			`{"id":%q,"revision":1,"employee_name":%q,"opened_at_ms":%d,"opening_cash":0,"closed_at_ms":%d,"counted_cash":0,"expected_cash":0}`,
			session, f.cashierName, opened, shut)
	}
	if _, err := f.pool.Exec(ctx,
		"INSERT INTO pos_sessions(id,tenant_id,outlet_id,pos_register_id,device_id,revision,employee_name,"+
			"opened_at_ms,closed_at_ms,opening_cash,counted_cash,expected_cash,payload) "+
			"VALUES($1,$2,$3,$4,(SELECT id FROM devices WHERE tenant_id=$2 AND pos_register_id=$4 LIMIT 1),"+
			"1,$5,$6,$7,0,$8,$8,$9::jsonb)",
		session, f.tenant, f.outletA, register, f.cashierName, opened, closedAt, counted, payload); err != nil {
		return err
	}
	for i := range n {
		status := "paid"
		// One receipt per day is refunded, so the waterfall has a return in it
		// and the status filter has something to narrow to.
		if i == n-1 {
			status = "refunded"
		}
		order := wire.Order{
			Id: uuid(), Revision: 1, BusinessDate: day.Format(time.DateOnly),
			Number:     fmt.Sprintf("%s-%03d", prefix, i+1),
			PlacedAtMs: day.Add(time.Duration(8+i) * time.Hour).UnixMilli(),
			Type:       "dine_in", Status: wire.OrderStatus(status), PosSessionId: session,
			CashierId: &f.cashier, CashierName: f.cashierName,
			Subtotal: 20000, Discount: 2000, Tax: 1800, Total: 19800, AmountPaid: 19800,
			PaymentMethod: "cash",
			Items: []wire.OrderItem{{
				Id: uuid(), ProductId: &f.product, ProductName: "Kopi", CategoryId: &f.category,
				Quantity: 2, UnitPrice: 10000, UnitCost: ptr(int64(4000)),
				Modifiers: []wire.OrderItemModifier{},
			}},
		}
		if status == "refunded" {
			order.AuthorizedBy, order.VoidReason, order.RefundedAmount =
				ptr("Mira"), ptr("Komplain"), ptr(int64(19800))
		}
		code, body := t.post("/api/v2/sync/push", wire.PushRequest{
			Batches: []wire.PushBatch{{Entity: "orders", Rows: []json.RawMessage{mustJSON(order)}}},
		})
		if code != http.StatusOK {
			return fmt.Errorf("push receipt %s: got %d %s", order.Number, code, errorCode(body))
		}
	}
	return nil
}

func ptr[T any](v T) *T { return &v }

func mustJSON(v any) json.RawMessage {
	out, err := json.Marshal(v)
	if err != nil {
		panic(err)
	}
	return out
}

// ---- receipt history --------------------------------------------------------

func verifyHistory(f *fixture, t till, today, yesterday time.Time) {
	fmt.Println("\ntill receipt history")

	// The original contract still works, untouched.
	status, header, body := t.get("/api/v2/till/orders?day=" + today.Format(time.DateOnly))
	check("the legacy day parameter still works", status == http.StatusOK && len(rows(body)) == 3,
		"got %d, %d rows", status, len(rows(body)))
	check("history is never cached", header.Get("Cache-Control") == "no-store",
		"got %q", header.Get("Cache-Control"))
	check("the server echoes the scope it applied", data(body)["scope"] == "register",
		"got %v", data(body)["scope"])

	// Cross-day and outlet-wide history belongs to a manager. A cashier is
	// intentionally held to their own receipts on today's business date; using
	// the cashier token for the range checks below would make the verifier
	// contradict the access rule it checks again later in this function.
	wide := till{client: t.client, token: t.token}
	if err := wide.signInCashier(f.manager); err != nil {
		check("a manager can sign in at the till", false, "%v", err)
		return
	}

	// A range spanning two business days, on this till only.
	status, _, body = wide.get(fmt.Sprintf("/api/v2/till/orders?from=%s&to=%s",
		yesterday.Format(time.DateOnly), today.Format(time.DateOnly)))
	check("a range covers both days on this till", status == http.StatusOK && len(rows(body)) == 5,
		"got %d, %d rows", status, len(rows(body)))
	check("the echoed range is the one asked for",
		data(body)["from"] == yesterday.Format(time.DateOnly) && data(body)["to"] == today.Format(time.DateOnly),
		"got %v..%v", data(body)["from"], data(body)["to"])

	// Newest first, across the day boundary.
	ordered := true
	var previous string
	for _, row := range rows(body) {
		day, _ := row["business_date"].(string)
		if previous != "" && day > previous {
			ordered = false
		}
		previous = day
	}
	check("the page is newest first across the day boundary", ordered, "dates went backwards")

	// Filters.
	status, _, body = wide.get("/api/v2/till/orders?from=" + yesterday.Format(time.DateOnly) +
		"&to=" + today.Format(time.DateOnly) + "&status=refunded")
	check("the status filter narrows to refunds", status == http.StatusOK && len(rows(body)) == 2,
		"got %d, %d rows", status, len(rows(body)))

	status, _, body = wide.get("/api/v2/till/orders?from=" + yesterday.Format(time.DateOnly) +
		"&to=" + today.Format(time.DateOnly) + "&status=sales")
	check("the sales group excludes what was undone", status == http.StatusOK && len(rows(body)) == 3,
		"got %d, %d rows", status, len(rows(body)))

	status, _, body = t.get("/api/v2/till/orders?day=" + today.Format(time.DateOnly) + "&receipt_number=r1-00")
	check("the receipt search matches a prefix, case-insensitively",
		status == http.StatusOK && len(rows(body)) == 3, "got %d, %d rows", status, len(rows(body)))

	status, _, body = t.get("/api/v2/till/orders?day=" + today.Format(time.DateOnly) + "&receipt_number=R1-002")
	check("the receipt search finds one receipt", status == http.StatusOK && len(rows(body)) == 1,
		"got %d, %d rows", status, len(rows(body)))

	// Ambiguity and cursors are refused rather than resolved.
	status, _, body = t.get("/api/v2/till/orders?day=" + today.Format(time.DateOnly) +
		"&from=" + today.Format(time.DateOnly) + "&to=" + today.Format(time.DateOnly))
	check("a day AND a range is refused as ambiguous",
		status == http.StatusConflict && errorCode(body) == "ambiguous_range",
		"got %d %s", status, errorCode(body))

	for _, cursor := range []string{"nonsense", "1700000000000:" + uuid(), "2026-09-22:abc:" + uuid()} {
		status, _, body = t.get("/api/v2/till/orders?day=" + today.Format(time.DateOnly) + "&before=" + url.QueryEscape(cursor))
		check("a hand-edited cursor is refused ("+cursor[:min(9, len(cursor))]+"…)",
			status == http.StatusConflict && errorCode(body) == "invalid_cursor",
			"got %d %s", status, errorCode(body))
	}

	status, _, body = t.get("/api/v2/till/orders?day=" + today.Format(time.DateOnly) + "&scope=nowhere")
	check("an unknown scope is refused", status == http.StatusConflict && errorCode(body) == "invalid_scope",
		"got %d %s", status, errorCode(body))

	// A cashier is held to their own till, their own day and their own name —
	// and TOLD so, rather than handed a narrower list with no label.
	status, _, body = t.get("/api/v2/till/orders?day=" + today.Format(time.DateOnly) + "&scope=outlet")
	check("a cashier may not widen to the whole outlet",
		status == http.StatusConflict && errorCode(body) == "forbidden_scope",
		"got %d %s", status, errorCode(body))

	status, _, body = t.get(fmt.Sprintf("/api/v2/till/orders?from=%s&to=%s",
		yesterday.Format(time.DateOnly), yesterday.Format(time.DateOnly)))
	check("a cashier may not read another day",
		status == http.StatusConflict && errorCode(body) == "forbidden_range",
		"got %d %s", status, errorCode(body))

	status, _, body = t.get("/api/v2/till/orders?day=" + today.Format(time.DateOnly) + "&cashier_id=" + uuid())
	check("a cashier may not name a colleague",
		status == http.StatusConflict && errorCode(body) == "forbidden_cashier",
		"got %d %s", status, errorCode(body))

	// A manager signed in at the same till sees the whole branch.
	status, _, body = wide.get(fmt.Sprintf("/api/v2/till/orders?from=%s&to=%s&scope=outlet",
		yesterday.Format(time.DateOnly), today.Format(time.DateOnly)))
	check("a manager reads every till in the branch",
		status == http.StatusOK && len(rows(body)) == 7 && data(body)["scope"] == "outlet",
		"got %d, %d rows, scope %v", status, len(rows(body)), data(body)["scope"])

	// Paging: the cursor walks the whole set without repeating or skipping.
	seen := map[string]bool{}
	cursor, pages, duplicates := "", 0, 0
	for pages < 10 {
		path := fmt.Sprintf("/api/v2/till/orders?from=%s&to=%s&scope=outlet",
			yesterday.Format(time.DateOnly), today.Format(time.DateOnly))
		if cursor != "" {
			path += "&before=" + url.QueryEscape(cursor)
		}
		status, _, body = wide.get(path)
		if status != http.StatusOK {
			check("paging stays healthy", false, "got %d %s", status, errorCode(body))
			return
		}
		for _, row := range rows(body) {
			id, _ := row["id"].(string)
			if seen[id] {
				duplicates++
			}
			seen[id] = true
		}
		pages++
		next, _ := data(body)["next"].(string)
		if next == "" {
			break
		}
		cursor = next
	}
	check("paging reaches every receipt exactly once", len(seen) == 7 && duplicates == 0,
		"%d receipts, %d duplicates, %d pages", len(seen), duplicates, pages)
}

// ---- the two report endpoints -----------------------------------------------

func verifyReports(ctx context.Context, f *fixture, t till) {
	fmt.Println("\ntill reports")

	// The rollups have to exist before a report can read them. Marking and
	// recomputing is the worker's job; here it is forced so the script does not
	// depend on job timing.
	if err := f.recompute(ctx); err != nil {
		check("the slices were recomputed", false, "%v", err)
		return
	}

	today := time.Now().UTC().Format(time.DateOnly)
	rangeQuery := fmt.Sprintf("?period=custom&from=%s&to=%s", today, today)

	cashier := till{client: t.client, token: t.token, cashier: t.cashier}
	status, _, body := cashier.get("/api/v2/till/reports/summary" + rangeQuery)
	check("a cashier may not open the summary", status == http.StatusForbidden,
		"got %d %s", status, errorCode(body))

	manager := till{client: t.client, token: t.token}
	if err := manager.signInCashier(f.manager); err != nil {
		check("the manager signed in", false, "%v", err)
		return
	}
	status, header, body := manager.get("/api/v2/till/reports/summary" + rangeQuery)
	check("a manager reads the summary", status == http.StatusOK, "got %d %s", status, errorCode(body))
	check("a report is never cached", header.Get("Cache-Control") == "no-store",
		"got %q", header.Get("Cache-Control"))

	// The heart of it: cost and profit are ABSENT from the manager's body, not
	// zeroed. A zero would still be a figure somebody could read.
	summary := data(body)
	_, hasProfit := summary["profit"]
	products, hasProducts := summary["by_product"].([]any)
	cashiers, hasCashiers := summary["by_cashier"].([]any)
	categories, hasCategories := summary["by_category"].([]any)
	check("the summary carries no profit section at all", !hasProfit, "profit was present")
	check("the summary carries the non-financial product breakdown", hasProducts && len(products) > 0,
		"by_product was absent or empty")
	check("the summary carries the cashier breakdown", hasCashiers && len(cashiers) > 0,
		"by_cashier was absent or empty")
	check("the summary carries the category breakdown", hasCategories && len(categories) > 0,
		"by_category was absent or empty")
	raw, _ := json.Marshal(body)
	check("the summary body mentions no cost anywhere",
		!strings.Contains(string(raw), "cost_of_goods") && !strings.Contains(string(raw), "gross_profit"),
		"a cost key leaked into the body")

	status, _, body = manager.get("/api/v2/till/reports/sales" + rangeQuery)
	check("a manager may not open the financial report", status == http.StatusForbidden,
		"got %d %s", status, errorCode(body))

	// The waterfall, on the figures this fixture actually rang up: five
	// receipts today at Kemang, 20000 less 2000 each, one of them refunded.
	sales, _ := summary["sales"].(map[string]any)
	gross, discounts := money(sales, "gross_sales"), money(sales, "discounts")
	returns, net := money(sales, "sales_returns"), money(sales, "net_sales")
	tax, revenue := money(sales, "tax"), money(sales, "revenue")
	check("the waterfall closes", gross-discounts-returns == net,
		"%d - %d - %d != %d", gross, discounts, returns, net)
	check("receipts are net sales plus tax", net+tax+money(sales, "service_charge") == revenue,
		"%d + %d != %d", net, tax, revenue)
	check("the report says which rules produced it", summary["calculation_version"] == float64(2),
		"got %v", summary["calculation_version"])
	check("the report says when it was computed", summary["computed_at_ms"] != nil, "no computation time")
	check("the report names its scope",
		summary["scope"] != nil && summary["period"] != nil && summary["timezone"] != "",
		"scope/period/timezone missing")

	owner := till{client: t.client, token: t.token}
	if err := owner.signInCashier(f.owner); err != nil {
		check("the owner signed in", false, "%v", err)
		return
	}
	status, _, body = owner.get("/api/v2/till/reports/sales" + rangeQuery)
	full := data(body)
	profit, _ := full["profit"].(map[string]any)
	check("an owner reads the financial report", status == http.StatusOK && profit != nil,
		"got %d %s", status, errorCode(body))
	if profit != nil {
		check("profit is net sales minus cost, never takings minus cost",
			money(profit, "gross_profit") == net-money(profit, "cost_of_goods"),
			"%d != %d - %d", money(profit, "gross_profit"), net, money(profit, "cost_of_goods"))
	}

	// A period this account may not widen, and a branch of another merchant,
	// are both refused rather than quietly narrowed to something safe.
	status, _, body = manager.get("/api/v2/till/reports/summary" + rangeQuery + "&outlet_id=" + uuid())
	check("an unknown outlet is refused", status == http.StatusBadRequest,
		"got %d %s", status, errorCode(body))

	status, _, body = manager.get("/api/v2/till/reports/summary?period=custom&from=2020-01-01&to=" + today)
	check("a range wider than a year is refused", status == http.StatusBadRequest,
		"got %d %s", status, errorCode(body))
}

// recompute marks every slice of the fixture dirty and runs the rollups now,
// so the report reads real figures rather than waiting on the worker.
func (f *fixture) recompute(ctx context.Context) error {
	_, err := f.pool.Exec(ctx, `
		INSERT INTO report_dirty_slices (tenant_id, outlet_id, business_date)
		SELECT DISTINCT tenant_id, outlet_id, business_date FROM orders WHERE tenant_id = $1
		ON CONFLICT (tenant_id, outlet_id, business_date) DO UPDATE
		SET generation = report_dirty_slices.generation + 1, changed_at = now()`, f.tenant)
	if err != nil {
		return err
	}
	// The worker picks these up within its sweep; poll until the markers clear.
	deadline := time.Now().Add(90 * time.Second)
	for time.Now().Before(deadline) {
		var pending int
		if err := f.pool.QueryRow(ctx,
			"SELECT count(*) FROM report_dirty_slices WHERE tenant_id=$1", f.tenant).Scan(&pending); err != nil {
			return err
		}
		if pending == 0 {
			return nil
		}
		time.Sleep(time.Second)
	}
	return fmt.Errorf("the worker did not drain the dirty slices; is `justclick worker` running?")
}

// ---- the Backoffice screens -------------------------------------------------

func verifyPanel(f *fixture) error {
	fmt.Println("\nBackoffice transactions and shifts")

	owner, err := signIn(f.ownerEmail, f.secret)
	if err != nil {
		return err
	}
	manager, err := signIn(f.managerEmail, f.secret)
	if err != nil {
		return err
	}

	today := time.Now().UTC().Format(time.DateOnly)
	yesterday := time.Now().UTC().AddDate(0, 0, -1).Format(time.DateOnly)
	listing := fmt.Sprintf("/backoffice/transactions?from=%s&to=%s", yesterday, today)

	status, page := owner.get(listing)
	check("the transactions page renders", status == http.StatusOK, "got %d", status)
	check("it lists this merchant's receipts", strings.Count(page, "R1-00") >= 3,
		"receipt numbers not on the page")
	check("it says the page totals are per page, not per period",
		strings.Contains(page, "di halaman ini"), "no per-page caveat")

	status, page = owner.get(listing + "&status=refunded")
	check("the status filter narrows the page", status == http.StatusOK && strings.Contains(page, "Refund"),
		"got %d", status)

	// Use the Backoffice form's own query key. `receipt_number` belongs to the
	// device API; accepting it here would make the verifier exercise a filter
	// the browser never emits.
	status, page = owner.get(listing + "&receipt=R2-001")
	check("the receipt search narrows the page",
		status == http.StatusOK && strings.Contains(page, "R2-001") && !strings.Contains(page, "R1-001"),
		"got %d", status)

	status, _ = owner.get(listing + "&cursor=nonsense")
	check("a hand-edited cursor does not crash the page", status == http.StatusOK, "got %d", status)

	status, _ = owner.get("/backoffice/transactions/00000000-0000-0000-0000-000000000000")
	check("an unknown transaction is a 404, not a 500", status == http.StatusNotFound, "got %d", status)
	status, _ = owner.get("/backoffice/transactions/not-a-uuid")
	check("a malformed transaction id is a 404, not a 500", status == http.StatusNotFound, "got %d", status)

	status, page = owner.get(fmt.Sprintf("/backoffice/shifts?from=%s&to=%s", yesterday, today))
	check("the shifts page renders", status == http.StatusOK, "got %d", status)
	check("it says the period filters the OPENING time",
		strings.Contains(page, "waktu BUKA laci"), "no opening-time caveat")
	check("it lists the fixture's drawers", strings.Contains(page, "Kasir 1") && strings.Contains(page, "Kasir 2"),
		"tills not on the page")

	status, _ = owner.get("/backoffice/shifts/00000000-0000-0000-0000-000000000000")
	check("an unknown shift is a 404, not a 500", status == http.StatusNotFound, "got %d", status)

	// A manager runs the floor and may read both screens; what they may NOT
	// have is the merchant's buying price, and the dashboard is where the
	// figures live.
	status, _ = manager.get(listing)
	check("a manager may read transactions", status == http.StatusOK, "got %d", status)
	status, _ = manager.get(fmt.Sprintf("/backoffice/shifts?from=%s&to=%s", yesterday, today))
	check("a manager may read shifts", status == http.StatusOK, "got %d", status)

	status, page = manager.get("/backoffice/dashboard?period=today")
	check("a manager may read the dashboard", status == http.StatusOK, "got %d", status)
	check("the dashboard withholds cost and profit from a manager",
		!strings.Contains(page, "Laba kotor") && !strings.Contains(page, "Margin kotor"),
		"a profit figure reached the manager's HTML")
	check("and still gives them the sales picture",
		strings.Contains(page, "Penjualan bersih"), "no net sales on the manager's dashboard")

	status, _ = manager.get("/backoffice/reports")
	check("a manager may not open the financial report", status == http.StatusForbidden, "got %d", status)

	status, page = owner.get("/backoffice/dashboard?period=today")
	check("an owner sees the profit tiles", status == http.StatusOK && strings.Contains(page, "Laba kotor"),
		"got %d", status)
	check("the dashboard compares against the previous period",
		strings.Contains(page, "periode sebelumnya"), "no comparison line")
	return nil
}
