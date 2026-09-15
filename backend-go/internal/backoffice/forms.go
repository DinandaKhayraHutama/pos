package backoffice

import (
	"encoding/json"
	"net/http"
	"regexp"
	"strconv"
	"strings"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/backoffice/views"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/validation"
)

// formOf keeps what arrived as strings. A rejected form is re-rendered from
// these, so the person sees exactly what they typed beside what was wrong.
func formOf(r *http.Request, multi ...string) views.Form {
	f := views.NewForm()
	for key, values := range r.PostForm {
		if len(values) > 0 {
			f.Values[key] = values[0]
		}
	}
	for _, name := range multi {
		f.Multi[name] = r.PostForm[name]
	}
	return f
}

// parser reads typed values out of a form and records a message for every
// input it cannot read, so a bad number is reported beside its field rather
// than as a failed request.
type parser struct {
	f    views.Form
	errs validation.Errors
}

func newParser(f views.Form) *parser { return &parser{f: f, errs: validation.Errors{}} }

func (p *parser) text(name string) string { return strings.TrimSpace(p.f.V(name)) }

func (p *parser) optionalText(name string) *string { return validation.Trimmed(p.f.V(name)) }

func (p *parser) check(name string) bool { return p.f.Checked(name) }

// integer reads a whole number; blank is zero. Sort orders and the like.
func (p *parser) integer(name string) int {
	raw := p.text(name)
	if raw == "" {
		return 0
	}
	n, err := strconv.Atoi(raw)
	if err != nil {
		p.errs.Add(name, "Harus angka bulat.")
	}
	return n
}

func (p *parser) optionalInteger(name string) *int {
	if p.text(name) == "" {
		return nil
	}
	n := p.integer(name)
	return &n
}

var (
	plainAmount   = regexp.MustCompile(`^-?[0-9]+$`)
	groupedAmount = regexp.MustCompile(`^-?[0-9]{1,3}(\.[0-9]{3})+$`)
)

// money reads integer rupiah.
//
// Thousands separators are accepted only where they ARE thousands separators:
// "25.000" is how a price is written here, and refusing it would refuse the way
// every merchant types. Stripping dots blindly would read "25000.50" as
// 2.500.050 — a hundredfold price rise with no message at all — so anything
// that is not plain digits or correctly grouped digits is refused.
func (p *parser) money(name string) int64 {
	n, message := parseRupiah(p.text(name))
	if message != "" {
		p.errs.Add(name, message)
	}
	return n
}

// parseRupiah is shared by every form and the price-list import, so a price
// typed into a form and the same price in a spreadsheet cannot be read two
// different ways. Blank is zero; a non-empty message means it was refused.
func parseRupiah(input string) (int64, string) {
	raw := strings.NewReplacer(" ", "", "Rp", "", "rp", "").Replace(strings.TrimSpace(input))
	switch {
	case raw == "":
		return 0, ""
	case groupedAmount.MatchString(raw):
		raw = strings.ReplaceAll(raw, ".", "")
	case !plainAmount.MatchString(raw):
		return 0, "Harus rupiah bulat, tanpa desimal."
	}

	n, err := strconv.ParseInt(raw, 10, 64)
	if err != nil {
		return 0, "Angka terlalu besar."
	}
	return n, ""
}

func (p *parser) optionalMoney(name string) *int64 {
	if p.text(name) == "" {
		return nil
	}
	n := p.money(name)
	return &n
}

// optionalRate reads a percentage. Blank stays nil, and nil is not zero: for a
// product's tax rate, nil means "use the store's PB1" and 0 means exempt.
func (p *parser) optionalRate(name string) *float64 {
	raw := strings.ReplaceAll(p.text(name), ",", ".")
	if raw == "" {
		return nil
	}
	n, err := strconv.ParseFloat(raw, 64)
	if err != nil {
		p.errs.Add(name, "Harus angka.")
		return nil
	}
	return &n
}

// absorb merges a writer's field errors into the form and reports whether it
// did. Anything else — not found, a database failure — is the caller's to
// handle, because it is not something the person can fix by retyping.
func absorb(f *views.Form, err error) bool {
	fields, ok := validation.As(err)
	if !ok {
		return false
	}
	for k, v := range fields {
		f.Errors[k] = v
	}
	return true
}

// toast asks the page to show a message once the swap lands. Messages are kept
// to ASCII: a header value is not the place to trust a browser's decoding.
func toast(w http.ResponseWriter, message string) { trigger(w, "toast", message) }

func toastError(w http.ResponseWriter, message string) { trigger(w, "toastError", message) }

func trigger(w http.ResponseWriter, event, message string) {
	payload, _ := json.Marshal(map[string]string{event: message})
	w.Header().Set("HX-Trigger", string(payload))
}

// redirect sends HTMX to a new page with a full navigation, and a plain
// browser the same way. A create ends here, so the next screen is the record's
// own page rather than a form that now describes something already saved.
func redirect(w http.ResponseWriter, r *http.Request, target string) {
	if r.Header.Get("HX-Request") == "true" {
		w.Header().Set("HX-Redirect", target)
		w.WriteHeader(http.StatusOK)
		return
	}
	http.Redirect(w, r, target, http.StatusSeeOther)
}

func isHX(r *http.Request) bool { return r.Header.Get("HX-Request") == "true" }

func itoa(n int) string { return strconv.Itoa(n) }

func i64toa(n int64) string { return strconv.FormatInt(n, 10) }

func optionalString(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}

func checkbox(on bool) string {
	if on {
		return "on"
	}
	return ""
}
