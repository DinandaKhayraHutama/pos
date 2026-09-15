package views

import (
	"net/url"
	"strconv"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/catalogue"
)

func urlQuery(s string) string { return url.QueryEscape(s) }

// availabilityVals is what the sold-out switch posts: the state it is moving
// TO, so a double click lands where the person meant rather than flipping back.
func availabilityVals(to bool) string {
	if to {
		return `{"available":"on"}`
	}
	return `{"available":""}`
}

func activeVals(to bool) string {
	if to {
		return `{"active":"on"}`
	}
	return `{"active":""}`
}

func variantForm(v catalogue.Variant, failed string, f Form) Form {
	if failed == v.ID {
		return f
	}

	out := NewForm()
	out.Values["name"] = v.Name
	out.Values["price_delta"] = strconv.FormatInt(v.PriceDelta, 10)
	out.Values["sort_order"] = strconv.Itoa(v.SortOrder)
	return out
}

func newVariantForm(failed string, f Form) Form {
	if failed == "new" {
		return f
	}
	return NewForm()
}

func optionForm(o catalogue.ModifierOption, failed string, f Form) Form {
	if failed == o.ID {
		return f
	}

	out := NewForm()
	out.Values["name"] = o.Name
	out.Values["price_delta"] = strconv.FormatInt(o.PriceDelta, 10)
	out.Values["sort_order"] = strconv.Itoa(o.SortOrder)
	if o.Active {
		out.Values["active"] = "on"
	}
	return out
}

func newOptionForm(failed string, f Form) Form {
	if failed == "new" {
		return f
	}
	out := NewForm()
	out.Values["active"] = "on"
	return out
}

// groupRule says in words what the till will enforce.
func groupRule(g catalogue.ModifierGroup) string {
	rule := "pilih satu"
	if g.SelectionType == catalogue.SelectMultiple {
		rule = "pilih beberapa"
		if g.MaxSelect != nil {
			rule = "pilih maks. " + strconv.Itoa(*g.MaxSelect)
		}
	}
	if g.Required {
		rule += ", wajib"
	}
	return rule
}

var SelectionOptions = []Option{
	{Value: catalogue.SelectSingle, Label: "Pilih satu"},
	{Value: catalogue.SelectMultiple, Label: "Pilih beberapa"},
}

var PromoKindOptions = []Option{
	{Value: "percent", Label: "Persen (%)"},
	{Value: "amount", Label: "Nominal (Rp)"},
}
