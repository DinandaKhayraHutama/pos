package platform

import (
	"encoding/base32"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

// RFC 6238 Appendix B, SHA-1 rows. The reference implementation prints eight
// digits; the algorithm is the same for six, which keeps the low six of these.
func TestTOTPMatchesTheRFC6238Vectors(t *testing.T) {
	key := []byte("12345678901234567890")

	for _, v := range []struct {
		unix int64
		code string
	}{
		{59, "94287082"},
		{1111111109, "07081804"},
		{1111111111, "14050471"},
		{1234567890, "89005924"},
		{2000000000, "69279037"},
		{20000000000, "65353130"},
	} {
		step := TOTPStep(time.Unix(v.unix, 0))
		require.Equal(t, v.code, hotp(key, uint64(step), 8), "T=%d", v.unix)
		require.Equal(t, v.code[2:], hotp(key, uint64(step), 6), "T=%d six digits", v.unix)
	}
}

func TestACodeIsAcceptedOneStepEitherSideAndNoFurther(t *testing.T) {
	secret := strings.TrimRight(base32.StdEncoding.EncodeToString([]byte("12345678901234567890")), "=")
	at := time.Unix(1234567890, 0)

	code, err := TOTPCode(secret, at)
	require.NoError(t, err)

	for _, offset := range []time.Duration{-totpStep, 0, totpStep} {
		step, ok := VerifyTOTP(secret, code, at.Add(offset))
		require.True(t, ok, "offset %s", offset)
		require.Equal(t, TOTPStep(at), step, "the step returned is the code's own, not the clock's")
	}

	for _, offset := range []time.Duration{-2 * totpStep, 2 * totpStep} {
		_, ok := VerifyTOTP(secret, code, at.Add(offset))
		require.False(t, ok, "offset %s is outside the skew", offset)
	}
}

func TestMalformedCodesAndSecretsAreRefused(t *testing.T) {
	secret, err := NewTOTPSecret()
	require.NoError(t, err)
	require.Len(t, secret, 32, "160 bits in unpadded base32")

	now := time.Now()
	good, err := TOTPCode(secret, now)
	require.NoError(t, err)

	for _, code := range []string{"", "12345", "1234567", "12a456", " "} {
		_, ok := VerifyTOTP(secret, code, now)
		require.False(t, ok, "%q", code)
	}

	_, ok := VerifyTOTP(secret, " "+good+" ", now)
	require.True(t, ok, "surrounding spaces from a paste are forgiven")

	_, ok = VerifyTOTP("not base32 !!", good, now)
	require.False(t, ok)

	_, ok = VerifyTOTP(GroupSecret(strings.ToLower(secret)), good, now)
	require.True(t, ok, "a secret typed in lower case with spaces is the same secret")
}

func TestTheURICarriesWhatAnAppNeeds(t *testing.T) {
	uri := TOTPURI("JustClick", "ops@justclick.id", "JBSWY3DPEHPK3PXP")
	require.True(t, strings.HasPrefix(uri, "otpauth://totp/JustClick:ops@justclick.id?"), uri)
	for _, part := range []string{"secret=JBSWY3DPEHPK3PXP", "issuer=JustClick", "digits=6", "period=30", "algorithm=SHA1"} {
		require.Contains(t, uri, part)
	}
}
