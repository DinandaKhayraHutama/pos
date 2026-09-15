package devices

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"time"
)

const (
	// I, O, 0 and 1 are absent: the code is read aloud across a counter, and
	// 12 characters of a 32-symbol alphabet still leaves 60 bits of entropy.
	codeAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	codeLength   = 12

	ActivationTTL = 10 * time.Minute
	TokenTTL      = 365 * 24 * time.Hour
)

// Fingerprint keys the stored form of an activation code. The plaintext is
// returned exactly once, by the issuing call, and never written to a row, a log
// or a notification — each of which parks a live credential somewhere durable.
func Fingerprint(code, appKey string) []byte {
	mac := hmac.New(sha256.New, []byte(appKey))
	mac.Write([]byte(code))
	return mac.Sum(nil)
}

func newCode() (string, error) {
	buf := make([]byte, codeLength)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}

	out := make([]byte, codeLength)
	for i, b := range buf {
		// len(codeAlphabet) is 32, which divides 256 exactly, so this modulo
		// introduces no bias. Changing the alphabet length breaks that.
		out[i] = codeAlphabet[int(b)%len(codeAlphabet)]
	}

	return string(out), nil
}

// newToken returns the bearer token and the only form of it the server keeps.
// 32 random bytes carry enough entropy that a hash is sufficient; bcrypt here
// would cost ~100ms on every authenticated request.
func newToken() (plain string, hash []byte, err error) {
	buf := make([]byte, 32)
	if _, err := rand.Read(buf); err != nil {
		return "", nil, err
	}

	plain = base64.RawURLEncoding.EncodeToString(buf)
	return plain, HashToken(plain), nil
}

func HashToken(plain string) []byte {
	sum := sha256.Sum256([]byte(plain))
	return sum[:]
}
