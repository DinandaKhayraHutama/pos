package reporting

// LinkPath is where an e-mailed download link points. It sits outside the
// signed-in /backoffice/reports section on purpose: the person opening it may
// have no session, and the token in its query is the credential.
func LinkPath(exportID string) string {
	return "/backoffice/report-links/" + exportID
}
