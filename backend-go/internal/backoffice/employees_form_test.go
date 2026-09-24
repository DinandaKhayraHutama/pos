package backoffice

import (
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/backoffice/views"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/auth"
)

// The staff form's select posts a role row's id, but a system role may still
// be named by its key — what the form posted before Fase 3 and what the
// verification scripts send. Either way the domain gets one unambiguous name.
func TestAStaffFormNamesARoleByIDOrBySystemKey(t *testing.T) {
	form := func(role string) views.Form {
		f := views.NewForm()
		f.Values["name"] = "Sari"
		f.Values["role"] = role
		return f
	}

	in, _ := profileFromForm(form("cashier"), "")
	require.Equal(t, auth.Cashier, in.Role)
	require.Empty(t, in.RoleID)

	id := "6f1c3c4e-8a53-4c79-9d8e-0c6f1f2b7a10"
	in, _ = profileFromForm(form(id), "")
	require.Equal(t, id, in.RoleID)
	require.Empty(t, in.Role)

	// Anything else stays a role id, for the domain to refuse.
	in, _ = profileFromForm(form("supervisor"), "")
	require.Equal(t, "supervisor", in.RoleID)
}
