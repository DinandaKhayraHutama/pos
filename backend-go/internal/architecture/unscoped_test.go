package architecture_test

import (
	"go/parser"
	"go/token"
	"io/fs"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"testing"
)

const unscopedImport = "github.com/daniryckidinata/nti_pos/backend-go/internal/store/unscoped"

// allowedUnscopedImporters is every package that may read across merchants.
// Each is there for one reason, and adding a line here is a security review:
//
//   - devices: a bearer token resolves to a merchant before one is known.
//   - staff: a Backoffice email resolves to a merchant before one is known.
//   - tenancy: there is no merchant to scope to until it has been created.
//   - reporting: the scheduled-report scan finds due schedules across merchants.
//   - jobs: the worker lists merchants and runs partition maintenance.
//   - platform: the super-admin panel, which is cross-merchant by definition.
var allowedUnscopedImporters = map[string]bool{
	"internal/domain/devices":   true,
	"internal/domain/staff":     true,
	"internal/domain/tenancy":   true,
	"internal/domain/reporting": true,
	"internal/infra/jobs":       true,
	"internal/domain/platform":  true,
}

// The credential that bypasses row-level security is reachable only through
// that package, so its importers are the complete list of code that can see
// another merchant's rows. CLAUDE.md promises that list stays short; this is
// what holds it to the promise.
func TestUnscopedImportersAreCountable(t *testing.T) {
	root := filepath.Join("..", "..")
	found := map[string]bool{}

	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			if d.Name() == "bin" || d.Name() == "var" || d.Name() == "scripts" {
				return filepath.SkipDir
			}
			return nil
		}
		if !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			return nil
		}

		f, err := parser.ParseFile(token.NewFileSet(), path, nil, parser.ImportsOnly)
		if err != nil {
			return err
		}
		for _, imp := range f.Imports {
			if p, _ := strconv.Unquote(imp.Path.Value); p == unscopedImport {
				rel, _ := filepath.Rel(root, filepath.Dir(path))
				found[filepath.ToSlash(rel)] = true
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}

	var unexpected []string
	for pkg := range found {
		if !allowedUnscopedImporters[pkg] {
			unexpected = append(unexpected, pkg)
		}
	}
	sort.Strings(unexpected)
	if len(unexpected) > 0 {
		t.Fatalf("these packages import internal/store/unscoped without being on the allow-list: %v", unexpected)
	}
	if !found["internal/domain/devices"] {
		t.Fatal("device authentication no longer imports unscoped; the walk is probably looking in the wrong place")
	}
}
