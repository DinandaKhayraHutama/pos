package catalogue

import (
	"bytes"
	"encoding/binary"
	"image"
	"image/draw"
	"image/jpeg"
	"image/png"
	"net/http"

	xdraw "golang.org/x/image/draw"
	_ "golang.org/x/image/webp" // registers the WebP decoder
)

const (
	// MaxImageBytes bounds an upload. A phone photo is a few megabytes.
	MaxImageBytes = 10 << 20
	// maxImagePixels bounds what is decoded. Decoding is where the memory
	// goes — a 50-megapixel JPEG is ~75 MB once decoded — so this is checked
	// from the header before a single pixel is read.
	maxImagePixels = 50_000_000
	maxImageSide   = 12_000
	// imageMaxEdge is the longest side a till receives. A product tile is a
	// few hundred pixels; a cheap tablet decoding a 4,000-pixel photo per tile
	// is a sell screen that stutters.
	imageMaxEdge = 1024
	jpegQuality  = 85
)

// processed is an image re-encoded for tills.
type processed struct {
	body []byte
	ext  string
}

// processImage turns an upload into what a till should receive, or says in
// words why it cannot.
//
// Every upload is decoded and re-encoded, never stored as sent. That is what
//   - strips EXIF, which on a phone photo includes where it was taken — often
//     the owner's kitchen or home;
//   - makes a file that is secretly something else (HTML, a script, a polyglot)
//     impossible to store, because only freshly encoded pixels are written;
//   - bounds what a tablet downloads and decodes.
//
// JPEG unless the image has transparency, which JPEG would silently turn black.
func processImage(data []byte) (processed, string) {
	switch {
	case len(data) == 0:
		return processed{}, "Pilih berkas gambar."
	case len(data) > MaxImageBytes:
		return processed{}, "Gambar maksimal 10 MB."
	}

	sniffed := http.DetectContentType(data)
	wantFormat := map[string]string{"image/jpeg": "jpeg", "image/png": "png", "image/webp": "webp"}[sniffed]
	if wantFormat == "" {
		return processed{}, "Format gambar harus JPG, PNG, atau WebP."
	}

	cfg, format, err := image.DecodeConfig(bytes.NewReader(data))
	if err != nil || format != wantFormat {
		return processed{}, "Berkas gambar rusak atau tidak didukung."
	}
	if cfg.Width < 1 || cfg.Height < 1 || cfg.Width > maxImageSide || cfg.Height > maxImageSide ||
		cfg.Width*cfg.Height > maxImagePixels {
		return processed{}, "Resolusi gambar terlalu besar (maksimal 50 megapiksel)."
	}

	src, _, err := image.Decode(bytes.NewReader(data))
	if err != nil {
		return processed{}, "Berkas gambar rusak atau tidak didukung."
	}

	orientation := 1
	if format == "jpeg" {
		orientation = jpegOrientation(data)
	}

	// Scaled before it is turned upright: the bound is the same on both axes,
	// so the order does not change the result, and rotating the small image
	// is far cheaper than rotating the original.
	out := orient(fit(src, imageMaxEdge), orientation)

	var buf bytes.Buffer
	if out.Opaque() {
		if err := jpeg.Encode(&buf, out, &jpeg.Options{Quality: jpegQuality}); err != nil {
			return processed{}, "Gambar tidak bisa diproses."
		}
		return processed{body: buf.Bytes(), ext: "jpg"}, ""
	}

	if err := png.Encode(&buf, out); err != nil {
		return processed{}, "Gambar tidak bisa diproses."
	}
	return processed{body: buf.Bytes(), ext: "png"}, ""
}

// fit scales src so its longest side is at most edge, never up. The result is
// always a fresh NRGBA, so nothing of the source's encoding survives.
func fit(src image.Image, edge int) *image.NRGBA {
	b := src.Bounds()
	w, h := b.Dx(), b.Dy()

	if w > edge || h > edge {
		if w >= h {
			h = max(1, h*edge/w)
			w = edge
		} else {
			w = max(1, w*edge/h)
			h = edge
		}
	}

	dst := image.NewNRGBA(image.Rect(0, 0, w, h))
	if w == b.Dx() && h == b.Dy() {
		draw.Draw(dst, dst.Bounds(), src, b.Min, draw.Src)
		return dst
	}

	xdraw.CatmullRom.Scale(dst, dst.Bounds(), src, b, draw.Src, nil)
	return dst
}

// orient turns a stored image upright according to its EXIF orientation.
//
// Phones store the sensor's pixels as they came off it and record how the
// phone was held in the orientation tag. Stripping metadata without applying
// that tag first would put every portrait photo on 15,000 tablets sideways.
//
// For each value, dst(x, y) reads from the source pixel the EXIF definition
// places there; see TestOrientationFollowsTheExifDefinition for the table.
func orient(src *image.NRGBA, orientation int) *image.NRGBA {
	if orientation < 2 || orientation > 8 {
		return src
	}

	w, h := src.Rect.Dx(), src.Rect.Dy()
	dw, dh := w, h
	if orientation >= 5 {
		dw, dh = h, w
	}

	dst := image.NewNRGBA(image.Rect(0, 0, dw, dh))
	for y := 0; y < dh; y++ {
		for x := 0; x < dw; x++ {
			var sx, sy int
			switch orientation {
			case 2:
				sx, sy = w-1-x, y
			case 3:
				sx, sy = w-1-x, h-1-y
			case 4:
				sx, sy = x, h-1-y
			case 5:
				sx, sy = y, x
			case 6:
				sx, sy = y, h-1-x
			case 7:
				sx, sy = w-1-y, h-1-x
			case 8:
				sx, sy = w-1-y, x
			}
			si := src.PixOffset(sx, sy)
			di := dst.PixOffset(x, y)
			copy(dst.Pix[di:di+4], src.Pix[si:si+4])
		}
	}

	return dst
}

// jpegOrientation reads the EXIF orientation tag (0x0112) from a JPEG's APP1
// segment. Anything unreadable is 1, "as stored" — a malformed tag must never
// fail an upload the image itself is fine for.
func jpegOrientation(data []byte) int {
	if len(data) < 4 || data[0] != 0xFF || data[1] != 0xD8 {
		return 1
	}

	for i := 2; i+4 <= len(data); {
		if data[i] != 0xFF {
			return 1
		}
		marker := data[i+1]
		// Start of scan: the metadata segments are all before it.
		if marker == 0xDA || marker == 0xD9 {
			return 1
		}
		length := int(binary.BigEndian.Uint16(data[i+2 : i+4]))
		if length < 2 || i+2+length > len(data) {
			return 1
		}

		segment := data[i+4 : i+2+length]
		if marker == 0xE1 && len(segment) >= 6 && string(segment[:6]) == "Exif\x00\x00" {
			return tiffOrientation(segment[6:])
		}

		i += 2 + length
	}

	return 1
}

func tiffOrientation(tiff []byte) int {
	if len(tiff) < 8 {
		return 1
	}

	var order binary.ByteOrder
	switch string(tiff[:2]) {
	case "II":
		order = binary.LittleEndian
	case "MM":
		order = binary.BigEndian
	default:
		return 1
	}
	if order.Uint16(tiff[2:4]) != 42 {
		return 1
	}

	ifd := int(order.Uint32(tiff[4:8]))
	if ifd < 8 || ifd+2 > len(tiff) {
		return 1
	}

	entries := int(order.Uint16(tiff[ifd : ifd+2]))
	for n := 0; n < entries; n++ {
		at := ifd + 2 + n*12
		if at+12 > len(tiff) {
			return 1
		}
		// Tag 0x0112, type SHORT (3): the value sits in the first two bytes of
		// the value field.
		if order.Uint16(tiff[at:at+2]) == 0x0112 && order.Uint16(tiff[at+2:at+4]) == 3 {
			if v := int(order.Uint16(tiff[at+8 : at+10])); v >= 1 && v <= 8 {
				return v
			}
			return 1
		}
	}

	return 1
}
