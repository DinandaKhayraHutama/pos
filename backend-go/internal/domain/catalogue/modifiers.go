package catalogue

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"

	"github.com/jackc/pgx/v5"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/validation"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
)

const (
	SelectSingle   = "single"
	SelectMultiple = "multiple"
)

// ModifierGroup is a reusable set of choices a product can offer on top of its
// variant — spice level, toppings, sugar level.
type ModifierGroup struct {
	ID            string
	Name          string
	SelectionType string
	Required      bool
	// MaxSelect is nil for "no upper bound", and only meaningful for a
	// multiple-choice group: a single group is capped at one by definition.
	MaxSelect *int
	SortOrder int
	Active    bool
	Options   []ModifierOption
}

type ModifierOption struct {
	ID      string
	GroupID string
	Name    string
	// Never negative. A modifier adds to a line; discounts are promos, which
	// are audited.
	PriceDelta int64
	SortOrder  int
	Active     bool
}

// ProductModifiers is one product's whole modifier configuration, saved as a
// unit — the same shape the till's own form edits.
type ProductModifiers struct {
	GroupIDs         []string
	OptionIDs        []string
	DefaultOptionIDs []string
}

// limit is how many options of this group one line may carry. nil means
// unbounded.
func (g ModifierGroup) limit() *int {
	if g.SelectionType == SelectSingle {
		one := 1
		return &one
	}
	return g.MaxSelect
}

// ModifierGroups lists live groups with their live options.
func (s *Service) ModifierGroups(ctx context.Context, tenantID string) ([]ModifierGroup, error) {
	var groups []ModifierGroup

	err := pg.InTenantReadTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		var err error
		groups, err = loadGroups(ctx, tx, tenantID, "")
		return err
	})

	return groups, err
}

// ModifierGroup returns one live group with its live options.
func (s *Service) ModifierGroup(ctx context.Context, tenantID, id string) (ModifierGroup, error) {
	if !validation.UUID(id) {
		return ModifierGroup{}, ErrNotFound
	}

	var groups []ModifierGroup
	err := pg.InTenantReadTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		var err error
		groups, err = loadGroups(ctx, tx, tenantID, id)
		return err
	})
	if err != nil {
		return ModifierGroup{}, err
	}
	if len(groups) == 0 {
		return ModifierGroup{}, ErrNotFound
	}

	return groups[0], nil
}

func loadGroups(ctx context.Context, tx pgx.Tx, tenantID, onlyID string) ([]ModifierGroup, error) {
	rows, err := tx.Query(ctx, `
		SELECT id, name, selection_type, required, max_select, sort_order, active
		FROM modifier_groups
		WHERE tenant_id = $1 AND deleted_at IS NULL AND ($2 = '' OR id = NULLIF($2, '')::uuid)
		ORDER BY sort_order, name`, tenantID, onlyID)
	if err != nil {
		return nil, err
	}

	groups, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (ModifierGroup, error) {
		var g ModifierGroup
		err := row.Scan(&g.ID, &g.Name, &g.SelectionType, &g.Required, &g.MaxSelect, &g.SortOrder, &g.Active)
		return g, err
	})
	if err != nil {
		return nil, err
	}

	rows, err = tx.Query(ctx, `
		SELECT id, group_id, name, price_delta, sort_order, active
		FROM modifier_options
		WHERE tenant_id = $1 AND deleted_at IS NULL AND ($2 = '' OR group_id = NULLIF($2, '')::uuid)
		ORDER BY sort_order, name`, tenantID, onlyID)
	if err != nil {
		return nil, err
	}

	options, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (ModifierOption, error) {
		var o ModifierOption
		err := row.Scan(&o.ID, &o.GroupID, &o.Name, &o.PriceDelta, &o.SortOrder, &o.Active)
		return o, err
	})
	if err != nil {
		return nil, err
	}

	index := make(map[string]int, len(groups))
	for i, g := range groups {
		index[g.ID] = i
	}
	for _, o := range options {
		if i, ok := index[o.GroupID]; ok {
			groups[i].Options = append(groups[i].Options, o)
		}
	}

	return groups, nil
}

// SaveModifierGroup creates or updates a group.
//
// Narrowing a group is checked against the products already using it: turning
// "Topping" from multiple to single while a pastry pre-selects two toppings
// would leave that pastry with a default no picker can show.
func (s *Service) SaveModifierGroup(ctx context.Context, tenantID string, in ModifierGroup) (string, error) {
	in.Name = strings.TrimSpace(in.Name)

	errs := validation.Errors{}
	errs.Name("name", in.Name, 120)
	switch in.SelectionType {
	case SelectSingle:
		// A single-choice group is capped at one by definition; a stored bound
		// would only be a second, contradictory answer.
		in.MaxSelect = nil
	case SelectMultiple:
		if in.MaxSelect != nil && *in.MaxSelect < 1 {
			errs.Add("max_select", "Minimal 1, atau kosongkan untuk tanpa batas.")
		}
	default:
		errs.Add("selection_type", "Pilih tunggal atau banyak.")
	}
	if err := errs.Err(); err != nil {
		return "", err
	}
	if in.ID != "" && !validation.UUID(in.ID) {
		return "", ErrNotFound
	}

	id := in.ID

	err := s.feed.Write(ctx, tenantID, func(ctx context.Context, w *syncfeed.Writer) error {
		if in.ID != "" {
			if err := claim(ctx, w.Tx, "modifier_groups", tenantID, in.ID); err != nil {
				return err
			}
		}

		if in.ID != "" {
			if limit := in.limit(); limit != nil {
				var over int
				if err := w.Tx.QueryRow(ctx, `
					SELECT count(*) FROM (
					    SELECT pmo.product_id
					    FROM product_modifier_options pmo
					    JOIN modifier_options o ON o.tenant_id = pmo.tenant_id AND o.id = pmo.option_id
					    WHERE pmo.tenant_id = $1 AND o.group_id = $2
					      AND pmo.is_default AND pmo.deleted_at IS NULL AND o.deleted_at IS NULL
					    GROUP BY pmo.product_id
					    HAVING count(*) > $3) crowded`,
					tenantID, in.ID, *limit).Scan(&over); err != nil {
					return err
				}
				if over > 0 {
					return validation.Errors{"max_select": fmt.Sprintf(
						"%d produk memilih lebih banyak default dari batas ini. Ubah produknya dulu.", over)}
				}
			}
		}

		seq, err := w.Seq(ctx, "modifier_groups")
		if err != nil {
			return err
		}

		return w.Tx.QueryRow(ctx, `
			INSERT INTO modifier_groups
				(id, tenant_id, name, selection_type, required, max_select, sort_order, active, sync_seq)
			VALUES (COALESCE(NULLIF($1, '')::uuid, gen_random_uuid()), $2, $3, $4, $5, $6, $7, $8, $9)
			ON CONFLICT (id) DO UPDATE
			SET name           = EXCLUDED.name,
			    selection_type = EXCLUDED.selection_type,
			    required       = EXCLUDED.required,
			    max_select     = EXCLUDED.max_select,
			    sort_order     = EXCLUDED.sort_order,
			    active         = EXCLUDED.active,
			    sync_seq       = EXCLUDED.sync_seq,
			    deleted_at     = NULL,
			    updated_at     = now()
			RETURNING id`,
			in.ID, tenantID, in.Name, in.SelectionType, in.Required, in.MaxSelect,
			in.SortOrder, in.Active, seq,
		).Scan(&id)
	})
	if err != nil {
		return "", err
	}

	return id, nil
}

// DeleteModifierGroup retires a group and everything the device would cascade
// away with it: its options, every product's attachment to it, and every
// product's scoping of its options. Left alive here, those rows would never be
// mentioned to the till again after it deleted them locally.
func (s *Service) DeleteModifierGroup(ctx context.Context, tenantID, id string) error {
	if !validation.UUID(id) {
		return ErrNotFound
	}

	return s.feed.Write(ctx, tenantID, func(ctx context.Context, w *syncfeed.Writer) error {
		retired, err := retire(ctx, w, "modifier_groups", "modifier_groups",
			"tenant_id = $1 AND id = $2", tenantID, id)
		if err != nil {
			return err
		}
		if retired == 0 {
			return ErrNotFound
		}

		// Registry order, as every writer takes counters.
		if _, err := retire(ctx, w, "modifier_options", "modifier_options",
			"tenant_id = $1 AND group_id = $2", tenantID, id); err != nil {
			return err
		}
		if _, err := retire(ctx, w, "product_modifier_groups", "product_modifier_groups",
			"tenant_id = $1 AND group_id = $2", tenantID, id); err != nil {
			return err
		}
		_, err = retire(ctx, w, "product_modifier_options", "product_modifier_options",
			`tenant_id = $1 AND option_id IN (
			     SELECT id FROM modifier_options WHERE tenant_id = $1 AND group_id = $2)`, tenantID, id)
		return err
	})
}

// SaveModifierOption creates or updates one choice within a group.
func (s *Service) SaveModifierOption(ctx context.Context, tenantID string, in ModifierOption) (string, error) {
	in.Name = strings.TrimSpace(in.Name)

	errs := validation.Errors{}
	errs.Name("name", in.Name, 120)
	if in.PriceDelta < 0 {
		errs.Add("price_delta", "Tambahan harga tidak boleh negatif.")
	}
	if err := errs.Err(); err != nil {
		return "", err
	}
	if !validation.UUID(in.GroupID) || (in.ID != "" && !validation.UUID(in.ID)) {
		return "", ErrNotFound
	}

	id := in.ID

	err := s.feed.Write(ctx, tenantID, func(ctx context.Context, w *syncfeed.Writer) error {
		if in.ID != "" {
			if err := claim(ctx, w.Tx, "modifier_options", tenantID, in.ID); err != nil {
				return err
			}
		}

		var live bool
		if err := w.Tx.QueryRow(ctx, `
			SELECT EXISTS (SELECT 1 FROM modifier_groups
			               WHERE tenant_id = $1 AND id = $2 AND deleted_at IS NULL)`,
			tenantID, in.GroupID).Scan(&live); err != nil {
			return err
		}
		if !live {
			return ErrNotFound
		}

		// The till refuses a configuration whose default is an inactive
		// option. Switching one off here while a product pre-selects it would
		// hand every till a configuration its own form would reject.
		if in.ID != "" && !in.Active {
			var defaults int
			if err := w.Tx.QueryRow(ctx, `
				SELECT count(*) FROM product_modifier_options
				WHERE tenant_id = $1 AND option_id = $2 AND is_default AND deleted_at IS NULL`,
				tenantID, in.ID).Scan(&defaults); err != nil {
				return err
			}
			if defaults > 0 {
				return validation.Errors{"active": fmt.Sprintf(
					"Opsi ini masih jadi pilihan default di %d produk.", defaults)}
			}
		}

		seq, err := w.Seq(ctx, "modifier_options")
		if err != nil {
			return err
		}

		err = w.Tx.QueryRow(ctx, `
			INSERT INTO modifier_options
				(id, tenant_id, group_id, name, price_delta, sort_order, active, sync_seq)
			VALUES (COALESCE(NULLIF($1, '')::uuid, gen_random_uuid()), $2, $3, $4, $5, $6, $7, $8)
			ON CONFLICT (id) DO UPDATE
			SET name        = EXCLUDED.name,
			    price_delta = EXCLUDED.price_delta,
			    sort_order  = EXCLUDED.sort_order,
			    active      = EXCLUDED.active,
			    sync_seq    = EXCLUDED.sync_seq,
			    deleted_at  = NULL,
			    updated_at  = now()
			-- An option belongs to one group for life; product scoping is
			-- keyed by option alone precisely because of that.
			WHERE modifier_options.group_id = EXCLUDED.group_id
			RETURNING id`,
			in.ID, tenantID, in.GroupID, in.Name, in.PriceDelta, in.SortOrder, in.Active, seq,
		).Scan(&id)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		return err
	})
	if err != nil {
		return "", err
	}

	return id, nil
}

// DeleteModifierOption retires an option and every product's scoping of it.
func (s *Service) DeleteModifierOption(ctx context.Context, tenantID, id string) error {
	if !validation.UUID(id) {
		return ErrNotFound
	}

	return s.feed.Write(ctx, tenantID, func(ctx context.Context, w *syncfeed.Writer) error {
		retired, err := retire(ctx, w, "modifier_options", "modifier_options",
			"tenant_id = $1 AND id = $2", tenantID, id)
		if err != nil {
			return err
		}
		if retired == 0 {
			return ErrNotFound
		}

		_, err = retire(ctx, w, "product_modifier_options", "product_modifier_options",
			"tenant_id = $1 AND option_id = $2", tenantID, id)
		return err
	})
}

// ProductModifiers reads one product's live configuration.
func (s *Service) ProductModifiers(ctx context.Context, tenantID, productID string) (ProductModifiers, error) {
	if !validation.UUID(productID) {
		return ProductModifiers{}, ErrNotFound
	}

	var cfg ProductModifiers
	err := pg.InTenantReadTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		var err error
		cfg, _, _, err = currentConfig(ctx, tx, tenantID, productID)
		return err
	})

	return cfg, err
}

func currentConfig(ctx context.Context, tx pgx.Tx, tenantID, productID string) (ProductModifiers, map[string]bool, map[string]bool, error) {
	var cfg ProductModifiers

	rows, err := tx.Query(ctx, `
		SELECT group_id::text FROM product_modifier_groups
		WHERE tenant_id = $1 AND product_id = $2 AND deleted_at IS NULL`, tenantID, productID)
	if err != nil {
		return cfg, nil, nil, err
	}
	if cfg.GroupIDs, err = pgx.CollectRows(rows, pgx.RowTo[string]); err != nil {
		return cfg, nil, nil, err
	}

	rows, err = tx.Query(ctx, `
		SELECT option_id::text, is_default FROM product_modifier_options
		WHERE tenant_id = $1 AND product_id = $2 AND deleted_at IS NULL`, tenantID, productID)
	if err != nil {
		return cfg, nil, nil, err
	}

	groups := make(map[string]bool, len(cfg.GroupIDs))
	for _, g := range cfg.GroupIDs {
		groups[g] = true
	}

	options := map[string]bool{}
	for rows.Next() {
		var (
			id        string
			isDefault bool
		)
		if err := rows.Scan(&id, &isDefault); err != nil {
			return cfg, nil, nil, err
		}
		options[id] = isDefault
		cfg.OptionIDs = append(cfg.OptionIDs, id)
		if isDefault {
			cfg.DefaultOptionIDs = append(cfg.DefaultOptionIDs, id)
		}
	}

	return cfg, groups, options, rows.Err()
}

// SaveProductModifiers replaces one product's configuration as a unit.
//
// The rules are the till's own (ModifierRepository.saveConfiguration), checked
// here so every tablet receives only configurations its form would accept:
// options must belong to attached groups, defaults must be offered and active,
// and no group may pre-select more than it allows. One more is added, because
// a till cannot recover from it: a required group must offer something, or the
// product can never be added to a cart.
//
// Only the difference is written. Re-stamping rows that did not change would
// wake every till in the company to pull a configuration it already has.
func (s *Service) SaveProductModifiers(ctx context.Context, tenantID, productID string, cfg ProductModifiers) error {
	if !validation.UUID(productID) {
		return ErrNotFound
	}
	for _, id := range slices.Concat(cfg.GroupIDs, cfg.OptionIDs, cfg.DefaultOptionIDs) {
		if !validation.UUID(id) {
			return validation.Errors{"modifiers": "Pilihan modifier tidak dikenal."}
		}
	}

	return s.feed.Write(ctx, tenantID, func(ctx context.Context, w *syncfeed.Writer) error {
		var live bool
		if err := w.Tx.QueryRow(ctx, `
			SELECT EXISTS (SELECT 1 FROM products
			               WHERE tenant_id = $1 AND id = $2 AND deleted_at IS NULL)`,
			tenantID, productID).Scan(&live); err != nil {
			return err
		}
		if !live {
			return ErrNotFound
		}

		groups, err := loadGroups(ctx, w.Tx, tenantID, "")
		if err != nil {
			return err
		}
		if err := checkConfig(groups, cfg); err != nil {
			return err
		}

		_, liveGroups, liveOptions, err := currentConfig(ctx, w.Tx, tenantID, productID)
		if err != nil {
			return err
		}

		return writeConfigDiff(ctx, w, tenantID, productID, cfg, liveGroups, liveOptions)
	})
}

func checkConfig(groups []ModifierGroup, cfg ProductModifiers) error {
	byGroup := make(map[string]ModifierGroup, len(groups))
	optionGroup := map[string]string{}
	optionActive := map[string]bool{}
	for _, g := range groups {
		byGroup[g.ID] = g
		for _, o := range g.Options {
			optionGroup[o.ID] = g.ID
			optionActive[o.ID] = o.Active
		}
	}

	attached := map[string]bool{}
	for _, id := range cfg.GroupIDs {
		if _, ok := byGroup[id]; !ok {
			return validation.Errors{"modifiers": "Grup modifier tidak ditemukan."}
		}
		attached[id] = true
	}

	offered := map[string]bool{}
	for _, id := range cfg.OptionIDs {
		if !attached[optionGroup[id]] {
			return validation.Errors{"modifiers": "Opsi harus berasal dari grup yang ditempelkan."}
		}
		offered[id] = true
	}

	defaultsPerGroup := map[string]int{}
	for _, id := range cfg.DefaultOptionIDs {
		if !offered[id] {
			return validation.Errors{"modifiers": "Pilihan default harus termasuk opsi yang ditawarkan."}
		}
		if !optionActive[id] {
			return validation.Errors{"modifiers": "Pilihan default tidak boleh opsi yang nonaktif."}
		}
		defaultsPerGroup[optionGroup[id]]++
	}

	for _, id := range cfg.GroupIDs {
		g := byGroup[id]
		if limit := g.limit(); limit != nil && defaultsPerGroup[id] > *limit {
			return validation.Errors{"modifiers": fmt.Sprintf(
				"%s hanya boleh punya %d pilihan default.", g.Name, *limit)}
		}

		if g.Required && !slices.ContainsFunc(g.Options, func(o ModifierOption) bool {
			return o.Active && offered[o.ID]
		}) {
			return validation.Errors{"modifiers": fmt.Sprintf(
				"%s wajib dipilih, jadi harus menawarkan minimal satu opsi aktif.", g.Name)}
		}
	}

	return nil
}

func writeConfigDiff(
	ctx context.Context, w *syncfeed.Writer, tenantID, productID string,
	cfg ProductModifiers, liveGroups, liveOptions map[string]bool,
) error {
	wantGroups := map[string]bool{}
	for _, id := range cfg.GroupIDs {
		wantGroups[id] = true
	}
	wantOptions := map[string]bool{}
	for _, id := range cfg.OptionIDs {
		wantOptions[id] = false
	}
	for _, id := range cfg.DefaultOptionIDs {
		wantOptions[id] = true
	}

	var addGroups, dropGroups []string
	for id := range wantGroups {
		if !liveGroups[id] {
			addGroups = append(addGroups, id)
		}
	}
	for id := range liveGroups {
		if !wantGroups[id] {
			dropGroups = append(dropGroups, id)
		}
	}

	var (
		putOptions  []string
		putDefaults []bool
		dropOptions []string
	)
	for id, isDefault := range wantOptions {
		if current, ok := liveOptions[id]; !ok || current != isDefault {
			putOptions = append(putOptions, id)
			putDefaults = append(putDefaults, isDefault)
		}
	}
	for id := range liveOptions {
		if _, ok := wantOptions[id]; !ok {
			dropOptions = append(dropOptions, id)
		}
	}

	// Registry order: the group attachments before the option scoping.
	if len(addGroups) > 0 {
		first, err := w.SeqBlock(ctx, "product_modifier_groups", int64(len(addGroups)))
		if err != nil {
			return err
		}
		if _, err := w.Tx.Exec(ctx, `
			INSERT INTO product_modifier_groups (tenant_id, product_id, group_id, sync_seq)
			SELECT $1, $2, x.id::uuid, $3 + x.ord - 1
			FROM unnest($4::text[]) WITH ORDINALITY AS x(id, ord)
			ON CONFLICT (product_id, group_id) DO UPDATE
			SET deleted_at = NULL, sync_seq = EXCLUDED.sync_seq, updated_at = now()`,
			tenantID, productID, first, addGroups); err != nil {
			return err
		}
	}
	if len(dropGroups) > 0 {
		if _, err := retire(ctx, w, "product_modifier_groups", "product_modifier_groups",
			"tenant_id = $1 AND product_id = $2 AND group_id = ANY($3::text[]::uuid[])",
			tenantID, productID, dropGroups); err != nil {
			return err
		}
	}

	if len(putOptions) > 0 {
		first, err := w.SeqBlock(ctx, "product_modifier_options", int64(len(putOptions)))
		if err != nil {
			return err
		}
		if _, err := w.Tx.Exec(ctx, `
			INSERT INTO product_modifier_options (tenant_id, product_id, option_id, is_default, sync_seq)
			SELECT $1, $2, x.id::uuid, x.is_default, $3 + x.ord - 1
			FROM unnest($4::text[], $5::boolean[]) WITH ORDINALITY AS x(id, is_default, ord)
			ON CONFLICT (product_id, option_id) DO UPDATE
			SET is_default = EXCLUDED.is_default, deleted_at = NULL,
			    sync_seq = EXCLUDED.sync_seq, updated_at = now()`,
			tenantID, productID, first, putOptions, putDefaults); err != nil {
			return err
		}
	}
	if len(dropOptions) > 0 {
		if _, err := retire(ctx, w, "product_modifier_options", "product_modifier_options",
			"tenant_id = $1 AND product_id = $2 AND option_id = ANY($3::text[]::uuid[])",
			tenantID, productID, dropOptions); err != nil {
			return err
		}
	}

	return nil
}
