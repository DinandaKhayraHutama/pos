package reporting

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"strings"
	"time"
)

// Gotenberg renders HTML to PDF through a gotenberg sidecar's Chromium route.
//
// The PDF is the Backoffice report page itself, rendered by a browser: a second
// layout engine for PDFs is a second report to keep in step.
type Gotenberg struct {
	base   string
	client *http.Client
}

// NewGotenberg returns nil for an empty URL; a nil *Gotenberg reports
// ErrPDFNotConfigured.
func NewGotenberg(baseURL string) *Gotenberg {
	baseURL = strings.TrimRight(strings.TrimSpace(baseURL), "/")
	if baseURL == "" {
		return nil
	}
	return &Gotenberg{base: baseURL, client: &http.Client{Timeout: 90 * time.Second}}
}

// maxPDF bounds what is read back: a month's report is a few pages.
const maxPDF = 64 << 20

func (g *Gotenberg) RenderPDF(ctx context.Context, html []byte) ([]byte, error) {
	if g == nil {
		return nil, ErrPDFNotConfigured
	}

	var body bytes.Buffer
	mw := multipart.NewWriter(&body)
	part, err := mw.CreateFormFile("files", "index.html")
	if err != nil {
		return nil, err
	}
	if _, err := part.Write(html); err != nil {
		return nil, err
	}
	// A4 portrait with narrow margins, in inches as gotenberg expects.
	for _, field := range [][2]string{
		{"paperWidth", "8.27"}, {"paperHeight", "11.7"},
		{"marginTop", "0.4"}, {"marginBottom", "0.4"}, {"marginLeft", "0.4"}, {"marginRight", "0.4"},
		{"printBackground", "true"},
	} {
		if err := mw.WriteField(field[0], field[1]); err != nil {
			return nil, err
		}
	}
	if err := mw.Close(); err != nil {
		return nil, err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, g.base+"/forms/chromium/convert/html", &body)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", mw.FormDataContentType())
	resp, err := g.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("reporting: gotenberg unreachable: %w", err)
	}
	defer resp.Body.Close()

	data, err := io.ReadAll(io.LimitReader(resp.Body, maxPDF+1))
	if err != nil {
		return nil, fmt.Errorf("reporting: read gotenberg response: %w", err)
	}
	if resp.StatusCode != http.StatusOK {
		snippet := string(data)
		if len(snippet) > 200 {
			snippet = snippet[:200]
		}
		return nil, fmt.Errorf("reporting: gotenberg answered %d: %s", resp.StatusCode, snippet)
	}
	if len(data) > maxPDF {
		return nil, fmt.Errorf("reporting: gotenberg returned more than %d bytes", maxPDF)
	}
	if !bytes.HasPrefix(data, []byte("%PDF-")) {
		return nil, fmt.Errorf("reporting: gotenberg did not return a PDF")
	}
	return data, nil
}
