package backoffice

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/csv"
	"errors"
	"fmt"
	"io"
	"mime"
	"net/http"
	"strings"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/backoffice/views"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/catalogue"
)

// ---- catalogue export ------------------------------------------------------

// exportProducts streams the live catalogue as CSV. Synchronous and
// unqueued, unlike report exports: a menu export is small — tens of
// thousands of rows at most — and a merchant downloading it wants the file
// now, not a job to poll.
func (h *Handler) exportProducts(w http.ResponseWriter, r *http.Request) {
	bytes, err := h.catalogue.ExportProductsCSV(r.Context(), tenantOf(r))
	if err != nil {
		h.serverError(w, r, err)
		return
	}

	w.Header().Set("Content-Type", "text/csv; charset=utf-8")
	w.Header().Set("Content-Disposition", mime.FormatMediaType("attachment", map[string]string{"filename": "produk.csv"}))
	w.Header().Set("Cache-Control", "private, no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Write(bytes)
}

// ---- catalogue import -------------------------------------------------------

// maxCatalogueImportBytes bounds the upload before anything is parsed. Wider
// than the legacy maxImportBytes because a full row carries every column, not
// just a price; scripts/verify-backoffice-crud's legacy-shape upload sits
// far under either bound, so raising it changes nothing that script checks.
const maxCatalogueImportBytes = 8 << 20

// readableColumns is every header name importCSV accepts. category_name and
// brand_name are accepted and then ignored — they exist in an export purely
// for a human editing the file to see what category_id/brand_id mean — so
// re-uploading an unmodified export never gets refused as "unknown column."
var readableColumns = func() map[string]bool {
	out := map[string]bool{"id": true, "category_name": true, "brand_name": true}
	for _, c := range catalogue.ImportColumns {
		out[c] = true
	}
	return out
}()

// importProducts is the sole entry point for POST .../products/import. It
// reads the upload once and routes by header shape: the legacy sku+harga
// file goes to applyLegacyPriceList completely unchanged, and everything
// else goes through the new preview-then-confirm flow below.
func (h *Handler) importProducts(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, maxCatalogueImportBytes)
	if err := r.ParseMultipartForm(maxCatalogueImportBytes); err != nil {
		h.render(w, r, views.ImportResult(0, 0, []catalogue.ImportError{{Message: "Berkas tidak terbaca atau lebih dari 8 MB."}}))
		return
	}

	file, _, err := r.FormFile("file")
	if err != nil {
		h.render(w, r, views.ImportResult(0, 0, []catalogue.ImportError{{Message: "Pilih berkas CSV."}}))
		return
	}
	defer file.Close()

	raw, err := io.ReadAll(file)
	if err != nil {
		h.render(w, r, views.ImportResult(0, 0, []catalogue.ImportError{{Message: "Berkas tidak terbaca."}}))
		return
	}

	if header, ok := peekCSVHeader(raw); ok && catalogue.LegacyPriceListHeader(header) {
		h.applyLegacyPriceList(w, r, raw)
		return
	}

	h.previewCatalogueImport(w, r, raw)
}

// confirmImportProducts commits a preview. It trusts nothing the preview
// page computed — file_b64 carries only the bytes, and this handler parses
// and validates them again from scratch, exactly as importProducts would a
// fresh upload, before ImportCatalogue is asked to commit=true. If the
// catalogue changed underneath the preview, this run's own fresh read of the
// database is what decides the outcome, not the numbers shown earlier.
func (h *Handler) confirmImportProducts(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, maxCatalogueImportBytes*2) // base64 inflates by ~1/3
	if err := r.ParseForm(); err != nil {
		h.render(w, r, views.ImportCatalogueResult(0, 0, 0, []catalogue.ImportError{{Message: "Berkas tidak terbaca."}}))
		return
	}

	raw, err := base64.StdEncoding.DecodeString(r.PostFormValue("file_b64"))
	if err != nil {
		h.render(w, r, views.ImportCatalogueResult(0, 0, 0, []catalogue.ImportError{{Message: "Berkas tidak terbaca."}}))
		return
	}
	wantHash := r.PostFormValue("file_sha256")
	gotHash := fmt.Sprintf("%x", sha256.Sum256(raw))
	if wantHash == "" || subtle.ConstantTimeCompare([]byte(wantHash), []byte(gotHash)) != 1 {
		h.render(w, r, views.ImportCatalogueResult(0, 0, 0, []catalogue.ImportError{{Message: "Isi berkas tidak cocok dengan preview."}}))
		return
	}

	header, rows, problems := readCatalogueCSV(raw)
	if len(problems) > 0 {
		h.render(w, r, views.ImportCatalogueResult(0, 0, 0, problems))
		return
	}

	result, err := h.catalogue.ImportCatalogue(r.Context(), tenantOf(r), header, rows, true)
	var refused catalogue.ImportErrors
	switch {
	case errors.As(err, &refused):
		h.render(w, r, views.ImportCatalogueResult(0, 0, 0, refused))
	case err != nil:
		h.serverError(w, r, err)
	default:
		toast(w, "Produk diterapkan.")
		h.render(w, r, views.ImportCatalogueResult(result.Created, result.Updated, result.Unchanged, nil))
	}
}

func (h *Handler) previewCatalogueImport(w http.ResponseWriter, r *http.Request, raw []byte) {
	header, rows, problems := readCatalogueCSV(raw)
	if len(problems) > 0 {
		h.render(w, r, views.ImportCatalogueResult(0, 0, 0, problems))
		return
	}

	result, err := h.catalogue.ImportCatalogue(r.Context(), tenantOf(r), header, rows, false)
	var refused catalogue.ImportErrors
	switch {
	case errors.As(err, &refused):
		h.render(w, r, views.ImportCatalogueResult(0, 0, 0, refused))
	case err != nil:
		h.serverError(w, r, err)
	default:
		h.render(w, r, views.ImportCataloguePreview(
			result.Created, result.Updated, result.Unchanged, base64.StdEncoding.EncodeToString(raw), fmt.Sprintf("%x", sha256.Sum256(raw))))
	}
}

// csvRecords strips the BOM Excel writes, picks ';' over ',' when the header
// line uses it more — the same Indonesian-locale accommodation
// readPriceList already makes — and returns every record unparsed.
func csvRecords(raw []byte) ([][]string, bool) {
	text := strings.TrimPrefix(string(raw), string(rune(0xFEFF)))
	reader := csv.NewReader(strings.NewReader(text))
	firstLine, _, _ := strings.Cut(text, "\n")
	if strings.Count(firstLine, ";") > strings.Count(firstLine, ",") {
		reader.Comma = ';'
	}
	reader.FieldsPerRecord = -1

	records, err := reader.ReadAll()
	if err != nil || len(records) == 0 {
		return nil, false
	}
	return records, true
}

func peekCSVHeader(raw []byte) ([]string, bool) {
	records, ok := csvRecords(raw)
	if !ok {
		return nil, false
	}
	return normalizeHeader(records[0]), true
}

func normalizeHeader(row []string) []string {
	out := make([]string, len(row))
	for i, c := range row {
		out[i] = strings.ToLower(strings.TrimSpace(c))
	}
	return out
}

// readCatalogueCSV parses a full catalogue import file: any header made up
// of readableColumns, in any order, any subset. Every unreadable or unknown
// column is reported before a single row is read, since a header the file
// does not actually have is not a per-row problem.
func readCatalogueCSV(raw []byte) (header []string, rows []catalogue.CatalogueRow, problems []catalogue.ImportError) {
	records, ok := csvRecords(raw)
	if !ok {
		return nil, nil, []catalogue.ImportError{{Message: "Berkas bukan CSV yang valid."}}
	}

	cols := normalizeHeader(records[0])
	seen := map[string]bool{}
	for i, name := range cols {
		if name == "" {
			return nil, nil, []catalogue.ImportError{{Line: 1, Message: "Kolom tanpa nama pada posisi " + itoa(i+1) + "."}}
		}
		if !readableColumns[name] {
			return nil, nil, []catalogue.ImportError{{Line: 1, Message: "Kolom \"" + name + "\" tidak dikenal."}}
		}
		if seen[name] {
			return nil, nil, []catalogue.ImportError{{Line: 1, Message: "Kolom \"" + name + "\" muncul dua kali."}}
		}
		seen[name] = true
	}

	// The header importCatalogue actually acts on: category_name/brand_name
	// are accepted above but never a field ImportCatalogue writes.
	for _, c := range cols {
		if c == "id" || catalogue.ImportColumnSet[c] {
			header = append(header, c)
		}
	}

	for i, record := range records[1:] {
		line := i + 2
		if strings.TrimSpace(strings.Join(record, "")) == "" {
			continue
		}
		fields := map[string]string{}
		for i, name := range cols {
			if i >= len(record) {
				break
			}
			if name == "id" || catalogue.ImportColumnSet[name] {
				fields[name] = record[i]
			}
		}
		rows = append(rows, catalogue.CatalogueRow{Line: line, Fields: fields})
	}

	return header, rows, nil
}
