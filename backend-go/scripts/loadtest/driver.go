package main

import (
	"context"
	"math"
	"sort"
	"sync"
	"time"
)

// Schedule says when arrival i is due, measured from the start of the run.
//
// An OPEN model: arrivals are due whether or not the previous one has come
// back. A closed loop (N workers, each looping as fast as the server answers)
// measures a system that politely slows its own load down when it struggles,
// and reports healthy latency for a server nobody could use. Fifteen thousand
// tills do not wait for each other.
type Schedule func(i int64) time.Duration

// ConstantRate spaces arrivals evenly. Evenly rather than by Poisson draw
// because the gates are stated as "2,000 rps", and a Poisson burst would make
// the measurement argue with its own target.
func ConstantRate(perSecond float64) Schedule {
	return func(i int64) time.Duration {
		return time.Duration(float64(i) / perSecond * float64(time.Second))
	}
}

// AtTimes replays a precomputed arrival list, for a scenario whose shape is
// the point — the morning rush, where the whole question is when each till
// decides to speak.
func AtTimes(offsets []time.Duration) Schedule {
	return func(i int64) time.Duration {
		if i < 0 || i >= int64(len(offsets)) {
			return 0
		}
		return offsets[i]
	}
}

// Outcome is what one simulated request produced. Accepted and Rejected are
// row counts on the push path, where one HTTP 200 can still hold a rejection.
type Outcome struct {
	Status   int
	Err      error
	Accepted int
	Rejected int
	// Codes are the per-row rejection codes, kept so a run can say WHICH
	// refusal it hit rather than only how many.
	Codes []string
}

type Driver struct {
	Count int64
	// Schedule nil means a CLOSED loop: arrivals go out as workers free up and
	// none is ever dropped. That is the right model when the question is what
	// the database did rather than how the server behaves at a rate — the
	// catalogue fan-out has to have every till pull exactly once, and an open
	// model that dropped a third of them would be counting the wrong thing.
	Schedule Schedule
	// Workers bounds concurrency. An arrival that finds every worker busy is
	// DROPPED and counted, never quietly delayed: a delayed arrival is how a
	// load test lies about the latency of an overloaded server.
	Workers int
	Call    func(ctx context.Context, arrival int64) Outcome
}

type Run struct {
	Started   int64
	Completed int64
	Dropped   int64
	Failed    int64
	Accepted  int64
	Rejected  int64
	Statuses  map[int]int64
	Codes     map[string]int64
	Errors    map[string]int64
	Elapsed   time.Duration
	// Latencies is sorted ascending once the run is over.
	Latencies []time.Duration
	// PerSecond counts completed requests in each whole second of the run,
	// which is what makes "does the startup spread flatten the morning?"
	// answerable as a number rather than an opinion.
	PerSecond []int64
}

func (d Driver) Run(ctx context.Context) Run {
	var (
		mu                                    sync.Mutex
		latencies                             = make([]time.Duration, 0, d.Count)
		perSecond                             []int64
		statuses                              = map[int]int64{}
		codes                                 = map[string]int64{}
		errs                                  = map[string]int64{}
		completed, failed, accepted, rejected int64
		started, dropped                      int64
		wg                                    sync.WaitGroup
	)

	slots := make(chan struct{}, d.Workers)
	for range d.Workers {
		slots <- struct{}{}
	}

	start := time.Now()
	timer := time.NewTimer(time.Hour)
	defer timer.Stop()

	for i := int64(0); i < d.Count && ctx.Err() == nil; i++ {
		if d.Schedule != nil {
			if wait := time.Until(start.Add(d.Schedule(i))); wait > 0 {
				timer.Reset(wait)
				select {
				case <-timer.C:
				case <-ctx.Done():
					if !timer.Stop() {
						select {
						case <-timer.C:
						default:
						}
					}
				}
			}
			if ctx.Err() != nil {
				break
			}

			select {
			case <-slots:
			default:
				dropped++
				continue
			}
		} else {
			// Closed loop: wait for a worker rather than dropping the arrival.
			select {
			case <-slots:
			case <-ctx.Done():
			}
			if ctx.Err() != nil {
				break
			}
		}

		started++
		wg.Add(1)
		go func(arrival int64) {
			defer wg.Done()
			defer func() { slots <- struct{}{} }()

			began := time.Now()
			outcome := d.Call(ctx, arrival)
			elapsed := time.Since(began)
			second := int64(began.Sub(start) / time.Second)

			mu.Lock()
			defer mu.Unlock()
			latencies = append(latencies, elapsed)
			for int64(len(perSecond)) <= second {
				perSecond = append(perSecond, 0)
			}
			perSecond[second]++
			statuses[outcome.Status]++
			completed++
			accepted += int64(outcome.Accepted)
			rejected += int64(outcome.Rejected)
			for _, code := range outcome.Codes {
				codes[code]++
			}
			if outcome.Err != nil {
				failed++
				errs[outcome.Err.Error()]++
			}
		}(i)
	}

	// Always waited for: sorting latencies while workers still append to them
	// would be a data race, and a partial run is still a result worth printing.
	wg.Wait()
	elapsed := time.Since(start)

	sort.Slice(latencies, func(a, b int) bool { return latencies[a] < latencies[b] })
	return Run{
		Started: started, Completed: completed, Dropped: dropped, Failed: failed,
		Accepted: accepted, Rejected: rejected,
		Statuses: statuses, Codes: codes, Errors: errs,
		Elapsed: elapsed, Latencies: latencies, PerSecond: perSecond,
	}
}

// Percentile reads the sorted latencies. Nearest-rank, not interpolated: at
// these sample sizes the difference is noise, and an interpolated p99 is a
// number no single request ever experienced.
func (r Run) Percentile(p float64) time.Duration {
	if len(r.Latencies) == 0 {
		return 0
	}
	rank := int(math.Ceil(p / 100 * float64(len(r.Latencies))))
	if rank < 1 {
		rank = 1
	}
	if rank > len(r.Latencies) {
		rank = len(r.Latencies)
	}
	return r.Latencies[rank-1]
}

func (r Run) Mean() time.Duration {
	if len(r.Latencies) == 0 {
		return 0
	}
	var total time.Duration
	for _, l := range r.Latencies {
		total += l
	}
	return total / time.Duration(len(r.Latencies))
}

// PeakPerSecond is the busiest whole second of the run.
func (r Run) PeakPerSecond() int64 {
	var peak int64
	for _, n := range r.PerSecond {
		if n > peak {
			peak = n
		}
	}
	return peak
}

// Throughput is completed requests per second over the whole run.
func (r Run) Throughput() float64 {
	if r.Elapsed <= 0 {
		return 0
	}
	return float64(r.Completed) / r.Elapsed.Seconds()
}

// NonOK counts responses that were not HTTP 200.
func (r Run) NonOK() int64 {
	var n int64
	for status, count := range r.Statuses {
		if status != 200 {
			n += count
		}
	}
	return n
}
