// Package views renders the platform panel.
package views

import (
	"encoding/json"
	"fmt"
	"net/url"
	"strconv"
	"time"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/entitlements"
	domain "github.com/daniryckidinata/nti_pos/backend-go/internal/domain/platform"

	bo "github.com/daniryckidinata/nti_pos/backend-go/internal/backoffice/views"
)

type Session struct {
	AdminName  string
	AdminEmail string
	CSRFToken  string
	// Path is the request path, so the sidebar can light the current entry.
	Path string
}

type Enrollment struct {
	Email  string
	Secret string
	URI    string
}

type TenantsView struct {
	Tenants []domain.TenantSummary
	Search  string
	Status  string
	Page    int
	More    bool
}

// TenantForms carries whichever form on a merchant's page was just refused, as
// it was typed. A zero Form is an untouched one.
type TenantForms struct {
	Suspend     bo.Form
	Limits      bo.Form
	Impersonate bo.Form
	Flash       string
}

type AuditView struct {
	Rows   []domain.AuditRow
	Tenant string
	Action string
	Next   string
}

var StatusOptions = []bo.Option{
	{Value: "", Label: "Semua status"},
	{Value: domain.StatusActive, Label: "Aktif"},
	{Value: domain.StatusSuspended, Label: "Disuspend"},
}

func itoa(n int) string     { return strconv.Itoa(n) }
func i64toa(n int64) string { return strconv.FormatInt(n, 10) }

func when(t *time.Time) string {
	if t == nil {
		return "—"
	}
	return whenT(*t)
}

func whenT(t time.Time) string { return t.Local().Format("2 Jan 2006 15:04") }

func perDay(week int64) string { return fmt.Sprintf("%.1f", float64(week)/7) }

// usageAgainst shows what a merchant runs beside what it is allowed.
func usageAgainst(used int, max *int) string {
	if max == nil {
		return strconv.Itoa(used) + " (tanpa batas)"
	}
	return fmt.Sprintf("%d dari %d", used, *max)
}

// detailText is an audit row's detail as compact JSON. Map keys are sorted by
// encoding/json, so the same detail always reads the same way.
func detailText(d map[string]any) string {
	if len(d) == 0 {
		return ""
	}
	raw, err := json.Marshal(d)
	if err != nil {
		return ""
	}
	return string(raw)
}

func tenantsURL(v TenantsView, page int) string {
	q := url.Values{}
	if v.Search != "" {
		q.Set("q", v.Search)
	}
	if v.Status != "" {
		q.Set("status", v.Status)
	}
	q.Set("page", strconv.Itoa(page))
	return "/platform/tenants?" + q.Encode()
}

func auditNextURL(v AuditView) string {
	q := url.Values{}
	if v.Tenant != "" {
		q.Set("tenant", v.Tenant)
	}
	if v.Action != "" {
		q.Set("action", v.Action)
	}
	q.Set("before", v.Next)
	return "/platform/audit?" + q.Encode()
}

func searchForm(v TenantsView) bo.Form {
	f := bo.NewForm()
	f.Values["q"] = v.Search
	f.Values["status"] = v.Status
	return f
}

func auditFilterForm(v AuditView) bo.Form {
	f := bo.NewForm()
	f.Values["tenant"] = v.Tenant
	f.Values["action"] = v.Action
	return f
}

func flagForm(set entitlements.Set) bo.Form {
	f := bo.NewForm()
	for _, flag := range entitlements.AllFlags {
		if set.Has(flag) {
			f.Values["flag_"+string(flag)] = "on"
		}
	}
	return f
}

func activeOwners(owners []domain.Owner) []bo.Option {
	var out []bo.Option
	for _, o := range owners {
		if o.Active {
			out = append(out, bo.Option{Value: o.ID, Label: o.Name + " — " + o.Email})
		}
	}
	return out
}
