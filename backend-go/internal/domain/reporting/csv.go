package reporting

import (
	"bytes"
	"encoding/csv"
	"strconv"
	"strings"
)

// RenderCSV writes every section one after another, separated by an empty
// line, each under its own title row. The byte-order mark is what makes
// Excel on Windows read the file as UTF-8 rather than mangling every name
// with an accent.
//
// This shape — a title row ahead of each section's header — is right for a
// report a person reads, and wrong for a file meant to be re-uploaded: a
// flat, single-purpose export like the catalogue's needs its header on line
// one with nothing above it, or a generic CSV reader's first row is the
// title rather than the columns. See RenderFlatCSV for that shape.
func RenderCSV(tables []Table) ([]byte, error) {
	w, buf := newSafeCSVWriter()
	for i, t := range tables {
		if i > 0 {
			if err := w.Write([]string{""}); err != nil {
				return nil, err
			}
		}
		if err := w.Write([]string{safeText(t.Title)}); err != nil {
			return nil, err
		}
		if err := writeTableBody(w, t); err != nil {
			return nil, err
		}
	}
	w.Flush()
	return buf.Bytes(), w.Error()
}

// RenderFlatCSV writes one table with nothing above its header — the shape a
// file needs when it exists to be parsed back, not only read. Fase 2's
// catalogue export uses this so the file it produces is, unmodified, a valid
// input to the catalogue importer: the same UTF-8 BOM and safeText
// formula-injection guard RenderCSV gives a report, with no title row for a
// generic reader to trip on.
func RenderFlatCSV(t Table) ([]byte, error) {
	w, buf := newSafeCSVWriter()
	if err := writeTableBody(w, t); err != nil {
		return nil, err
	}
	w.Flush()
	return buf.Bytes(), w.Error()
}

func newSafeCSVWriter() (*csv.Writer, *bytes.Buffer) {
	var buf bytes.Buffer
	buf.Write([]byte{0xEF, 0xBB, 0xBF})
	return csv.NewWriter(&buf), &buf
}

func writeTableBody(w *csv.Writer, t Table) error {
	if err := w.Write(t.Header); err != nil {
		return err
	}
	for _, r := range t.Rows {
		record := make([]string, len(r))
		for j, c := range r {
			switch {
			case c.IsInt():
				record[j] = strconv.FormatInt(c.Int, 10)
			case c.IsDecimal():
				record[j] = strconv.FormatFloat(c.Float, 'f', 2, 64)
			default:
				record[j] = safeText(c.Text)
			}
		}
		if err := w.Write(record); err != nil {
			return err
		}
	}
	return nil
}

// safeText stops a spreadsheet from running a name as a formula. A product
// called "=HYPERLINK(...)" typed at a till is data, and a leading quote is how
// a spreadsheet is told so.
func safeText(s string) string {
	if s != "" && strings.ContainsRune("=+-@\t\r", rune(s[0])) {
		return "'" + s
	}
	return s
}
