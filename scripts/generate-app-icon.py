#!/usr/bin/env python3
"""Generate the Markdown Notepad app icon from original geometric artwork.

The artwork is drawn from scratch with Pillow: a macOS-style squircle, a
blue notepad binding, a white page, and a geometric "M". No fonts, third-party
images, or trademarked assets are used, so the output is licence-safe and
reproducible.

Outputs (relative to the repository root):

    artwork/AppIcon-1024.png                 1024x1024 master
    artwork/AppIcon.iconset/                 macOS iconset (all required sizes)
    artwork/AppIcon.icns                     compiled icon for the app bundle
    app/MarkdownNotepad/Resources/AppIcon.icns
    app/MarkdownNotepad/Resources/Assets.xcassets/AppIcon.appiconset/

Usage:
    python3 scripts/generate-app-icon.py
    python3 scripts/generate-app-icon.py --check   # validate committed output

Requires Pillow (pip install pillow).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import struct
import sys
from pathlib import Path

try:
    from PIL import Image, ImageDraw, ImageFilter
except ImportError:  # pragma: no cover - friendly message for developers
    sys.exit("Pillow is required: python3 -m pip install pillow")

CANVAS = 1024
BODY = 824
BODY_ORIGIN = ((CANVAS - BODY) // 2, (CANVAS - BODY) // 2)
PAGE = (232, 162, 792, 862)
PAGE_RADIUS = 52
BINDING_WIDTH = 92

ICONSET_SIZES = {
    "icon_16x16.png": 16,
    "icon_16x16@2x.png": 32,
    "icon_32x32.png": 32,
    "icon_32x32@2x.png": 64,
    "icon_128x128.png": 128,
    "icon_128x128@2x.png": 256,
    "icon_256x256.png": 256,
    "icon_256x256@2x.png": 512,
    "icon_512x512.png": 512,
    "icon_512x512@2x.png": 1024,
}

# ICNS entry type -> pixel size. PNG payloads are supported by every macOS
# version this app targets (14+).
ICNS_TYPES = [
    ("icp4", 16),
    ("icp5", 32),
    ("icp6", 64),
    ("ic07", 128),
    ("ic08", 256),
    ("ic09", 512),
    ("ic10", 1024),
    ("ic11", 32),
    ("ic12", 64),
    ("ic13", 256),
    ("ic14", 512),
]


def _lerp(a: tuple[int, int, int], b: tuple[int, int, int], t: float) -> tuple[int, int, int]:
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))  # type: ignore[return-value]


def _vertical_gradient(size: int, top: tuple[int, int, int], bottom: tuple[int, int, int]) -> Image.Image:
    strip = Image.new("RGB", (1, size))
    for y in range(size):
        strip.putpixel((0, y), _lerp(top, bottom, y / (size - 1)))
    return strip.resize((size, size), Image.Resampling.BILINEAR)


def _squircle_mask(size: int, exponent: float = 5.0) -> Image.Image:
    """Continuous-curvature macOS-style rounded square, antialiased at 4x."""
    scale = 4
    big = size * scale
    points = []
    steps = 720
    for i in range(steps):
        t = 2 * math.pi * i / steps
        ct, st = math.cos(t), math.sin(t)
        x = math.copysign(abs(ct) ** (2 / exponent), ct)
        y = math.copysign(abs(st) ** (2 / exponent), st)
        points.append((big / 2 + x * big / 2, big / 2 + y * big / 2))
    mask = Image.new("L", (big, big), 0)
    ImageDraw.Draw(mask).polygon(points, fill=255)
    return mask.resize((size, size), Image.Resampling.LANCZOS)


def _letter_m_mask(width: int, height: int, stem: float = 0.26) -> Image.Image:
    """Build a bold geometric "M" by cutting two notches out of a rectangle.

    The top and bottom notches are open at the edges, leaving the four diagonal
    strokes and two vertical stems of an M. This keeps the silhouette crisp at
    16 px without depending on a system font.
    """
    mask = Image.new("L", (width, height), 255)
    draw = ImageDraw.Draw(mask)
    stroke = stem * width
    draw.polygon([(stroke, -2), (width / 2, 0.46 * height), (width - stroke, -2)], fill=0)
    draw.polygon([(stroke, height + 2), (width / 2, 0.66 * height), (width - stroke, height + 2)], fill=0)
    return mask


def draw_icon() -> Image.Image:
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    body_mask = _squircle_mask(BODY)

    # Soft drop shadow under the squircle.
    shadow = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    shadow.paste(Image.new("RGBA", (BODY, BODY), (0, 0, 0, 110)), (BODY_ORIGIN[0], BODY_ORIGIN[1] + 16), body_mask)
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(20)))

    # Blue body with a subtle top sheen.
    body = _vertical_gradient(BODY, (86, 148, 255), (29, 78, 216)).convert("RGBA")
    canvas.paste(body, BODY_ORIGIN, body_mask)
    sheen_alpha = Image.new("L", (BODY, BODY), 0)
    sheen_draw = ImageDraw.Draw(sheen_alpha)
    for y in range(BODY // 2):
        sheen_draw.line([(0, y), (BODY, y)], fill=int(46 * (1 - y / (BODY * 0.5))))
    sheen = Image.new("RGBA", (BODY, BODY), (255, 255, 255, 0))
    sheen.putalpha(sheen_alpha)
    canvas.paste(sheen, BODY_ORIGIN, body_mask)

    # White notepad page, inset into the squircle.
    page_width = PAGE[2] - PAGE[0]
    page_height = PAGE[3] - PAGE[1]
    page_mask = Image.new("L", (page_width, page_height), 0)
    ImageDraw.Draw(page_mask).rounded_rectangle(
        [0, 0, page_width - 1, page_height - 1], radius=PAGE_RADIUS, fill=255
    )

    page_shadow = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    page_shadow.paste(
        Image.new("RGBA", (page_width, page_height), (0, 0, 0, 55)),
        (PAGE[0], PAGE[1] + 10),
        page_mask,
    )
    canvas.alpha_composite(page_shadow.filter(ImageFilter.GaussianBlur(10)))

    page = Image.new("RGBA", (page_width, page_height), (252, 252, 250, 255))
    ImageDraw.Draw(page).rounded_rectangle(
        [1, 1, page_width - 2, page_height - 2],
        radius=PAGE_RADIUS - 1,
        outline=(198, 209, 227, 255),
        width=3,
    )
    canvas.paste(page, (PAGE[0], PAGE[1]), page_mask)

    # Blue binding strip with three punched holes.
    binding_mask = Image.new("L", (BINDING_WIDTH, page_height), 0)
    ImageDraw.Draw(binding_mask).rounded_rectangle(
        [0, 0, BINDING_WIDTH - 1, page_height - 1], radius=PAGE_RADIUS - 2, fill=255
    )
    binding = Image.new("RGBA", (BINDING_WIDTH, page_height), (30, 64, 175, 255))
    binding_draw = ImageDraw.Draw(binding)
    for centre in (page_height * 0.27, page_height * 0.5, page_height * 0.73):
        radius = 17
        binding_draw.ellipse(
            [BINDING_WIDTH / 2 - radius, centre - radius, BINDING_WIDTH / 2 + radius, centre + radius],
            fill=(232, 240, 255, 255),
        )
    canvas.paste(binding, (PAGE[0], PAGE[1]), binding_mask)

    # Geometric M, centred in the white writing area.
    m_width, m_height = 344, 296
    m_mask = _letter_m_mask(m_width * 4, m_height * 4).resize((m_width, m_height), Image.Resampling.LANCZOS)
    m_image = Image.new("RGBA", (m_width, m_height), (24, 36, 72, 255))
    m_x = PAGE[0] + BINDING_WIDTH + (page_width - BINDING_WIDTH - m_width) // 2
    content_height = m_height + 50 + 22
    m_y = PAGE[1] + (page_height - content_height) // 2
    canvas.paste(m_image, (m_x, m_y), m_mask)

    # Writing line under the M, doubling as a cursor accent.
    line_y = m_y + m_height + 50
    ImageDraw.Draw(canvas).rounded_rectangle(
        [m_x + 24, line_y, m_x + m_width - 24, line_y + 22],
        radius=11,
        fill=(59, 130, 246, 255),
    )

    return canvas


def _png_bytes(image: Image.Image) -> bytes:
    from io import BytesIO

    buffer = BytesIO()
    image.save(buffer, format="PNG", optimize=True)
    return buffer.getvalue()


def build_icns(master: Image.Image) -> bytes:
    entries = b""
    for kind, size in ICNS_TYPES:
        payload = _png_bytes(master.resize((size, size), Image.Resampling.LANCZOS))
        entries += kind.encode("ascii") + struct.pack(">I", len(payload) + 8) + payload
    return b"icns" + struct.pack(">I", len(entries) + 8) + entries


def asset_catalog_contents() -> dict:
    images = []
    for filename in ICONSET_SIZES:
        stem = filename.removeprefix("icon_").removesuffix(".png")
        if "@2x" in stem:
            size, scale = stem.removesuffix("@2x"), "2x"
        else:
            size, scale = stem, "1x"
        images.append({"filename": filename, "idiom": "mac", "scale": scale, "size": size})
    return {"images": images, "info": {"author": "xcode", "version": 1}}


def generate(root: Path) -> dict[Path, bytes]:
    master = draw_icon()
    outputs: dict[Path, bytes] = {}

    artwork = root / "artwork"
    iconset = artwork / "AppIcon.iconset"
    catalog = root / "app" / "MarkdownNotepad" / "Resources" / "Assets.xcassets" / "AppIcon.appiconset"
    resources = root / "app" / "MarkdownNotepad" / "Resources"

    outputs[artwork / "AppIcon-1024.png"] = _png_bytes(master)
    for filename, size in ICONSET_SIZES.items():
        resized = master.resize((size, size), Image.Resampling.LANCZOS)
        outputs[iconset / filename] = _png_bytes(resized)
        outputs[catalog / filename] = outputs[iconset / filename]
    outputs[artwork / "AppIcon.icns"] = build_icns(master)
    outputs[resources / "AppIcon.icns"] = outputs[artwork / "AppIcon.icns"]
    outputs[catalog / "Contents.json"] = (
        json.dumps(asset_catalog_contents(), indent=2, sort_keys=True) + "\n"
    ).encode()
    outputs[catalog.parent / "Contents.json"] = (
        json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2, sort_keys=True) + "\n"
    ).encode()
    return outputs


def check(root: Path) -> int:
    errors = 0
    generated = generate(root)
    for rel, expected in generated.items():
        path = root / rel
        if not path.is_file():
            print(f"MISSING {rel}", file=sys.stderr)
            errors += 1
        elif path.read_bytes() != expected:
            print(f"STALE   {rel}", file=sys.stderr)
            errors += 1
    master_path = root / "artwork" / "AppIcon-1024.png"
    if master_path.is_file():
        with Image.open(master_path) as image:
            if image.size != (CANVAS, CANVAS):
                print(f"BAD SIZE artwork/AppIcon-1024.png: {image.size}", file=sys.stderr)
                errors += 1
    return 1 if errors else 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate the Markdown Notepad app icon.")
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--check", action="store_true", help="verify committed files match generated output")
    args = parser.parse_args()

    if args.check:
        return check(args.root)

    outputs = generate(args.root)
    for rel, data in outputs.items():
        path = args.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        print(f"{hashlib.sha256(data).hexdigest()[:16]}  {rel}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
