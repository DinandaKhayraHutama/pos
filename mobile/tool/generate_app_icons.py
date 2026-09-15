#!/usr/bin/env python3
"""Regenerate every launcher icon from the JustClick brand mark.

    python3 tool/generate_app_icons.py

Writes the iOS AppIcon set, the Android mipmaps, the macOS AppIcon set, and the
web icons + favicon. Run it from `mobile/`, the Flutter project root.

SOURCE is a 1024px render of `justclick_mark.svg`, which is the mark lifted out
of the brand's own `justclick-bnw.svg` wordmark (the four paths before the
lettering) and recoloured with the tones sampled from the 152px PNG the apps
pass around: #007AFF, #21B1FF and #DCE1E2. Every JustClick raster in the
monorepo is a small upscale — even the 1024px icon in `justclick_hcms` measures
blurrier than resampling the 152px file — so going back to the vector is the
only way these come out crisp.

To re-render the master after editing the SVG (no rsvg/ImageMagick here, but
headless Chrome renders SVG exactly): open the SVG at width=height=1024 in a
page and screenshot the element with a transparent background.

Design decisions, so a re-run does not quietly change the look:

* The plate is near-white with a faint tint towards the brand gradient's own
  start colour. The mark is blue-and-light-grey on transparency, so it needs a
  light ground; a flat white plate went dead against a light home screen.
* Every target is resampled from ONE 1024px master rather than from the 152px
  source, so the small sizes are downscales (crisp) instead of upscales.
* iOS icons are flattened to RGB. An alpha channel there is an App Store
  validation failure, not a cosmetic issue.
* macOS follows Apple's icon grid: the plate covers 824/1024 of the canvas with
  a 185/1024 corner radius, leaving the transparent margin the platform expects.
* The maskable web icons hold the mark inside the centre 80% safe zone, because
  Android crops them to a circle.
"""

from __future__ import annotations

import pathlib

from PIL import Image, ImageDraw

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "assets/images/justclick_logo.png"

MASTER = 1024
PLATE_TOP = (255, 255, 255)
PLATE_BOTTOM = (238, 243, 251)  # a step towards accent.gradient[0] (#F1F5FB)


def _plate(size: int) -> Image.Image:
    """A square plate with a faint vertical tint."""
    plate = Image.new("RGB", (size, size), PLATE_TOP)
    draw = ImageDraw.Draw(plate)
    for y in range(size):
        t = y / max(size - 1, 1)
        draw.line(
            [(0, y), (size, y)],
            fill=tuple(
                round(a + (b - a) * t) for a, b in zip(PLATE_TOP, PLATE_BOTTOM)
            ),
        )
    return plate


def _master(mark_ratio: float) -> Image.Image:
    """A 1024px square icon: plate + mark, no rounding, no alpha."""
    logo = Image.open(SOURCE).convert("RGBA")
    edge = round(MASTER * mark_ratio)
    logo = logo.resize((edge, edge), Image.LANCZOS)
    canvas = _plate(MASTER).convert("RGBA")
    canvas.alpha_composite(logo, ((MASTER - edge) // 2, (MASTER - edge) // 2))
    return canvas


def _write(master: Image.Image, path: pathlib.Path, size: int, *, alpha: bool) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    out = master.resize((size, size), Image.LANCZOS)
    out.convert("RGBA" if alpha else "RGB").save(path, "PNG")
    print(f"  {path.relative_to(ROOT)}  {size}x{size}")


def _rounded_master(master: Image.Image) -> Image.Image:
    """Apple's macOS grid: an 824/1024 plate, radius 185, transparent margin."""
    inset, radius = 100, 185
    mask = Image.new("L", (MASTER, MASTER), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [inset, inset, MASTER - inset, MASTER - inset], radius=radius, fill=255
    )
    out = Image.new("RGBA", (MASTER, MASTER), (0, 0, 0, 0))
    out.paste(master.convert("RGBA"), (0, 0), mask)
    return out


def main() -> None:
    if not SOURCE.exists():
        raise SystemExit(f"missing brand mark: {SOURCE}")

    full = _master(0.62)  # full-bleed platforms
    maskable = _master(0.46)  # cropped to a circle by the launcher
    mac = _rounded_master(_master(0.50))  # the mark sits inside the 824 plate

    print("iOS")
    ios = ROOT / "ios/Runner/Assets.xcassets/AppIcon.appiconset"
    for name, size in {
        "Icon-App-20x20@1x.png": 20,
        "Icon-App-20x20@2x.png": 40,
        "Icon-App-20x20@3x.png": 60,
        "Icon-App-29x29@1x.png": 29,
        "Icon-App-29x29@2x.png": 58,
        "Icon-App-29x29@3x.png": 87,
        "Icon-App-40x40@1x.png": 40,
        "Icon-App-40x40@2x.png": 80,
        "Icon-App-40x40@3x.png": 120,
        "Icon-App-60x60@2x.png": 120,
        "Icon-App-60x60@3x.png": 180,
        "Icon-App-76x76@1x.png": 76,
        "Icon-App-76x76@2x.png": 152,
        "Icon-App-83.5x83.5@2x.png": 167,
        "Icon-App-1024x1024@1x.png": 1024,
    }.items():
        _write(full, ios / name, size, alpha=False)

    print("Android")
    android = ROOT / "android/app/src/main/res"
    for density, size in {
        "mdpi": 48,
        "hdpi": 72,
        "xhdpi": 96,
        "xxhdpi": 144,
        "xxxhdpi": 192,
    }.items():
        _write(full, android / f"mipmap-{density}/ic_launcher.png", size, alpha=False)

    print("macOS")
    macos = ROOT / "macos/Runner/Assets.xcassets/AppIcon.appiconset"
    for size in (16, 32, 64, 128, 256, 512, 1024):
        _write(mac, macos / f"app_icon_{size}.png", size, alpha=True)

    print("Web")
    web = ROOT / "web"
    _write(full, web / "icons/Icon-192.png", 192, alpha=False)
    _write(full, web / "icons/Icon-512.png", 512, alpha=False)
    _write(maskable, web / "icons/Icon-maskable-192.png", 192, alpha=False)
    _write(maskable, web / "icons/Icon-maskable-512.png", 512, alpha=False)
    _write(_master(0.78), web / "favicon.png", 32, alpha=False)


if __name__ == "__main__":
    main()
