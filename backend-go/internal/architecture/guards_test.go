package architecture_test

import (
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
)

var tenantSource = regexp.MustCompile(`(?is)\b(?:from|join)\s+(?:public\.)?tenants\b(?:\s+(?:as\s+)?(\w+))?`)
var rowLock = regexp.MustCompile(`(?is)\bfor\s+(?:no\s+key\s+update|update|share|key\s+share)\b(?:\s+of\s+([\w, ]+))?`)

func locksTenant(sql string) bool {
	for _, stmt := range strings.Split(sql, ";") {
		sources := tenantSource.FindAllStringSubmatch(stmt, -1)
		for _, l := range rowLock.FindAllStringSubmatch(stmt, -1) {
			for _, s := range sources {
				if l[1] == "" {
					return true
				}
				for _, alias := range strings.FieldsFunc(l[1], func(r rune) bool { return r == ',' || r == ' ' }) {
					if alias == "tenants" || alias == s[1] {
						return true
					}
				}
			}
		}
	}
	return false
}
func TestTenantLockGuardRecognizesMultilineSQL(t *testing.T) {
	for _, sql := range []string{"SELECT id FROM tenants\nWHERE id=$1\nFOR UPDATE", "select t.id from tenants t join outlets o on true for update of t"} {
		if !locksTenant(sql) {
			t.Fatal(sql)
		}
	}
	if locksTenant("select r.id from pos_registers r join tenants t on true for update of r") {
		t.Fatal("register lock is allowed")
	}
}
func TestNoTenantRowLocksInProductionQueries(t *testing.T) {
	root := filepath.Join("..", "..")
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			if d.Name() == "bin" || d.Name() == "var" {
				return filepath.SkipDir
			}
			return nil
		}
		if strings.HasSuffix(path, "_test.go") {
			return nil
		}
		if strings.HasSuffix(path, ".go") {
			f, e := parser.ParseFile(token.NewFileSet(), path, nil, 0)
			if e != nil {
				return e
			}
			ast.Inspect(f, func(n ast.Node) bool {
				if v, ok := n.(*ast.BasicLit); ok && v.Kind == token.STRING {
					sql, e := strconv.Unquote(v.Value)
					if e == nil && locksTenant(sql) {
						t.Errorf("tenant row lock in %s: %s", path, sql)
					}
				}
				return true
			})
		} else if strings.HasSuffix(path, ".sql") {
			raw, e := os.ReadFile(path)
			if e != nil {
				return e
			}
			if locksTenant(string(raw)) {
				t.Errorf("tenant lock in %s", path)
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}
