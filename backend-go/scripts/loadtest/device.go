package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"sync"
	"time"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/httpapi/wire"
)

// newHTTPClient is shared by every simulated till.
//
// One client, so connections are reused the way a real fleet's are — but with
// an idle pool big enough for the whole worker set: a pool smaller than the
// concurrency turns every request into a fresh TCP (and TLS) handshake, and
// the run then measures connection setup rather than the server.
func newHTTPClient(workers int, insecureTLS bool) *http.Client {
	transport := &http.Transport{
		Proxy:               nil,
		MaxIdleConns:        workers * 2,
		MaxIdleConnsPerHost: workers * 2,
		MaxConnsPerHost:     0,
		IdleConnTimeout:     90 * time.Second,
		DialContext:         (&net.Dialer{Timeout: 10 * time.Second, KeepAlive: 30 * time.Second}).DialContext,
		DisableCompression:  true,
	}
	if insecureTLS {
		// Local development CA only; never a flag to set against a real host.
		transport.TLSClientConfig = &tls.Config{InsecureSkipVerify: true}
	}
	return &http.Client{Transport: transport, Timeout: 60 * time.Second}
}

// Till is one simulated device: a token, the branch it is bound to, and the
// cursors it has reached. It is not safe for concurrent use by design — a real
// tablet runs one sync at a time, and letting the harness do otherwise would
// measure a load no fleet can produce.
type Till struct {
	base    string
	client  *http.Client
	token   string
	id      string
	outlet  string
	cursors map[string]int64

	sessionID string
	sequence  int64
}

func newTill(base string, client *http.Client, id, outlet, token string) *Till {
	return &Till{base: base, client: client, token: token, id: id, outlet: outlet, cursors: map[string]int64{}}
}

func (t *Till) do(ctx context.Context, method, path string, body []byte) (int, []byte, error) {
	var reader io.Reader
	if body != nil {
		reader = bytes.NewReader(body)
	}
	req, err := http.NewRequestWithContext(ctx, method, t.base+path, reader)
	if err != nil {
		return 0, nil, err
	}
	req.Header.Set("Authorization", "Bearer "+t.token)
	req.Header.Set("X-Schema-Version", fmt.Sprint(syncfeed.SchemaVersion))
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}

	resp, err := t.client.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()

	// Read to the end even when the status is wrong: an unread body is a
	// connection that cannot be reused, and the run would then be measuring
	// handshakes.
	payload, err := io.ReadAll(resp.Body)
	return resp.StatusCode, payload, err
}

func (t *Till) Changes(ctx context.Context) (wire.Changes, int, error) {
	status, body, err := t.do(ctx, http.MethodGet, "/api/v2/sync/changes", nil)
	if err != nil {
		return wire.Changes{}, status, err
	}
	if status != http.StatusOK {
		return wire.Changes{}, status, fmt.Errorf("changes: HTTP %d", status)
	}
	var out wire.Changes
	if err := json.Unmarshal(body, &out); err != nil {
		return wire.Changes{}, status, fmt.Errorf("changes: %w", err)
	}
	if out.Cursors == nil {
		// The till reads any 2xx that is not an object as malformed, and on
		// the push path that is what deletes a queued sale. Worth checking on
		// every single measured response rather than once in a unit test.
		return out, status, fmt.Errorf("changes: response carried no cursors object")
	}
	return out, status, nil
}

func (t *Till) Pull(ctx context.Context, entity string, afterSeq int64, limit int) (wire.PullPage, int, error) {
	path := fmt.Sprintf("/api/v2/sync/pull?entity=%s&after_seq=%d&limit=%d", entity, afterSeq, limit)
	status, body, err := t.do(ctx, http.MethodGet, path, nil)
	if err != nil {
		return wire.PullPage{}, status, err
	}
	if status != http.StatusOK {
		return wire.PullPage{}, status, fmt.Errorf("pull %s: HTTP %d", entity, status)
	}
	var page wire.PullPage
	if err := json.Unmarshal(body, &page); err != nil {
		return wire.PullPage{}, status, fmt.Errorf("pull %s: %w", entity, err)
	}
	return page, status, nil
}

func (t *Till) Push(ctx context.Context, req wire.PushRequest) (wire.PushResponse, int, error) {
	body, err := json.Marshal(req)
	if err != nil {
		return wire.PushResponse{}, 0, err
	}
	status, payload, err := t.do(ctx, http.MethodPost, "/api/v2/sync/push", body)
	if err != nil {
		return wire.PushResponse{}, status, err
	}
	if status != http.StatusOK {
		return wire.PushResponse{}, status, fmt.Errorf("push: HTTP %d", status)
	}
	var out wire.PushResponse
	if err := json.Unmarshal(payload, &out); err != nil {
		return wire.PushResponse{}, status, fmt.Errorf("push: %w", err)
	}
	return out, status, nil
}

// Startup is what a till does when the app opens: ask what changed, and page
// whatever moved.
//
// The fleet-wide cost of a morning depends entirely on this being the shape it
// is. A till that is already current makes ONE request and stops, which is why
// fifteen thousand of them are survivable at all.
func (t *Till) Startup(ctx context.Context) Outcome {
	changes, status, err := t.Changes(ctx)
	if err != nil {
		return Outcome{Status: status, Err: err}
	}

	pulled := 0
	for entity, mark := range changes.Cursors {
		for t.cursors[entity] < mark {
			page, pullStatus, err := t.Pull(ctx, entity, t.cursors[entity], 500)
			if err != nil {
				return Outcome{Status: pullStatus, Err: err, Accepted: pulled}
			}
			pulled += len(page.Rows)
			if page.NextSeq <= t.cursors[entity] {
				break // nothing further to page; avoid spinning on a stuck cursor
			}
			t.cursors[entity] = page.NextSeq
			if !page.HasMore {
				break
			}
		}
	}
	return Outcome{Status: status, Accepted: pulled}
}

// OpenSession pushes the open drawer this till's orders will belong to.
func (t *Till) OpenSession(ctx context.Context) error {
	t.sessionID = newUUID()
	session := wire.Session{
		Id: t.sessionID, Revision: 1, EmployeeName: "Load Cashier",
		OpenedAtMs: time.Now().UnixMilli(), OpeningCash: 100000,
	}
	response, _, err := t.Push(ctx, wire.PushRequest{Batches: []wire.PushBatch{{
		Entity: "pos_sessions", Rows: []json.RawMessage{mustJSON(session)},
	}}})
	if err != nil {
		return err
	}
	for _, result := range response.Results {
		if result.Status != "accepted" {
			return fmt.Errorf("session refused: %s (%s)", result.Status, code(result))
		}
	}
	return nil
}

// Sell pushes a batch of receipts, the way a till drains its outbox.
func (t *Till) Sell(ctx context.Context, products []product, orders int) Outcome {
	rows := make([]json.RawMessage, 0, orders)
	for range orders {
		rows = append(rows, mustJSON(t.receipt(products)))
	}
	response, status, err := t.Push(ctx, wire.PushRequest{Batches: []wire.PushBatch{{Entity: "orders", Rows: rows}}})
	if err != nil {
		return Outcome{Status: status, Err: err}
	}
	return summarise(response, status)
}

// receipt builds one plausible sale: two lines, one of them with a modifier.
// unit_price already includes the modifier delta — adding it again is the
// money bug this system's rules exist to prevent.
func (t *Till) receipt(products []product) wire.Order {
	t.sequence++
	first := products[int(t.sequence)%len(products)]
	second := products[int(t.sequence*7+3)%len(products)]

	lineOne := wire.OrderItem{
		Id: newUUID(), ProductId: &first.id, ProductName: first.name, Quantity: 1,
		UnitPrice: first.price + 2000,
		Modifiers: []wire.OrderItemModifier{{
			Id: newUUID(), GroupName: "Susu", OptionName: "Oat", PriceDelta: 2000,
		}},
	}
	lineTwo := wire.OrderItem{
		Id: newUUID(), ProductId: &second.id, ProductName: second.name, Quantity: 2,
		UnitPrice: second.price, Modifiers: []wire.OrderItemModifier{},
	}

	subtotal := lineOne.UnitPrice*int64(lineOne.Quantity) + lineTwo.UnitPrice*int64(lineTwo.Quantity)
	now := time.Now()
	return wire.Order{
		Id: newUUID(), Revision: 1,
		// Chosen by the device and immutable in the outbox, so a push that is
		// a day late still lands in the day it was rung up.
		BusinessDate: now.UTC().Format(time.DateOnly),
		Number:       fmt.Sprintf("LOAD-%s-%d", t.id[:8], t.sequence),
		PlacedAtMs:   now.UnixMilli(), Type: "dinein", Status: "paid",
		PosSessionId: t.sessionID, Subtotal: subtotal, Total: subtotal,
		AmountPaid: subtotal, PaymentMethod: "cash", CashierName: "Load Cashier",
		Items: []wire.OrderItem{lineOne, lineTwo},
	}
}

// MoveStock pushes one ledger movement, the delta a sale leaves behind.
func (t *Till) MoveStock(ctx context.Context, p product, delta int64) Outcome {
	movement := wire.StockMovement{
		Id: newUUID(), Revision: 1, ProductId: p.id, ProductName: p.name,
		Reason: "sale", DeltaQty: delta, OccurredAtMs: time.Now().UnixMilli(),
		EmployeeName: "Load Cashier",
	}
	response, status, err := t.Push(ctx, wire.PushRequest{Batches: []wire.PushBatch{{
		Entity: "stock_movements", Rows: []json.RawMessage{mustJSON(movement)},
	}}})
	if err != nil {
		return Outcome{Status: status, Err: err}
	}
	return summarise(response, status)
}

func summarise(response wire.PushResponse, status int) Outcome {
	out := Outcome{Status: status}
	for _, result := range response.Results {
		if result.Status == "accepted" {
			out.Accepted++
			continue
		}
		out.Rejected++
		out.Codes = append(out.Codes, code(result))
	}
	return out
}

func code(result wire.PushResult) string {
	if result.Code == nil {
		return "unnamed"
	}
	return string(*result.Code)
}

func mustJSON(v any) json.RawMessage {
	raw, err := json.Marshal(v)
	if err != nil {
		panic(err)
	}
	return raw
}

// Identifiers come from a buffered read of crypto/rand rather than a syscall
// per identifier.
//
// Still cryptographic: the entropy is the same, it is simply drawn in blocks.
// It matters because seeding a large history mints three of these per receipt,
// and at a few million receipts one syscall each was the slowest thing in the
// scenario — the generator, not the system under test.
var (
	uuidMu     sync.Mutex
	uuidBuffer [1 << 16]byte
	uuidOffset = len(uuidBuffer)
)

func newUUID() string {
	var b [16]byte

	uuidMu.Lock()
	if uuidOffset+16 > len(uuidBuffer) {
		if _, err := rand.Read(uuidBuffer[:]); err != nil {
			uuidMu.Unlock()
			panic(err)
		}
		uuidOffset = 0
	}
	copy(b[:], uuidBuffer[uuidOffset:uuidOffset+16])
	uuidOffset += 16
	uuidMu.Unlock()

	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[:4], b[4:6], b[6:8], b[8:10], b[10:])
}

// startupSpread is the Flutter till's own rule, ported exactly:
// sha256(device_id), the first four bytes as a big-endian signed 31-bit
// number, modulo the window.
//
// It has to be the same function, not merely a similar one. The morning-rush
// scenario's whole claim — that the spread flattens the burst — is a claim
// about the distribution THIS produces, and a harness that spread devices some
// other way would prove nothing about the fleet.
// See mobile/lib/data/sync/sync_scheduler.dart: startupSpreadFor.
func startupSpread(deviceID string, window time.Duration) time.Duration {
	sum := sha256.Sum256([]byte(deviceID))
	value := binary.BigEndian.Uint32(sum[:4]) & 0x7fffffff
	seconds := window / time.Second
	if seconds <= 0 {
		return 0
	}
	return time.Duration(int64(value)%int64(seconds)) * time.Second
}
