// Command verify-recovery proves the Fase 0 manager path against a REAL
// running server, through the Backoffice the way a manager reaches it.
//
// `verify-till` already drives the recovery DOMAIN, but it calls ForceTakeover
// and AcceptRecoveryItem in-process. Nothing there renders the takeover form,
// carries a CSRF token, passes the permission gate, parses the typed rupiah, or
// posts a decision — so the whole surface a manager actually touches was
// unverified. The assertions that matter most here:
//
//   - the devices page names who holds each drawer, and offers takeover only
//     for a register that has one;
//   - a takeover whose typed register name does not match is REFUSED, because
//     that confirmation is the only thing between a mistyped click and someone
//     else's open drawer;
//   - a recovered installation's late sale is quarantined once and stays out of
//     orders, stock and reports until a manager decides it in the browser;
//   - a case cannot be closed while an item is still pending, so nothing is
//     decided by omission.
//
// It provisions a disposable merchant and deletes it in a defer.
//
//	justclick serve &
//	go run ./scripts/verify-recovery
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

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/tenancy"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/httpapi/wire"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/redisx"
)

const (
	ownerPass   = "verify-recovery-owner"
	managerPass = "verify-recovery-manager"
	cashierPIN  = "2468"
	// The installation identity survives a reinstall, so the recovered tablet
	// re-activates onto the SAME devices row and the case still recognises it.
	tabletUUID     = "verify-recovery-tablet"
	spareUUID      = "verify-recovery-spare"
	registerName   = "Kasir 1"
	takeoverReason = "tablet tertinggal di outlet dan tidak dapat dihubungi"
)

var (
	csrfRE         = regexp.MustCompile(`name="gorilla\.csrf\.Token" value="([^"]+)"`)
	codeRE         = regexp.MustCompile(`class="code">([A-Z2-9]{12})<`)
	uuid           = `[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}`
	operationRE    = regexp.MustCompile(`name="operation_id" value="(` + uuid + `)"`)
	recoveryFormRE = regexp.MustCompile(`/backoffice/till-recoveries/(` + uuid + `)/items/(` + uuid + `)/accept`)

	failures int
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
	fmt.Println("\nall recovery checks passed")
}

func run() error {
	ctx := context.Background()
	baseURL := envOr("VERIFY_BASE_URL", "http://127.0.0.1:9000")

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

	slug := fmt.Sprintf("vrec-%d", time.Now().UnixNano())
	ownerEmail, managerEmail := slug+"-owner@justclick.test", slug+"-manager@justclick.test"

	provisioned, err := tenancy.Provision(ctx, pools, tenancy.Input{
		BusinessName: "Verify Recovery", Slug: slug, OwnerName: "Owner Recovery",
		OwnerEmail: ownerEmail, OwnerPassword: ownerPass,
	})
	if err != nil {
		return err
	}
	tenant := provisioned.TenantID
	defer func() {
		if _, err := owner.Exec(context.Background(), `DELETE FROM jobs.river_job WHERE args->>'tenant_id'=$1`, tenant); err != nil {
			fmt.Fprintln(os.Stderr, "job cleanup:", err)
		}
		if _, err := owner.Exec(context.Background(), `DELETE FROM tenants WHERE id=$1`, tenant); err != nil {
			fmt.Fprintln(os.Stderr, "cleanup failed:", err)
		}
	}()
	clearActivationLimiter(ctx)

	// ---- what the owner sets up before anyone sells ------------------------

	fmt.Println("the drawer a manager will have to take over")

	o, err := signIn(baseURL, ownerEmail, ownerPass)
	if err != nil {
		return err
	}

	_, _, body := o.hx("/backoffice/outlets", url.Values{"name": {"Outlet Recovery"}, "address": {"Jl. Pemulihan 1"}})
	outletID := firstMatch(regexp.MustCompile(`/backoffice/outlets/(`+uuid+`)"`), body)
	if outletID == "" {
		return fmt.Errorf("no outlet created: %s", truncate(body))
	}
	_, _, body = o.hx("/backoffice/outlets/"+outletID+"/registers", url.Values{"name": {registerName}})
	registerID := firstMatch(regexp.MustCompile(`/registers/(`+uuid+`)"`), body)
	if registerID == "" {
		return fmt.Errorf("no register created: %s", truncate(body))
	}

	cashierID, err := o.staff(baseURL, "Sari", "cashier", slug+"-sari@justclick.test", cashierPIN, "")
	if err != nil {
		return err
	}
	if _, err := o.staff(baseURL, "Mira", "manager", managerEmail, "5678", managerPass); err != nil {
		return err
	}

	// The catalogue is proven by verify-backoffice-crud; here a product exists
	// only so the receipt can carry a real stock effect.
	var category, product string
	if err := owner.QueryRow(ctx, `INSERT INTO categories(tenant_id,name) VALUES($1,'Minuman') RETURNING id::text`, tenant).Scan(&category); err != nil {
		return err
	}
	if err := owner.QueryRow(ctx, `INSERT INTO products(tenant_id,category_id,name,price) VALUES($1,$2,'Kopi',10000) RETURNING id::text`, tenant, category).Scan(&product); err != nil {
		return err
	}

	_, body = o.get("/backoffice/devices")
	o.refresh(body)
	_, _, body = o.hx("/backoffice/registers/"+registerID+"/activation-code", nil)
	code := firstMatch(codeRE, body)
	if code == "" {
		return fmt.Errorf("no activation code issued: %s", truncate(body))
	}

	till, err := activate(baseURL, code, tabletUUID, "Till Depan")
	if err != nil {
		return err
	}
	if err := till.signIn(cashierID); err != nil {
		return err
	}
	session := wire.Session{
		Id: newUUID(ctx, owner), Revision: 1, EmployeeId: &cashierID, EmployeeName: "Sari",
		OpenedAtMs: time.Now().Add(-2 * time.Hour).UnixMilli(), OpeningCash: 100000,
	}
	status, _ := till.post("/api/v2/till/sessions/open", session)
	check("the cashier claims the drawer", status == http.StatusOK, "got %d", status)

	sale := receipt(ctx, owner, session.Id, cashierID, product, "REC-1")
	status, pushed := till.post("/api/v2/sync/push", wire.PushRequest{
		Batches: []wire.PushBatch{{Entity: "orders", Rows: []json.RawMessage{raw(sale)}}},
	})
	check("a receipt and its stock effect are accepted", status == http.StatusOK && resultStatus(pushed, 0) == "accepted",
		"got %d %v", status, pushed["results"])

	// ---- the manager, in the browser ---------------------------------------

	fmt.Println("\nwhat the manager sees and confirms")

	m, err := signIn(baseURL, managerEmail, managerPass)
	if err != nil {
		return err
	}
	status, body = m.get("/backoffice/devices")
	m.refresh(body)
	check("the devices page opens for the manager", status == http.StatusOK, "got %d", status)
	check("it names who holds the drawer and on which tablet",
		strings.Contains(body, "Sari") && strings.Contains(body, "Till Depan"), "got %s", truncate(body))
	check("it offers takeover for the register that has an open drawer",
		strings.Contains(body, "/backoffice/till-sessions/"+session.Id+"/takeover"), "no takeover form for the open session")
	operation := firstMatch(operationRE, body)
	check("the form carries an operation id, so a resubmitted page is one takeover", operation != "",
		"no operation_id in %s", truncate(body))

	deviceID, err := deviceOf(ctx, owner, tabletUUID)
	if err != nil {
		return err
	}
	takeoverPath := "/backoffice/till-sessions/" + session.Id + "/takeover"
	form := url.Values{
		"operation_id": {operation}, "device_id": {deviceID},
		"register_name": {registerName}, "reason": {takeoverReason}, "counted_cash": {"115.000"},
	}

	wrong := cloneForm(form)
	wrong.Set("register_name", "Kasir 2")
	status, _, body = m.form(takeoverPath, wrong)
	check("a takeover whose typed register name does not match is refused",
		status == http.StatusConflict, "got %d", status)
	check("and says so instead of failing silently", strings.Contains(body, "Takeover ditolak"), "got %s", truncate(body))
	check("the drawer is still open after the refusal", openSessions(ctx, owner, registerID) == 1,
		"open sessions = %d", openSessions(ctx, owner, registerID))

	blank := cloneForm(form)
	blank.Set("reason", "")
	status, _, _ = m.form(takeoverPath, blank)
	check("a takeover with no reason is refused", status == http.StatusConflict, "got %d", status)

	bad := cloneForm(form)
	bad.Set("counted_cash", "seratus ribu")
	status, _, body = m.form(takeoverPath, bad)
	check("a cash count that is not rupiah is refused beside the field",
		status == http.StatusUnprocessableEntity, "got %d", status)

	status, headers, _ := m.form(takeoverPath, form)
	check("the confirmed takeover is accepted",
		status == http.StatusSeeOther && headers.Get("Location") == "/backoffice/devices", "got %d %s", status, headers.Get("Location"))

	var closeKind, recoveryID, actorName, reason string
	var closedAt, expected, orderCount int64
	var counted *int64
	var revoked *time.Time
	if err := owner.QueryRow(ctx, `SELECT p.close_kind,p.forced_recovery_id::text,p.closed_at_ms,
		r.actor_name,r.reason,r.expected_cash_at_takeover,r.order_count_at_takeover,r.counted_cash,d.revoked_at
		FROM pos_sessions p JOIN till_recoveries r ON r.id=p.forced_recovery_id
		JOIN devices d ON d.id=r.device_id WHERE p.id=$1`, session.Id).
		Scan(&closeKind, &recoveryID, &closedAt, &actorName, &reason, &expected, &orderCount, &counted, &revoked); err != nil {
		return fmt.Errorf("the takeover left no case on the session: %w", err)
	}
	check("the drawer is closed as a forced closure, not a normal one", closeKind == "forced" && closedAt > 0,
		"close_kind=%s closed_at_ms=%d", closeKind, closedAt)
	check("the case records who forced it and why", actorName == "Mira" && reason == takeoverReason,
		"actor=%q reason=%q", actorName, reason)
	check("the case snapshots the drawer: opening cash plus its cash sales, and the receipt count",
		expected == 110000 && orderCount == 1, "expected=%d orders=%d", expected, orderCount)
	check("the manager's own count is kept beside it, not instead of it",
		counted != nil && *counted == 115000, "counted=%v", counted)
	check("the tablet is revoked by the same transaction", revoked != nil, "revoked_at is null")
	check("no cashier is left assigned to the closed drawer", activeCashiers(ctx, owner, session.Id) == 0,
		"still assigned: %d", activeCashiers(ctx, owner, session.Id))
	check("pending activation codes for that register are cancelled", liveCodes(ctx, owner, registerID) == 0,
		"live codes: %d", liveCodes(ctx, owner, registerID))

	status, body = m.get("/backoffice/devices")
	m.refresh(body)
	check("the register no longer shows an active session", strings.Contains(body, "Tidak ada"), "got %s", truncate(body))
	check("the Recovery Center lists the open case with its reason",
		strings.Contains(body, recoveryID) && strings.Contains(body, takeoverReason), "case not on the page")

	// ---- the replacement till, and the tablet that comes back --------------

	fmt.Println("\nthe replacement drawer and the late sale")

	_, _, body = m.hx("/backoffice/registers/"+registerID+"/activation-code", nil)
	spareCode := firstMatch(codeRE, body)
	check("takeover clears the way for a replacement activation", spareCode != "", "no code issued: %s", truncate(body))
	spare, err := activate(baseURL, spareCode, spareUUID, "Till Cadangan")
	if err != nil {
		return err
	}
	if err := spare.signIn(cashierID); err != nil {
		return err
	}
	replacement := wire.Session{
		Id: newUUID(ctx, owner), Revision: 1, EmployeeId: &cashierID, EmployeeName: "Sari",
		OpenedAtMs: time.Now().UnixMilli(), OpeningCash: 70000,
	}
	status, _ = spare.post("/api/v2/till/sessions/open", replacement)
	check("the same cashier opens a fresh drawer on the spare tablet", status == http.StatusOK, "got %d", status)

	late := receipt(ctx, owner, session.Id, cashierID, product, "REC-LATE-1")
	discardable := receipt(ctx, owner, session.Id, cashierID, product, "REC-LATE-2")

	status, _ = till.post("/api/v2/sync/push", wire.PushRequest{
		Batches: []wire.PushBatch{{Entity: "orders", Rows: []json.RawMessage{raw(late)}}},
	})
	check("the revoked tablet cannot push anything", status == http.StatusUnauthorized, "got %d", status)

	// The real path back: a new code for the same register, and the SAME
	// installation uuid, so the case still recognises the device.
	m.refresh(mustGet(m, "/backoffice/devices"))
	_, _, body = m.hx("/backoffice/registers/"+registerID+"/activation-code", nil)
	returnCode := firstMatch(codeRE, body)
	if returnCode == "" {
		return fmt.Errorf("no code for the returning tablet: %s", truncate(body))
	}
	returned, err := activate(baseURL, returnCode, tabletUUID, "Till Depan")
	if err != nil {
		return err
	}
	returnedID, err := deviceOf(ctx, owner, tabletUUID)
	if err != nil {
		return err
	}
	check("re-activating the same installation reuses its device row", returnedID == deviceID,
		"was %s, now %s", deviceID, returnedID)
	if err := returned.signIn(cashierID); err != nil {
		return err
	}

	status, current := returned.get("/api/v2/till/sessions/current?local_session_id=" + session.Id)
	pointer, _ := current["recovery"].(map[string]any)
	check("the returning till is told its drawer was force-closed, and which case holds it",
		status == http.StatusOK && current["data"] == nil && pointer["id"] == recoveryID,
		"got %d %v", status, truncate(fmt.Sprint(current)))

	for i := 0; i < 3; i++ {
		status, pushed = returned.post("/api/v2/sync/push", wire.PushRequest{
			Batches: []wire.PushBatch{{Entity: "orders", Rows: []json.RawMessage{raw(late)}}},
		})
		if i == 0 {
			check("the late sale is refused with a recovery pointer, not a plain rejection",
				status == http.StatusOK && resultCode(pushed, 0) == "recovery_required" && resultRecovery(pushed, 0) == recoveryID,
				"got %d %v", status, pushed["results"])
		}
	}
	returned.post("/api/v2/sync/push", wire.PushRequest{
		Batches: []wire.PushBatch{{Entity: "orders", Rows: []json.RawMessage{raw(discardable)}}},
	})
	check("three identical retries plus a second sale are two quarantined items",
		quarantined(ctx, owner, recoveryID) == 2, "items = %d", quarantined(ctx, owner, recoveryID))
	check("nothing reached orders, stock or the report queue yet",
		orderRows(ctx, owner, late.Id) == 0 && movementRows(ctx, owner, late.Id) == 0,
		"orders=%d movements=%d", orderRows(ctx, owner, late.Id), movementRows(ctx, owner, late.Id))

	// ---- the manager decides, in the browser -------------------------------

	fmt.Println("\nthe manager's decision")

	status, body = m.get("/backoffice/devices")
	m.refresh(body)
	check("both late receipts are on the page for review",
		strings.Contains(body, late.Id) && strings.Contains(body, discardable.Id), "items not listed")
	check("each carries the summary a decision needs",
		strings.Contains(body, late.BusinessDate) && strings.Contains(body, "efek stok"), "no item summary")
	items := map[string]string{}
	for _, match := range recoveryFormRE.FindAllStringSubmatch(body, -1) {
		items[match[2]] = match[1]
	}
	check("a pending item offers accept and discard", len(items) == 2, "found %d accept forms", len(items))

	byOrder, err := itemsByOrder(ctx, owner, recoveryID)
	if err != nil {
		return err
	}
	acceptID, discardID := byOrder[late.Id], byOrder[discardable.Id]
	if acceptID == "" || discardID == "" {
		return fmt.Errorf("could not identify both recovery items")
	}

	reconcilePath := "/backoffice/till-recoveries/" + recoveryID + "/reconcile"
	status, _, body = m.form(reconcilePath, url.Values{"basis": {"device_checked"}, "reason": {"ditutup lebih awal"}})
	check("a case cannot be closed while an item is still pending", status == http.StatusConflict, "got %d", status)
	check("and says why", strings.Contains(body, "Keputusan ditolak"), "got %s", truncate(body))

	discardPath := "/backoffice/till-recoveries/" + recoveryID + "/items/" + discardID + "/discard"
	status, _, _ = m.form(discardPath, url.Values{"reason": {""}})
	check("a discard with no reason is refused", status == http.StatusConflict, "got %d", status)
	status, headers, _ = m.form(discardPath, url.Values{"reason": {"struk kertas ganda"}})
	check("a discard with a reason is recorded", status == http.StatusSeeOther, "got %d", status)
	check("the discarded receipt never becomes a sale", orderRows(ctx, owner, discardable.Id) == 0,
		"orders for the discarded receipt = %d", orderRows(ctx, owner, discardable.Id))

	acceptPath := "/backoffice/till-recoveries/" + recoveryID + "/items/" + acceptID + "/accept"
	status, headers, _ = m.form(acceptPath, nil)
	check("the accepted receipt is applied", status == http.StatusSeeOther, "got %d %s", status, headers.Get("Location"))
	check("it writes exactly one order and one stock effect",
		orderRows(ctx, owner, late.Id) == 1 && movementRows(ctx, owner, late.Id) == 1,
		"orders=%d movements=%d", orderRows(ctx, owner, late.Id), movementRows(ctx, owner, late.Id))
	check("and marks the day for recomputation", dirtySlices(ctx, owner, tenant, late.BusinessDate) == 1,
		"dirty slices = %d", dirtySlices(ctx, owner, tenant, late.BusinessDate))

	status, _, _ = m.form(acceptPath, nil)
	check("accepting twice is the same acceptance", status == http.StatusSeeOther, "got %d", status)
	check("no second order and no second stock effect",
		orderRows(ctx, owner, late.Id) == 1 && movementRows(ctx, owner, late.Id) == 1,
		"orders=%d movements=%d", orderRows(ctx, owner, late.Id), movementRows(ctx, owner, late.Id))

	status, pushed = returned.post("/api/v2/sync/push", wire.PushRequest{
		Batches: []wire.PushBatch{{Entity: "orders", Rows: []json.RawMessage{raw(late)}}},
	})
	check("the till's own retry now clears its queue", resultStatus(pushed, 0) == "accepted", "got %v", pushed["results"])
	check("still one order and one stock effect",
		orderRows(ctx, owner, late.Id) == 1 && movementRows(ctx, owner, late.Id) == 1,
		"orders=%d movements=%d", orderRows(ctx, owner, late.Id), movementRows(ctx, owner, late.Id))

	status, headers, _ = m.form(reconcilePath, url.Values{"basis": {"device_checked"}, "reason": {"antrean perangkat sudah diperiksa"}})
	check("the case closes once every item is decided", status == http.StatusSeeOther, "got %d", status)

	var caseStatus, basis string
	if err := owner.QueryRow(ctx, `SELECT status,reconciliation_basis FROM till_recoveries WHERE id=$1`, recoveryID).Scan(&caseStatus, &basis); err != nil {
		return err
	}
	check("and is recorded as reconciled on a stated basis", caseStatus == "reconciled" && basis == "device_checked",
		"status=%s basis=%s", caseStatus, basis)

	trail, err := eventTrail(ctx, owner, recoveryID)
	if err != nil {
		return err
	}
	// In the order the manager acted: the case, the two quarantined receipts,
	// the refusal, the approval, the close.
	check("the audit trail holds every step of the case, in the order it happened",
		trail == "takeover,item_found,item_found,item_discarded,item_accepted,reconciled", "got %s", trail)

	var replacementOpening int64
	var replacementCounted *int64
	if err := owner.QueryRow(ctx, `SELECT opening_cash,counted_cash FROM pos_sessions WHERE id=$1`, replacement.Id).
		Scan(&replacementOpening, &replacementCounted); err != nil {
		return err
	}
	check("the replacement drawer's cash is untouched by any of it",
		replacementOpening == 70000 && replacementCounted == nil, "opening=%d counted=%v", replacementOpening, replacementCounted)

	fmt.Printf("\nF0_EVIDENCE tenant=%s register=%s device=%s forced_session=%s replacement_session=%s recovery=%s accepted_order=%s discarded_order=%s\n",
		tenant, registerID, deviceID, session.Id, replacement.Id, recoveryID, late.Id, discardable.Id)
	return nil
}

// ---- the Backoffice ---------------------------------------------------------

type session struct {
	client  *http.Client
	baseURL string
	csrf    string
}

func signIn(baseURL, email, password string) (*session, error) {
	jar, _ := cookiejar.New(nil)
	client := &http.Client{
		Jar: jar, Timeout: 30 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	// Caddy issues from its own local CA in development. Only ever localhost.
	if os.Getenv("VERIFY_INSECURE_TLS") == "1" {
		client.Transport = &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true}} //nolint:gosec
	}

	s := &session{client: client, baseURL: baseURL}
	_, body := s.get("/backoffice/login")
	s.refresh(body)

	form := url.Values{"email": {email}, "password": {password}, "gorilla.csrf.Token": {s.csrf}}
	status, _, _ := s.form("/backoffice/login", form)
	if status != http.StatusSeeOther {
		return nil, fmt.Errorf("sign in as %s: got %d", email, status)
	}
	s.refresh(mustGet(s, "/backoffice/devices"))
	return s, nil
}

func (s *session) refresh(body string) {
	if token := firstMatch(csrfRE, body); token != "" {
		s.csrf = token
	}
}

func (s *session) get(path string) (int, string) {
	req, _ := http.NewRequest(http.MethodGet, s.baseURL+path, nil)
	status, _, body := s.send(req)
	return status, body
}

// hx sends what an HTMX control sends: the token as a header, and the marker
// that makes the handler answer with a fragment.
func (s *session) hx(path string, form url.Values) (int, http.Header, string) {
	req, _ := http.NewRequest(http.MethodPost, s.baseURL+path, strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("X-CSRF-Token", s.csrf)
	req.Header.Set("HX-Request", "true")
	s.browser(req)
	return s.send(req)
}

// form sends what a plain <form method="post"> sends, which is what the
// takeover and decision forms are: the token as a FIELD, no HX marker, and a
// 303 back to the page. Posting these as HTMX would never exercise the
// redirect a manager's browser actually follows.
func (s *session) form(path string, form url.Values) (int, http.Header, string) {
	body := cloneForm(form)
	body.Set("gorilla.csrf.Token", s.csrf)
	req, _ := http.NewRequest(http.MethodPost, s.baseURL+path, strings.NewReader(body.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	s.browser(req)
	return s.send(req)
}

// staff creates an employee through the panel and, when a password is given,
// grants the Backoffice sign-in that goes with it.
func (s *session) staff(baseURL, name, role, email, pin, password string) (string, error) {
	status, headers, _ := s.hx("/backoffice/staff", url.Values{
		"name": {name}, "role": {role}, "email": {email}, "pin": {pin},
	})
	id := firstMatch(regexp.MustCompile(`/backoffice/staff/(`+uuid+`)$`), headers.Get("HX-Redirect"))
	if status != http.StatusOK || id == "" {
		return "", fmt.Errorf("create %s %s: got %d", role, name, status)
	}
	if password == "" {
		return id, nil
	}
	if status, _, _ = s.hx("/backoffice/staff/"+id+"/password", url.Values{"password": {password}}); status != http.StatusOK {
		return "", fmt.Errorf("set %s password: got %d", role, status)
	}
	return id, nil
}

// browser supplies the Origin a real browser sends on a same-origin POST;
// without it the CSRF middleware refuses before any handler runs.
func (s *session) browser(req *http.Request) {
	origin := req.URL.Scheme + "://" + req.URL.Host
	req.Header.Set("Origin", origin)
	req.Header.Set("Referer", origin+"/backoffice/")
}

func (s *session) send(req *http.Request) (int, http.Header, string) {
	resp, err := s.client.Do(req)
	if err != nil {
		return 0, http.Header{}, err.Error()
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, resp.Header, string(body)
}

func mustGet(s *session, path string) string {
	_, body := s.get(path)
	return body
}

// ---- the till ---------------------------------------------------------------

type tablet struct {
	client  *http.Client
	baseURL string
	token   string
	cashier string
}

func activate(baseURL, code, deviceUUID, label string) (*tablet, error) {
	t := &tablet{client: &http.Client{Timeout: 30 * time.Second}, baseURL: baseURL}
	if os.Getenv("VERIFY_INSECURE_TLS") == "1" {
		t.client.Transport = &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true}} //nolint:gosec
	}
	status, body := t.call(http.MethodPost, "/api/v2/devices/activate", map[string]any{
		"code": code, "device_uuid": deviceUUID, "label": label, "platform": "windows",
	})
	token, _ := dataOf(body)["token"].(string)
	if status != http.StatusOK || token == "" {
		return nil, fmt.Errorf("activate %s: got %d", deviceUUID, status)
	}
	t.token = token
	return t, nil
}

func (t *tablet) signIn(employee string) error {
	status, body := t.post("/api/v2/till/login", map[string]any{"employee_id": employee, "pin": cashierPIN})
	token, _ := dataOf(body)["token"].(string)
	if status != http.StatusOK || token == "" {
		return fmt.Errorf("cashier sign-in: got %d", status)
	}
	t.cashier = token
	return nil
}

func (t *tablet) get(path string) (int, map[string]any) { return t.call(http.MethodGet, path, nil) }
func (t *tablet) post(path string, in any) (int, map[string]any) {
	return t.call(http.MethodPost, path, in)
}

func (t *tablet) call(method, path string, in any) (int, map[string]any) {
	var reader io.Reader
	if in != nil {
		reader = bytes.NewReader(raw(in))
	}
	req, _ := http.NewRequest(method, t.baseURL+path, reader)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Schema-Version", fmt.Sprint(syncfeed.SchemaVersion))
	if t.token != "" {
		req.Header.Set("Authorization", "Bearer "+t.token)
	}
	if t.cashier != "" {
		req.Header.Set("X-Cashier-Token", t.cashier)
	}
	resp, err := t.client.Do(req)
	if err != nil {
		return 0, map[string]any{}
	}
	defer resp.Body.Close()
	var out map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&out)
	if out == nil {
		out = map[string]any{}
	}
	return resp.StatusCode, out
}

// ---- fixtures and readbacks -------------------------------------------------

func receipt(ctx context.Context, owner *pgxpool.Pool, session, cashier, product, number string) wire.Order {
	effects := []wire.StockMovement{{
		Id: newUUID(ctx, owner), Revision: 1, ProductId: product, ProductName: "Kopi",
		Reason: "sale", DeltaQty: -1, OccurredAtMs: time.Now().UnixMilli(), EmployeeName: "Sari",
	}}
	return wire.Order{
		Id: newUUID(ctx, owner), Revision: 1, BusinessDate: time.Now().UTC().Format(time.DateOnly),
		Number: number, PlacedAtMs: time.Now().UnixMilli(), Type: "takeaway", Status: "paid",
		PosSessionId: session, CashierId: &cashier, CashierName: "Sari",
		Subtotal: 10000, Total: 10000, AmountPaid: 10000, PaymentMethod: "cash",
		Items: []wire.OrderItem{{
			Id: newUUID(ctx, owner), ProductId: &product, ProductName: "Kopi",
			Quantity: 1, UnitPrice: 10000, Modifiers: []wire.OrderItemModifier{},
		}},
		StockMovements: &effects,
	}
}

func newUUID(ctx context.Context, owner *pgxpool.Pool) string {
	var id string
	if err := owner.QueryRow(ctx, "SELECT gen_random_uuid()::text").Scan(&id); err != nil {
		panic(err)
	}
	return id
}

func deviceOf(ctx context.Context, owner *pgxpool.Pool, deviceUUID string) (string, error) {
	var id string
	err := owner.QueryRow(ctx, `SELECT id::text FROM devices WHERE device_uuid=$1`, deviceUUID).Scan(&id)
	return id, err
}

func itemsByOrder(ctx context.Context, owner *pgxpool.Pool, recovery string) (map[string]string, error) {
	rows, err := owner.Query(ctx, `SELECT entity_id::text,id::text FROM till_recovery_items WHERE recovery_id=$1`, recovery)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]string{}
	for rows.Next() {
		var order, item string
		if err := rows.Scan(&order, &item); err != nil {
			return nil, err
		}
		out[order] = item
	}
	return out, rows.Err()
}

func eventTrail(ctx context.Context, owner *pgxpool.Pool, recovery string) (string, error) {
	var out string
	err := owner.QueryRow(ctx, `SELECT string_agg(event_type,',' ORDER BY created_at,event_type)
		FROM till_recovery_events WHERE recovery_id=$1`, recovery).Scan(&out)
	return out, err
}

func scalar(ctx context.Context, owner *pgxpool.Pool, query string, args ...any) int64 {
	var n int64
	if err := owner.QueryRow(ctx, query, args...).Scan(&n); err != nil {
		fmt.Fprintln(os.Stderr, "readback failed:", err)
		return -1
	}
	return n
}

func openSessions(ctx context.Context, owner *pgxpool.Pool, register string) int64 {
	return scalar(ctx, owner, `SELECT count(*) FROM pos_sessions WHERE pos_register_id=$1 AND closed_at_ms IS NULL`, register)
}
func activeCashiers(ctx context.Context, owner *pgxpool.Pool, session string) int64 {
	return scalar(ctx, owner, `SELECT count(*) FROM till_claims WHERE session_id=$1 AND active_employee_id IS NOT NULL`, session)
}
func liveCodes(ctx context.Context, owner *pgxpool.Pool, register string) int64 {
	return scalar(ctx, owner, `SELECT count(*) FROM activation_codes
		WHERE pos_register_id=$1 AND consumed_at IS NULL AND cancelled_at IS NULL`, register)
}
func quarantined(ctx context.Context, owner *pgxpool.Pool, recovery string) int64 {
	return scalar(ctx, owner, `SELECT count(*) FROM till_recovery_items WHERE recovery_id=$1`, recovery)
}
func orderRows(ctx context.Context, owner *pgxpool.Pool, order string) int64 {
	return scalar(ctx, owner, `SELECT count(*) FROM orders WHERE id=$1`, order)
}
func movementRows(ctx context.Context, owner *pgxpool.Pool, order string) int64 {
	return scalar(ctx, owner, `SELECT count(*) FROM stock_movements WHERE ref_type='order' AND ref_id=$1`, order)
}
func dirtySlices(ctx context.Context, owner *pgxpool.Pool, tenant, day string) int64 {
	return scalar(ctx, owner, `SELECT count(*) FROM report_dirty_slices WHERE tenant_id=$1 AND business_date=$2`, tenant, day)
}

// ---- helpers ----------------------------------------------------------------

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

func raw(v any) json.RawMessage {
	out, err := json.Marshal(v)
	if err != nil {
		panic(err)
	}
	return out
}

func dataOf(body map[string]any) map[string]any {
	d, _ := body["data"].(map[string]any)
	if d == nil {
		return map[string]any{}
	}
	return d
}

func resultAt(body map[string]any, i int) map[string]any {
	results, _ := body["results"].([]any)
	if i >= len(results) {
		return map[string]any{}
	}
	row, _ := results[i].(map[string]any)
	if row == nil {
		return map[string]any{}
	}
	return row
}

func resultStatus(body map[string]any, i int) string {
	s, _ := resultAt(body, i)["status"].(string)
	return s
}
func resultCode(body map[string]any, i int) string {
	s, _ := resultAt(body, i)["code"].(string)
	return s
}
func resultRecovery(body map[string]any, i int) string {
	s, _ := resultAt(body, i)["recovery_id"].(string)
	return s
}

func cloneForm(in url.Values) url.Values {
	out := url.Values{}
	for key, values := range in {
		out[key] = append([]string(nil), values...)
	}
	return out
}

func firstMatch(re *regexp.Regexp, s string) string {
	if m := re.FindStringSubmatch(s); len(m) > 1 {
		return m[1]
	}
	return ""
}

func truncate(s string) string {
	s = strings.Join(strings.Fields(s), " ")
	if len(s) > 240 {
		return s[:240] + "…"
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
