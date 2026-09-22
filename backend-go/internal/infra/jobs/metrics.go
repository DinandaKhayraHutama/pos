package jobs

import (
	"context"
	"log/slog"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/prometheus/client_golang/prometheus"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/store/unscoped"
)

// FleetCollector reports the fleet-wide numbers the plan's alerts are written
// against: River's queue depth and its dead jobs, how stale the report rollups
// are, how many tills were seen in the last five minutes, and whether anything
// has landed in a DEFAULT partition.
//
// It lives in this package because these are cross-merchant reads and this
// package is already on the `unscoped` allow-list. Putting it anywhere else
// would add a package to that list, which is a security review — and the
// worker is the right process for it anyway: one instance, no request path to
// slow down.
//
// Scrapes are coalesced: several Prometheus servers (or a scrape and a manual
// curl) share one set of queries within minInterval rather than each opening
// its own transaction.
type FleetCollector struct {
	pool        *pgxpool.Pool
	logger      *slog.Logger
	now         func() time.Time
	minInterval time.Duration

	mu      sync.Mutex
	last    time.Time
	current fleetSnapshot

	riverJobs        *prometheus.Desc
	dirtySlices      *prometheus.Desc
	rollupStaleness  *prometheus.Desc
	devicesSeen      *prometheus.Desc
	defaultPartition *prometheus.Desc
	scrapeOK         *prometheus.Desc
}

type fleetSnapshot struct {
	ok               bool
	jobs             []jobCount
	dirtySlices      int64
	rollupStaleness  float64
	devicesSeen      int64
	occupiedDefaults map[string]bool
}

type jobCount struct {
	state, queue string
	count        int64
}

func NewFleetCollector(pool *pgxpool.Pool, logger *slog.Logger) *FleetCollector {
	return &FleetCollector{
		pool: pool, logger: logger, now: time.Now, minInterval: 15 * time.Second,
		riverJobs:   prometheus.NewDesc("justclick_river_jobs", "Background jobs by queue and state.", []string{"queue", "state"}, nil),
		dirtySlices: prometheus.NewDesc("justclick_report_dirty_slices", "Report slices waiting to be recomputed.", nil, nil),
		// Age of the OLDEST unfinished marker, not an average: one slice stuck
		// for an hour is the incident, and an average over a thousand fresh
		// ones would hide it.
		rollupStaleness:  prometheus.NewDesc("justclick_report_rollup_staleness_seconds", "Age of the oldest report slice still waiting.", nil, nil),
		devicesSeen:      prometheus.NewDesc("justclick_devices_seen_5m", "Devices that made a request in the last five minutes.", nil, nil),
		defaultPartition: prometheus.NewDesc("justclick_default_partition_occupied", "1 when rows have landed in a DEFAULT partition, where no report or retention job looks.", []string{"table"}, nil),
		scrapeOK:         prometheus.NewDesc("justclick_fleet_scrape_ok", "1 when the last fleet query succeeded.", nil, nil),
	}
}

func (c *FleetCollector) Describe(ch chan<- *prometheus.Desc) {
	ch <- c.riverJobs
	ch <- c.dirtySlices
	ch <- c.rollupStaleness
	ch <- c.devicesSeen
	ch <- c.defaultPartition
	ch <- c.scrapeOK
}

func (c *FleetCollector) Collect(ch chan<- prometheus.Metric) {
	snapshot := c.snapshot()

	ok := 0.0
	if snapshot.ok {
		ok = 1
	}
	ch <- prometheus.MustNewConstMetric(c.scrapeOK, prometheus.GaugeValue, ok)
	if !snapshot.ok {
		// Publishing the last good numbers as if they were current would be a
		// dashboard that looks healthy while the database is unreachable.
		return
	}

	for _, j := range snapshot.jobs {
		ch <- prometheus.MustNewConstMetric(c.riverJobs, prometheus.GaugeValue, float64(j.count), j.queue, j.state)
	}
	ch <- prometheus.MustNewConstMetric(c.dirtySlices, prometheus.GaugeValue, float64(snapshot.dirtySlices))
	ch <- prometheus.MustNewConstMetric(c.rollupStaleness, prometheus.GaugeValue, snapshot.rollupStaleness)
	ch <- prometheus.MustNewConstMetric(c.devicesSeen, prometheus.GaugeValue, float64(snapshot.devicesSeen))
	for table, occupied := range snapshot.occupiedDefaults {
		value := 0.0
		if occupied {
			value = 1
		}
		ch <- prometheus.MustNewConstMetric(c.defaultPartition, prometheus.GaugeValue, value, table)
	}
}

func (c *FleetCollector) snapshot() fleetSnapshot {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.now().Sub(c.last) < c.minInterval {
		return c.current
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	fresh, err := c.read(ctx)
	c.last = c.now()
	if err != nil {
		c.logger.Warn("fleet metrics unavailable", slog.Any("error", err))
		c.current = fleetSnapshot{}
		return c.current
	}

	c.current = fresh
	return c.current
}

func (c *FleetCollector) read(ctx context.Context) (fleetSnapshot, error) {
	out := fleetSnapshot{ok: true, occupiedDefaults: map[string]bool{}}

	err := unscoped.Tx(ctx, c.pool, func(ctx context.Context, tx pgx.Tx) error {
		// A scrape must never be the thing that waits on a lock.
		if _, err := tx.Exec(ctx, "SET LOCAL statement_timeout = '4s'"); err != nil {
			return err
		}

		rows, err := tx.Query(ctx, `SELECT state::text, queue, count(*) FROM jobs.river_job GROUP BY 1, 2`)
		if err != nil {
			return err
		}
		out.jobs, err = pgx.CollectRows(rows, func(row pgx.CollectableRow) (jobCount, error) {
			var j jobCount
			return j, row.Scan(&j.state, &j.queue, &j.count)
		})
		if err != nil {
			return err
		}

		if err := tx.QueryRow(ctx, `
			SELECT count(*), COALESCE(EXTRACT(EPOCH FROM now() - min(changed_at)), 0)
			FROM report_dirty_slices`).Scan(&out.dirtySlices, &out.rollupStaleness); err != nil {
			return err
		}

		if err := tx.QueryRow(ctx,
			`SELECT count(*) FROM devices WHERE last_seen_at > now() - interval '5 minutes'`,
		).Scan(&out.devicesSeen); err != nil {
			return err
		}

		for _, table := range DefaultPartitions {
			var occupied bool
			if err := tx.QueryRow(ctx,
				"SELECT EXISTS (SELECT 1 FROM "+pgx.Identifier{table}.Sanitize()+" LIMIT 1)").Scan(&occupied); err != nil {
				return err
			}
			out.occupiedDefaults[table] = occupied
		}
		return nil
	})
	if err != nil {
		return fleetSnapshot{}, err
	}

	return out, nil
}
