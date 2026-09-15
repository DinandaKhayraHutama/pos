// Package mailer sends plain-text mail over SMTP.
//
// Only one thing is mailed today — a scheduled report's download link — and it
// is mailed as a link, never as an attachment: a link expires, a forwarded
// attachment does not.
package mailer

import (
	"context"
	"crypto/rand"
	"crypto/tls"
	"encoding/hex"
	"errors"
	"fmt"
	"mime"
	"net"
	"net/mail"
	"net/smtp"
	"strconv"
	"strings"
	"time"
)

// ErrNotConfigured is returned by Send when no SMTP host is set. A scheduled
// export still completes; its delivery records this.
var ErrNotConfigured = errors.New("mailer: SMTP_HOST is not configured")

type Config struct {
	Host     string
	Port     int
	Username string
	Password string
	From     string
}

type Message struct {
	To      []string
	Subject string
	Text    string
}

type SMTP struct {
	cfg  Config
	from *mail.Address
}

// New validates the sender. An empty host is allowed: the process starts, and
// every Send reports ErrNotConfigured.
func New(cfg Config) (*SMTP, error) {
	m := &SMTP{cfg: cfg}
	if strings.TrimSpace(cfg.Host) == "" {
		return m, nil
	}
	if cfg.Port <= 0 || cfg.Port > 65535 {
		return nil, fmt.Errorf("mailer: SMTP_PORT %d is out of range", cfg.Port)
	}
	from, err := mail.ParseAddress(cfg.From)
	if err != nil {
		return nil, fmt.Errorf("mailer: MAIL_FROM is not an address: %w", err)
	}
	m.from = from
	return m, nil
}

func (m *SMTP) Configured() bool { return m != nil && m.from != nil }

// Send delivers one message. STARTTLS is used whenever the server offers it,
// and credentials are only ever sent over TLS or to a loopback server
// (net/smtp's PlainAuth refuses anything else).
func (m *SMTP) Send(ctx context.Context, msg Message) error {
	if !m.Configured() {
		return ErrNotConfigured
	}
	recipients := make([]string, 0, len(msg.To))
	for _, to := range msg.To {
		addr, err := mail.ParseAddress(to)
		if err != nil {
			return fmt.Errorf("mailer: recipient %q is not an address", to)
		}
		recipients = append(recipients, addr.Address)
	}
	if len(recipients) == 0 {
		return errors.New("mailer: no recipients")
	}

	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	addr := net.JoinHostPort(m.cfg.Host, strconv.Itoa(m.cfg.Port))
	conn, err := (&net.Dialer{}).DialContext(ctx, "tcp", addr)
	if err != nil {
		return fmt.Errorf("mailer: dial %s: %w", addr, err)
	}
	if deadline, ok := ctx.Deadline(); ok {
		_ = conn.SetDeadline(deadline)
	}

	c, err := smtp.NewClient(conn, m.cfg.Host)
	if err != nil {
		_ = conn.Close()
		return fmt.Errorf("mailer: greeting: %w", err)
	}
	defer c.Close()

	if err := c.Hello("justclick"); err != nil {
		return fmt.Errorf("mailer: hello: %w", err)
	}
	if ok, _ := c.Extension("STARTTLS"); ok {
		if err := c.StartTLS(&tls.Config{ServerName: m.cfg.Host, MinVersion: tls.VersionTLS12}); err != nil {
			return fmt.Errorf("mailer: starttls: %w", err)
		}
	}
	if m.cfg.Username != "" {
		if err := c.Auth(smtp.PlainAuth("", m.cfg.Username, m.cfg.Password, m.cfg.Host)); err != nil {
			return fmt.Errorf("mailer: auth: %w", err)
		}
	}
	if err := c.Mail(m.from.Address); err != nil {
		return fmt.Errorf("mailer: mail from: %w", err)
	}
	for _, to := range recipients {
		if err := c.Rcpt(to); err != nil {
			return fmt.Errorf("mailer: rcpt: %w", err)
		}
	}
	w, err := c.Data()
	if err != nil {
		return fmt.Errorf("mailer: data: %w", err)
	}
	if _, err := w.Write(m.compose(recipients, msg)); err != nil {
		return fmt.Errorf("mailer: write: %w", err)
	}
	if err := w.Close(); err != nil {
		return fmt.Errorf("mailer: end data: %w", err)
	}
	return c.Quit()
}

func (m *SMTP) compose(to []string, msg Message) []byte {
	// Header values never carry a line break: a subject built from data must not
	// be able to add a header of its own.
	subject := strings.NewReplacer("\r", " ", "\n", " ").Replace(msg.Subject)
	id := make([]byte, 12)
	_, _ = rand.Read(id)

	var b strings.Builder
	header := func(k, v string) { b.WriteString(k + ": " + v + "\r\n") }
	header("From", m.from.String())
	header("To", strings.Join(to, ", "))
	header("Subject", mime.QEncoding.Encode("utf-8", subject))
	header("Date", time.Now().Format(time.RFC1123Z))
	header("Message-ID", "<"+hex.EncodeToString(id)+"@justclick>")
	header("MIME-Version", "1.0")
	header("Content-Type", "text/plain; charset=utf-8")
	header("Content-Transfer-Encoding", "8bit")
	b.WriteString("\r\n")

	body := strings.ReplaceAll(strings.ReplaceAll(msg.Text, "\r\n", "\n"), "\n", "\r\n")
	b.WriteString(body)
	if !strings.HasSuffix(body, "\r\n") {
		b.WriteString("\r\n")
	}
	return []byte(b.String())
}
