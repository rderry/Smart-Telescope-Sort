#!/usr/bin/env python3
"""Builds every Telescope Data Sort icon from AppIcon-artwork.jpg (needs Pillow and numpy; macOS for SF Pro and iconutil).

    python3 App/Icons/make-icons.py            Mac and Windows
    python3 App/Icons/make-icons.py --mac      App/Icons/*.icns, AppIcon-source.png, Assets.xcassets/AppIcon.appiconset
    python3 App/Icons/make-icons.py --windows  Windows .ico and MSIX visual assets

The tile is seated on Apple's 1024 grid (824-px rounded square) with an "OPEN SOURCE" banner in Weather Magic green.
Renditions under 128 px keep the green band but drop the text, which can't be read that small.
Windows unplated icons (.ico, Square44x44) are cropped so the tile fills ~88% of the frame; plated tiles keep the Mac framing.
"""
import shutil
import struct
import subprocess
import sys
import tempfile
from io import BytesIO
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ICONS = Path(__file__).resolve().parent
ROOT = ICONS.parent.parent
ARTWORK = ICONS / "AppIcon-artwork.jpg"
FONT = "/System/Library/Fonts/SFNS.ttf"

TILE, CANVAS, INSET, RADIUS, SS = 824, 1024, 100, 185, 4
WEATHER_MAGIC_GREEN = (77, 158, 61)  # WeatherDesktopTheme.greenDigits, Color(red: 0.30, green: 0.62, blue: 0.24)
WINDOWS_PLATE = (0x0A, 0x1A, 0x4A)  # AppxManifest BackgroundColor
WINDOWS_CROP = (44, 44, 980, 980)
TEXT_MIN_PX = 128


def font(size, weight="Black"):
    f = ImageFont.truetype(FONT, size)
    f.set_variation_by_name(weight)
    return f


def clean_tile():
    src = Image.open(ARTWORK).convert("RGB")
    a = np.asarray(src).astype(int)
    ys, xs = np.where(a.sum(axis=2) < 450)
    tile = src.crop((xs.min(), ys.min(), xs.max() + 1, ys.max() + 1))
    inset = int(min(tile.size) * 0.03)
    tile = tile.crop((inset, inset, tile.size[0] - inset, tile.size[1] - inset)).resize((TILE, TILE), Image.LANCZOS)
    t = np.asarray(tile).astype(float)
    sky = np.concatenate([t[:, 40:200, :], t[:, 690:790, :]], axis=1)
    rows = np.median(sky, axis=1)
    rows = np.array([np.convolve(np.pad(rows[:, c], 40, mode="edge"), np.ones(81) / 81, mode="valid") for c in range(3)]).T
    canvas = Image.fromarray(np.repeat(rows[:, None, :], TILE, axis=1).astype(np.uint8))
    art_size = int(TILE * 0.84)
    art = tile.resize((art_size, art_size), Image.LANCZOS)
    feather = Image.new("L", (art_size, art_size), 0)
    ImageDraw.Draw(feather).rounded_rectangle((36, 36, art_size - 36, art_size - 36), radius=120, fill=255)
    feather = feather.filter(ImageFilter.GaussianBlur(26))
    canvas.paste(art, ((TILE - art_size) // 2, 8), feather)
    return canvas.convert("RGBA")


def draw_banner(tile, with_text):
    top = 692 if with_text else 668
    layer = Image.new("RGBA", (TILE * SS, TILE * SS), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    d.rectangle((0, top * SS, TILE * SS, TILE * SS), fill=WEATHER_MAGIC_GREEN + (255,))
    d.line((0, top * SS, TILE * SS, top * SS), fill=(255, 255, 255, 120), width=4 * SS)
    if with_text:
        text = "OPEN SOURCE"
        size = 10
        while True:
            f = font((size + 1) * SS)
            tracking = 0.06 * (size + 1) * SS
            width = sum(d.textlength(c, font=f) for c in text) + tracking * (len(text) - 1)
            ink = f.getbbox("OPENSURC", anchor="ls")
            if width > 600 * SS or ink[3] - ink[1] > 66 * SS:
                break
            size += 1
        f, tracking = font(size * SS), 0.06 * size * SS
        widths = [d.textlength(c, font=f) for c in text]
        ink = f.getbbox("OPENSURC", anchor="ls")
        x = (TILE * SS - sum(widths) - tracking * (len(text) - 1)) / 2
        y = ((top + 2) + (TILE - 8)) * SS / 2 - (ink[1] + ink[3]) / 2
        for ch, w in zip(text, widths):
            d.text((x, y), ch, font=f, fill=(255, 255, 255, 255), anchor="ls")
            x += w + tracking
    tile.alpha_composite(layer.resize((TILE, TILE), Image.LANCZOS))


_MASTERS = {}


def master(with_text):
    """1024-px icon with transparent margins on Apple's grid."""
    if with_text not in _MASTERS:
        tile = clean_tile()
        draw_banner(tile, with_text)
        mask = Image.new("L", (TILE * SS, TILE * SS), 0)
        ImageDraw.Draw(mask).rounded_rectangle((0, 0, TILE * SS - 1, TILE * SS - 1), radius=RADIUS * SS, fill=255)
        icon = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
        icon.paste(tile, (INSET, INSET), mask.resize((TILE, TILE), Image.LANCZOS))
        _MASTERS[with_text] = icon
    return _MASTERS[with_text]


def icon(px, windows_framing=False):
    im = master(px >= TEXT_MIN_PX)
    if windows_framing:
        im = im.crop(WINDOWS_CROP)
    return im if im.size == (px, px) else im.resize((px, px), Image.LANCZOS)


def on_plate(width, height, icon_px):
    plate = Image.new("RGBA", (width, height), WINDOWS_PLATE + (255,))
    plate.alpha_composite(icon(icon_px), ((width - icon_px) // 2, (height - icon_px) // 2))
    return plate


def build_mac():
    appiconset = ROOT / "App/Assets.xcassets/AppIcon.appiconset"
    icon(CANVAS).save(ICONS / "AppIcon-source.png")
    with tempfile.TemporaryDirectory() as tmp:
        iconset = Path(tmp) / "AppIcon.iconset"
        iconset.mkdir()
        for s in (16, 32, 128, 256, 512):
            for name, px in ((f"icon_{s}x{s}.png", s), (f"icon_{s}x{s}@2x.png", s * 2)):
                icon(px).save(iconset / name)
                shutil.copyfile(iconset / name, appiconset / name)
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(ICONS / "AppIcon.icns")], check=True)
    for variant in ("OS27", "OS15"):
        shutil.copyfile(ICONS / "AppIcon.icns", ICONS / f"AppIcon-{variant}.icns")


def build_windows():
    win = ROOT / "Windows"
    store = win / "installer/Store/Assets"
    sizes = [16, 20, 24, 32, 40, 48, 64, 256]
    frames = []
    for px in sizes:
        buf = BytesIO()
        icon(px, windows_framing=True).save(buf, format="PNG")
        frames.append(buf.getvalue())
    offset = 6 + 16 * len(frames)
    entries = b""
    for px, data in zip(sizes, frames):
        dim = 0 if px >= 256 else px
        entries += struct.pack("<BBBBHHII", dim, dim, 0, 0, 1, 32, len(data), offset)
        offset += len(data)
    (win / "src/SmartTelescopeSort.App/Assets/AppIcon.ico").write_bytes(struct.pack("<HHH", 0, 1, len(frames)) + entries + b"".join(frames))

    icon(44, windows_framing=True).save(store / "Square44x44Logo.png")
    icon(44, windows_framing=True).save(store / "Square44x44Logo.targetsize-44_altform-unplated.png")
    icon(71).save(store / "Square71x71Logo.png")
    icon(150).save(store / "Square150x150Logo.png")
    icon(50).save(store / "StoreLogo.png")
    icon(300).save(store / "StoreListingIcon-300.png")
    on_plate(310, 150, 150).save(store / "Wide310x150Logo.png")
    on_plate(620, 300, 300).save(store / "SplashScreen.png")


if __name__ == "__main__":
    args = set(sys.argv[1:]) or {"--mac", "--windows"}
    if "--mac" in args:
        build_mac()
    if "--windows" in args:
        build_windows()
    print("Icons built:", ", ".join(sorted(a.lstrip("-") for a in args)))
