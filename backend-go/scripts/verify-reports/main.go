// Command verify-reports is the Fase 7 gate, against a real database and the
// running Backoffice:
//
//   - a month of orders across six outlets is seeded straight into the order
//     tables and rolled up slice by slice with the code the jobs run;
//   - the month's report read from the rollups equals, figure for figure, the
//     same report computed from the raw tables by independent SQL;
//   - the report returns in under 200 ms through the domain and through the
//     Backoffice page, and says exactly the same once every order is deleted;
//   - exports requested on the page download with the same figures, and the
//     consistency check notices a rollup someone changed by hand.
//
// Exports are rendered by a running worker when there is one. Without one the
// script takes the job off the queue and renders it itself into REPORTS_DIR,
// which must then be the API's (it is in CI).
//
// It provisions a disposable merchant and deletes it in a defer.
//
//	justclick serve &
//	go run ./scripts/verify-reports
package main

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/rand"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	mathrand "math/rand"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"os"
	"reflect"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/backoffice/views"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/reporting"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/tenancy"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/httpapi/wire"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
)

const (
	outletCount   = 6
	days          = 30
	ordersPerDay  = 260
	budget        = 200 * time.Millisecond
	ownerPassword = "verify-reports-owner"
	domainRuns    = 40
	httpRuns      = 25
)

var (
	csrfRE   = regexp.MustCompile(`name="gorilla\.csrf\.Token" value="([^"]+)"`)
	failures int
)

func check(name string, ok bool, format string, args ...any) {
	if ok {
		fmt.Printf("  PASS  %s\n", name)
		return
	}
	failures++
	fmt.Printf("  FAIL  %s: %s\n", name, fmt.Sprintf(format, args...))
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "fatal:", err)
		os.Exit(1)
	}
	if failures > 0 {
		fmt.Printf("\n%d check(s) FAILED\n", failures)
		os.Exit(1)
	}
	fmt.Println("\nall report checks passed")
}

func run() error {
	ctx := context.Background()
	baseURL := strings.TrimRight(envOr("VERIFY_BASE_URL", "http://127.0.0.1:9000"), "/")

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

	slug := fmt.Sprintf("vreports-%d", time.Now().UnixNano())
	email := slug + "@justclick.test"
	provisioned, err := tenancy.Provision(ctx, pools, tenancy.Input{
		BusinessName: "Verifikasi Laporan", Slug: slug, OwnerName: "Owner Laporan",
		OwnerEmail: email, OwnerPassword: ownerPassword,
	})
	if err != nil {
		return err
	}
	tenant := provisioned.TenantID
	defer func() {
		cleanup := context.Background()
		if _, err := owner.Exec(cleanup, `DELETE FROM jobs.river_job WHERE args->>'tenant_id' = $1`, tenant); err != nil {
			fmt.Fprintln(os.Stderr, "job cleanup failed:", err)
		}
		if _, err := owner.Exec(cleanup, `DELETE FROM tenants WHERE id = $1`, tenant); err != nil {
			fmt.Fprintln(os.Stderr, "fixture cleanup failed:", err)
		}
	}()

	exportDir := os.Getenv("REPORTS_DIR")
	if exportDir == "" {
		if exportDir, err = os.MkdirTemp("", "verify-reports-*"); err != nil {
			return err
		}
		defer os.RemoveAll(exportDir)
	}
	opts := reporting.Options{ExportDir: exportDir, LinkBaseURL: baseURL, HTML: views.RenderReportHTML}
	if g := reporting.NewGotenberg(os.Getenv("GOTENBERG_URL")); g != nil {
		opts.PDF = g
	}
	svc, err := reporting.NewService(pools, slog.New(slog.NewTextHandler(io.Discard, nil)), opts)
	if err != nil {
		return err
	}
	loc, err := svc.Location(ctx, tenant)
	if err != nil {
		return err
	}

	// Seeding takes minutes; find a stale or unmigrated server first.
	session, err := signIn(baseURL, email, ownerPassword)
	if err != nil {
		return err
	}
	if status, _ := session.get("/backoffice/reports"); status != http.StatusOK {
		return fmt.Errorf("the report page answered %d; is the API running this build, migrated?", status)
	}

	// ---- seed and roll up -------------------------------------------------------

	fmt.Println("seed")
	today := reporting.Date(time.Now(), loc)
	from := time.Date(today.Year(), today.Month(), 1, 0, 0, 0, 0, time.UTC)
	to := from.AddDate(0, 0, days-1)
	month := reporting.Filter{From: from, To: to}

	started := time.Now()
	outlets, orders, items, err := seed(ctx, owner, tenant, from, loc)
	if err != nil {
		return err
	}
	fmt.Printf("  INFO  %d orders and %d lines over %d days at %d outlets, seeded in %s\n",
		orders, items, days, len(outlets), time.Since(started).Round(time.Millisecond))

	fmt.Println("roll up")
	started = time.Now()
	unclean := 0
	for _, outlet := range outlets {
		for d := 0; d < days; d++ {
			clean, err := svc.RecomputeSlice(ctx, tenant, outlet, from.AddDate(0, 0, d))
			if err != nil {
				return fmt.Errorf("recompute %s day %d: %w", outlet, d+1, err)
			}
			if !clean {
				unclean++
			}
		}
	}
	slices := len(outlets) * days
	elapsed := time.Since(started)
	fmt.Printf("  INFO  %d slices rolled up in %s (%.1f ms per slice)\n",
		slices, elapsed.Round(time.Millisecond), float64(elapsed.Microseconds())/1000/float64(slices))
	check("every slice rolled up clean", unclean == 0, "%d slices saw a change while computing", unclean)

	// A category renamed after its receipts were written: the report shows the
	// current name, from rollups and raw tables alike.
	if _, err := owner.Exec(ctx, `UPDATE categories SET name = 'Kopi Nusantara' WHERE tenant_id = $1 AND name = 'Kopi'`, tenant); err != nil {
		return err
	}

	// ---- exact match -----------------------------------------------------------------

	fmt.Println("the rollup report equals the raw tables")
	got, err := svc.Report(ctx, tenant, month)
	if err != nil {
		return err
	}
	want, err := reference(ctx, owner, tenant, "", from, to)
	if err != nil {
		return err
	}
	compare("whole chain", got, want)

	oneOutlet := reporting.Filter{From: from, To: to, OutletID: outlets[2]}
	got, err = svc.Report(ctx, tenant, oneOutlet)
	if err != nil {
		return err
	}
	want, err = reference(ctx, owner, tenant, outlets[2], from, to)
	if err != nil {
		return err
	}
	compare("one outlet", got, want)

	// ---- latency ---------------------------------------------------------------------

	fmt.Println("latency")
	reportPath := "/backoffice/reports?from=" + from.Format(time.DateOnly) + "&to=" + to.Format(time.DateOnly)
	for i := 0; i < 5; i++ {
		session.get(reportPath)
		if _, err := svc.Report(ctx, tenant, month); err != nil {
			return err
		}
	}

	var report reporting.Report
	timings := make([]time.Duration, 0, domainRuns)
	for i := 0; i < domainRuns; i++ {
		t0 := time.Now()
		if report, err = svc.Report(ctx, tenant, month); err != nil {
			return err
		}
		timings = append(timings, time.Since(t0))
	}
	p50, p95, worst := percentiles(timings)
	fmt.Printf("  INFO  domain, %d days x %d outlets: p50 %s, p95 %s, max %s\n", days, len(outlets), p50, p95, worst)
	check("the month's report returns in under 200 ms (domain, p95)", p95 < budget, "p95 %s", p95)

	timings = timings[:0]
	var page string
	for i := 0; i < httpRuns; i++ {
		t0 := time.Now()
		status, body := session.get(reportPath)
		timings = append(timings, time.Since(t0))
		if status != http.StatusOK {
			return fmt.Errorf("the report page answered %d", status)
		}
		page = body
	}
	p50, p95, worst = percentiles(timings)
	fmt.Printf("  INFO  Backoffice report page: p50 %s, p95 %s, max %s\n", p50, p95, worst)
	check("the month's report page returns in under 200 ms (HTTP, p95)", p95 < budget, "p95 %s", p95)
	check("the page shows the month's revenue", strings.Contains(page, views.Rupiah(report.Revenue)),
		"%s not on the page", views.Rupiah(report.Revenue))
	check("the page says when its figures were computed", strings.Contains(page, "Data per"), "no freshness line")

	// ---- consistency ---------------------------------------------------------------------

	fmt.Println("consistency")
	drift := 0
	for i := 0; i < 5; i++ {
		tables, _, err := svc.VerifySlice(ctx, tenant, outlets[i%len(outlets)], from.AddDate(0, 0, i*6))
		if err != nil {
			return err
		}
		drift += len(tables)
	}
	check("sampled slices agree with their orders", drift == 0, "%d tables disagree", drift)
	if _, err := owner.Exec(ctx, `
		UPDATE daily_sales_rollup SET revenue = revenue + 1
		WHERE tenant_id = $1 AND outlet_id = $2 AND business_date = $3`, tenant, outlets[0], from); err != nil {
		return err
	}
	tables, _, err := svc.VerifySlice(ctx, tenant, outlets[0], from)
	if err != nil {
		return err
	}
	check("a hand-edited rollup is noticed", reflect.DeepEqual(tables, []string{"daily_sales_rollup"}), "got %v", tables)
	if _, err := svc.RecomputeSlice(ctx, tenant, outlets[0], from); err != nil {
		return err
	}
	if tables, _, err = svc.VerifySlice(ctx, tenant, outlets[0], from); err != nil {
		return err
	}
	check("a recompute repairs it", len(tables) == 0, "got %v", tables)

	// ---- exports -----------------------------------------------------------------------

	fmt.Println("exports")
	for _, format := range reporting.Formats {
		status, _, _ := session.post("/backoffice/reports/exports", url.Values{
			"from": {from.Format(time.DateOnly)}, "to": {to.Format(time.DateOnly)}, "format": {format},
		})
		if status != http.StatusOK {
			check(format+" export is requested on the page", false, "got %d", status)
			continue
		}
		var id string
		if err := owner.QueryRow(ctx, `
			SELECT id::text FROM report_exports WHERE tenant_id = $1 AND format = $2
			ORDER BY created_at DESC LIMIT 1`, tenant, format).Scan(&id); err != nil {
			return err
		}
		state, message, err := finishExport(ctx, owner, svc, tenant, id)
		if err != nil {
			return err
		}
		if format == reporting.FormatPDF && state == reporting.ExportFailed && strings.Contains(message, "gotenberg") {
			fmt.Println("  INFO  PDF export not verified: gotenberg is not configured for whoever rendered it")
			continue
		}
		check(format+" export is rendered", state == reporting.ExportDone, "status %s: %s", state, message)
		if state != reporting.ExportDone {
			continue
		}
		status, body := session.get("/backoffice/reports/exports/" + id + "/download")
		check(format+" export downloads from the Backoffice", status == http.StatusOK,
			"got %d (is REPORTS_DIR the API's?)", status)
		if status != http.StatusOK {
			continue
		}
		revenue := strconv.FormatInt(report.Revenue, 10)
		switch format {
		case reporting.FormatCSV:
			check("the CSV carries the month's revenue", strings.Contains(body, "Pendapatan,"+revenue), "not found")
		case reporting.FormatXLSX:
			sheet, err := firstSheet([]byte(body))
			check("the XLSX carries the month's revenue as a number", err == nil && strings.Contains(sheet, "<v>"+revenue+"</v>"),
				"not found (%v)", err)
		case reporting.FormatPDF:
			check("the PDF is a PDF", strings.HasPrefix(body, "%PDF-"), "not a PDF")
		}
	}

	// ---- no raw reads -----------------------------------------------------------------------

	fmt.Println("the report reads no orders")
	before, err := svc.Report(ctx, tenant, month)
	if err != nil {
		return err
	}
	if _, err := owner.Exec(ctx, `DELETE FROM orders WHERE tenant_id = $1`, tenant); err != nil {
		return err
	}
	after, err := svc.Report(ctx, tenant, month)
	if err != nil {
		return err
	}
	check("with every order deleted, the domain report is unchanged", reflect.DeepEqual(before, after),
		"revenue %d became %d", before.Revenue, after.Revenue)
	status, page := session.get(reportPath)
	check("and so is the page", status == http.StatusOK && strings.Contains(page, views.Rupiah(before.Revenue)), "got %d", status)

	// ---- hitung ulang ----------------------------------------------------------------------

	fmt.Println("hitung ulang")
	day := from.Format(time.DateOnly)
	status, _, body := session.post("/backoffice/reports/recompute", url.Values{"from": {day}, "to": {day}, "outlet": {outlets[1]}})
	check("the button answers on the page", status == http.StatusOK && strings.Contains(body, "dijadwalkan"), "got %d", status)
	var queued int
	if err := owner.QueryRow(ctx, `
		SELECT count(*) FROM jobs.river_job
		WHERE kind = 'report_slice' AND args->>'tenant_id' = $1 AND args->>'outlet_id' = $2 AND args->>'business_date' = $3`,
		tenant, outlets[1], day).Scan(&queued); err != nil {
		return err
	}
	check("exactly that slice is queued", queued == 1, "got %d jobs", queued)
	return nil
}

// finishExport waits for a worker to render an export. When none takes it, the
// job is deleted while still waiting — so a worker cannot start it as well —
// and the export is rendered here.
func finishExport(ctx context.Context, owner *pgxpool.Pool, svc *reporting.Service, tenant, id string) (status, message string, err error) {
	offerUntil := time.Now().Add(5 * time.Second)
	deadline := time.Now().Add(90 * time.Second)
	for time.Now().Before(deadline) {
		if err := owner.QueryRow(ctx, `SELECT status, COALESCE(error, '') FROM report_exports WHERE id = $1`, id).
			Scan(&status, &message); err != nil {
			return "", "", err
		}
		if status == reporting.ExportDone || status == reporting.ExportFailed {
			return status, message, nil
		}
		if status == reporting.ExportQueued && time.Now().After(offerUntil) {
			tag, err := owner.Exec(ctx, `
				DELETE FROM jobs.river_job
				WHERE kind = 'report_export' AND args->>'export_id' = $1 AND state IN ('available', 'scheduled', 'retryable')`, id)
			if err != nil {
				return "", "", err
			}
			if tag.RowsAffected() == 1 {
				fmt.Println("  INFO  no worker took the export; rendering it here")
				if err := svc.RunExport(ctx, tenant, id, true); err != nil {
					return "", "", err
				}
				continue
			}
		}
		time.Sleep(250 * time.Millisecond)
	}
	return status, "timed out waiting for the export", nil
}

func uuid() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(err)
	}
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[:4], b[4:6], b[6:8], b[8:10], b[10:])
}

type product struct {
	id, name, categoryID, categoryName string
	price                              int64
	cost                               *int64
}

// seed writes the month with COPY, in the columns and payload keys ingest
// stores: cashier_id and promo_name on the order, product_id and category_id on
// each line.
func seed(ctx context.Context, owner *pgxpool.Pool, tenant string, from time.Time, loc *time.Location) ([]string, int, int, error) {
	rng := mathrand.New(mathrand.NewSource(20260915))

	var outlets []string
	for i := 1; i <= outletCount; i++ {
		var id string
		if err := owner.QueryRow(ctx, `INSERT INTO outlets (tenant_id, name) VALUES ($1, $2) RETURNING id::text`,
			tenant, fmt.Sprintf("Outlet Laporan %d", i)).Scan(&id); err != nil {
			return nil, 0, 0, err
		}
		outlets = append(outlets, id)
	}

	categoryNames := []string{"Kopi", "Teh", "Makanan Berat", "Camilan", "Minuman Dingin"}
	categories := map[string]string{}
	for _, name := range categoryNames {
		var id string
		if err := owner.QueryRow(ctx, `INSERT INTO categories (tenant_id, name) VALUES ($1, $2) RETURNING id::text`,
			tenant, name).Scan(&id); err != nil {
			return nil, 0, 0, err
		}
		categories[name] = id
	}

	var products []product
	for i := 0; i < 24; i++ {
		category := categoryNames[i%len(categoryNames)]
		p := product{
			name: fmt.Sprintf("%s %02d", category, i+1), categoryName: category, categoryID: categories[category],
			price: int64(8000 + rng.Intn(75)*500),
		}
		if rng.Intn(10) >= 3 {
			cost := p.price * int64(30+rng.Intn(30)) / 100
			p.cost = &cost
		}
		// One product deleted since: the report shows its newest snapshot name.
		if err := owner.QueryRow(ctx, `
			INSERT INTO products (tenant_id, category_id, name, price, deleted_at)
			VALUES ($1, $2, $3, $4, CASE WHEN $5 THEN now() END) RETURNING id::text`,
			tenant, p.categoryID, p.name, p.price, i == 7).Scan(&p.id); err != nil {
			return nil, 0, 0, err
		}
		products = append(products, p)
	}

	type till struct{ register, device, session string }
	tills := map[string]till{}
	for i, outlet := range outlets {
		t := till{session: uuid()}
		if err := owner.QueryRow(ctx, `INSERT INTO pos_registers (tenant_id, outlet_id, name) VALUES ($1, $2, 'Kasir 1') RETURNING id::text`,
			tenant, outlet).Scan(&t.register); err != nil {
			return nil, 0, 0, err
		}
		if err := owner.QueryRow(ctx, `
			INSERT INTO devices (tenant_id, outlet_id, pos_register_id, device_uuid) VALUES ($1, $2, $3, $4) RETURNING id::text`,
			tenant, outlet, t.register, fmt.Sprintf("verify-reports-%d-%s", i, uuid())).Scan(&t.device); err != nil {
			return nil, 0, 0, err
		}
		if _, err := owner.Exec(ctx, `
			INSERT INTO pos_sessions (id, tenant_id, outlet_id, pos_register_id, device_id, revision, employee_name,
				opened_at_ms, opening_cash, payload)
			VALUES ($1, $2, $3, $4, $5, 1, 'Kasir Laporan', $6, 0, '{}')`,
			t.session, tenant, outlet, t.register, t.device, from.Add(-24*time.Hour).UnixMilli()); err != nil {
			return nil, 0, 0, err
		}
		tills[outlet] = t
	}

	type cashier struct {
		id   *string
		name string
	}
	promos := []string{"Happy Hour", "Member", "Diskon Manajer: Rina"}
	payments := []string{"cash", "cash", "cash", "qris", "qris", "card", "transfer"}
	var orderRows, itemRows [][]any

	for _, outlet := range outlets {
		t := tills[outlet]
		cashiers := []cashier{{name: "Kasir Tanpa Akun"}}
		for c := 0; c < 3; c++ {
			id := uuid()
			cashiers = append(cashiers, cashier{id: &id, name: fmt.Sprintf("Kasir %d", c+1)})
		}
		for d := 0; d < days; d++ {
			day := from.AddDate(0, 0, d)
			n := ordersPerDay - 40 + rng.Intn(80)
			for o := 0; o < n; o++ {
				placed := time.Date(day.Year(), day.Month(), day.Day(), 7+rng.Intn(16), rng.Intn(60), rng.Intn(60), rng.Intn(1000)*1e6, loc)
				c := cashiers[rng.Intn(len(cashiers))]
				order := wire.Order{
					Id: uuid(), Revision: 1, BusinessDate: day.Format(time.DateOnly), Number: fmt.Sprintf("V-%d", o),
					PlacedAtMs: placed.UnixMilli(), Type: "dine_in", Status: wire.OrderStatusPaid, PosSessionId: t.session,
					PaymentMethod: payments[rng.Intn(len(payments))], CashierId: c.id, CashierName: c.name,
				}

				for l, lines := 0, 1+rng.Intn(4); l < lines; l++ {
					item := wire.OrderItem{Id: uuid(), Quantity: 1 + rng.Intn(3), Modifiers: []wire.OrderItemModifier{}}
					if rng.Intn(100) < 3 {
						item.ProductName, item.UnitPrice = "Tambahan Es", 2000 // no product, no category
					} else {
						p := products[rng.Intn(len(products))]
						id, category, categoryName := p.id, p.categoryID, p.categoryName
						item.ProductId, item.ProductName, item.CategoryId, item.CategoryName = &id, p.name, &category, &categoryName
						item.UnitPrice, item.UnitCost = p.price, p.cost
					}
					order.Subtotal += item.UnitPrice * int64(item.Quantity)
					order.Items = append(order.Items, item)
				}

				if rng.Intn(100) < 15 {
					promo := promos[rng.Intn(len(promos))]
					order.PromoName = &promo
					order.Discount = order.Subtotal * int64(5+rng.Intn(16)) / 100
				}
				order.Tax = (order.Subtotal - order.Discount) / 10
				if rng.Intn(2) == 0 {
					order.ServiceChargeAmount = (order.Subtotal - order.Discount) * 5 / 100
				}
				order.Total = order.Subtotal - order.Discount + order.Tax + order.ServiceChargeAmount
				order.AmountPaid = order.Total

				var settledAt *time.Time
				switch r := rng.Intn(100); {
				case r < 3:
					by, why := []string{"Manajer A", "Manajer B"}[rng.Intn(2)], "Salah input"
					order.Status, order.AuthorizedBy, order.VoidReason = wire.OrderStatusCancelled, &by, &why
				case r < 5:
					by, why, refund := "Owner", "Komplain", order.Total
					if rng.Intn(2) == 0 {
						refund = order.Total / 2
					}
					order.Status, order.AuthorizedBy, order.VoidReason, order.RefundedAmount = wire.OrderStatusRefunded, &by, &why, &refund
				case r < 12:
					order.Status = []wire.OrderStatus{wire.OrderStatusServed, wire.OrderStatusReady, wire.OrderStatusPreparing}[rng.Intn(3)]
				}
				if order.Status == wire.OrderStatusCancelled || order.Status == wire.OrderStatusRefunded {
					now := time.Now()
					settledAt = &now
				}

				payload, err := json.Marshal(order)
				if err != nil {
					return nil, 0, 0, err
				}
				orderRows = append(orderRows, []any{
					day, order.Id, tenant, outlet, t.register, t.device, t.session, order.Revision, string(order.Status), settledAt,
					order.PlacedAtMs, order.Subtotal, order.Discount, order.Tax, order.ServiceChargeAmount, order.Total,
					order.AmountPaid, order.RefundedAmount, order.PaymentMethod, order.CashierName, order.AuthorizedBy,
					order.VoidReason, string(payload),
				})
				for _, item := range order.Items {
					itemPayload, err := json.Marshal(item)
					if err != nil {
						return nil, 0, 0, err
					}
					itemRows = append(itemRows, []any{
						day, item.Id, tenant, order.Id, item.ProductName, item.CategoryName, item.UnitPrice,
						item.UnitCost, int64(item.Quantity), string(itemPayload),
					})
				}
			}
		}
	}

	if _, err := owner.CopyFrom(ctx, pgx.Identifier{"orders"}, []string{
		"business_date", "id", "tenant_id", "outlet_id", "pos_register_id", "device_id", "pos_session_id", "revision",
		"status", "settled_at", "placed_at_ms", "subtotal", "discount", "tax", "service_charge_amount", "total",
		"amount_paid", "refunded_amount", "payment_method", "cashier_name", "authorized_by", "void_reason", "payload",
	}, pgx.CopyFromRows(orderRows)); err != nil {
		return nil, 0, 0, fmt.Errorf("copy orders: %w", err)
	}
	if _, err := owner.CopyFrom(ctx, pgx.Identifier{"order_items"}, []string{
		"business_date", "id", "tenant_id", "order_id", "product_name", "category_name", "unit_price", "unit_cost",
		"quantity", "payload",
	}, pgx.CopyFromRows(itemRows)); err != nil {
		return nil, 0, 0, fmt.Errorf("copy order items: %w", err)
	}
	if _, err := owner.Exec(ctx, `ANALYZE orders; ANALYZE order_items`); err != nil {
		return nil, 0, 0, err
	}
	return outlets, len(orderRows), len(itemRows), nil
}

// reference computes the report from the raw tables. It shares no SQL with the
// rollups: the whole range is summed in one pass, the way the Laravel report
// did, and the category split runs over every order of the range at once.
func reference(ctx context.Context, owner *pgxpool.Pool, tenant, outlet string, from, to time.Time) (reporting.Report, error) {
	var r reporting.Report
	var outletArg *string
	if outlet != "" {
		outletArg = &outlet
	}
	args := []any{tenant, from, to, outletArg}
	const where = `o.tenant_id = $1 AND o.business_date BETWEEN $2 AND $3 AND ($4::uuid IS NULL OR o.outlet_id = $4::uuid)`
	const revenue = `o.status NOT IN ('cancelled', 'refunded')`
	const lineJoin = `FROM order_items i
		JOIN orders o ON o.business_date = i.business_date AND o.tenant_id = i.tenant_id AND o.id = i.order_id`

	if err := owner.QueryRow(ctx, `
		SELECT count(*) FILTER (WHERE `+revenue+`),
		       COALESCE(sum(o.subtotal) FILTER (WHERE `+revenue+`), 0)::bigint,
		       COALESCE(sum(o.discount) FILTER (WHERE `+revenue+`), 0)::bigint,
		       COALESCE(sum(o.tax) FILTER (WHERE `+revenue+`), 0)::bigint,
		       COALESCE(sum(o.service_charge_amount) FILTER (WHERE `+revenue+`), 0)::bigint,
		       COALESCE(sum(o.total) FILTER (WHERE `+revenue+`), 0)::bigint,
		       count(*) FILTER (WHERE `+revenue+` AND o.discount > 0),
		       count(*) FILTER (WHERE o.status = 'cancelled'),
		       COALESCE(sum(COALESCE(o.refunded_amount, o.total)) FILTER (WHERE o.status = 'cancelled'), 0)::bigint,
		       count(*) FILTER (WHERE o.status = 'refunded'),
		       COALESCE(sum(COALESCE(o.refunded_amount, o.total)) FILTER (WHERE o.status = 'refunded'), 0)::bigint
		FROM orders o WHERE `+where, args...).Scan(
		&r.OrderCount, &r.Subtotal, &r.Discount, &r.Tax, &r.ServiceCharge, &r.Revenue, &r.DiscountedOrders,
		&r.CancelledCount, &r.CancelledAmount, &r.RefundedCount, &r.RefundedAmount); err != nil {
		return r, err
	}
	if err := owner.QueryRow(ctx, `
		SELECT COALESCE(sum(i.quantity), 0)::bigint,
		       COALESCE(sum(COALESCE(i.unit_cost, 0) * i.quantity), 0)::bigint,
		       COALESCE(sum(CASE WHEN i.unit_cost IS NULL THEN 0 ELSE i.quantity END), 0)::bigint
		`+lineJoin+` WHERE `+where+` AND `+revenue, args...).Scan(&r.ItemsSold, &r.CostOfGoods, &r.CostedItems); err != nil {
		return r, err
	}
	if r.OrderCount > 0 {
		r.AverageOrder = r.Revenue / r.OrderCount
	}
	if r.ItemsSold > 0 {
		r.CostCoverage = float64(r.CostedItems) / float64(r.ItemsSold)
	}
	r.GrossProfit = r.Revenue - r.CostOfGoods

	var err error
	scanLine := func(row pgx.CollectableRow) (reporting.Line, error) {
		var l reporting.Line
		return l, row.Scan(&l.Key, &l.Label, &l.Value, &l.Count)
	}
	if r.ByOutlet, err = query(ctx, owner, `
		SELECT o.outlet_id::text, ot.name, sum(o.total)::bigint, count(*)
		FROM orders o JOIN outlets ot ON ot.id = o.outlet_id
		WHERE `+where+` AND `+revenue+`
		GROUP BY 1, 2 ORDER BY 3 DESC, 2, 1`, args, scanLine); err != nil {
		return r, err
	}
	if r.ByCashier, err = query(ctx, owner, `
		SELECT COALESCE(o.payload->>'cashier_id', 'name:' || o.cashier_name),
		       (array_agg(o.cashier_name ORDER BY o.placed_at_ms DESC))[1], sum(o.total)::bigint, count(*)
		FROM orders o WHERE `+where+` AND `+revenue+`
		GROUP BY 1 ORDER BY 3 DESC, 1`, args, scanLine); err != nil {
		return r, err
	}
	if r.ByPayment, err = query(ctx, owner, `
		SELECT o.payment_method, o.payment_method, sum(o.total)::bigint, count(*)
		FROM orders o WHERE `+where+` AND `+revenue+`
		GROUP BY 1 ORDER BY 3 DESC, 1`, args, scanLine); err != nil {
		return r, err
	}
	for i := range r.ByPayment {
		r.ByPayment[i].Label = reporting.PaymentLabel(r.ByPayment[i].Key)
	}
	if r.Daily, err = query(ctx, owner, `
		SELECT o.business_date, sum(o.total)::bigint, count(*)
		FROM orders o WHERE `+where+` AND `+revenue+` GROUP BY 1 ORDER BY 1`, args,
		func(row pgx.CollectableRow) (reporting.DayLine, error) {
			var d reporting.DayLine
			return d, row.Scan(&d.Date, &d.Revenue, &d.Orders)
		}); err != nil {
		return r, err
	}
	if r.ByHour, err = query(ctx, owner, `
		SELECT extract(hour FROM (to_timestamp(o.placed_at_ms / 1000.0) AT TIME ZONE t.timezone))::int,
		       sum(o.total)::bigint, count(*)
		FROM orders o JOIN tenants t ON t.id = o.tenant_id
		WHERE `+where+` AND `+revenue+` GROUP BY 1 ORDER BY 1`, args,
		func(row pgx.CollectableRow) (reporting.HourLine, error) {
			var h reporting.HourLine
			return h, row.Scan(&h.Hour, &h.Revenue, &h.Orders)
		}); err != nil {
		return r, err
	}
	if r.ByProduct, err = query(ctx, owner, `
		SELECT COALESCE(i.payload->>'product_id', 'name:' || i.product_name),
		       COALESCE(p.name, (array_agg(i.product_name ORDER BY o.placed_at_ms DESC))[1]),
		       sum(i.quantity)::bigint, sum(i.unit_price * i.quantity)::bigint,
		       sum(COALESCE(i.unit_cost, 0) * i.quantity)::bigint,
		       sum(CASE WHEN i.unit_cost IS NULL THEN 0 ELSE i.quantity END)::bigint
		`+lineJoin+`
		LEFT JOIN products p ON p.tenant_id = o.tenant_id AND p.id::text = i.payload->>'product_id' AND p.deleted_at IS NULL
		WHERE `+where+` AND `+revenue+`
		GROUP BY 1, p.name ORDER BY 4 DESC, 3 DESC, 1`, args,
		func(row pgx.CollectableRow) (reporting.ProductLine, error) {
			var p reporting.ProductLine
			return p, row.Scan(&p.Key, &p.Name, &p.Quantity, &p.Revenue, &p.CostOfGoods, &p.CostedQuantity)
		}); err != nil {
		return r, err
	}

	categoryLines, err := query(ctx, owner, `
		SELECT o.id::text, o.discount, o.subtotal, o.placed_at_ms,
		       COALESCE(i.payload->>'category_id', ''), COALESCE(i.category_name, ''), COALESCE(c.name, ''),
		       sum(i.unit_price * i.quantity)::bigint, sum(i.quantity)::bigint
		`+lineJoin+`
		LEFT JOIN categories c ON c.tenant_id = o.tenant_id AND c.id::text = i.payload->>'category_id' AND c.deleted_at IS NULL
		WHERE `+where+` AND `+revenue+`
		GROUP BY o.id, o.discount, o.subtotal, o.placed_at_ms, 5, 6, 7
		ORDER BY o.placed_at_ms, o.id, 5, 6`, args,
		func(row pgx.CollectableRow) (reporting.CategoryLine, error) {
			var l reporting.CategoryLine
			return l, row.Scan(&l.OrderID, &l.OrderDiscount, &l.OrderSubtotal, &l.PlacedAtMs, &l.CategoryID,
				&l.SnapshotName, &l.LiveName, &l.LineTotal, &l.Quantity)
		})
	if err != nil {
		return r, err
	}
	r.ByCategory = reporting.AggregateCategories(categoryLines)
	for i := range r.ByCategory {
		r.ByCategory[i].NameAtMs = 0 // a rollup detail the report does not carry
	}

	if r.Adjustments, err = query(ctx, owner, `
		SELECT 'discount', COALESCE(o.payload->>'promo_name', ''), count(*), sum(o.discount)::bigint
		FROM orders o WHERE `+where+` AND `+revenue+` AND o.discount > 0 GROUP BY 2
		UNION ALL
		SELECT o.status, COALESCE(o.authorized_by, ''), count(*), sum(COALESCE(o.refunded_amount, o.total))::bigint
		FROM orders o WHERE `+where+` AND o.status IN ('cancelled', 'refunded') GROUP BY 1, 2`, args,
		func(row pgx.CollectableRow) (reporting.Adjustment, error) {
			var a reporting.Adjustment
			return a, row.Scan(&a.Kind, &a.Label, &a.Count, &a.Amount)
		}); err != nil {
		return r, err
	}
	rank := map[string]int{"discount": 0, "cancelled": 1, "refunded": 2}
	sort.SliceStable(r.Adjustments, func(i, j int) bool {
		a, b := r.Adjustments[i], r.Adjustments[j]
		if rank[a.Kind] != rank[b.Kind] {
			return rank[a.Kind] < rank[b.Kind]
		}
		if a.Amount != b.Amount {
			return a.Amount > b.Amount
		}
		return a.Label < b.Label
	})
	return r, nil
}

func query[T any](ctx context.Context, pool *pgxpool.Pool, sql string, args []any, scan func(pgx.CollectableRow) (T, error)) ([]T, error) {
	rows, err := pool.Query(ctx, sql, args...)
	if err != nil {
		return nil, err
	}
	out, err := pgx.CollectRows(rows, scan)
	if out == nil {
		out = []T{}
	}
	return out, err
}

// compare checks every figure the report shows.
func compare(scope string, got, want reporting.Report) {
	for _, f := range []struct {
		name      string
		got, want any
	}{
		{"order count", got.OrderCount, want.OrderCount},
		{"revenue", got.Revenue, want.Revenue},
		{"subtotal", got.Subtotal, want.Subtotal},
		{"discount", got.Discount, want.Discount},
		{"tax", got.Tax, want.Tax},
		{"service charge", got.ServiceCharge, want.ServiceCharge},
		{"average order", got.AverageOrder, want.AverageOrder},
		{"items sold", got.ItemsSold, want.ItemsSold},
		{"cost of goods", got.CostOfGoods, want.CostOfGoods},
		{"cost coverage", [2]int64{got.CostedItems, got.ItemsSold}, [2]int64{want.CostedItems, want.ItemsSold}},
		{"gross profit", got.GrossProfit, want.GrossProfit},
		{"discounted orders", got.DiscountedOrders, want.DiscountedOrders},
		{"cancelled", [2]int64{got.CancelledCount, got.CancelledAmount}, [2]int64{want.CancelledCount, want.CancelledAmount}},
		{"refunded", [2]int64{got.RefundedCount, got.RefundedAmount}, [2]int64{want.RefundedCount, want.RefundedAmount}},
		{"by outlet", got.ByOutlet, want.ByOutlet},
		{"daily", got.Daily, want.Daily},
		{"by category", got.ByCategory, want.ByCategory},
		{"by product", got.ByProduct, want.ByProduct},
		{"by cashier", got.ByCashier, want.ByCashier},
		{"by payment", got.ByPayment, want.ByPayment},
		{"by hour", got.ByHour, want.ByHour},
		{"discount and void audit", got.Adjustments, want.Adjustments},
	} {
		check(scope+": "+f.name, reflect.DeepEqual(f.got, f.want), "rollup %s, raw %s", brief(f.got), brief(f.want))
	}
	var net int64
	for _, c := range got.ByCategory {
		net += c.Net
	}
	check(scope+": category net adds up to subtotal minus discount", net == got.Subtotal-got.Discount,
		"%d vs %d", net, got.Subtotal-got.Discount)
	fmt.Printf("  INFO  %s: %d orders, revenue %s, %d categories, %d products\n",
		scope, got.OrderCount, views.Rupiah(got.Revenue), len(got.ByCategory), len(got.ByProduct))
}

func brief(v any) string {
	s := fmt.Sprintf("%+v", v)
	if len(s) > 240 {
		return s[:240] + "..."
	}
	return s
}

func percentiles(ds []time.Duration) (p50, p95, worst time.Duration) {
	sorted := append([]time.Duration(nil), ds...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i] < sorted[j] })
	at := func(p float64) time.Duration {
		return sorted[int(float64(len(sorted)-1)*p)].Round(100 * time.Microsecond)
	}
	return at(0.5), at(0.95), at(1)
}

func firstSheet(xlsx []byte) (string, error) {
	zr, err := zip.NewReader(bytes.NewReader(xlsx), int64(len(xlsx)))
	if err != nil {
		return "", err
	}
	for _, f := range zr.File {
		if f.Name == "xl/worksheets/sheet1.xml" {
			rc, err := f.Open()
			if err != nil {
				return "", err
			}
			defer rc.Close()
			b, err := io.ReadAll(rc)
			return string(b), err
		}
	}
	return "", fmt.Errorf("no first sheet")
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

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
	// Caddy issues from its own local CA in development. Only ever against localhost.
	if os.Getenv("VERIFY_INSECURE_TLS") == "1" {
		client.Transport = &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true}} //nolint:gosec
	}
	s := &session{client: client, baseURL: baseURL}

	_, body := s.get("/backoffice/login")
	s.refresh(body)

	form := url.Values{"email": {email}, "password": {password}, "gorilla.csrf.Token": {s.csrf}}
	req, _ := http.NewRequest(http.MethodPost, baseURL+"/backoffice/login", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	s.browser(req)
	if status, _, body := s.send(req); status != http.StatusSeeOther {
		return nil, fmt.Errorf("sign in as %s at %s: got %d: %.200s", email, baseURL, status, body)
	}

	_, body = s.get("/backoffice/reports")
	s.refresh(body)
	return s, nil
}

func (s *session) refresh(body string) {
	if m := csrfRE.FindStringSubmatch(body); len(m) == 2 {
		s.csrf = m[1]
	}
}

func (s *session) get(path string) (int, string) {
	req, _ := http.NewRequest(http.MethodGet, s.baseURL+path, nil)
	status, _, body := s.send(req)
	return status, body
}

// post sends what HTMX sends: the form url-encoded, the token as a header and
// the HX-Request marker.
func (s *session) post(path string, form url.Values) (int, http.Header, string) {
	req, _ := http.NewRequest(http.MethodPost, s.baseURL+path, strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("X-CSRF-Token", s.csrf)
	req.Header.Set("HX-Request", "true")
	s.browser(req)
	return s.send(req)
}

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
