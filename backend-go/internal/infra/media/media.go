// Package media stores the files the platform serves to the public — today,
// product images — and serves them back.
//
// # Where the files live, and why
//
// On disk, in one directory (a Docker volume in Compose), written once under a
// content-addressed name and never modified. Caddy serves that directory
// directly under /media/; this package can serve it too, for any deployment
// without Caddy in front (CI, a developer's `justclick serve`).
//
// Not PostgreSQL: fifteen thousand tablets fetching menu photos must not go
// through the database or its backups. Not Redis: flushing it must never lose
// anything. And not object storage yet: the only self-hosted S3 server the stack
// could run in Compose is no longer distributed as an image, and the pilot is
// one VPS. The public URL is the part that must not change — every product row
// publishes it to every till — so it is `MEDIA_PUBLIC_BASE_URL` + key, and
// moving the bytes to object storage or a CDN later means copying the directory
// and pointing that base at the new home. No published row has to change.
//
// # Why content-addressed
//
// A key is the SHA-256 of the stored bytes, so a key names exactly one image
// forever. That makes every response cacheable for a year with no invalidation,
// makes a retried upload a no-op, and means replacing a product's image never
// breaks the URL a till that has not synced yet is still showing.
package media

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"net/http"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// keyPattern is the only shape a key may take. It is checked on write and on
// read, which is what keeps a request path from ever naming a file outside the
// directory, and a stored name from ever being something a browser would run.
var keyPattern = regexp.MustCompile(
	`^(products|receipts)/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{64}\.(jpg|png)$`)

var ErrInvalidKey = errors.New("media: invalid key")

// maxBaseURL leaves room under products.image_url's 500-character bound for
// the longest key this package will produce.
const maxBaseURL = 300

type Store struct {
	dir  string
	base string
}

// Open prepares the directory and refuses a base URL a till could not use.
func Open(dir, publicBase string) (*Store, error) {
	if dir == "" {
		return nil, errors.New("media: MEDIA_DIR is not set")
	}

	base := strings.TrimRight(publicBase, "/")
	u, err := url.Parse(base)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		return nil, fmt.Errorf("media: MEDIA_PUBLIC_BASE_URL must be an absolute http(s) URL, got %q", publicBase)
	}
	if len(base) > maxBaseURL {
		return nil, fmt.Errorf("media: MEDIA_PUBLIC_BASE_URL is longer than %d characters", maxBaseURL)
	}

	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, fmt.Errorf("media: create %s: %w", dir, err)
	}

	// Found at startup rather than on the first upload: a read-only volume is
	// a configuration mistake, not something an owner should discover.
	probe, err := os.CreateTemp(dir, ".probe-*")
	if err != nil {
		return nil, fmt.Errorf("media: %s is not writable: %w", dir, err)
	}
	probe.Close()
	os.Remove(probe.Name())

	return &Store{dir: dir, base: base}, nil
}

// BaseURL is what every published image URL starts with.
func (s *Store) BaseURL() string { return s.base }

// URL is the public address of a stored key.
func (s *Store) URL(key string) string { return s.base + "/" + key }

// Put stores body under key, once.
//
// Written to a temporary file, synced, then renamed into place, so a reader
// can never see half an image and a crash mid-write leaves nothing under the
// real name. An existing key is left alone: the name is the hash of the
// content, so it already holds these bytes.
func (s *Store) Put(ctx context.Context, key string, body []byte) error {
	if !keyPattern.MatchString(key) {
		return ErrInvalidKey
	}
	if err := ctx.Err(); err != nil {
		return err
	}

	target := filepath.Join(s.dir, filepath.FromSlash(key))
	if _, err := os.Stat(target); err == nil {
		return nil
	}

	folder := filepath.Dir(target)
	if err := os.MkdirAll(folder, 0o755); err != nil {
		return fmt.Errorf("media: create %s: %w", folder, err)
	}

	tmp, err := os.CreateTemp(folder, ".upload-*")
	if err != nil {
		return fmt.Errorf("media: temp file: %w", err)
	}
	defer os.Remove(tmp.Name())

	if _, err := tmp.Write(body); err != nil {
		tmp.Close()
		return fmt.Errorf("media: write: %w", err)
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return fmt.Errorf("media: sync: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("media: close: %w", err)
	}
	// CreateTemp makes the file 0600; Caddy reads it as another process.
	if err := os.Chmod(tmp.Name(), 0o644); err != nil {
		return fmt.Errorf("media: chmod: %w", err)
	}

	return os.Rename(tmp.Name(), target)
}

// Handler serves stored files. Mount it with the /media prefix stripped.
//
// Only a well-formed key is ever opened, so there is no directory listing and
// no way to name a temporary file or step outside the directory. Headers match
// the Caddyfile, so an image looks the same whichever of the two served it.
func (s *Store) Handler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			w.Header().Set("Allow", "GET, HEAD")
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}

		key := strings.TrimPrefix(r.URL.Path, "/")
		if !keyPattern.MatchString(key) {
			http.NotFound(w, r)
			return
		}

		file, err := os.Open(filepath.Join(s.dir, filepath.FromSlash(key)))
		if errors.Is(err, fs.ErrNotExist) {
			http.NotFound(w, r)
			return
		}
		if err != nil {
			http.Error(w, "unavailable", http.StatusInternalServerError)
			return
		}
		defer file.Close()

		info, err := file.Stat()
		if err != nil {
			http.Error(w, "unavailable", http.StatusInternalServerError)
			return
		}

		h := w.Header()
		h.Set("Content-Type", ContentType(key))
		// Immutable because the name is the content's hash — set only on a
		// file that exists, so a 404 is never cached for a year.
		h.Set("Cache-Control", "public, max-age=31536000, immutable")
		h.Set("ETag", `"`+strings.TrimSuffix(path.Base(key), path.Ext(key))+`"`)
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Content-Security-Policy", "default-src 'none'; sandbox")

		http.ServeContent(w, r, "", info.ModTime().Truncate(time.Second), file)
	})
}

// ContentType is decided by the key's extension, which this package chose.
func ContentType(key string) string {
	if strings.HasSuffix(key, ".png") {
		return "image/png"
	}
	return "image/jpeg"
}
