package reporting_test

import (
	"archive/zip"
	"bytes"
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/reporting"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/validation"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/mailer"
)

type fakeMail struct {
	mu   sync.Mutex
	sent []mailer.Message
	fail error
}

func (m *fakeMail) Send(_ context.Context, msg mailer.Message) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.fail != nil {
		err := m.fail
		m.fail = nil
		return err
	}
	m.sent = append(m.sent, msg)
	return nil
}

func htmlStub(_ context.Context, r reporting.Report) ([]byte, error) {
	return []byte("<html><body>" + r.BusinessName + " " + strconv.FormatInt(r.Revenue, 10) + "</body></html>"), nil
}

// fakeGotenberg answers the Chromium HTML route with a PDF and remembers the
// page it was sent.
func fakeGotenberg(t *testing.T) (*reporting.Gotenberg, func() string) {
	var mu sync.Mutex
	var received []byte
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/forms/chromium/convert/html" {
			http.NotFound(w, r)
			return
		}
		file, header, err := r.FormFile("files")
		if err != nil || header.Filename != "index.html" {
			http.Error(w, "index.html is required", http.StatusBadRequest)
			return
		}
		body, _ := io.ReadAll(file)
		mu.Lock()
		received = body
		mu.Unlock()
		_, _ = w.Write([]byte("%PDF-1.7\n% fake\n"))
	}))
	t.Cleanup(srv.Close)
	return reporting.NewGotenberg(srv.URL), func() string {
		mu.Lock()
		defer mu.Unlock()
		return string(received)
	}
}

func TestExportsAreRenderedStoredAndServedToTheirMerchantOnly(t *testing.T) {
	pdf, sentPage := fakeGotenberg(t)
	f := setup(t, func(o *reporting.Options) { o.PDF, o.HTML = pdf, htmlStub })
	ctx := context.Background()
	f.seedDay()
	f.recompute(f.outletA)
	day := reporting.Filter{From: f.day, To: f.day}
	d := f.day.Format(time.DateOnly)

	csvID, err := f.svc.RequestExport(ctx, f.tenantID, "", day, reporting.FormatCSV)
	require.NoError(t, err)
	require.Equal(t, 1, f.count(`SELECT count(*) FROM jobs.river_job WHERE kind = 'report_export' AND args->>'export_id' = $1`, csvID),
		"the job is enqueued with its row")
	require.NoError(t, f.svc.RunExport(ctx, f.tenantID, csvID, false))

	file, err := f.svc.OpenExport(ctx, f.tenantID, csvID)
	require.NoError(t, err)
	require.Equal(t, "laporan-"+d+"-"+d+".csv", file.Name)
	require.True(t, strings.HasPrefix(file.ContentType, "text/csv"))
	data, err := os.ReadFile(file.Path)
	require.NoError(t, err)
	require.True(t, bytes.HasPrefix(data, []byte{0xEF, 0xBB, 0xBF}))
	require.Contains(t, string(data), "Pendapatan,77450")
	require.Contains(t, string(data), "Minuman Dingin,45000,42000,3,")

	before, err := os.Stat(file.Path)
	require.NoError(t, err)
	require.NoError(t, f.svc.RunExport(ctx, f.tenantID, csvID, false), "a retry of a finished export")
	after, err := os.Stat(file.Path)
	require.NoError(t, err)
	require.Equal(t, before.ModTime(), after.ModTime(), "renders nothing twice")

	_, err = f.svc.OpenExport(ctx, f.otherTenantID, csvID)
	require.ErrorIs(t, err, reporting.ErrNotFound)

	xlsxID, err := f.svc.RequestExport(ctx, f.tenantID, "", day, reporting.FormatXLSX)
	require.NoError(t, err)
	require.NoError(t, f.svc.RunExport(ctx, f.tenantID, xlsxID, false))
	file, err = f.svc.OpenExport(ctx, f.tenantID, xlsxID)
	require.NoError(t, err)
	zr, err := zip.OpenReader(file.Path)
	require.NoError(t, err)
	var summary string
	for _, part := range zr.File {
		if part.Name == "xl/worksheets/sheet1.xml" {
			rc, err := part.Open()
			require.NoError(t, err)
			b, _ := io.ReadAll(rc)
			_ = rc.Close()
			summary = string(b)
		}
	}
	require.NoError(t, zr.Close())
	require.Contains(t, summary, "<v>77450</v>")

	pdfID, err := f.svc.RequestExport(ctx, f.tenantID, "", day, reporting.FormatPDF)
	require.NoError(t, err)
	require.NoError(t, f.svc.RunExport(ctx, f.tenantID, pdfID, false))
	file, err = f.svc.OpenExport(ctx, f.tenantID, pdfID)
	require.NoError(t, err)
	data, err = os.ReadFile(file.Path)
	require.NoError(t, err)
	require.True(t, bytes.HasPrefix(data, []byte("%PDF-")))
	require.Contains(t, sentPage(), "Warung Laporan 77450", "the PDF is the report page")

	list, err := f.svc.Exports(ctx, f.tenantID, 10)
	require.NoError(t, err)
	require.Len(t, list, 3)
	for _, e := range list {
		require.Equal(t, reporting.ExportDone, e.Status, e.Format)
		require.Positive(t, e.ByteSize)
	}

	_, err = f.svc.RequestExport(ctx, f.tenantID, "", day, "docx")
	_, invalid := validation.As(err)
	require.True(t, invalid)
	_, err = f.svc.RequestExport(ctx, f.tenantID, "", reporting.Filter{From: f.day, To: f.day, OutletID: uuid()}, reporting.FormatCSV)
	require.ErrorIs(t, err, reporting.ErrNotFound)
}

func TestAPDFExportWithoutGotenbergFailsAtOnceAndSaysWhy(t *testing.T) {
	f := setup(t)
	ctx := context.Background()

	id, err := f.svc.RequestExport(ctx, f.tenantID, "", reporting.Filter{From: f.day, To: f.day}, reporting.FormatPDF)
	require.NoError(t, err)
	require.NoError(t, f.svc.RunExport(ctx, f.tenantID, id, false), "not a retryable failure")

	list, err := f.svc.Exports(ctx, f.tenantID, 10)
	require.NoError(t, err)
	require.Equal(t, reporting.ExportFailed, list[0].Status)
	require.Contains(t, list[0].Error, "gotenberg")
	_, err = f.svc.OpenExport(ctx, f.tenantID, id)
	require.ErrorIs(t, err, reporting.ErrExportNotReady)
}

func TestScheduledReportsAreMailedAsLinksThatExpire(t *testing.T) {
	mail := &fakeMail{}
	f := setup(t, func(o *reporting.Options) { o.Mail = mail })
	ctx := context.Background()

	_, err := f.svc.CreateSchedule(ctx, f.tenantID, "", reporting.ScheduleInput{Frequency: "hourly", Format: "csv", Recipients: "bukan email"})
	problems, invalid := validation.As(err)
	require.True(t, invalid)
	require.Contains(t, problems, "frequency")
	require.Contains(t, problems, "recipients")

	scheduleID, err := f.svc.CreateSchedule(ctx, f.tenantID, "", reporting.ScheduleInput{
		Frequency: reporting.FrequencyDaily, Format: reporting.FormatCSV,
		Recipients: "owner@warung.test; Manajer <manajer@warung.test>\nOWNER@warung.test",
	})
	require.NoError(t, err)
	schedules, err := f.svc.Schedules(ctx, f.tenantID)
	require.NoError(t, err)
	require.Len(t, schedules, 1)
	require.Equal(t, []string{"owner@warung.test", "manajer@warung.test"}, schedules[0].Recipients)
	require.True(t, schedules[0].NextRunAt.After(time.Now()))

	_, err = f.db.Owner.Exec(ctx, `UPDATE report_schedules SET next_run_at = now() - interval '1 minute' WHERE id = $1`, scheduleID)
	require.NoError(t, err)
	n, err := f.svc.RunDueSchedules(ctx, time.Now())
	require.NoError(t, err)
	require.Equal(t, 1, n)
	n, err = f.svc.RunDueSchedules(ctx, time.Now())
	require.NoError(t, err)
	require.Zero(t, n, "the schedule moved on; a second scan mails nothing")

	var exportID string
	var from, to time.Time
	require.NoError(t, f.db.Owner.QueryRow(ctx,
		`SELECT id::text, date_from, date_to FROM report_exports WHERE schedule_id = $1`, scheduleID).Scan(&exportID, &from, &to))
	require.True(t, from.Equal(to), "a daily report covers one day")
	require.True(t, from.Before(f.day.AddDate(0, 0, 1)))

	// The mail server is down on the first attempt: the file is kept, the
	// failure recorded, and the retry mails without rendering again.
	mail.fail = errors.New("smtp down")
	require.Error(t, f.svc.RunExport(ctx, f.tenantID, exportID, false))
	var status string
	var deliveryError *string
	var deliveredAt *time.Time
	require.NoError(t, f.db.Owner.QueryRow(ctx,
		`SELECT status, delivery_error, delivered_at FROM report_exports WHERE id = $1`, exportID).Scan(&status, &deliveryError, &deliveredAt))
	require.Equal(t, reporting.ExportDone, status)
	require.NotNil(t, deliveryError)
	require.Contains(t, *deliveryError, "smtp down")
	require.Nil(t, deliveredAt)

	require.NoError(t, f.svc.RunExport(ctx, f.tenantID, exportID, false))
	require.NoError(t, f.db.Owner.QueryRow(ctx,
		`SELECT delivery_error, delivered_at FROM report_exports WHERE id = $1`, exportID).Scan(&deliveryError, &deliveredAt))
	require.Nil(t, deliveryError)
	require.NotNil(t, deliveredAt)

	require.Len(t, mail.sent, 1)
	msg := mail.sent[0]
	require.Equal(t, []string{"owner@warung.test", "manajer@warung.test"}, msg.To)
	require.Contains(t, msg.Text, "https://pos.test"+reporting.LinkPath(exportID)+"?token=")
	require.NotContains(t, msg.Text, "Pendapatan", "a link, never the figures")

	token := regexp.MustCompile(`token=([0-9a-f]{64})`).FindStringSubmatch(msg.Text)
	require.Len(t, token, 2)
	file, err := f.svc.OpenExportByToken(ctx, exportID, token[1])
	require.NoError(t, err)
	require.True(t, strings.HasSuffix(file.Name, ".csv"))

	wrong := []byte(token[1])
	if wrong[0] == 'a' {
		wrong[0] = 'b'
	} else {
		wrong[0] = 'a'
	}
	_, err = f.svc.OpenExportByToken(ctx, exportID, string(wrong))
	require.ErrorIs(t, err, reporting.ErrNotFound)
	_, err = f.svc.OpenExportByToken(ctx, uuid(), token[1])
	require.ErrorIs(t, err, reporting.ErrNotFound)

	_, err = f.db.Owner.Exec(ctx, `UPDATE report_exports SET link_expires_at = now() - interval '1 second' WHERE id = $1`, exportID)
	require.NoError(t, err)
	_, err = f.svc.OpenExportByToken(ctx, exportID, token[1])
	require.ErrorIs(t, err, reporting.ErrLinkExpired)

	require.NoError(t, f.svc.SetScheduleActive(ctx, f.tenantID, scheduleID, false))
	schedules, err = f.svc.Schedules(ctx, f.tenantID)
	require.NoError(t, err)
	require.False(t, schedules[0].Active)
	require.NoError(t, f.svc.SetScheduleActive(ctx, f.tenantID, scheduleID, true))
	schedules, err = f.svc.Schedules(ctx, f.tenantID)
	require.NoError(t, err)
	require.True(t, schedules[0].Active)
	require.True(t, schedules[0].NextRunAt.After(time.Now()), "resuming never fires a stale run")

	require.ErrorIs(t, f.svc.SetScheduleActive(ctx, f.otherTenantID, scheduleID, false), reporting.ErrNotFound)
	require.NoError(t, f.svc.DeleteSchedule(ctx, f.tenantID, scheduleID))
	require.ErrorIs(t, f.svc.DeleteSchedule(ctx, f.tenantID, scheduleID), reporting.ErrNotFound)
	require.Equal(t, 1, f.count(`SELECT count(*) FROM report_exports WHERE id = $1 AND schedule_id IS NULL`, exportID),
		"a deleted schedule's exports stay, detached")
}

func TestOldExportsAreRemovedWithTheirFiles(t *testing.T) {
	f := setup(t)
	ctx := context.Background()

	id, err := f.svc.RequestExport(ctx, f.tenantID, "", reporting.Filter{From: f.day, To: f.day}, reporting.FormatCSV)
	require.NoError(t, err)
	require.NoError(t, f.svc.RunExport(ctx, f.tenantID, id, false))
	file, err := f.svc.OpenExport(ctx, f.tenantID, id)
	require.NoError(t, err)

	_, err = f.db.Owner.Exec(ctx, `UPDATE report_exports SET created_at = now() - interval '31 days' WHERE id = $1`, id)
	require.NoError(t, err)
	n, err := f.svc.PurgeExports(ctx, time.Now().Add(-30*24*time.Hour))
	require.NoError(t, err)
	require.Equal(t, 1, n)
	_, err = os.Stat(file.Path)
	require.True(t, os.IsNotExist(err))
	_, err = f.svc.OpenExport(ctx, f.tenantID, id)
	require.ErrorIs(t, err, reporting.ErrNotFound)
}
