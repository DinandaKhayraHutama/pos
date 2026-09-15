package reporting

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/validation"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/jobs"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/mailer"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/store/unscoped"
)

const (
	FormatCSV  = "csv"
	FormatXLSX = "xlsx"
	FormatPDF  = "pdf"

	ExportQueued  = "queued"
	ExportRunning = "running"
	ExportDone    = "done"
	ExportFailed  = "failed"
)

// Formats is every export format, in the order the page offers them.
var Formats = []string{FormatCSV, FormatXLSX, FormatPDF}

func validFormat(format string) bool {
	for _, f := range Formats {
		if f == format {
			return true
		}
	}
	return false
}

// Export is one export as the Backoffice lists it.
type Export struct {
	ID            string
	Format        string
	Status        string
	OutletID      string
	OutletName    string
	Error         string
	Scheduled     bool
	From          time.Time
	To            time.Time
	ByteSize      int64
	CreatedAt     time.Time
	FinishedAt    *time.Time
	DeliveredAt   *time.Time
	DeliveryError string
}

// File is an export ready to download.
type File struct {
	Path        string
	Name        string
	ContentType string
}

// RequestExport records an export and enqueues its job in the same transaction.
func (s *Service) RequestExport(ctx context.Context, tenantID, employeeID string, f Filter, format string) (string, error) {
	if err := f.Validate(MaxReportDays); err != nil {
		return "", err
	}
	if !validFormat(format) {
		return "", validation.Errors{"format": "Pilih format ekspor."}
	}
	var requestedBy *string
	if validation.UUID(employeeID) {
		requestedBy = &employeeID
	}

	var id string
	err := pg.InTenantTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		if err := liveOutlet(ctx, tx, tenantID, f.OutletID); err != nil {
			return err
		}
		if err := tx.QueryRow(ctx, `
			INSERT INTO report_exports (tenant_id, requested_by, format, outlet_id, date_from, date_to)
			VALUES ($1, $2, $3, $4, $5::date, $6::date)
			RETURNING id::text`,
			tenantID, requestedBy, format, outletArg(f.OutletID),
			f.From.Format(time.DateOnly), f.To.Format(time.DateOnly)).Scan(&id); err != nil {
			return err
		}
		return jobs.EnqueueExport(ctx, tx, s.queue, jobs.ReportExport{TenantID: tenantID, ExportID: id})
	})
	return id, err
}

// liveOutlet refuses an outlet that is not the merchant's. An empty id is the
// whole chain.
func liveOutlet(ctx context.Context, tx pgx.Tx, tenantID, outletID string) error {
	if outletID == "" {
		return nil
	}
	if !validation.UUID(outletID) {
		return ErrNotFound
	}
	var live bool
	if err := tx.QueryRow(ctx, `
		SELECT EXISTS (SELECT 1 FROM outlets WHERE tenant_id = $1 AND id = $2 AND deleted_at IS NULL)`,
		tenantID, outletID).Scan(&live); err != nil {
		return err
	}
	if !live {
		return ErrNotFound
	}
	return nil
}

// Exports lists the merchant's newest exports.
func (s *Service) Exports(ctx context.Context, tenantID string, limit int) ([]Export, error) {
	var out []Export
	err := pg.InTenantReadTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		var err error
		out, err = collect(ctx, tx, `
			SELECT e.id::text, e.format, e.status, COALESCE(e.outlet_id::text, ''), COALESCE(o.name, ''),
			       COALESCE(e.error, ''), e.schedule_id IS NOT NULL, e.date_from, e.date_to,
			       COALESCE(e.byte_size, 0), e.created_at, e.finished_at, e.delivered_at,
			       COALESCE(e.delivery_error, '')
			FROM report_exports e
			LEFT JOIN outlets o ON o.tenant_id = e.tenant_id AND o.id = e.outlet_id
			WHERE e.tenant_id = $1
			ORDER BY e.created_at DESC, e.id
			LIMIT $2`, []any{tenantID, limit}, func(row pgx.CollectableRow) (Export, error) {
			var e Export
			return e, row.Scan(&e.ID, &e.Format, &e.Status, &e.OutletID, &e.OutletName, &e.Error, &e.Scheduled,
				&e.From, &e.To, &e.ByteSize, &e.CreatedAt, &e.FinishedAt, &e.DeliveredAt, &e.DeliveryError)
		})
		return err
	})
	return out, err
}

type exportRow struct {
	format      string
	status      string
	outletID    *string
	from, to    time.Time
	scheduleID  *string
	deliveredAt *time.Time
}

// RunExport renders one export, stores its file and, for a scheduled export,
// mails its link.
//
// It is safe to run again. A finished export is not rendered twice, and a
// scheduled one whose mail failed is only mailed. lastAttempt is the job's
// final try: a failure is then recorded on the row instead of retried. A PDF
// export without gotenberg fails at once — no retry configures it.
func (s *Service) RunExport(ctx context.Context, tenantID, exportID string, lastAttempt bool) error {
	if !validation.UUID(exportID) {
		return nil
	}
	row, claimed, err := s.claimExport(ctx, tenantID, exportID)
	if errors.Is(err, ErrNotFound) {
		return nil
	}
	if err != nil {
		return err
	}
	if !claimed {
		if row.status == ExportDone && row.scheduleID != nil && row.deliveredAt == nil {
			return s.deliver(ctx, tenantID, exportID, lastAttempt)
		}
		return nil
	}

	data, err := s.render(ctx, tenantID, row)
	if err == nil {
		var key string
		if key, err = s.storeFile(tenantID, exportID, row.format, data); err == nil {
			err = pg.InTenantTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
				_, err := tx.Exec(ctx, `
					UPDATE report_exports
					SET status = 'done', file_key = $3, byte_size = $4, error = NULL, finished_at = now()
					WHERE tenant_id = $1 AND id = $2`, tenantID, exportID, key, len(data))
				return err
			})
		}
	}
	if err != nil {
		if !lastAttempt && !errors.Is(err, ErrPDFNotConfigured) {
			return err
		}
		return s.recordFailure(ctx, tenantID, exportID, err)
	}

	if row.scheduleID != nil {
		return s.deliver(ctx, tenantID, exportID, lastAttempt)
	}
	return nil
}

func (s *Service) claimExport(ctx context.Context, tenantID, exportID string) (exportRow, bool, error) {
	var row exportRow
	claimed := false
	err := pg.InTenantTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		err := tx.QueryRow(ctx, `
			UPDATE report_exports SET status = 'running'
			WHERE tenant_id = $1 AND id = $2 AND status IN ('queued', 'running')
			RETURNING format, status, outlet_id::text, date_from, date_to, schedule_id::text, delivered_at`,
			tenantID, exportID).Scan(&row.format, &row.status, &row.outletID, &row.from, &row.to, &row.scheduleID, &row.deliveredAt)
		if err == nil {
			claimed = true
			return nil
		}
		if !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
		err = tx.QueryRow(ctx, `
			SELECT format, status, outlet_id::text, date_from, date_to, schedule_id::text, delivered_at
			FROM report_exports WHERE tenant_id = $1 AND id = $2`,
			tenantID, exportID).Scan(&row.format, &row.status, &row.outletID, &row.from, &row.to, &row.scheduleID, &row.deliveredAt)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		return err
	})
	return row, claimed, err
}

func (s *Service) render(ctx context.Context, tenantID string, row exportRow) ([]byte, error) {
	f := Filter{From: row.from, To: row.to}
	if row.outletID != nil {
		f.OutletID = *row.outletID
	}
	report, err := s.Report(ctx, tenantID, f)
	if err != nil {
		return nil, err
	}
	loc, err := s.Location(ctx, tenantID)
	if err != nil {
		return nil, err
	}
	switch row.format {
	case FormatCSV:
		return RenderCSV(Tables(report, loc))
	case FormatXLSX:
		return RenderXLSX(Tables(report, loc))
	case FormatPDF:
		if s.opts.PDF == nil || s.opts.HTML == nil {
			return nil, ErrPDFNotConfigured
		}
		html, err := s.opts.HTML(ctx, report)
		if err != nil {
			return nil, err
		}
		return s.opts.PDF.RenderPDF(ctx, html)
	}
	return nil, fmt.Errorf("reporting: unknown export format %q", row.format)
}

var fileKeyPattern = regexp.MustCompile(`^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}/[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}\.(csv|xlsx|pdf)$`)

// storeFile writes the export atomically: a download never sees half a file.
func (s *Service) storeFile(tenantID, exportID, format string, data []byte) (string, error) {
	if s.opts.ExportDir == "" {
		return "", errors.New("reporting: REPORTS_DIR is not set")
	}
	key := strings.ToLower(tenantID) + "/" + strings.ToLower(exportID) + "." + format
	if !fileKeyPattern.MatchString(key) {
		return "", fmt.Errorf("reporting: refusing export key %q", key)
	}
	path := filepath.Join(s.opts.ExportDir, filepath.FromSlash(key))
	if err := os.MkdirAll(filepath.Dir(path), 0o750); err != nil {
		return "", err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".export-*")
	if err != nil {
		return "", err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		return "", err
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		return "", err
	}
	if err := tmp.Close(); err != nil {
		return "", err
	}
	if err := os.Rename(tmp.Name(), path); err != nil {
		return "", err
	}
	return key, nil
}

func (s *Service) recordFailure(ctx context.Context, tenantID, exportID string, cause error) error {
	message := cause.Error()
	if errors.Is(cause, ErrPDFNotConfigured) {
		message = "PDF belum tersedia: layanan gotenberg belum dikonfigurasi."
	}
	return pg.InTenantTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `
			UPDATE report_exports SET status = 'failed', error = $3, finished_at = now()
			WHERE tenant_id = $1 AND id = $2`, tenantID, exportID, truncate(message, 500))
		return err
	})
}

func truncate(s string, max int) string {
	if r := []rune(s); len(r) > max {
		return string(r[:max])
	}
	return s
}

// errScheduleDeleted is recorded when a schedule is gone before its export is
// mailed.
var errScheduleDeleted = errors.New("reporting: schedule deleted before delivery")

// deliver mails a scheduled export's download link. The link carries a fresh
// random token; only its hash is stored, and it expires after LinkTTL.
func (s *Service) deliver(ctx context.Context, tenantID, exportID string, lastAttempt bool) error {
	var (
		recipients []string
		business   string
		outlet     string
		format     string
		from, to   time.Time
	)
	err := pg.InTenantReadTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		return tx.QueryRow(ctx, `
			SELECT rs.recipients, t.name, COALESCE(o.name, 'semua outlet'), e.format, e.date_from, e.date_to
			FROM report_exports e
			JOIN report_schedules rs ON rs.tenant_id = e.tenant_id AND rs.id = e.schedule_id
			JOIN tenants t ON t.id = e.tenant_id
			LEFT JOIN outlets o ON o.tenant_id = e.tenant_id AND o.id = e.outlet_id
			WHERE e.tenant_id = $1 AND e.id = $2`, tenantID, exportID).
			Scan(&recipients, &business, &outlet, &format, &from, &to)
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return s.recordDelivery(ctx, tenantID, exportID, errScheduleDeleted)
	}
	if err != nil {
		return err
	}
	loc, err := s.Location(ctx, tenantID)
	if err != nil {
		return err
	}

	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		return err
	}
	token := hex.EncodeToString(secret)
	hash := sha256.Sum256([]byte(token))
	expires := time.Now().Add(s.opts.LinkTTL)
	if err := pg.InTenantTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `
			UPDATE report_exports SET token_sha256 = $3, link_expires_at = $4
			WHERE tenant_id = $1 AND id = $2`, tenantID, exportID, hash[:], expires)
		return err
	}); err != nil {
		return err
	}

	period := from.Format(time.DateOnly) + " s.d. " + to.Format(time.DateOnly)
	link := strings.TrimRight(s.opts.LinkBaseURL, "/") + LinkPath(exportID) + "?token=" + token
	msg := mailer.Message{
		To:      recipients,
		Subject: fmt.Sprintf("Laporan penjualan %s, %s", business, period),
		Text: fmt.Sprintf("Laporan penjualan %s untuk %s, periode %s, sudah siap (%s).\n\n"+
			"Unduh laporan:\n%s\n\n"+
			"Tautan ini berlaku sampai %s dan hanya untuk penerima jadwal ini. Jangan teruskan email ini.\n",
			business, outlet, period, strings.ToUpper(format), link, expires.In(loc).Format("02 Jan 2006 15:04 MST")),
	}

	if s.opts.Mail == nil {
		err = mailer.ErrNotConfigured
	} else {
		err = s.opts.Mail.Send(ctx, msg)
	}
	if err != nil && !lastAttempt && !errors.Is(err, mailer.ErrNotConfigured) {
		_ = s.recordDelivery(ctx, tenantID, exportID, err)
		return err
	}
	return s.recordDelivery(ctx, tenantID, exportID, err)
}

func (s *Service) recordDelivery(ctx context.Context, tenantID, exportID string, sendErr error) error {
	return pg.InTenantTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		if sendErr == nil {
			_, err := tx.Exec(ctx, `
				UPDATE report_exports SET delivered_at = now(), delivery_error = NULL
				WHERE tenant_id = $1 AND id = $2`, tenantID, exportID)
			return err
		}
		message := sendErr.Error()
		switch {
		case errors.Is(sendErr, mailer.ErrNotConfigured):
			message = "Email belum dikonfigurasi (SMTP_HOST); laporan tetap bisa diunduh dari Backoffice."
		case errors.Is(sendErr, errScheduleDeleted):
			message = "Jadwal sudah dihapus; laporan tidak dikirim."
		}
		_, err := tx.Exec(ctx, `
			UPDATE report_exports SET delivery_error = $3
			WHERE tenant_id = $1 AND id = $2`, tenantID, exportID, truncate(message, 500))
		return err
	})
}

// OpenExport is a signed-in employee's download of one of the merchant's
// finished exports.
func (s *Service) OpenExport(ctx context.Context, tenantID, exportID string) (File, error) {
	if !validation.UUID(exportID) {
		return File{}, ErrNotFound
	}
	var status, format string
	var key *string
	var from, to time.Time
	err := pg.InTenantReadTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		err := tx.QueryRow(ctx, `
			SELECT status, file_key, format, date_from, date_to FROM report_exports
			WHERE tenant_id = $1 AND id = $2`, tenantID, exportID).Scan(&status, &key, &format, &from, &to)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		return err
	})
	if err != nil {
		return File{}, err
	}
	if status != ExportDone || key == nil {
		return File{}, ErrExportNotReady
	}
	return s.file(*key, format, from, to)
}

// OpenExportByToken is the e-mailed link: no session, so the export is looked
// up across merchants by id, and the token — compared in constant time against
// its stored hash — is the whole credential.
func (s *Service) OpenExportByToken(ctx context.Context, exportID, token string) (File, error) {
	if !validation.UUID(exportID) || len(token) != 64 {
		return File{}, ErrNotFound
	}
	var (
		status, format string
		key            *string
		from, to       time.Time
		stored         []byte
		expires        *time.Time
	)
	err := unscoped.Tx(ctx, s.pools.Unscoped, func(ctx context.Context, tx pgx.Tx) error {
		err := tx.QueryRow(ctx, `
			SELECT status, file_key, format, date_from, date_to, token_sha256, link_expires_at
			FROM report_exports WHERE id = $1`, exportID).Scan(&status, &key, &format, &from, &to, &stored, &expires)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		return err
	})
	if err != nil {
		return File{}, err
	}
	hash := sha256.Sum256([]byte(token))
	if len(stored) != len(hash) || subtle.ConstantTimeCompare(hash[:], stored) != 1 {
		return File{}, ErrNotFound
	}
	if expires == nil || !time.Now().Before(*expires) {
		return File{}, ErrLinkExpired
	}
	if status != ExportDone || key == nil {
		return File{}, ErrExportNotReady
	}
	return s.file(*key, format, from, to)
}

func (s *Service) file(key, format string, from, to time.Time) (File, error) {
	if !fileKeyPattern.MatchString(key) {
		return File{}, ErrNotFound
	}
	path := filepath.Join(s.opts.ExportDir, filepath.FromSlash(key))
	if _, err := os.Stat(path); err != nil {
		return File{}, ErrNotFound
	}
	return File{
		Path:        path,
		Name:        fmt.Sprintf("laporan-%s-%s.%s", from.Format(time.DateOnly), to.Format(time.DateOnly), format),
		ContentType: contentTypes[format],
	}, nil
}

var contentTypes = map[string]string{
	FormatCSV:  "text/csv; charset=utf-8",
	FormatXLSX: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
	FormatPDF:  "application/pdf",
}

// PurgeExports removes exports, and their files, created before olderThan.
// Exports are a delivery, not an archive: the rollups are what is kept.
func (s *Service) PurgeExports(ctx context.Context, olderThan time.Time) (int, error) {
	var keys []*string
	err := unscoped.Tx(ctx, s.pools.Unscoped, func(ctx context.Context, tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `DELETE FROM report_exports WHERE created_at < $1 RETURNING file_key`, olderThan)
		if err != nil {
			return err
		}
		keys, err = pgx.CollectRows(rows, pgx.RowTo[*string])
		return err
	})
	if err != nil {
		return 0, err
	}
	for _, key := range keys {
		if key != nil && fileKeyPattern.MatchString(*key) && s.opts.ExportDir != "" {
			_ = os.Remove(filepath.Join(s.opts.ExportDir, filepath.FromSlash(*key)))
		}
	}
	return len(keys), nil
}
