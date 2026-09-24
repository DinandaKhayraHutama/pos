package backoffice

import (
	"errors"
	"fmt"
	"io"
	"mime"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/backoffice/views"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/customer"
)

func (h *Handler) exportCustomers(w http.ResponseWriter, r *http.Request) {
	employee := employeeFrom(r.Context())
	b, err := h.customers.ExportCSV(r.Context(), employee.TenantID, employee.ID)
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	w.Header().Set("Content-Type", "text/csv; charset=utf-8")
	w.Header().Set("Content-Disposition", mime.FormatMediaType("attachment", map[string]string{"filename": "pelanggan.csv"}))
	w.Header().Set("Cache-Control", "private, no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	_, _ = w.Write(b)
}

func (h *Handler) importCustomers(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, 8<<20)
	if err := r.ParseMultipartForm(8 << 20); err != nil {
		toastError(w, "Berkas tidak terbaca atau terlalu besar.")
		redirect(w, r, "/backoffice/customers")
		return
	}
	f, _, err := r.FormFile("file")
	if err != nil {
		toastError(w, "Pilih berkas CSV.")
		redirect(w, r, "/backoffice/customers")
		return
	}
	defer f.Close()
	b, err := io.ReadAll(f)
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	records, ok := csvRecords(b)
	if !ok || len(records) < 2 {
		toastError(w, "Berkas bukan CSV pelanggan yang valid.")
		redirect(w, r, "/backoffice/customers")
		return
	}
	header := normalizeHeader(records[0])
	allowed := map[string]bool{}
	for _, c := range customer.CustomerColumns {
		allowed[c] = true
	}
	for _, c := range header {
		if !allowed[c] {
			toastError(w, "Kolom \""+c+"\" tidak dikenal.")
			redirect(w, r, "/backoffice/customers")
			return
		}
	}
	var rows []customer.ImportRow
	for i, record := range records[1:] {
		if strings.TrimSpace(strings.Join(record, "")) == "" {
			continue
		}
		fields := map[string]string{}
		for j, c := range header {
			if j < len(record) {
				fields[c] = record[j]
			}
		}
		rows = append(rows, customer.ImportRow{Line: i + 2, Fields: fields})
	}
	result, err := h.customers.Import(r.Context(), tenantOf(r), rows, true)
	var refused customer.ImportErrors
	if errors.As(err, &refused) {
		toastError(w, "Impor ditolak: "+refused[0].Message)
		redirect(w, r, "/backoffice/customers")
		return
	}
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	toast(w, fmt.Sprintf("%d dibuat, %d diperbarui, %d tidak berubah.", result.Created, result.Updated, result.Unchanged))
	redirect(w, r, "/backoffice/customers")
}

func customerForm(c customer.Customer) views.Form {
	f := views.NewForm()
	f.Values["name"] = c.Name
	f.Values["phone"] = optionalString(c.Phone)
	f.Values["email"] = optionalString(c.Email)
	f.Values["address"] = optionalString(c.Address)
	f.Values["note"] = optionalString(c.Note)
	if c.Active {
		f.Values["active"] = "on"
	}
	return f
}

func customerFromForm(f views.Form, id string) (customer.Customer, *parser) {
	p := newParser(f)
	return customer.Customer{ID: id, Name: p.text("name"), Phone: p.optionalText("phone"), Email: p.optionalText("email"), Address: p.optionalText("address"), Note: p.optionalText("note"), Active: true}, p
}

func (h *Handler) customersPage(w http.ResponseWriter, r *http.Request) {
	page, _ := strconv.Atoi(r.URL.Query().Get("page"))
	result, err := h.customers.List(r.Context(), tenantOf(r), customer.Filter{Query: r.URL.Query().Get("q"), Page: page})
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	h.render(w, r, views.CustomersPage(h.sessionView(r), result, r.URL.Query().Get("q"), views.NewForm()))
}

func (h *Handler) createCustomer(w http.ResponseWriter, r *http.Request) {
	f, ok := h.parseForm(w, r)
	if !ok {
		return
	}
	in, p := customerFromForm(f, "")
	err := p.errs.Err()
	if err == nil {
		_, err = h.customers.SaveCustomer(r.Context(), tenantOf(r), in)
	}
	if err != nil && !absorb(&f, err) {
		h.serverError(w, r, err)
		return
	}
	if err == nil {
		toast(w, "Pelanggan ditambahkan.")
		redirect(w, r, "/backoffice/customers")
		return
	}
	result, loadErr := h.customers.List(r.Context(), tenantOf(r), customer.Filter{Page: 1})
	if loadErr != nil {
		h.serverError(w, r, loadErr)
		return
	}
	h.render(w, r, views.CustomersPage(h.sessionView(r), result, "", f))
}

func (h *Handler) customerPage(w http.ResponseWriter, r *http.Request) {
	c, err := h.customers.Get(r.Context(), tenantOf(r), chi.URLParam(r, "id"))
	if h.failed(w, r, err, customer.ErrNotFound) {
		return
	}
	purchases, err := h.customers.Purchases(r.Context(), tenantOf(r), c.ID, time.Time{}, time.Time{})
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	h.render(w, r, views.CustomerPage(h.sessionView(r), c, purchases, customerForm(c)))
}

func (h *Handler) updateCustomer(w http.ResponseWriter, r *http.Request) {
	f, ok := h.parseForm(w, r)
	if !ok {
		return
	}
	id := chi.URLParam(r, "id")
	in, p := customerFromForm(f, id)
	err := p.errs.Err()
	if err == nil {
		_, err = h.customers.SaveCustomer(r.Context(), tenantOf(r), in)
	}
	if !absorb(&f, err) && h.failed(w, r, err, customer.ErrNotFound) {
		return
	}
	if err == nil {
		toast(w, "Pelanggan disimpan.")
	}
	h.render(w, r, views.CustomerForm(id, f))
}

func (h *Handler) setCustomerActive(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		h.renderStatus(w, r, http.StatusBadRequest, views.ErrorCard("Formulir tidak terbaca."))
		return
	}
	active := r.PostFormValue("active") == "true"
	err := h.customers.SetActive(r.Context(), tenantOf(r), chi.URLParam(r, "id"), active)
	if h.failed(w, r, err, customer.ErrNotFound) {
		return
	}
	toast(w, "Status pelanggan disimpan.")
	redirect(w, r, "/backoffice/customers/"+chi.URLParam(r, "id"))
}

func (h *Handler) mergeCustomer(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		h.renderStatus(w, r, http.StatusBadRequest, views.ErrorCard("Formulir tidak terbaca."))
		return
	}
	loser := chi.URLParam(r, "id")
	winner := r.PostFormValue("winner_id")
	err := h.customers.Merge(r.Context(), tenantOf(r), winner, loser)
	if errors.Is(err, customer.ErrCannotMergeIntoSelf) || errors.Is(err, customer.ErrAlreadyMerged) {
		toastError(w, "Pelanggan tidak dapat digabung dengan pilihan tersebut.")
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if h.failed(w, r, err, customer.ErrNotFound) {
		return
	}
	toast(w, "Pelanggan digabung.")
	redirect(w, r, "/backoffice/customers/"+winner)
}
