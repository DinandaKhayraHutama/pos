package mailer_test

import (
	"bufio"
	"context"
	"net"
	"strconv"
	"strings"
	"sync"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/mailer"
)

// fakeSMTP speaks just enough SMTP to accept one message and remember it.
type fakeSMTP struct {
	addr string

	mu   sync.Mutex
	from string
	rcpt []string
	data string
}

func startFake(t *testing.T) *fakeSMTP {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	require.NoError(t, err)
	t.Cleanup(func() { _ = ln.Close() })

	f := &fakeSMTP{addr: ln.Addr().String()}
	go func() {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		r, w := bufio.NewReader(conn), bufio.NewWriter(conn)
		reply := func(s string) { _, _ = w.WriteString(s + "\r\n"); _ = w.Flush() }
		reply("220 fake")
		for {
			line, err := r.ReadString('\n')
			if err != nil {
				return
			}
			cmd := strings.TrimRight(line, "\r\n")
			upper := strings.ToUpper(cmd)
			switch {
			case strings.HasPrefix(upper, "EHLO"), strings.HasPrefix(upper, "HELO"):
				reply("250 fake")
			case strings.HasPrefix(upper, "MAIL FROM:"):
				f.mu.Lock()
				f.from = cmd[len("MAIL FROM:"):]
				f.mu.Unlock()
				reply("250 ok")
			case strings.HasPrefix(upper, "RCPT TO:"):
				f.mu.Lock()
				f.rcpt = append(f.rcpt, cmd[len("RCPT TO:"):])
				f.mu.Unlock()
				reply("250 ok")
			case upper == "DATA":
				reply("354 go ahead")
				var body strings.Builder
				for {
					l, err := r.ReadString('\n')
					if err != nil {
						return
					}
					if l == ".\r\n" {
						break
					}
					body.WriteString(l)
				}
				f.mu.Lock()
				f.data = body.String()
				f.mu.Unlock()
				reply("250 queued")
			case upper == "QUIT":
				reply("221 bye")
				return
			default:
				reply("502 unsupported")
			}
		}
	}()
	return f
}

func TestAMessageIsDeliveredWithHeadersThatCannotBeInjected(t *testing.T) {
	f := startFake(t)
	host, port, err := net.SplitHostPort(f.addr)
	require.NoError(t, err)
	p, err := strconv.Atoi(port)
	require.NoError(t, err)

	m, err := mailer.New(mailer.Config{Host: host, Port: p, From: "JustClick <laporan@justclick.test>"})
	require.NoError(t, err)
	require.True(t, m.Configured())

	err = m.Send(context.Background(), mailer.Message{
		To:      []string{"owner@warung.test", "Manajer <manajer@warung.test>"},
		Subject: "Laporan harian\r\nBcc: spy@evil.test",
		Text:    "Unduh laporan:\nhttps://pos.test/backoffice/reports/download/abc",
	})
	require.NoError(t, err)

	f.mu.Lock()
	defer f.mu.Unlock()
	require.Equal(t, "<laporan@justclick.test>", f.from)
	require.Equal(t, []string{"<owner@warung.test>", "<manajer@warung.test>"}, f.rcpt)
	require.Contains(t, f.data, "Subject: Laporan harian  Bcc: spy@evil.test\r\n")
	require.NotContains(t, f.data, "\r\nBcc:")
	require.Contains(t, f.data, "https://pos.test/backoffice/reports/download/abc\r\n")
}

func TestAnUnconfiguredMailerSaysSo(t *testing.T) {
	m, err := mailer.New(mailer.Config{})
	require.NoError(t, err)
	require.False(t, m.Configured())
	require.ErrorIs(t, m.Send(context.Background(), mailer.Message{To: []string{"a@b.test"}}), mailer.ErrNotConfigured)
}

func TestABadRecipientIsRefusedBeforeConnecting(t *testing.T) {
	m, err := mailer.New(mailer.Config{Host: "127.0.0.1", Port: 1, From: "a@b.test"})
	require.NoError(t, err)
	require.Error(t, m.Send(context.Background(), mailer.Message{To: []string{"not an address"}}))
}
