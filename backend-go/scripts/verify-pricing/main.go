// Command verify-pricing is the Fase 3 gate over real HTTP: business settings,
// the device capability gate in front of version 2 pricing, and version 2
// receipts through ingest and into the reports.
//
//   - a till's X-Device-Capabilities header is recorded on its device, and an
//     absent header leaves an old build's set empty;
//   - the owner saves the business settings in the Backoffice, and switching an
//     outlet to v2 pricing is refused while a till there cannot run it, then
//     allowed once that till is gone;
//   - a version 2 receipt priced by the shared engine is accepted and stored
//     with its included tax and rounding; one whose snapshot does not reproduce
//     its figures is accepted and FLAGGED, never refused; one whose lines do
//     not close, and a legacy receipt carrying included tax, are refused;
//   - the report reads those receipts back with a waterfall that closes:
//     gross − discounts − returns − included tax = net, and revenue is net plus
//     tax, service charge and rounding.
//
// It provisions a disposable merchant and deletes it in a defer. The report
// step needs the rollup worker (`justclick worker`).
//
//	go run ./scripts/verify-pricing
package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"os"
	"regexp"
	"slices"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"golang.org/x/crypto/bcrypt"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/devices"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/pricing"
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
	fmt.Println("\nall pricing checks passed")
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
		return strings.TrimRight(base, "/")
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

func ptr[T any](v T) *T { return &v }

// ---- the till ---------------------------------------------------------------

type till struct {
	id, token, cashier string
	capabilities       string
	client             *http.Client
}

func (t till) do(method, path string, body any) (int, map[string]any) {
	var reader io.Reader
	if body != nil {
		payload, err := json.Marshal(body)
		if err != nil {
			panic(err)
		}
		reader = bytes.NewReader(payload)
	}
	req, err := http.NewRequest(method, baseURL()+path, reader)
	if err != nil {
		panic(err)
	}
	req.Header.Set("Authorization", "Bearer "+t.token)
	req.Header.Set("X-Schema-Version", "1")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if t.capabilities != "" {
		req.Header.Set("X-Device-Capabilities", t.capabilities)
	}
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
	e, _ := body["error"].(map[string]any)
	code, _ := e["code"].(string)
	return code
}

func money(section map[string]any, key string) int64 {
	v, _ := section[key].(float64)
	return int64(v)
}

// push sends one receipt and returns how the server answered that row.
func (t till) push(order wire.Order) (status, code string) {
	row, err := json.Marshal(order)
	if err != nil {
		panic(err)
	}
	httpStatus, body := t.do(http.MethodPost, "/api/v2/sync/push", wire.PushRequest{
		Batches: []wire.PushBatch{{Entity: "orders", Rows: []json.RawMessage{row}}},
	})
	if httpStatus != http.StatusOK {
		return fmt.Sprintf("http %d", httpStatus), errorCode(body)
	}
	results, _ := data(body)["results"].([]any)
	if results == nil {
		results, _ = body["results"].([]any)
	}
	if len(results) != 1 {
		return "no result", ""
	}
	result, _ := results[0].(map[string]any)
	status, _ = result["status"].(string)
	code, _ = result["code"].(string)
	return status, code
}

// ---- the Backoffice ---------------------------------------------------------

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
	s.get("/backoffice/login")
	form := url.Values{"email": {email}, "password": {password}, "gorilla.csrf.Token": {s.csrf}}
	status, _ := s.send(http.MethodPost, "/backoffice/login", form, false)
	if status != http.StatusSeeOther {
		return nil, fmt.Errorf("sign in as %s: got %d", email, status)
	}
	return s, nil
}

func (s *session) get(path string) (int, string) {
	return s.send(http.MethodGet, path, nil, false)
}

// post sends what HTMX sends: the form, the token as a header and the
// HX-Request marker.
func (s *session) post(path string, form url.Values) (int, string) {
	return s.send(http.MethodPost, path, form, true)
}

func (s *session) send(method, path string, form url.Values, htmx bool) (int, string) {
	var reader io.Reader
	if form != nil {
		reader = strings.NewReader(form.Encode())
	}
	req, _ := http.NewRequest(method, baseURL()+path, reader)
	if form != nil {
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	}
	if htmx {
		req.Header.Set("X-CSRF-Token", s.csrf)
		req.Header.Set("HX-Request", "true")
	}
	origin := req.URL.Scheme + "://" + req.URL.Host
	req.Header.Set("Origin", origin)
	req.Header.Set("Referer", origin+"/backoffice/")
	resp, err := s.client.Do(req)
	if err != nil {
		return 0, err.Error()
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if m := csrfRE.FindSubmatch(body); len(m) == 2 {
		s.csrf = string(m[1])
	}
	return resp.StatusCode, string(body)
}

// ---- the fixture ------------------------------------------------------------

type fixture struct {
	pool                   *pgxpool.Pool
	tenant, outlet         string
	registerOld, registerN string
	owner, cashier         string
	ownerEmail, secret     string
	coffee, rice, category string
	takeaway               string
}

const pin = "1357"

func provision(ctx context.Context, pool *pgxpool.Pool) (*fixture, error) {
	f := &fixture{
		pool: pool, tenant: uuid(), outlet: uuid(), registerOld: uuid(), registerN: uuid(),
		secret: "verify-pricing-" + uuid(),
	}
	f.ownerEmail = "owner-" + f.tenant + "@verify.local"
	exec := func(sql string, args ...any) error {
		_, err := pool.Exec(ctx, sql, args...)
		return err
	}
	steps := []func() error{
		func() error {
			return exec("INSERT INTO tenants(id,name,slug) VALUES($1::uuid,'Pricing verification',$1::uuid::text)", f.tenant)
		},
		func() error {
			return exec("INSERT INTO outlets(id,tenant_id,name) VALUES($1,$2,'Kemang')", f.outlet, f.tenant)
		},
		func() error {
			return exec("INSERT INTO pos_registers(id,tenant_id,outlet_id,name) VALUES($1,$2,$3,'Kasir lama')", f.registerOld, f.tenant, f.outlet)
		},
		func() error {
			return exec("INSERT INTO pos_registers(id,tenant_id,outlet_id,name) VALUES($1,$2,$3,'Kasir baru')", f.registerN, f.tenant, f.outlet)
		},
	}
	for _, step := range steps {
		if err := step(); err != nil {
			return nil, err
		}
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
		"INSERT INTO employees(tenant_id,name,role,pin_hash) VALUES($1,'Sari','cashier',$2) RETURNING id::text",
		f.tenant, string(pinHash)).Scan(&f.cashier); err != nil {
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
	if err := pool.QueryRow(ctx, "INSERT INTO products(tenant_id,category_id,name,price) VALUES($1,$2,'Kopi Susu',16500) RETURNING id::text", f.tenant, f.category).Scan(&f.coffee); err != nil {
		return nil, err
	}
	if err := pool.QueryRow(ctx, "INSERT INTO products(tenant_id,category_id,name,price) VALUES($1,$2,'Nasi Goreng',27500) RETURNING id::text", f.tenant, f.category).Scan(&f.rice); err != nil {
		return nil, err
	}
	// Seeded with the merchant by the Fase 3 trigger.
	if err := pool.QueryRow(ctx, "SELECT id::text FROM sales_types WHERE tenant_id=$1 AND system_key='takeaway'", f.tenant).Scan(&f.takeaway); err != nil {
		return nil, fmt.Errorf("the system sales types were not seeded: %w", err)
	}
	return f, nil
}

func (f *fixture) cleanup() {
	ctx := context.Background()
	if _, err := f.pool.Exec(ctx, "DELETE FROM jobs.river_job WHERE args->>'tenant_id'=$1", f.tenant); err != nil {
		fmt.Fprintln(os.Stderr, "job cleanup:", err)
	}
	if _, err := f.pool.Exec(ctx, "DELETE FROM tenants WHERE id=$1", f.tenant); err != nil {
		fmt.Fprintln(os.Stderr, "fixture cleanup:", err)
	}
}

func (f *fixture) device(ctx context.Context, register, capabilities string) till {
	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		panic(err)
	}
	token := hex.EncodeToString(secret)
	id := uuid()
	if _, err := f.pool.Exec(ctx,
		"INSERT INTO devices(id,tenant_id,outlet_id,pos_register_id,device_uuid,token_sha256,token_expires_at) "+
			"VALUES($1::uuid,$2,$3,$4,$1::uuid::text,$5,now()+interval '1 hour')",
		id, f.tenant, f.outlet, register, devices.HashToken(token)); err != nil {
		panic(err)
	}
	return till{id: id, token: token, capabilities: capabilities, client: newClient()}
}

func (f *fixture) capabilitiesOf(ctx context.Context, device string) []string {
	var caps []string
	if err := f.pool.QueryRow(ctx, "SELECT capabilities FROM devices WHERE id=$1", device).Scan(&caps); err != nil {
		panic(err)
	}
	return caps
}

func (f *fixture) pricingModel(ctx context.Context) string {
	var model string
	if err := f.pool.QueryRow(ctx,
		"SELECT COALESCE((SELECT pricing_model FROM outlet_settings WHERE tenant_id=$1 AND outlet_id=$2), 'legacy')",
		f.tenant, f.outlet).Scan(&model); err != nil {
		panic(err)
	}
	return model
}

// openSession writes an open drawer for register straight into the table, the
// way verify-history does: this script is about pricing, not about claiming.
func (f *fixture) openSession(ctx context.Context, register string, day time.Time) (string, error) {
	session := uuid()
	opened := day.Add(7 * time.Hour).UnixMilli()
	payload := fmt.Sprintf(`{"id":%q,"revision":1,"employee_name":"Sari","opened_at_ms":%d,"opening_cash":0}`, session, opened)
	_, err := f.pool.Exec(ctx,
		"INSERT INTO pos_sessions(id,tenant_id,outlet_id,pos_register_id,device_id,revision,employee_name,"+
			"opened_at_ms,opening_cash,payload) "+
			"VALUES($1,$2,$3,$4,(SELECT id FROM devices WHERE tenant_id=$2 AND pos_register_id=$4 LIMIT 1),"+
			"1,'Sari',$5,0,$6::jsonb)",
		session, f.tenant, f.outlet, register, opened, payload)
	return session, err
}

// ---- the receipts -----------------------------------------------------------

// v2Receipt prices a takeaway bill with the shared engine: inclusive PB1 10%,
// service 5%, rounding to 100, 10% off the coffee and Rp 1.000 off the bill.
// [snapshotMode] is the rounding mode the receipt CLAIMS it was priced with.
func (f *fixture) v2Receipt(session string, day time.Time, n int, snapshotMode wire.PricingSnapshotRoundingMode) (wire.Order, pricing.Result) {
	in := pricing.Input{
		Version: pricing.VersionV2, TaxMode: pricing.TaxInclusive, ServiceRateBP: 500, ServiceTaxable: true,
		RoundingUnit: 100, RoundingMode: pricing.RoundNearest,
		BillDiscount: &pricing.Discount{Kind: pricing.DiscountAmount, Value: 1000},
		Lines: []pricing.Line{
			{UnitPrice: 16500, Quantity: 2, TaxRateBP: 1000, Discount: &pricing.Discount{Kind: pricing.DiscountPercent, Value: 1000}},
			{UnitPrice: 27500, Quantity: 1, TaxRateBP: 1000},
		},
	}
	res, err := pricing.Compute(in)
	if err != nil {
		panic(err)
	}
	order := wire.Order{
		Id: uuid(), Revision: 1, BusinessDate: day.Format(time.DateOnly),
		Number: fmt.Sprintf("V2-%03d", n), PlacedAtMs: day.Add(time.Duration(9+n) * time.Hour).UnixMilli(),
		Type: "takeaway", Status: "paid", PosSessionId: session,
		CashierId: &f.cashier, CashierName: "Sari",
		Subtotal: res.Subtotal, Discount: res.Discount, Tax: res.Tax, ServiceChargeAmount: res.ServiceCharge,
		Total: res.Total, AmountPaid: res.Total, PaymentMethod: "cash",
		PricingVersion: ptr(2),
		Pricing: &wire.PricingSnapshot{TaxMode: "inclusive", ServiceRateBp: 500, ServiceTaxable: true,
			RoundingUnit: 100, RoundingMode: snapshotMode,
			BillDiscount: &wire.DiscountSpec{Kind: "amount", Value: 1000}},
		TaxIncluded: ptr(res.TaxIncluded), RoundingAmount: ptr(res.Rounding),
		SalesTypeId: &f.takeaway, SalesTypeName: ptr("Takeaway"),
	}
	products := []struct{ id, name string }{{f.coffee, "Kopi Susu"}, {f.rice, "Nasi Goreng"}}
	for i, l := range res.Lines {
		item := wire.OrderItem{
			Id: uuid(), ProductId: &products[i].id, ProductName: products[i].name, CategoryId: &f.category,
			Quantity: int(in.Lines[i].Quantity), UnitPrice: in.Lines[i].UnitPrice, Modifiers: []wire.OrderItemModifier{},
			BasePrice: ptr(in.Lines[i].UnitPrice), PriceSource: ptr(wire.OrderItemPriceSource("base")),
			TaxRateBp:    ptr(int(in.Lines[i].TaxRateBP)),
			LineDiscount: ptr(l.LineDiscount), BillDiscountShare: ptr(l.BillDiscountShare),
			ServiceShare: ptr(l.ServiceShare), TaxAmount: ptr(l.TaxAmount),
			TaxIncluded: ptr(l.TaxIncluded), NetAmount: ptr(l.NetAmount),
		}
		if d := in.Lines[i].Discount; d != nil {
			item.Discount = &wire.DiscountSpec{Kind: wire.DiscountSpecKind(d.Kind), Value: d.Value}
		}
		order.Items = append(order.Items, item)
	}
	return order, res
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

	fmt.Println("device capabilities")
	old := f.device(ctx, f.registerOld, "")
	fresh := f.device(ctx, f.registerN, "pricing-v2, roles-v1, hoverboard")
	status, body := old.do(http.MethodGet, "/api/v2/sync/manifest", nil)
	check("an old build syncs as before", status == http.StatusOK, "got %d %s", status, errorCode(body))
	status, body = fresh.do(http.MethodGet, "/api/v2/sync/manifest", nil)
	check("a Fase 3 build syncs", status == http.StatusOK, "got %d %s", status, errorCode(body))
	check("an absent header records no capability", len(f.capabilitiesOf(ctx, old.id)) == 0,
		"got %v", f.capabilitiesOf(ctx, old.id))
	caps := f.capabilitiesOf(ctx, fresh.id)
	check("the header is recorded, unknown tokens dropped",
		slices.Equal(caps, []string{devices.CapabilityPricingV2, devices.CapabilityRolesV1}), "got %v", caps)
	manifest, _ := json.Marshal(body)
	for _, entity := range []string{"roles", "business_settings", "outlet_settings", "sales_types", "payment_methods", "discounts"} {
		check("the manifest offers "+entity, strings.Contains(string(manifest), `"`+entity+`"`), "absent")
	}

	fmt.Println("\nbusiness settings and the v2 gate")
	owner, err := signIn(f.ownerEmail, f.secret)
	if err != nil {
		return err
	}
	owner.get("/backoffice/settings")
	status, _ = owner.post("/backoffice/settings/business", url.Values{
		"tax_rate": {"10"}, "tax_mode": {"inclusive"}, "service_enabled": {"on"}, "service_rate": {"5"},
		"service_taxable": {"on"}, "rounding_unit": {"100"}, "rounding_mode": {"nearest"},
	})
	var taxBP, serviceBP, unit int
	var mode string
	err = pool.QueryRow(ctx, "SELECT tax_rate_bp, tax_mode, service_rate_bp, rounding_unit FROM business_settings WHERE tenant_id=$1",
		f.tenant).Scan(&taxBP, &mode, &serviceBP, &unit)
	check("the owner saves the business settings", status == http.StatusOK && err == nil &&
		taxBP == 1000 && mode == "inclusive" && serviceBP == 500 && unit == 100,
		"status %d, err %v, got %d %s %d %d", status, err, taxBP, mode, serviceBP, unit)

	owner.get("/backoffice/settings/outlets/" + f.outlet)
	status, page := owner.post("/backoffice/settings/outlets/"+f.outlet+"/pricing", url.Values{"model": {"v2"}})
	check("v2 is refused while a till cannot run it",
		status == http.StatusOK && strings.Contains(page, "belum siap") && f.pricingModel(ctx) == "legacy",
		"status %d, model %s", status, f.pricingModel(ctx))
	if _, err := pool.Exec(ctx, "UPDATE devices SET revoked_at=now() WHERE id=$1", old.id); err != nil {
		return err
	}
	status, _ = owner.post("/backoffice/settings/outlets/"+f.outlet+"/pricing", url.Values{"model": {"v2"}})
	check("v2 is allowed once every till can run it", status == http.StatusOK && f.pricingModel(ctx) == "v2",
		"status %d, model %s", status, f.pricingModel(ctx))

	fmt.Println("\nversion 2 receipts")
	today := time.Now().UTC()
	session, err := f.openSession(ctx, f.registerN, today)
	if err != nil {
		return err
	}
	good, res := f.v2Receipt(session, today, 1, "nearest")
	st, code := fresh.push(good)
	check("a receipt priced by the engine is accepted", st == "accepted", "got %s %s", st, code)
	var included, rounding int64
	var mismatch bool
	err = pool.QueryRow(ctx, "SELECT tax_included, rounding_amount, pricing_mismatch FROM orders WHERE tenant_id=$1 AND id=$2",
		f.tenant, good.Id).Scan(&included, &rounding, &mismatch)
	check("it is stored with its included tax and rounding, unflagged",
		err == nil && included == res.TaxIncluded && rounding == res.Rounding && !mismatch,
		"err %v, got %d %d %v", err, included, rounding, mismatch)

	// Rounded UP it would have come to Rp 100 more than the till charged.
	claimed, _ := f.v2Receipt(session, today, 2, "up")
	st, code = fresh.push(claimed)
	err = pool.QueryRow(ctx, "SELECT pricing_mismatch FROM orders WHERE tenant_id=$1 AND id=$2",
		f.tenant, claimed.Id).Scan(&mismatch)
	check("a snapshot that does not reproduce the figures is accepted and flagged",
		st == "accepted" && err == nil && mismatch, "got %s %s, err %v, flagged %v", st, code, err, mismatch)

	broken, _ := f.v2Receipt(session, today, 3, "nearest")
	*broken.Items[0].NetAmount++
	st, code = fresh.push(broken)
	check("lines that do not close are refused", st == "rejected" && code == "schema_rejected", "got %s %s", st, code)

	legacy, _ := f.v2Receipt(session, today, 4, "nearest")
	legacy.PricingVersion, legacy.Pricing = nil, nil
	st, code = fresh.push(legacy)
	check("a legacy receipt may not carry included tax", st == "rejected" && code == "schema_rejected", "got %s %s", st, code)

	fmt.Println("\nthe report")
	if err := f.recompute(ctx); err != nil {
		check("the slices were recomputed", false, "%v", err)
		return nil
	}
	reader := till{token: fresh.token, client: fresh.client, capabilities: fresh.capabilities}
	status, body = reader.do(http.MethodPost, "/api/v2/till/login", map[string]any{"employee_id": f.owner, "pin": pin})
	if status != http.StatusOK {
		return fmt.Errorf("owner till login: got %d %s", status, errorCode(body))
	}
	reader.cashier, _ = data(body)["token"].(string)
	day := today.Format(time.DateOnly)
	status, body = reader.do(http.MethodGet, fmt.Sprintf("/api/v2/till/reports/sales?period=custom&from=%s&to=%s", day, day), nil)
	report := data(body)
	check("the owner reads the report", status == http.StatusOK, "got %d %s", status, errorCode(body))
	sales, _ := report["sales"].(map[string]any)
	gross, discounts, returns := money(sales, "gross_sales"), money(sales, "discounts"), money(sales, "sales_returns")
	net, tax, service := money(sales, "net_sales"), money(sales, "tax"), money(sales, "service_charge")
	taxIncluded, roundingTotal, revenue := money(sales, "tax_included"), money(sales, "rounding"), money(sales, "revenue")
	check("included tax is reported", taxIncluded == 2*res.TaxIncluded, "got %d want %d", taxIncluded, 2*res.TaxIncluded)
	check("rounding is reported", roundingTotal == 2*res.Rounding, "got %d want %d", roundingTotal, 2*res.Rounding)
	check("the waterfall closes", gross-discounts-returns-taxIncluded == net,
		"%d - %d - %d - %d != %d", gross, discounts, returns, taxIncluded, net)
	check("revenue is net plus tax, service charge and rounding", net+tax+service+roundingTotal == revenue,
		"%d + %d + %d + %d != %d", net, tax, service, roundingTotal, revenue)
	check("net sales are the lines' own net", net == 2*(res.Lines[0].NetAmount+res.Lines[1].NetAmount),
		"got %d", net)
	check("the flagged receipt is counted as an anomaly", money(report, "anomaly_count") >= 1,
		"got %v", report["anomaly_count"])
	bySalesType, _ := report["by_sales_type"].([]any)
	check("sales are grouped by sales type", len(bySalesType) == 1, "got %v", bySalesType)
	return nil
}

// recompute marks the fixture's slices dirty and waits for the worker to roll
// them up.
func (f *fixture) recompute(ctx context.Context) error {
	if _, err := f.pool.Exec(ctx, `
		INSERT INTO report_dirty_slices (tenant_id, outlet_id, business_date)
		SELECT DISTINCT tenant_id, outlet_id, business_date FROM orders WHERE tenant_id = $1
		ON CONFLICT (tenant_id, outlet_id, business_date) DO UPDATE
		SET generation = report_dirty_slices.generation + 1, changed_at = now()`, f.tenant); err != nil {
		return err
	}
	deadline := time.Now().Add(90 * time.Second)
	for time.Now().Before(deadline) {
		var pending int
		if err := f.pool.QueryRow(ctx, "SELECT count(*) FROM report_dirty_slices WHERE tenant_id=$1", f.tenant).Scan(&pending); err != nil {
			return err
		}
		if pending == 0 {
			return nil
		}
		time.Sleep(time.Second)
	}
	return fmt.Errorf("the worker did not drain the dirty slices; is `justclick worker` running?")
}
