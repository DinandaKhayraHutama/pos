package reporting

import (
	"archive/zip"
	"bytes"
	"encoding/xml"
	"fmt"
	"strconv"
	"strings"
)

// RenderXLSX writes one worksheet per section as an Office Open XML workbook.
//
// Written by hand with archive/zip rather than a library: the format needed —
// inline strings, integers, two-decimal numbers, a bold header — is a handful
// of fixed parts, and a dependency that renders every spreadsheet feature is a
// large surface to carry for them.
func RenderXLSX(tables []Table) ([]byte, error) {
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	add := func(name, content string) error {
		w, err := zw.Create(name)
		if err != nil {
			return err
		}
		_, err = w.Write([]byte(content))
		return err
	}

	names := sheetNames(tables)

	var types, sheets, rels strings.Builder
	types.WriteString(xml.Header + `<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">` +
		`<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>` +
		`<Default Extension="xml" ContentType="application/xml"/>` +
		`<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>` +
		`<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>`)
	sheets.WriteString(xml.Header + `<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" ` +
		`xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>`)
	rels.WriteString(xml.Header + `<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">`)

	for i, t := range tables {
		n := i + 1
		fmt.Fprintf(&types, `<Override PartName="/xl/worksheets/sheet%d.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>`, n)
		fmt.Fprintf(&sheets, `<sheet name="%s" sheetId="%d" r:id="rId%d"/>`, escape(names[i]), n, n)
		fmt.Fprintf(&rels, `<Relationship Id="rId%d" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet%d.xml"/>`, n, n)
		if err := add(fmt.Sprintf("xl/worksheets/sheet%d.xml", n), worksheet(t)); err != nil {
			return nil, err
		}
	}
	types.WriteString(`</Types>`)
	sheets.WriteString(`</sheets></workbook>`)
	fmt.Fprintf(&rels, `<Relationship Id="rId%d" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>`, len(tables)+1)

	for _, part := range []struct{ name, content string }{
		{"[Content_Types].xml", types.String()},
		{"_rels/.rels", xml.Header + `<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">` +
			`<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>`},
		{"xl/workbook.xml", sheets.String()},
		{"xl/_rels/workbook.xml.rels", rels.String()},
		{"xl/styles.xml", stylesXML},
	} {
		if err := add(part.name, part.content); err != nil {
			return nil, err
		}
	}
	if err := zw.Close(); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// Style indexes into cellXfs below.
const (
	styleDefault = 0
	styleBold    = 1
	styleInteger = 2
	styleDecimal = 3
)

const stylesXML = xml.Header + `<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">` +
	`<fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts>` +
	`<fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>` +
	`<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>` +
	`<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>` +
	`<cellXfs count="4">` +
	`<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>` +
	`<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>` +
	`<xf numFmtId="3" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>` +
	`<xf numFmtId="4" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>` +
	`</cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>`

func worksheet(t Table) string {
	var b strings.Builder
	b.WriteString(xml.Header + `<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">`)
	b.WriteString(`<cols><col min="1" max="1" width="34" customWidth="1"/><col min="2" max="16" width="18" customWidth="1"/></cols><sheetData>`)

	writeRow := func(r int, cells []Cell, header bool) {
		fmt.Fprintf(&b, `<row r="%d">`, r)
		for i, c := range cells {
			ref := columnName(i) + strconv.Itoa(r)
			switch {
			case c.IsInt():
				fmt.Fprintf(&b, `<c r="%s" s="%d"><v>%d</v></c>`, ref, styleInteger, c.Int)
			case c.IsDecimal():
				fmt.Fprintf(&b, `<c r="%s" s="%d"><v>%s</v></c>`, ref, styleDecimal, strconv.FormatFloat(c.Float, 'f', 2, 64))
			default:
				style := styleDefault
				if header {
					style = styleBold
				}
				fmt.Fprintf(&b, `<c r="%s" t="inlineStr" s="%d"><is><t xml:space="preserve">%s</t></is></c>`, ref, style, escape(c.Text))
			}
		}
		b.WriteString(`</row>`)
	}

	writeRow(1, []Cell{textCell(t.Title)}, true)
	header := make([]Cell, len(t.Header))
	for i, h := range t.Header {
		header[i] = textCell(h)
	}
	writeRow(2, header, true)
	for i, r := range t.Rows {
		writeRow(i+3, r, false)
	}
	b.WriteString(`</sheetData></worksheet>`)
	return b.String()
}

// columnName is the spreadsheet column for a zero-based index: A, B, ... Z, AA.
func columnName(i int) string {
	name := ""
	for i >= 0 {
		name = string(rune('A'+i%26)) + name
		i = i/26 - 1
	}
	return name
}

// sheetNames makes every title a legal, unique sheet name: at most 31
// characters and none of []:*?/\.
func sheetNames(tables []Table) []string {
	clean := strings.NewReplacer("[", "(", "]", ")", ":", " ", "*", " ", "?", " ", "/", "-", "\\", "-")
	seen := map[string]int{}
	out := make([]string, len(tables))
	for i, t := range tables {
		name := strings.TrimSpace(clean.Replace(t.Title))
		if name == "" {
			name = "Sheet"
		}
		if r := []rune(name); len(r) > 28 {
			name = string(r[:28])
		}
		base := name
		for seen[strings.ToLower(name)] > 0 {
			seen[strings.ToLower(base)]++
			name = fmt.Sprintf("%s %d", base, seen[strings.ToLower(base)])
		}
		seen[strings.ToLower(name)]++
		out[i] = name
	}
	return out
}

// escape writes text XML can carry. Characters XML forbids become U+FFFD.
func escape(s string) string {
	var b bytes.Buffer
	_ = xml.EscapeText(&b, []byte(s))
	return b.String()
}
