package reporting

// SetAfterRollup lets a test land a sale between a slice's rollup commit and
// its marker check — exactly where a real one would race the job.
func (s *Service) SetAfterRollup(fn func()) { s.afterRollup = fn }

var (
	ColumnName = columnName
	SheetNames = sheetNames
	SafeText   = safeText
)
