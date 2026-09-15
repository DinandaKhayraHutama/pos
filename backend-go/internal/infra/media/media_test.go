package media_test

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/media"
)

const key = "products/2f1c1f5e-4d1a-4f0e-9f36-8e1d2b7c9a10/" +
	"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef.jpg"

func open(t *testing.T) (*media.Store, string) {
	t.Helper()

	dir := t.TempDir()
	s, err := media.Open(dir, "https://pos.example.test/media/")
	require.NoError(t, err)
	return s, dir
}

func get(t *testing.T, s *media.Store, target string, header http.Header) *httptest.ResponseRecorder {
	t.Helper()

	req := httptest.NewRequest(http.MethodGet, target, nil)
	for k, v := range header {
		req.Header[k] = v
	}
	w := httptest.NewRecorder()
	s.Handler().ServeHTTP(w, req)
	return w
}

func TestAStoredImageIsServedImmutableAndInert(t *testing.T) {
	s, _ := open(t)
	require.NoError(t, s.Put(context.Background(), key, []byte("jpeg bytes")))

	require.Equal(t, "https://pos.example.test/media/"+key, s.URL(key), "one slash, whatever the base carried")

	w := get(t, s, "/"+key, nil)
	require.Equal(t, http.StatusOK, w.Code)
	require.Equal(t, "jpeg bytes", w.Body.String())
	require.Equal(t, "image/jpeg", w.Header().Get("Content-Type"))
	require.Equal(t, "public, max-age=31536000, immutable", w.Header().Get("Cache-Control"))
	require.Equal(t, "nosniff", w.Header().Get("X-Content-Type-Options"))
	require.Contains(t, w.Header().Get("Content-Security-Policy"), "sandbox")

	etag := w.Header().Get("ETag")
	require.NotEmpty(t, etag)
	again := get(t, s, "/"+key, http.Header{"If-None-Match": {etag}})
	require.Equal(t, http.StatusNotModified, again.Code, "a till that already has it downloads nothing")
}

// Only a well-formed key is ever opened: no listing, no temporary files, no
// way out of the directory. A missing image is a 404 nobody caches for a year.
func TestNothingButAWellFormedKeyIsServed(t *testing.T) {
	s, dir := open(t)
	require.NoError(t, s.Put(context.Background(), key, []byte("jpeg bytes")))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "secret.txt"), []byte("nope"), 0o644))

	for _, target := range []string{
		"/products/", "/products/2f1c1f5e-4d1a-4f0e-9f36-8e1d2b7c9a10/",
		"/secret.txt", "/../secret.txt", "/" + strings.Replace(key, ".jpg", ".html", 1),
		"/" + strings.Replace(key, "0123", "zzzz", 1),
	} {
		w := get(t, s, target, nil)
		require.Equal(t, http.StatusNotFound, w.Code, target)
		require.Empty(t, w.Header().Get("Cache-Control"), "%s: a 404 must not be cached as immutable", target)
	}

	missing := strings.Replace(key, "0123", "4567", 1)
	require.Equal(t, http.StatusNotFound, get(t, s, "/"+missing, nil).Code)
}

func TestAKeyOfAnyOtherShapeIsRefusedOnWrite(t *testing.T) {
	s, dir := open(t)

	for _, bad := range []string{"../escape.jpg", "products/x/y.jpg", "products/" + key, key + ".exe"} {
		require.ErrorIs(t, s.Put(context.Background(), bad, []byte("x")), media.ErrInvalidKey, bad)
	}

	entries, err := os.ReadDir(dir)
	require.NoError(t, err)
	require.Empty(t, entries, "a refused write must leave nothing behind")
}

// The name is the hash of the content, so a key that exists already holds
// these bytes; writing it again is a no-op, never a truncation.
func TestWritingAKeyTwiceKeepsTheFirstFileWhole(t *testing.T) {
	s, dir := open(t)
	ctx := context.Background()

	require.NoError(t, s.Put(ctx, key, []byte("first")))
	require.NoError(t, s.Put(ctx, key, []byte("second")))

	body, err := os.ReadFile(filepath.Join(dir, filepath.FromSlash(key)))
	require.NoError(t, err)
	require.Equal(t, "first", string(body))

	leftovers, err := filepath.Glob(filepath.Join(dir, "products", "*", ".upload-*"))
	require.NoError(t, err)
	require.Empty(t, leftovers, "no temporary file may outlive a write")
}

func TestABaseURLATillCannotUseIsRefusedAtStartup(t *testing.T) {
	for _, base := range []string{"", "/media", "localhost/media", "ftp://host/media", "https://" + strings.Repeat("a", 300)} {
		_, err := media.Open(t.TempDir(), base)
		require.Error(t, err, base)
	}
}
