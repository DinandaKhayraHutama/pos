package reporting

import (
	"bytes"
	"encoding/csv"
	"strconv"
	"strings"
)

// RenderCSV writes every section one after another, separated by an empty
// line. The byte-order mark is what makes Excel on Windows read the file as
// UTF-8 rather than mangling every name with an accent.
func RenderCSV(tables []Table) ([]byte, error) {
	var buf bytes.Buffer
	buf.Write([]byte{0xEF, 0xBB, 0xBF})
	w := csv.NewWriter(&buf)
	for i, t := range tables {
		if i > 0 {
			if err := w.Write([]string{""}); err != nil {
				return nil, err
			}
		}
		if err := w.Write([]string{safeText(t.Title)}); err != nil {
			return nil, err
		}
		if err := w.Write(t.Header); err != nil {
			return nil, err
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
				return nil, err
			}
		}
	}
	w.Flush()
	return buf.Bytes(), w.Error()
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
