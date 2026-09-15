package catalogue

import (
	"bytes"
	"encoding/binary"
	"hash/crc32"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"testing"

	"github.com/stretchr/testify/require"
)

// photo is a solid image with a marker pixel block in its stored top-left
// corner, so where that corner ends up says which way the image was turned.
func photo(w, h int) *image.NRGBA {
	img := image.NewNRGBA(image.Rect(0, 0, w, h))
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			img.Set(x, y, color.NRGBA{R: 30, G: 120, B: 200, A: 255})
		}
	}
	for y := 0; y < h/8; y++ {
		for x := 0; x < w/8; x++ {
			img.Set(x, y, color.NRGBA{R: 255, A: 255})
		}
	}
	return img
}

func encodeJPEG(t *testing.T, img image.Image) []byte {
	t.Helper()
	var buf bytes.Buffer
	require.NoError(t, jpeg.Encode(&buf, img, &jpeg.Options{Quality: 95}))
	return buf.Bytes()
}

// withOrientation inserts an EXIF APP1 segment straight after the SOI marker,
// the way a phone camera writes one.
func withOrientation(jpegBytes []byte, orientation uint16, order binary.ByteOrder) []byte {
	tiff := make([]byte, 8+2+12+4)
	if order == binary.LittleEndian {
		copy(tiff, "II")
	} else {
		copy(tiff, "MM")
	}
	order.PutUint16(tiff[2:], 42)
	order.PutUint32(tiff[4:], 8)
	order.PutUint16(tiff[8:], 1)
	order.PutUint16(tiff[10:], 0x0112)
	order.PutUint16(tiff[12:], 3)
	order.PutUint32(tiff[14:], 1)
	order.PutUint16(tiff[18:], orientation)

	payload := append([]byte("Exif\x00\x00"), tiff...)
	segment := []byte{0xFF, 0xE1, 0, 0}
	binary.BigEndian.PutUint16(segment[2:], uint16(len(payload)+2))
	segment = append(segment, payload...)

	out := append([]byte{}, jpegBytes[:2]...)
	out = append(out, segment...)
	return append(out, jpegBytes[2:]...)
}

func isMarker(c color.Color) bool {
	r, g, b, _ := c.RGBA()
	return r > 0xB000 && g < 0x5000 && b < 0x5000
}

// The table is the EXIF definition itself — where the stored image's first row
// and first column belong when displayed — not a restatement of orient().
func TestOrientationFollowsTheExifDefinition(t *testing.T) {
	const w, h = 40, 24

	for orientation, want := range map[int]struct {
		corner string // where the stored top-left pixel is displayed
		swap   bool
	}{
		1: {"top-left", false},
		2: {"top-right", false},
		3: {"bottom-right", false},
		4: {"bottom-left", false},
		5: {"top-left", true},
		6: {"top-right", true},
		7: {"bottom-right", true},
		8: {"bottom-left", true},
	} {
		out := orient(photo(w, h), orientation)
		dw, dh := out.Rect.Dx(), out.Rect.Dy()

		if want.swap {
			require.Equal(t, [2]int{h, w}, [2]int{dw, dh}, "orientation %d swaps the axes", orientation)
		} else {
			require.Equal(t, [2]int{w, h}, [2]int{dw, dh}, "orientation %d keeps the axes", orientation)
		}

		corners := map[string]color.Color{
			"top-left":     out.At(0, 0),
			"top-right":    out.At(dw-1, 0),
			"bottom-left":  out.At(0, dh-1),
			"bottom-right": out.At(dw-1, dh-1),
		}
		for name, c := range corners {
			require.Equal(t, name == want.corner, isMarker(c),
				"orientation %d: marker should be at %s, checked %s", orientation, want.corner, name)
		}
	}
}

// A portrait phone photo is stored landscape with orientation 6. Without the
// tag applied, every such photo would appear on every till lying on its side.
func TestAPortraitPhonePhotoArrivesUprightAndScaled(t *testing.T) {
	for _, order := range []binary.ByteOrder{binary.BigEndian, binary.LittleEndian} {
		upload := withOrientation(encodeJPEG(t, photo(2000, 1500)), 6, order)
		require.Equal(t, 6, jpegOrientation(upload))

		out, problem := processImage(upload)
		require.Empty(t, problem)
		require.Equal(t, "jpg", out.ext)

		cfg, err := jpeg.DecodeConfig(bytes.NewReader(out.body))
		require.NoError(t, err)
		require.Equal(t, 768, cfg.Width, "turned upright: the long side is now vertical")
		require.Equal(t, 1024, cfg.Height, "and never longer than the edge a till receives")

		decoded, err := jpeg.Decode(bytes.NewReader(out.body))
		require.NoError(t, err)
		require.True(t, isMarker(decoded.At(cfg.Width-20, 20)), "the stored top-left is displayed top-right")
	}
}

// Stripping EXIF is a privacy property, not a size optimisation: a phone photo
// records where it was taken.
func TestTheStoredImageCarriesNoMetadata(t *testing.T) {
	upload := withOrientation(encodeJPEG(t, photo(300, 200)), 1, binary.BigEndian)
	require.True(t, bytes.Contains(upload, []byte("Exif")))

	out, problem := processImage(upload)
	require.Empty(t, problem)
	require.False(t, bytes.Contains(out.body, []byte("Exif")))
}

func TestASmallImageIsNeverScaledUp(t *testing.T) {
	out, problem := processImage(encodeJPEG(t, photo(320, 240)))
	require.Empty(t, problem)

	cfg, err := jpeg.DecodeConfig(bytes.NewReader(out.body))
	require.NoError(t, err)
	require.Equal(t, [2]int{320, 240}, [2]int{cfg.Width, cfg.Height})
}

// JPEG has no transparency; encoding a cut-out product shot as JPEG would put
// it on a black square.
func TestTransparencySurvives(t *testing.T) {
	img := photo(200, 200)
	img.Set(5, 5, color.NRGBA{A: 0})

	var buf bytes.Buffer
	require.NoError(t, png.Encode(&buf, img))

	out, problem := processImage(buf.Bytes())
	require.Empty(t, problem)
	require.Equal(t, "png", out.ext)

	decoded, err := png.Decode(bytes.NewReader(out.body))
	require.NoError(t, err)
	_, _, _, a := decoded.At(5, 5).RGBA()
	require.Zero(t, a)
}

func TestAnOpaquePNGIsStoredAsJPEG(t *testing.T) {
	var buf bytes.Buffer
	require.NoError(t, png.Encode(&buf, photo(200, 200)))

	out, problem := processImage(buf.Bytes())
	require.Empty(t, problem)
	require.Equal(t, "jpg", out.ext)
}

// Refused in words the owner can act on, never stored as sent.
func TestWhatIsNotAnImageIsRefused(t *testing.T) {
	jpegBytes := encodeJPEG(t, photo(64, 64))

	// A header that claims more pixels than the limit, checked before any
	// pixel is decoded: a tiny file can declare a huge image.
	bomb := image.NewNRGBA(image.Rect(0, 0, 1, 1))
	var bombBuf bytes.Buffer
	require.NoError(t, png.Encode(&bombBuf, bomb))
	huge := bombBuf.Bytes()
	binary.BigEndian.PutUint32(huge[16:], 11_000) // IHDR width
	binary.BigEndian.PutUint32(huge[20:], 11_000) // IHDR height
	// Re-sign the chunk, or the decoder refuses it as corrupt and this case
	// would pass without ever reaching the pixel limit.
	binary.BigEndian.PutUint32(huge[29:], crc32.ChecksumIEEE(huge[12:29]))
	_, problem := processImage(huge)
	require.Contains(t, problem, "megapiksel", "refused for its size, from the header alone")

	for name, upload := range map[string][]byte{
		"empty":           nil,
		"text":            []byte("hello, this is not a picture"),
		"svg":             []byte(`<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>`),
		"html":            []byte("<!doctype html><script>alert(1)</script>"),
		"gif":             []byte("GIF89a\x01\x00\x01\x00\x00\x00\x00;"),
		"truncated jpeg":  jpegBytes[:len(jpegBytes)/3],
		"too many pixels": huge,
		"too large":       append(append([]byte{}, jpegBytes...), make([]byte, MaxImageBytes)...),
	} {
		_, problem := processImage(upload)
		require.NotEmpty(t, problem, name)
	}
}

// A malformed tag must never fail an upload the picture itself is fine for.
func TestAMalformedOrientationTagIsIgnored(t *testing.T) {
	good := encodeJPEG(t, photo(64, 48))

	for name, upload := range map[string][]byte{
		"out of range": withOrientation(good, 42, binary.BigEndian),
		"cut short":    withOrientation(good, 6, binary.BigEndian)[:30],
		"no exif":      good,
	} {
		if name != "cut short" {
			_, problem := processImage(upload)
			require.Empty(t, problem, name)
		}
		require.Equal(t, 1, jpegOrientation(upload), name)
	}
}
