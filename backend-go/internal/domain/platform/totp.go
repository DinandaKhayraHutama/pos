package platform

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha1" //nolint:gosec // RFC 6238 TOTP is defined over HMAC-SHA1, and every authenticator app speaks it.
	"crypto/subtle"
	"encoding/base32"
	"encoding/binary"
	"errors"
	"fmt"
	"net/url"
	"strings"
	"time"
)

// TOTP, written against RFC 6238 with the standard library rather than a
// dependency: the algorithm is thirty lines, and a module proxy that could not
// be reached during Fase 7 is not something a sign-in path should wait on.
//
// The parameters are the ones every authenticator app assumes when it is given
// only a secret: HMAC-SHA1, six digits, thirty-second steps. Changing any of
// them silently breaks enrolment for anyone who typed the secret by hand.
const (
	totpStep   = 30 * time.Second
	totpDigits = 6
	// One step either side absorbs a phone clock that is a little off and a
	// code typed just as it rolled over. Wider would widen the replay window.
	totpSkew = 1
)

var secretEncoding = base32.StdEncoding.WithPadding(base32.NoPadding)

// ErrInvalidSecret is a stored secret that does not decode — a hand-edited row.
var ErrInvalidSecret = errors.New("platform: TOTP secret is not valid base32")

// NewTOTPSecret returns 160 random bits, the length RFC 4226 recommends for
// HMAC-SHA1, in the unpadded base32 authenticator apps accept.
func NewTOTPSecret() (string, error) {
	raw := make([]byte, 20)
	if _, err := rand.Read(raw); err != nil {
		return "", err
	}
	return secretEncoding.EncodeToString(raw), nil
}

// TOTPStep is the thirty-second step a moment falls in.
func TOTPStep(at time.Time) int64 { return at.Unix() / int64(totpStep/time.Second) }

// TOTPCode is the code an authenticator app shows at a moment. The server only
// ever needs VerifyTOTP; this exists for the verification script, which has to
// play the part of the phone.
func TOTPCode(secret string, at time.Time) (string, error) {
	key, err := decodeSecret(secret)
	if err != nil {
		return "", err
	}
	return hotp(key, uint64(TOTPStep(at)), totpDigits), nil
}

// VerifyTOTP reports the step a code belongs to, if it belongs to one within
// the skew. The step is what the caller records to refuse a replay: a code is
// accepted only for a step later than the last one accepted.
//
// Every candidate is compared, in constant time, so how long this takes says
// nothing about how close a guess was.
func VerifyTOTP(secret, code string, at time.Time) (int64, bool) {
	code = strings.TrimSpace(code)
	if len(code) != totpDigits || strings.Trim(code, "0123456789") != "" {
		return 0, false
	}
	key, err := decodeSecret(secret)
	if err != nil {
		return 0, false
	}

	now := TOTPStep(at)
	var (
		matched int64
		found   bool
	)
	for step := now - totpSkew; step <= now+totpSkew; step++ {
		if step < 0 {
			continue
		}
		if subtle.ConstantTimeCompare([]byte(hotp(key, uint64(step), totpDigits)), []byte(code)) == 1 && !found {
			matched, found = step, true
		}
	}
	return matched, found
}

// TOTPURI is the otpauth:// URI an authenticator app imports. There is no QR
// code: rendering one would take a dependency, and the secret beside it can be
// typed by hand.
func TOTPURI(issuer, account, secret string) string {
	label := url.PathEscape(issuer + ":" + account)
	q := url.Values{}
	q.Set("secret", secret)
	q.Set("issuer", issuer)
	q.Set("algorithm", "SHA1")
	q.Set("digits", fmt.Sprint(totpDigits))
	q.Set("period", fmt.Sprint(int(totpStep/time.Second)))
	return "otpauth://totp/" + label + "?" + q.Encode()
}

// GroupSecret spaces a secret in fours, which is how a person types it
// correctly into a phone.
func GroupSecret(secret string) string {
	var b strings.Builder
	for i, r := range secret {
		if i > 0 && i%4 == 0 {
			b.WriteByte(' ')
		}
		b.WriteRune(r)
	}
	return b.String()
}

func decodeSecret(secret string) ([]byte, error) {
	cleaned := strings.ToUpper(strings.NewReplacer(" ", "", "-", "").Replace(secret))
	key, err := secretEncoding.DecodeString(strings.TrimRight(cleaned, "="))
	if err != nil || len(key) == 0 {
		return nil, ErrInvalidSecret
	}
	return key, nil
}

// hotp is RFC 4226: HMAC the big-endian counter, take four bytes at the offset
// the last nibble names, drop the sign bit, keep the low digits.
func hotp(key []byte, counter uint64, digits int) string {
	var msg [8]byte
	binary.BigEndian.PutUint64(msg[:], counter)

	mac := hmac.New(sha1.New, key)
	mac.Write(msg[:])
	sum := mac.Sum(nil)

	offset := sum[len(sum)-1] & 0x0f
	value := binary.BigEndian.Uint32(sum[offset:offset+4]) & 0x7fffffff

	mod := uint32(1)
	for range digits {
		mod *= 10
	}
	return fmt.Sprintf("%0*d", digits, value%mod)
}
