package syncfeed

import (
	"github.com/daniryckidinata/nti_pos/backend-go/internal/httpapi/wire"
	"strings"
)

// ApplyMode tells the till how to write a pulled row.
type ApplyMode = wire.ManifestEntityApply

const (
	// ApplyUpsert updates in place, leaving rows the page did not mention
	// alone. Everything published today uses it.
	ApplyUpsert ApplyMode = "upsert"
	// ApplyReplace deletes the row and re-inserts it. Nothing uses it yet, and
	// the note on productModifierOptions below is why it is spelled out in the
	// manifest rather than assumed.
	ApplyReplace ApplyMode = "replace"
)

// column is one published field: the key on the wire, and the SQL that
// produces it.
//
// Explicit per entity rather than SELECT *, so a column added later for
// server-side bookkeeping is never silently published to fifteen thousand
// tablets. In the Laravel original this list existed because mapping an entity
// name to a model by convention had once served `employees` complete with
// password hashes to anything holding a device token.
type column struct {
	wire string
	expr string
}

func col(name string) column     { return column{wire: name, expr: name} }
func uuidCol(name string) column { return column{wire: name, expr: name + "::text"} }

// renamed publishes a column under a different wire name.
func renamed(wireName, name string) column { return column{wire: wireName, expr: name} }

// Entity is one pullable feed.
type Entity struct {
	Name  string
	Scope Scope
	Table string
	// Key names the columns that identify a row on the wire. Most entities are
	// keyed by `id`; the join tables are keyed by their pair, because on the
	// device that pair IS the primary key.
	Key []string
	// DependsOn is published so the till can apply entities in an order its
	// foreign keys accept. The device runs with PRAGMA foreign_keys ON, so a
	// product landing before its category fails outright — and publishing the
	// order keeps adding an entity a server-side change.
	DependsOn []string
	Apply     ApplyMode
	// Push says tills also write this feed. Only the stock ledger does; the
	// projection it drives never travels upward.
	Push    bool
	columns []column
}

// selectJSON builds the row payload.
//
// One jsonb object per row rather than a column list, so the wire types are
// decided here and not by whatever the driver infers: uuids become strings,
// timestamps become epoch milliseconds, and money stays an integer.
func (e Entity) selectJSON() string {
	var b strings.Builder
	b.WriteString("jsonb_build_object(")

	for _, c := range e.columns {
		b.WriteString("'")
		b.WriteString(c.wire)
		b.WriteString("', ")
		b.WriteString(c.expr)
		b.WriteString(", ")
	}

	// On every row without exception. sync_seq is the cursor the device stores;
	// deleted_at_ms is the tombstone, and a tombstone is the only way a till
	// ever learns a row is gone — absence from a delta page means nothing.
	b.WriteString("'sync_seq', sync_seq, ")
	b.WriteString("'deleted_at_ms', (EXTRACT(EPOCH FROM deleted_at) * 1000)::bigint)")

	return b.String()
}

// Entities are ordered so that a dependency always precedes its dependents.
// The order is the contract; do not sort this slice.
var entities = []Entity{
	{
		// Staff first: a till has to know who may sign in before anything else
		// matters, and nothing in the catalogue depends on it either way.
		//
		// Note what is absent: `email` and `password`. A browser credential is
		// of no use to a till, and copying it to every tablet in every branch
		// would put it somewhere far easier to reach than the server.
		// `pin_hash` travels because offline sign-in genuinely needs it, and it
		// is a hash the device verifies locally, never a plaintext PIN.
		Name: "employees", Scope: ScopeCompany, Table: "employees",
		Key: []string{"id"}, Apply: ApplyUpsert,
		columns: []column{uuidCol("id"), col("name"), col("pin_hash"), col("role"), col("active"), col("sort_order")},
	},
	{
		// Branch structure is pulled now, not just handed over once at
		// activation. Renaming a branch in the Backoffice used to reach no till
		// that was already running.
		Name: "outlets", Scope: ScopeCompany, Table: "outlets",
		Key: []string{"id"}, Apply: ApplyUpsert,
		columns: []column{uuidCol("id"), col("name"), col("address"), col("active"), col("sort_order")},
	},
	{
		Name: "pos_registers", Scope: ScopeCompany, Table: "pos_registers",
		Key: []string{"id"}, DependsOn: []string{"outlets"}, Apply: ApplyUpsert,
		columns: []column{
			uuidCol("id"), uuidCol("outlet_id"), col("name"), col("table_service"),
			col("active"), col("sort_order"),
		},
	},
	{
		Name: "categories", Scope: ScopeCompany, Table: "categories",
		Key: []string{"id"}, Apply: ApplyUpsert,
		columns: []column{uuidCol("id"), col("name"), col("icon_key"), col("sort_order"), col("is_popular")},
	},
	{
		Name: "products", Scope: ScopeCompany, Table: "products",
		Key: []string{"id"}, DependsOn: []string{"categories"}, Apply: ApplyUpsert,
		columns: []column{
			uuidCol("id"), uuidCol("category_id"), col("name"), col("price"), col("cost"),
			col("sku"), col("tax_rate"), col("description"), col("image_url"), col("icon_key"),
			col("available"), col("is_popular"), col("sort_order"),
		},
	},
	{
		Name: "product_variants", Scope: ScopeCompany, Table: "product_variants",
		Key: []string{"id"}, DependsOn: []string{"products"}, Apply: ApplyUpsert,
		columns: []column{
			uuidCol("id"), uuidCol("product_id"), col("name"), col("price_delta"), col("sort_order"),
		},
	},
	{
		Name: "modifier_groups", Scope: ScopeCompany, Table: "modifier_groups",
		Key: []string{"id"}, Apply: ApplyUpsert,
		columns: []column{
			uuidCol("id"), col("name"), col("selection_type"), col("required"),
			col("max_select"), col("sort_order"), col("active"),
		},
	},
	{
		Name: "modifier_options", Scope: ScopeCompany, Table: "modifier_options",
		Key: []string{"id"}, DependsOn: []string{"modifier_groups"}, Apply: ApplyUpsert,
		columns: []column{
			uuidCol("id"), uuidCol("group_id"), col("name"), col("price_delta"),
			col("sort_order"), col("active"),
		},
	},
	{
		Name: "product_modifier_groups", Scope: ScopeCompany, Table: "product_modifier_groups",
		Key:       []string{"product_id", "group_id"},
		DependsOn: []string{"products", "modifier_groups"}, Apply: ApplyUpsert,
		columns: []column{uuidCol("product_id"), uuidCol("group_id")},
	},
	{
		// apply:"upsert" is load-bearing here, which is why the manifest says
		// so rather than leaving it to the client's default. The till's
		// ConflictAlgorithm.replace deletes before inserting, and on the device
		// this table cascades from modifier_options — so replacing one row
		// would take every product's option scoping with it, and menus would
		// quietly start offering choices nobody priced.
		Name: "product_modifier_options", Scope: ScopeCompany, Table: "product_modifier_options",
		Key:       []string{"product_id", "option_id"},
		DependsOn: []string{"products", "modifier_options"}, Apply: ApplyUpsert,
		columns: []column{uuidCol("product_id"), uuidCol("option_id"), col("is_default")},
	},
	{
		// all_outlets decides what promo_outlets means. When it is true the
		// promo is live everywhere and promo_outlets is empty; when it is
		// false the promo is live only where promo_outlets says — and with
		// no rows, nowhere. Absence of scoping rows must never read as "all",
		// or narrowing a promo one branch too far would spread it company-wide.
		Name: "promos", Scope: ScopeCompany, Table: "promos",
		Key: []string{"id"}, Apply: ApplyUpsert,
		columns: []column{
			uuidCol("id"), col("name"), col("kind"), col("value"),
			col("min_spend"), col("active"), col("sort_order"), col("all_outlets"),
		},
	},
	{
		// A table, not an array column on promos: a delta feed has to be able
		// to say "this one branch stopped being included", where a rewritten
		// array can only say "the promo changed" and make every till in the
		// chain re-read a row that did not concern it.
		Name: "promo_outlets", Scope: ScopeCompany, Table: "promo_outlets",
		Key:       []string{"promo_id", "outlet_id"},
		DependsOn: []string{"promos", "outlets"}, Apply: ApplyUpsert,
		columns: []column{uuidCol("promo_id"), uuidCol("outlet_id")},
	},
	{
		// The count at one branch, derived from the ledger below and kept in
		// the same transaction as every movement. Pulled as the authoritative
		// snapshot; never pushed. Outlet-scoped: a till receives its own
		// branch's shelf and no other.
		Name: "outlet_stock", Scope: ScopeOutlet, Table: "outlet_stock",
		Key:       []string{"outlet_id", "product_id"},
		DependsOn: []string{"outlets", "products"}, Apply: ApplyUpsert,
		columns: []column{uuidCol("outlet_id"), uuidCol("product_id"), col("qty_on_hand")},
	},
	{
		// The ledger itself, and the one feed tills both pull and push. A till
		// pulls its branch's movements for history; `stock_seq` is the
		// projection sequence each was applied at, which is how a till knows
		// whether its own movement is already inside the snapshot it holds.
		Name: "stock_movements", Scope: ScopeOutlet, Table: "stock_movements",
		Key: []string{"id"}, DependsOn: []string{"outlets", "products"}, Apply: ApplyUpsert,
		Push: true,
		columns: []column{
			uuidCol("id"), uuidCol("outlet_id"), uuidCol("product_id"), col("product_name"),
			col("reason"), col("delta_qty"), col("counted_qty"), col("balance_after"),
			col("occurred_at_ms"), col("employee_name"), col("note"), col("source"),
			renamed("stock_seq", "applied_stock_seq"),
		},
	},
	{
		// A branch's floor plan (Fase 6). Backoffice-owned, pulled by every till
		// in the branch like the menu; `area` is what the till calls `floor`.
		Name: "tables", Scope: ScopeOutlet, Table: "tables",
		Key: []string{"id"}, DependsOn: []string{"outlets"}, Apply: ApplyUpsert,
		columns: []column{
			uuidCol("id"), uuidCol("outlet_id"), col("name"), col("area"), col("capacity"),
			col("pos_x"), col("pos_y"), col("sort_order"), col("active"),
		},
	},
	{
		// Each table's live status: the projection of the status events tills
		// push (table_status_events, push-only). `contested` says two tills
		// raced on the table; the till shows it rather than hiding the
		// disagreement. The row's sync_seq is what a till's next event names as
		// its basis.
		Name: "table_status", Scope: ScopeOutlet, Table: "table_status",
		Key: []string{"table_id"}, DependsOn: []string{"tables"}, Apply: ApplyUpsert,
		columns: []column{
			uuidCol("table_id"), uuidCol("outlet_id"), col("status"), col("occurred_at_ms"),
			col("employee_name"), col("contested"),
		},
	},
}

var byName = func() map[string]Entity {
	m := make(map[string]Entity, len(entities))
	for _, e := range entities {
		m[e.Name] = e
	}
	return m
}()

// Lookup resolves an entity name that arrived from a client.
//
// An allow-list, never a lookup by table name from the request: turning client
// input into a table is how an endpoint ends up serving whatever the caller
// names.
func Lookup(name string) (Entity, bool) {
	e, ok := byName[name]
	return e, ok
}

// Entities returns the feeds in dependency order.
func Entities() []Entity {
	out := make([]Entity, len(entities))
	copy(out, entities)
	return out
}

// scopeKeyFor names the counter an entity's rows are numbered by: one per
// merchant for company feeds, one per branch for outlet feeds. outletID is
// ignored for a company feed.
func scopeKeyFor(e Entity, tenantID, outletID string) string {
	if e.Scope == ScopeOutlet {
		return OutletScope(tenantID, outletID, e.Name)
	}
	return CompanyScope(tenantID, e.Name)
}
