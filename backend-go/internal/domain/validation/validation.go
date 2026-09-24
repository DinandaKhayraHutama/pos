// Package validation carries per-field rejections from a domain writer to the
// form that submitted them.
//
// The domain decides what is invalid, not the handler: the Backoffice is one
// writer today, and a second one — a bulk import, the platform panel — must not
// be able to accept a row the first would refuse. Messages are in Indonesian
// because the people reading them are merchants; the field keys are the form
// input names, so a handler can place each message beside its input without a
// translation table.
package validation

import (
	"errors"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"unicode/utf8"
)

// Errors maps a form field to what is wrong with it.
type Errors map[string]string

func (e Errors) Error() string {
	keys := make([]string, 0, len(e))
	for k := range e {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	parts := make([]string, 0, len(keys))
	for _, k := range keys {
		parts = append(parts, k+": "+e[k])
	}

	return "validation: " + strings.Join(parts, "; ")
}

// Add records the first problem with a field; later ones are dropped, because
// a form shows one message per input.
func (e Errors) Add(field, message string) {
	if _, taken := e[field]; !taken {
		e[field] = message
	}
}

// Err returns nil when nothing was recorded. A nil map returned as an error
// interface is not a nil error, which is the bug this exists to avoid.
func (e Errors) Err() error {
	if len(e) == 0 {
		return nil
	}
	return e
}

// As extracts field errors from anything a writer returned.
func As(err error) (Errors, bool) {
	var fields Errors
	if errors.As(err, &fields) {
		return fields, true
	}
	return nil, false
}

// Name checks a required display name against the bound every published text
// column carries. The bound is in characters, like the CHECK constraint, not
// bytes.
func (e Errors) Name(field, value string, max int) {
	switch {
	case strings.TrimSpace(value) == "":
		e.Add(field, "Wajib diisi.")
	case utf8.RuneCountInString(value) > max:
		e.Add(field, "Terlalu panjang.")
	}
}

// Optional bounds a text field that may be empty.
func (e Errors) Optional(field string, value *string, max int) {
	if value != nil && utf8.RuneCountInString(*value) > max {
		e.Add(field, "Terlalu panjang.")
	}
}

var uuidPattern = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

// UUID reports whether an id that arrived from a URL or a form is well formed.
//
// Checked before it reaches PostgreSQL, where a malformed uuid is an input
// error that surfaces as a 500 and a logged failure — noise that buries the
// real ones. A malformed id is the caller's mistake and reads as "not found".
func UUID(s string) bool { return uuidPattern.MatchString(s) }

// Trimmed returns nil for a blank input, so "nothing typed" is stored as NULL
// rather than as an empty string that looks like a value.
func Trimmed(s string) *string {
	s = strings.TrimSpace(s)
	if s == "" {
		return nil
	}
	return &s
}

var (
	plainAmount   = regexp.MustCompile(`^-?[0-9]+$`)
	groupedAmount = regexp.MustCompile(`^-?[0-9]{1,3}(\.[0-9]{3})+$`)
)

// ParseRupiah is the one reader of money in this codebase — both the
// Backoffice form parser (internal/backoffice/forms.go's parseRupiah) and
// Fase 2's full catalogue importer call this, never their own strconv.
//
// A dotted thousands grouping ("25.000") is accepted because that is what an
// owner types and what Excel/Sheets writes back when a merchant edits an
// exported CSV in Indonesian locale; a decimal point ("25000.50") is refused
// outright rather than truncated, because silently rounding somebody's typed
// price is a worse failure than making them fix it. Blank returns (0, "") —
// zero rather than an error — so a caller can tell "left blank" from
// "typed something invalid" only by checking the input first, exactly as
// parser.optionalMoney already does.
func ParseRupiah(input string) (int64, string) {
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
