package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"math/rand"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/catalogue"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/devices"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/reporting"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/httpapi/wire"
)

type fanoutOptions struct {
	devices   int
	catalogue int
}

// runFanout answers the question a 15,000-device fleet makes expensive: what
// does changing ONE product cost the database?
//
// The intended answer is one index-only scan per till and nothing else. The
// way it goes wrong is invisible until it is enormous: a published column
// missing from the covering index turns each scan into a heap fetch per row,
// and the first symptom is a database that falls over on the afternoon
// somebody edits the menu.
func runFanout(ctx context.Context, e *env, opts fanoutOptions) (*Result, error) {
	result := newResult("fanout", map[string]any{
		"devices": opts.devices, "catalogue_rows_per_feed": opts.catalogue, "workers": e.workers,
	})

	fleet, err := ProvisionFleet(ctx, e.owner, e.feed, FleetOptions{
		Devices: opts.devices, TillsPerOutlet: 3, CatalogueRows: opts.catalogue,
		BaseURL: e.baseURL, Client: newHTTPClient(e.workers, e.insecureTLS),
	})
	defer fleet.Cleanup(e.owner, e.keep)
	if err != nil {
		return result, err
	}

	// Every till is up to date, then one product moves. Without this the run
	// would measure a cold catalogue download, which is a different question.
	if err := currentCursors(ctx, e, fleet); err != nil {
		return result, err
	}
	if err := warmFleet(ctx, e, fleet); err != nil {
		return result, fmt.Errorf("warm the fleet: %w", err)
	}
	if _, err := e.owner.Exec(ctx, "VACUUM (ANALYZE) products"); err != nil {
		return result, err
	}
	fmt.Printf("fleet ready: %d tills up to date, tenant %s\n", len(fleet.Tills), fleet.TenantID)

	if err := result.snapshotStatements(ctx, e.owner); err != nil {
		return result, err
	}

	// The real writer, not an UPDATE: the sequence number, the tombstone rules
	// and the watermark publish are all part of what a menu edit costs.
	changed := fleet.Products[0]
	service := catalogue.NewService(e.pools, e.feed, nil)
	var categoryID string
	if err := e.owner.QueryRow(ctx, `SELECT category_id::text FROM products WHERE tenant_id = $1 AND id = $2`,
		fleet.TenantID, changed.id).Scan(&categoryID); err != nil {
		return result, err
	}
	if _, err := service.SaveProduct(ctx, fleet.TenantID, catalogue.Product{
		ID: changed.id, CategoryID: categoryID, Name: changed.name + " (baru)",
		Price: changed.price + 500, IconKey: "restaurant", Available: true,
	}); err != nil {
		return result, fmt.Errorf("change one product: %w", err)
	}

	run := Driver{
		// Closed loop: every till must pull exactly once, so nothing is dropped.
		Count: int64(len(fleet.Tills)), Workers: e.workers,
		Call: func(ctx context.Context, arrival int64) Outcome {
			return fleet.Tills[int(arrival)%len(fleet.Tills)].Startup(ctx)
		},
	}.Run(ctx)
	result.record("fanout", run)

	pulls, err := statementsLike(ctx, e.owner, "%FROM products%", "%sync_seq > $2%")
	if err != nil {
		return result, err
	}
	result.TopAfter, _ = topStatements(ctx, e.owner, 20)

	var pullCalls, pullRows, pullReads int64
	for _, s := range pulls {
		pullCalls += s.Calls
		pullRows += s.Rows
		pullReads += s.SharedRead
	}
	result.Measured["product_pull_calls"] = pullCalls
	result.Measured["product_pull_rows"] = pullRows
	result.Measured["product_pull_blocks_read_from_disk"] = pullReads
	result.Measured["rows_pulled_by_tills"] = run.Accepted

	plan, planErr := e.feed.ExplainPull(ctx, fleet.TenantID, "", "products", 0, 500)
	indexOnly := planErr == nil && strings.Contains(plan, "Index Only Scan")
	result.Measured["product_pull_plan"] = planLine(plan, "Index Only Scan")

	devicesCount := int64(len(fleet.Tills))
	result.gate("one pull per till, no more", withinPercent(pullCalls, devicesCount, 2),
		"%d product pulls for %d tills", pullCalls, devicesCount)
	result.gate("one row per pull", pullRows <= devicesCount+1 && pullRows > 0,
		"%d rows returned across %d calls", pullRows, pullCalls)
	result.gate("each till took the change", int64(run.Accepted) >= devicesCount,
		"%d rows applied by %d tills", run.Accepted, devicesCount)
	result.gate("the plan is an index-only scan", indexOnly, "%s", planLine(plan, "Index Only Scan"))
	result.gate("no till failed", run.Failed == 0 && run.NonOK() == 0,
		"%d failures, %d non-200", run.Failed, run.NonOK())

	result.note("a pull is three statements: the transaction's tenant context, the feed scan and the counter read. " +
		"The gate counts the scan, which is the one that grows with the catalogue.")

	return result, nil
}

func withinPercent(got, want, percent int64) bool {
	if want == 0 {
		return got == 0
	}
	slack := want * percent / 100
	if slack < 1 {
		slack = 1
	}
	return got >= want-slack && got <= want+slack
}

func firstLine(text string) string {
	if idx := strings.IndexByte(text, '\n'); idx > 0 {
		return strings.TrimSpace(text[:idx])
	}
	return strings.TrimSpace(text)
}

type dataScaleOptions struct {
	orders    int
	days      int
	devices   int
	catalogue int
}

// runDataScale asks whether the reports still work once the history is large.
//
// The claim being tested is structural, not statistical: a report reads the
// rollups and never the orders. Proof is pg_stat_statements — the report is
// run against a seeded history and the statements it produced are searched for
// any mention of the raw tables. If one appears, the report is reading
// millions of rows and its latency is an accident waiting for volume.
func runDataScale(ctx context.Context, e *env, opts dataScaleOptions) (*Result, error) {
	if opts.days < 1 {
		opts.days = 1
	}
	result := newResult("datascale", map[string]any{
		"orders": opts.orders, "days": opts.days, "branches": opts.devices,
	})

	fleet, err := ProvisionFleet(ctx, e.owner, e.feed, FleetOptions{
		Devices: opts.devices, TillsPerOutlet: 1, CatalogueRows: opts.catalogue,
		BaseURL: e.baseURL, Client: newHTTPClient(e.workers, e.insecureTLS),
	})
	defer fleet.Cleanup(e.owner, e.keep)
	if err != nil {
		return result, err
	}

	if err := openSessions(ctx, fleet.Tills, e.workers, e.logger); err != nil {
		return result, fmt.Errorf("open drawers: %w", err)
	}

	// Business dates run backwards from yesterday, so nothing lands on a day
	// still being written to.
	end := time.Now().UTC().AddDate(0, 0, -1).Truncate(24 * time.Hour)
	start := end.AddDate(0, 0, -(opts.days - 1))

	created, err := ensurePartitions(ctx, e, start, end)
	if err != nil {
		return result, err
	}
	if len(created) > 0 {
		result.note("created past partitions the hourly job does not: %s. "+
			"ensure_ingest_partitions builds the current month and three ahead, so a HISTORICAL seed "+
			"(not live traffic, which never writes into a month that has gone) would otherwise land in orders_default.",
			strings.Join(created, ", "))
		defer dropEmptyPartitions(e, created)
	}

	seedStart := time.Now()
	seeded, items, err := seedOrderHistory(ctx, e, fleet, start, opts)
	if err != nil {
		return result, err
	}
	result.Measured["orders_seeded"] = seeded
	result.Measured["order_items_seeded"] = items
	result.Measured["seed_seconds"] = round(time.Since(seedStart).Seconds(), 1)
	fmt.Printf("seeded %d receipts and %d lines in %s\n", seeded, items, time.Since(seedStart).Round(time.Second))

	reports, err := reporting.NewService(e.pools, e.logger, reporting.Options{ExportDir: "", LinkBaseURL: "http://localhost"})
	if err != nil {
		return result, err
	}

	rollupStart := time.Now()
	slices := 0
	for day := start; !day.After(end); day = day.AddDate(0, 0, 1) {
		for _, outlet := range distinct(fleet.Outlets) {
			if _, err := reports.RecomputeSlice(ctx, fleet.TenantID, outlet, day); err != nil {
				return result, fmt.Errorf("roll up %s: %w", day.Format(time.DateOnly), err)
			}
			slices++
		}
	}
	result.Measured["slices_rolled_up"] = slices
	result.Measured["rollup_seconds"] = round(time.Since(rollupStart).Seconds(), 1)
	fmt.Printf("rolled up %d slices in %s\n", slices, time.Since(rollupStart).Round(time.Second))

	if _, err := e.owner.Exec(ctx, "ANALYZE daily_sales_rollup; ANALYZE daily_category_rollup; ANALYZE daily_product_rollup"); err != nil {
		return result, err
	}

	filter := reporting.Filter{From: start, To: end}
	if _, err := reports.Report(ctx, fleet.TenantID, filter); err != nil {
		return result, fmt.Errorf("first report: %w", err)
	}

	// Everything from here is what the report itself did.
	if err := result.snapshotStatements(ctx, e.owner); err != nil {
		return result, err
	}

	const runs = 20
	latencies := make([]time.Duration, 0, runs)
	var report reporting.Report
	for range runs {
		began := time.Now()
		report, err = reports.Report(ctx, fleet.TenantID, filter)
		if err != nil {
			return result, err
		}
		latencies = append(latencies, time.Since(began))
	}
	measurement := Run{Latencies: sorted(latencies), Completed: runs, Elapsed: time.Since(rollupStart)}
	result.Measured["report_p50_ms"] = round(msOf(measurement.Percentile(50)), 2)
	result.Measured["report_p95_ms"] = round(msOf(measurement.Percentile(95)), 2)
	result.Measured["report_max_ms"] = round(msOf(measurement.Percentile(100)), 2)
	result.Measured["report_revenue"] = report.Revenue
	result.Measured["report_order_count"] = report.OrderCount

	raw, err := statementsLike(ctx, e.owner, "%orders%")
	if err != nil {
		return result, err
	}
	var offenders []string
	var rawCalls int64
	for _, s := range raw {
		if mentionsRawOrders(s.Query) {
			offenders = append(offenders, fmt.Sprintf("%d calls: %s", s.Calls, truncate(s.Query, 90)))
			rawCalls += s.Calls
		}
	}
	result.TopAfter, _ = topStatements(ctx, e.owner, 20)
	result.TableStats, _ = tableStats(ctx, e.owner, "orders%")
	rollupStats, _ := tableStats(ctx, e.owner, "daily_%")
	result.TableStats = append(result.TableStats, rollupStats...)

	p95 := msOf(measurement.Percentile(95))
	result.gate("a report reads no raw order table", rawCalls == 0,
		"%d statements touched orders or order_items%s", rawCalls, joinOffenders(offenders))
	result.gate("a month of reports stays under 200 ms", p95 < 200,
		"p95 %.1f ms over %d runs across %d receipts", p95, runs, seeded)
	result.gate("the report found the seeded receipts", report.OrderCount > 0,
		"%d receipts, revenue %d", report.OrderCount, report.Revenue)

	analysed, vacuumLag := autovacuumHealth(result.TableStats)
	result.gate("autovacuum and autoanalyze kept up", vacuumLag == "",
		"%d relations analysed%s", analysed, prefixIf(", behind on: ", vacuumLag))
	result.gate("no receipt in a default partition", defaultPartitionRows(result.TableStats) == 0,
		"%d rows in orders_default", defaultPartitionRows(result.TableStats))

	return result, nil
}

// seedOrderHistory writes the history with COPY, in chunks.
//
// Chunked because thirty million receipts do not fit in memory, and through
// COPY because pushing them through the API would take days and would be
// measuring the API rather than the history. Payloads are the real wire
// shape, so the rollups aggregate the same JSON a till would have sent.
func seedOrderHistory(ctx context.Context, e *env, fleet *Fleet, start time.Time, opts dataScaleOptions) (int64, int64, error) {
	rng := rand.New(rand.NewSource(20260921))
	tills := fleet.Tills
	perDayPerTill := opts.orders / (opts.days * len(tills))
	if perDayPerTill < 1 {
		perDayPerTill = 1
	}

	type tillRow struct{ device, register, outlet, session string }
	rows := make([]tillRow, 0, len(tills))
	for _, till := range tills {
		var register string
		if err := e.owner.QueryRow(ctx, `SELECT pos_register_id::text FROM devices WHERE id = $1`, till.id).Scan(&register); err != nil {
			return 0, 0, err
		}
		rows = append(rows, tillRow{device: till.id, register: register, outlet: till.outlet, session: till.sessionID})
	}

	var totalOrders, totalItems int64
	const chunk = 20000

	orderBuf := make([][]any, 0, chunk)
	itemBuf := make([][]any, 0, chunk*2)
	flush := func() error {
		if len(orderBuf) == 0 {
			return nil
		}
		if _, err := e.owner.CopyFrom(ctx, pgx.Identifier{"orders"}, []string{
			"business_date", "id", "tenant_id", "outlet_id", "pos_register_id", "device_id", "pos_session_id",
			"revision", "status", "placed_at_ms", "subtotal", "discount", "tax", "service_charge_amount",
			"total", "amount_paid", "payment_method", "cashier_name", "payload",
		}, pgx.CopyFromRows(orderBuf)); err != nil {
			return fmt.Errorf("copy orders: %w", err)
		}
		if _, err := e.owner.CopyFrom(ctx, pgx.Identifier{"order_items"}, []string{
			"business_date", "id", "tenant_id", "order_id", "product_name", "category_name",
			"unit_price", "unit_cost", "quantity", "payload",
		}, pgx.CopyFromRows(itemBuf)); err != nil {
			return fmt.Errorf("copy order items: %w", err)
		}
		totalOrders += int64(len(orderBuf))
		totalItems += int64(len(itemBuf))
		orderBuf, itemBuf = orderBuf[:0], itemBuf[:0]
		return nil
	}

	for d := range opts.days {
		day := start.AddDate(0, 0, d)
		for _, till := range rows {
			for n := range perDayPerTill {
				if ctx.Err() != nil {
					return totalOrders, totalItems, ctx.Err()
				}
				placed := day.Add(time.Duration(8+rng.Intn(12)) * time.Hour)
				product := fleet.Products[rng.Intn(len(fleet.Products))]
				quantity := 1 + rng.Intn(3)
				itemID := newUUID()
				order := wire.Order{
					Id: newUUID(), Revision: 1, BusinessDate: day.Format(time.DateOnly),
					Number: fmt.Sprintf("H-%d-%d", d, n), PlacedAtMs: placed.UnixMilli(),
					Type: "dinein", Status: "paid", PosSessionId: till.session,
					PaymentMethod: "cash", CashierName: "Kasir Riwayat",
					Items: []wire.OrderItem{{
						Id: itemID, ProductName: product.name, Quantity: quantity,
						UnitPrice: product.price, Modifiers: []wire.OrderItemModifier{},
					}},
				}
				order.Subtotal = product.price * int64(quantity)
				order.Total = order.Subtotal
				order.AmountPaid = order.Total

				payload, err := json.Marshal(order)
				if err != nil {
					return totalOrders, totalItems, err
				}
				itemPayload, err := json.Marshal(order.Items[0])
				if err != nil {
					return totalOrders, totalItems, err
				}
				orderBuf = append(orderBuf, []any{
					day, order.Id, fleet.TenantID, till.outlet, till.register, till.device, till.session,
					order.Revision, string(order.Status), order.PlacedAtMs, order.Subtotal, order.Discount,
					order.Tax, order.ServiceChargeAmount, order.Total, order.AmountPaid,
					order.PaymentMethod, order.CashierName, string(payload),
				})
				itemBuf = append(itemBuf, []any{
					day, itemID, fleet.TenantID, order.Id, product.name, nil,
					product.price, nil, int64(quantity), string(itemPayload),
				})
				if len(orderBuf) >= chunk {
					if err := flush(); err != nil {
						return totalOrders, totalItems, err
					}
					fmt.Printf("  seeded %d receipts\n", totalOrders)
				}
			}
		}
	}
	if err := flush(); err != nil {
		return totalOrders, totalItems, err
	}

	if _, err := e.owner.Exec(ctx, "ANALYZE orders; ANALYZE order_items"); err != nil {
		return totalOrders, totalItems, err
	}
	return totalOrders, totalItems, nil
}

// ensurePartitions creates the monthly partitions a historical seed needs.
//
// app.ensure_ingest_partitions() builds this month and the three ahead, which
// is right for live traffic — a device cannot push into a month that has
// already gone without the partition for it still existing. A backfill can,
// and the DEFAULT partition is where no report or retention job looks.
func ensurePartitions(ctx context.Context, e *env, start, end time.Time) ([]string, error) {
	var created []string
	for _, table := range []string{"orders", "order_items", "order_item_modifiers"} {
		for month := start.AddDate(0, 0, 1-start.Day()); !month.After(end); month = month.AddDate(0, 1, 0) {
			name := fmt.Sprintf("%s_%s", table, month.Format("2006_01"))
			var exists bool
			if err := e.owner.QueryRow(ctx, `SELECT to_regclass('public.' || $1) IS NOT NULL`, name).Scan(&exists); err != nil {
				return created, err
			}
			if exists {
				continue
			}
			next := month.AddDate(0, 1, 0)
			// Table and dates are computed here, never taken from input.
			ddl := fmt.Sprintf(`CREATE TABLE public.%s PARTITION OF public.%s FOR VALUES FROM ('%s') TO ('%s')`,
				name, table, month.Format(time.DateOnly), next.Format(time.DateOnly))
			if _, err := e.owner.Exec(ctx, ddl); err != nil {
				return created, fmt.Errorf("create partition %s: %w", name, err)
			}
			for _, statement := range []string{
				fmt.Sprintf("ALTER TABLE public.%s ENABLE ROW LEVEL SECURITY", name),
				fmt.Sprintf("ALTER TABLE public.%s FORCE ROW LEVEL SECURITY", name),
				fmt.Sprintf("CREATE POLICY tenant_isolation ON public.%s USING (tenant_id = app.current_tenant_id()) WITH CHECK (tenant_id = app.current_tenant_id())", name),
			} {
				if _, err := e.owner.Exec(ctx, statement); err != nil {
					return created, err
				}
			}
			created = append(created, name)
		}
	}
	return created, nil
}

// dropEmptyPartitions removes only what this run created, and only when the
// merchant's rows have gone with the tenant.
func dropEmptyPartitions(e *env, names []string) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	for _, name := range names {
		var empty bool
		if err := e.owner.QueryRow(ctx, "SELECT NOT EXISTS (SELECT 1 FROM "+pgx.Identifier{name}.Sanitize()+" LIMIT 1)").Scan(&empty); err != nil || !empty {
			fmt.Printf("keeping partition %s (not empty or unreadable)\n", name)
			continue
		}
		if _, err := e.owner.Exec(ctx, "DROP TABLE "+pgx.Identifier{name}.Sanitize()); err != nil {
			fmt.Println("drop partition:", err)
		}
	}
}

// mentionsRawOrders looks for the tables a report must never read. The rollup
// tables are named daily_… and the markers report_…, so a plain substring
// would accuse the wrong statements.
func mentionsRawOrders(query string) bool {
	lower := strings.ToLower(strings.Join(strings.Fields(query), " "))
	for _, needle := range []string{"from orders", "join orders", "from order_items", "join order_items", "from only orders"} {
		if strings.Contains(lower, needle) {
			return true
		}
	}
	return false
}

func joinOffenders(offenders []string) string {
	if len(offenders) == 0 {
		return ""
	}
	return ": " + strings.Join(offenders, " | ")
}

func prefixIf(prefix, value string) string {
	if value == "" {
		return ""
	}
	return prefix + value
}

func truncate(text string, limit int) string {
	if len(text) <= limit {
		return text
	}
	return text[:limit] + "…"
}

func sorted(values []time.Duration) []time.Duration {
	out := append([]time.Duration(nil), values...)
	for i := 1; i < len(out); i++ {
		for j := i; j > 0 && out[j] < out[j-1]; j-- {
			out[j], out[j-1] = out[j-1], out[j]
		}
	}
	return out
}

func distinct(values []string) []string {
	seen := map[string]bool{}
	var out []string
	for _, value := range values {
		if !seen[value] {
			seen[value] = true
			out = append(out, value)
		}
	}
	return out
}

// autovacuumHealth reports which relations are behind. Dead tuples come from
// updates and deletes, so a COPY-seeded history exercises autoANALYZE (plans)
// while the rollup tables, rewritten slice by slice, are where autoVACUUM has
// something to do.
func autovacuumHealth(stats []TableStat) (analysed int, behind string) {
	var lagging []string
	for _, t := range stats {
		if t.LiveTuples == 0 {
			continue
		}
		if t.LastAutoanalyze != nil || t.LastAutovacuum != nil {
			analysed++
		}
		if t.DeadRatio() > 0.2 && t.DeadTuples > 10000 {
			lagging = append(lagging, fmt.Sprintf("%s (dead/live %.2f)", t.Relation, t.DeadRatio()))
		}
	}
	return analysed, strings.Join(lagging, ", ")
}

func defaultPartitionRows(stats []TableStat) int64 {
	for _, t := range stats {
		if t.Relation == "orders_default" {
			return t.LiveTuples
		}
	}
	return 0
}

// activateOneTill exercises the real activation path: a code minted through
// the domain service, then POST /api/v2/devices/activate as a tablet does.
//
// The single most valuable assertion in the repository is the one in
// verify-backoffice — a code minted in the browser activating a till. This is
// the harness's smaller version of the same idea, so the lifecycle it
// simulates starts where a real one does.
func activateOneTill(ctx context.Context, e *env, fleet *Fleet) (*Till, error) {
	var register string
	err := e.owner.QueryRow(ctx, `
		INSERT INTO pos_registers (tenant_id, outlet_id, name)
		VALUES ($1, $2, 'Load Activation Register') RETURNING id::text`,
		fleet.TenantID, fleet.Outlets[0]).Scan(&register)
	if err != nil {
		return nil, err
	}

	issued, err := devices.NewService(e.pools, e.appKey).Issue(ctx, fleet.TenantID, register, nil)
	if err != nil {
		return nil, fmt.Errorf("issue a code: %w", err)
	}

	client := newHTTPClient(4, e.insecureTLS)
	deviceUUID := newUUID()
	body := mustJSON(wire.ActivateRequest{Code: issued.Code, DeviceUuid: deviceUUID})

	// A till with no token yet: the activation endpoint is the one route that
	// takes none.
	anonymous := newTill(e.baseURL, client, deviceUUID, fleet.Outlets[0], "")
	status, payload, err := anonymous.do(ctx, "POST", "/api/v2/devices/activate", body)
	if err != nil {
		return nil, err
	}
	if status != 200 {
		return nil, fmt.Errorf("activate: HTTP %d", status)
	}
	var response wire.ActivateResponse
	if err := json.Unmarshal(payload, &response); err != nil {
		return nil, err
	}
	if response.Data.Token == "" {
		return nil, fmt.Errorf("activate: no token in the response")
	}

	e.logger.Debug("activated a till", slog.String("device_id", response.Data.Device.Id))
	return newTill(e.baseURL, client, response.Data.Device.Id, response.Data.Outlet.Id, response.Data.Token), nil
}

// planLine pulls the line that carries the claim out of an EXPLAIN, so the
// evidence printed next to a gate is the node it is about rather than the
// plan's first line.
func planLine(plan, needle string) string {
	for _, line := range strings.Split(plan, "\n") {
		if strings.Contains(line, needle) {
			return strings.TrimSpace(line)
		}
	}
	return firstLine(plan)
}
