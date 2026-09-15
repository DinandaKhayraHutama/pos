package config

import (
	"fmt"
	"strings"
	"time"

	"github.com/caarlos0/env/v11"
)

type Config struct {
	TrustProxy  bool   `env:"TRUST_PROXY" envDefault:"false"`
	Environment string `env:"ENVIRONMENT" envDefault:"local"`
	HTTPAddr    string `env:"HTTP_ADDR" envDefault:":9000"`
	LogLevel    string `env:"LOG_LEVEL" envDefault:"info"`
	// The tenant-scoped credential. It must NOT be able to bypass row-level
	// security; the process refuses to start if it can.
	DatabaseURL string `env:"DATABASE_URL,required"`
	// The escape hatch, which deliberately can. Only the handful of lookups
	// that resolve an identity before a tenant is known use it.
	UnscopedDatabaseURL string `env:"UNSCOPED_DATABASE_URL,required"`
	// Owns the schema and runs DDL. Never used to serve a request.
	MigrateDatabaseURL string `env:"MIGRATE_DATABASE_URL"`
	RedisURL           string `env:"REDIS_URL"`
	// How often a till should poll /sync/changes. Served to the fleet in every
	// response rather than compiled into the app, so an incident can widen the
	// interval without waiting on an app-store review.
	SyncPollInterval time.Duration `env:"SYNC_POLL_INTERVAL" envDefault:"60s"`
	// Keys activation-code fingerprints and the Backoffice CSRF secret.
	//
	// Rule: nothing durable may be derived from it. Rotating it costs
	// ten-minute activation codes and forms that are open at that moment, and
	// it must stay that cheap — so no stored hash, fingerprint or published URL
	// is ever keyed by it. An earlier PIN-uniqueness fingerprint broke that
	// rule and was removed with the constraint it served.
	AppKey string `env:"APP_KEY,required"`

	// Where uploaded product images are written. A Docker volume in Compose,
	// shared read-only with Caddy, which serves it under /media/.
	MediaDir string `env:"MEDIA_DIR" envDefault:"var/media"`
	// What every published image URL starts with, e.g.
	// https://pos.example.id/media. Every till stores these URLs, so this is the
	// part to keep stable: moving the files to object storage or a CDN later
	// means pointing this host at the new home, not rewriting product rows.
	MediaPublicBaseURL string `env:"MEDIA_PUBLIC_BASE_URL"`

	// Report exports (Fase 7). Files are private: served only to a signed-in
	// employee of the merchant, or through an e-mailed link that expires. A
	// Docker volume shared by the API (which serves downloads) and the worker
	// (which writes them) in Compose.
	ReportsDir string `env:"REPORTS_DIR" envDefault:"var/reports"`
	// The origin e-mailed download links start with, e.g. https://pos.example.id.
	PublicBaseURL string `env:"PUBLIC_BASE_URL"`
	// A gotenberg sidecar renders the report page to PDF. Unset, a PDF export
	// fails with a message saying so; CSV and XLSX still work.
	GotenbergURL string `env:"GOTENBERG_URL"`
	SMTPHost     string `env:"SMTP_HOST"`
	SMTPPort     int    `env:"SMTP_PORT" envDefault:"587"`
	SMTPUsername string `env:"SMTP_USERNAME"`
	SMTPPassword string `env:"SMTP_PASSWORD"`
	MailFrom     string `env:"MAIL_FROM"`
}

// LinkBaseURL is the origin of e-mailed report links. Outside local development
// it must be https: the link carries a credential.
func (c Config) LinkBaseURL() (string, error) {
	base := strings.TrimRight(strings.TrimSpace(c.PublicBaseURL), "/")
	if base == "" {
		if c.Environment != "local" {
			return "", fmt.Errorf("PUBLIC_BASE_URL is not set; scheduled reports need an absolute https origin for their links")
		}
		host := c.HTTPAddr
		if strings.HasPrefix(host, ":") {
			host = "localhost" + host
		}
		return "http://" + host, nil
	}
	if c.Environment != "local" && !strings.HasPrefix(base, "https://") {
		return "", fmt.Errorf("PUBLIC_BASE_URL must be https outside local development, got %q", base)
	}
	return base, nil
}

func Load() (Config, error) {
	var c Config
	if err := env.Parse(&c); err != nil {
		return Config{}, fmt.Errorf("load config: %w", err)
	}
	if c.SyncPollInterval < time.Second || c.SyncPollInterval > time.Hour {
		return Config{}, fmt.Errorf("SYNC_POLL_INTERVAL must be between 1s and 1h")
	}
	if c.RedisURL == "" {
		return Config{}, fmt.Errorf("REDIS_URL is required (availability is optional)")
	}
	if c.Environment != "local" && c.Environment != "test" && len(c.AppKey) < 32 {
		return Config{}, fmt.Errorf("APP_KEY must contain at least 32 bytes outside local/test")
	}

	return c, nil
}

// RequireMigrateURL is checked by the commands that run DDL rather than at
// load time: the serving process must not carry the owner credential at all,
// which is the point of keeping it a separate variable.
func (c Config) RequireMigrateURL() (string, error) {
	if c.MigrateDatabaseURL == "" {
		return "", fmt.Errorf("MIGRATE_DATABASE_URL is not set; DDL must not run on the application credential")
	}

	return c.MigrateDatabaseURL, nil
}

// MediaBaseURL is the image base URL the server publishes, checked where a
// mistake would otherwise surface as blank tiles on every tablet.
//
// Outside local development it must be https: the till refuses plain http for
// anything but loopback, and would fall back to icons without a word. Locally,
// an unset value points at this process, which serves /media itself.
func (c Config) MediaBaseURL() (string, error) {
	base := strings.TrimSpace(c.MediaPublicBaseURL)

	if base == "" {
		if c.Environment != "local" {
			return "", fmt.Errorf("MEDIA_PUBLIC_BASE_URL is not set; tills need an absolute https URL to fetch product images")
		}
		host := c.HTTPAddr
		if strings.HasPrefix(host, ":") {
			host = "localhost" + host
		}
		return "http://" + host + "/media", nil
	}

	if c.Environment != "local" && !strings.HasPrefix(base, "https://") {
		return "", fmt.Errorf("MEDIA_PUBLIC_BASE_URL must be https outside local development, got %q", base)
	}

	return base, nil
}
