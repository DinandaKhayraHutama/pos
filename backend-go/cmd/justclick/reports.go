package main

import (
	"log/slog"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/backoffice/views"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/reporting"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/config"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/mailer"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
)

// newReports builds the reporting service the API and the worker share. The
// API reads reports and serves downloads; the worker computes rollups, renders
// exports and mails links — both from the same configuration, so a link the
// worker mails is one the API can serve.
func newReports(cfg config.Config, pools pg.Pools, logger *slog.Logger) (*reporting.Service, error) {
	linkBase, err := cfg.LinkBaseURL()
	if err != nil {
		return nil, err
	}
	mail, err := mailer.New(mailer.Config{
		Host: cfg.SMTPHost, Port: cfg.SMTPPort,
		Username: cfg.SMTPUsername, Password: cfg.SMTPPassword, From: cfg.MailFrom,
	})
	if err != nil {
		return nil, err
	}

	opts := reporting.Options{
		ExportDir:   cfg.ReportsDir,
		LinkBaseURL: linkBase,
		HTML:        views.RenderReportHTML,
		Mail:        mail,
	}
	// A nil *Gotenberg in the interface would still report ErrPDFNotConfigured,
	// but leaving the field nil says so without relying on that.
	if pdf := reporting.NewGotenberg(cfg.GotenbergURL); pdf != nil {
		opts.PDF = pdf
	}
	return reporting.NewService(pools, logger, opts)
}
