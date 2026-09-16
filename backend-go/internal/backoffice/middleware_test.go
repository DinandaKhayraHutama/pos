package backoffice

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/auth"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/entitlements"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/platform"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/staff"
)

type recordingImpersonations struct {
	Impersonations
	recordErr error
	recorded  []string
}

func (f *recordingImpersonations) RecordImpersonatedRequest(_ context.Context, _ platform.Impersonation, method, path, _ string) error {
	if f.recordErr != nil {
		return f.recordErr
	}
	f.recorded = append(f.recorded, method+" "+path)
	return nil
}

func newTestHandler(imps Impersonations) *Handler {
	return New(Deps{
		Logger:         slog.New(slog.NewTextHandler(io.Discard, nil)),
		CSRFKey:        make([]byte, 32),
		Impersonations: imps,
	})
}

func owner(features entitlements.Set) staff.Employee {
	return staff.Employee{ID: "e", TenantID: "t", Name: "Owner", Role: auth.Owner, Active: true, Features: features}
}

// request builds what requireEmployee would have put in the context.
func request(method, path string, emp staff.Employee, imp *platform.Impersonation) *http.Request {
	r := httptest.NewRequest(method, path, nil)
	ctx := context.WithValue(r.Context(), employeeKey, emp)
	if imp != nil {
		ctx = context.WithValue(ctx, impersonationKey, *imp)
	}
	return r.WithContext(ctx)
}

var impersonating = &platform.Impersonation{
	ID: "i", TenantID: "t", EmployeeID: "e", AdminName: "Support", ExpiresAt: time.Now().Add(time.Hour),
}

// Under impersonation the audit row is the condition for writing at all: a
// change whose row could not be written must not run.
func TestAnImpersonatedChangeIsRefusedWhenItsAuditRowCannotBeWritten(t *testing.T) {
	failing := &recordingImpersonations{recordErr: errors.New("database unavailable")}
	h := newTestHandler(failing)

	ran := false
	next := http.HandlerFunc(func(http.ResponseWriter, *http.Request) { ran = true })

	w := httptest.NewRecorder()
	h.auditImpersonatedWrites(next).ServeHTTP(w, request(http.MethodPost, "/backoffice/catalogue/categories", owner(nil), impersonating))
	require.Equal(t, http.StatusServiceUnavailable, w.Code)
	require.False(t, ran, "the change must not run without its audit row")

	working := &recordingImpersonations{}
	h = newTestHandler(working)

	w = httptest.NewRecorder()
	h.auditImpersonatedWrites(next).ServeHTTP(w, request(http.MethodPost, "/backoffice/catalogue/categories", owner(nil), impersonating))
	require.True(t, ran)
	require.Equal(t, []string{"POST /backoffice/catalogue/categories"}, working.recorded)

	ran = false
	w = httptest.NewRecorder()
	h.auditImpersonatedWrites(next).ServeHTTP(w, request(http.MethodGet, "/backoffice/stock", owner(nil), impersonating))
	require.True(t, ran)
	require.Len(t, working.recorded, 1, "reads are not recorded")

	ran = false
	w = httptest.NewRecorder()
	h.auditImpersonatedWrites(next).ServeHTTP(w, request(http.MethodPost, "/backoffice/catalogue/categories", owner(nil), nil))
	require.True(t, ran)
	require.Len(t, working.recorded, 1, "an owner working normally is not audited")
}

func TestASwitchedOffModuleIsNotFound(t *testing.T) {
	h := newTestHandler(nil)
	ran := false
	next := http.HandlerFunc(func(http.ResponseWriter, *http.Request) { ran = true })

	w := httptest.NewRecorder()
	h.requireFeature(entitlements.Stock)(next).ServeHTTP(w,
		request(http.MethodGet, "/backoffice/stock", owner(entitlements.Set{entitlements.Stock: false}), nil))
	require.Equal(t, http.StatusNotFound, w.Code)
	require.False(t, ran)

	w = httptest.NewRecorder()
	h.requireFeature(entitlements.Stock)(next).ServeHTTP(w, request(http.MethodGet, "/backoffice/stock", owner(nil), nil))
	require.True(t, ran, "a merchant with no override has the module")

	s := h.sessionView(request(http.MethodGet, "/", owner(entitlements.Set{entitlements.Stock: false}), nil))
	require.False(t, s.CanStock, "the nav must not link to a module the route refuses")
	require.True(t, s.CanPromos)
}

func TestSupportCannotSetAPasswordOrPINWhileImpersonating(t *testing.T) {
	h := newTestHandler(&recordingImpersonations{})
	ran := false
	next := http.HandlerFunc(func(http.ResponseWriter, *http.Request) { ran = true })

	w := httptest.NewRecorder()
	h.refuseWhileImpersonating(next).ServeHTTP(w, request(http.MethodPost, "/backoffice/staff/e/password", owner(nil), impersonating))
	require.Equal(t, http.StatusForbidden, w.Code)
	require.False(t, ran)

	w = httptest.NewRecorder()
	h.refuseWhileImpersonating(next).ServeHTTP(w, request(http.MethodPost, "/backoffice/staff/e/password", owner(nil), nil))
	require.True(t, ran, "the owner themself may")

	banner := h.sessionView(request(http.MethodGet, "/", owner(nil), impersonating)).Impersonation
	require.NotNil(t, banner)
	require.Equal(t, "Support", banner.AdminName)
}
