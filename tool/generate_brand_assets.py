#!/usr/bin/env python3
"""Generate OCR PDF Studio brand assets from assets/LOGO.png.

The supplied logo is a 1254x1254 RGB PNG: a rounded navy tile (#000730) with a
white document, white scan brackets and a blue scan bar, on a white field. This
script never modifies the source. It derives:

  * legacy launcher icons (mipmap-*/ic_launcher.png)
  * round launcher icons   (mipmap-*/ic_launcher_round.png)
  * adaptive foreground    (drawable-*/ic_launcher_foreground.png)
  * monochrome layer       (drawable-*/ic_launcher_monochrome.png)
  * the in-app header mark (assets/branding/logo_mark.png)
  * the pre-Android-12 splash lockup (drawable-*/brand_splash.png)
  * Play Store graphics    (store-assets/graphics/)

The white field around the tile is flood-filled with the tile navy first, so
scaling and masking never leave a pale halo on a navy background. Sizes are
built at 4x and downsampled with Lanczos.

Requires Pillow (pip install pillow). Fonts are macOS system fonts; pass
--font-dir to use a directory that contains an Avenir Next or Helvetica Neue
collection.
"""

from __future__ import annotations

import argparse
import shutil
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "assets" / "LOGO.png"
RES = ROOT / "android" / "app" / "src" / "main" / "res"
BRANDING = ROOT / "assets" / "branding"
STORE_GRAPHICS = ROOT / "store-assets" / "graphics"

# Sampled from the source (it is a flat fill with +/-1 rounding noise).
NAVY = (0, 7, 48)
PRIMARY = (36, 42, 92)       # AppColors.primary
MUTED = (95, 101, 121)       # AppColors.muted
PAGE = (250, 250, 252)       # AppColors.page
WHITE = (255, 255, 255)

# Tile bounds and corner radius, measured on the 1254x1254 source.
TILE_BOX = (21, 23, 1234, 1230)
TILE_RADIUS_RATIO = 271 / 1213

# Artwork occupies the middle 93.3% of the tile; keep that composition.
# Adaptive foreground: the tile is 52% of the 108dp canvas, so the corner
# brackets (the outermost artwork) stay inside the 72dp visible viewport even
# under a circular mask.
ADAPTIVE_TILE_SCALE = 0.52
LEGACY_TILE_SCALE = 0.94
ROUND_TILE_SCALE = 0.74

DENSITIES = {
    "mdpi": 1.0,
    "hdpi": 1.5,
    "xhdpi": 2.0,
    "xxhdpi": 3.0,
    "xxxhdpi": 4.0,
}
LEGACY_DP = 48
ADAPTIVE_DP = 108
HOME_MARK_PX = 256
SPLASH_WIDTH_DP = 260


def load_tile_source() -> Image.Image:
    """Crop the tile and replace the white field with the tile navy.

    Flood-filling from the corners removes the white surround while leaving the
    white document untouched (the navy tile separates the two regions).
    """
    image = Image.open(SOURCE).convert("RGB")
    tile = image.crop(TILE_BOX).copy()
    width, height = tile.size
    for corner in ((0, 0), (width - 1, 0), (0, height - 1), (width - 1, height - 1)):
        ImageDraw.floodfill(tile, corner, NAVY, thresh=150)

    # Flood fill stops at the antialiased rim (a pale grey ring that would show
    # as a faint outline on the navy launcher background). Repaint everything
    # outside an inset copy of the tile shape with the flat navy: the tile and
    # the launcher field are the same colour, so the seam is invisible.
    inset = 5
    mask = Image.new("L", tile.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [inset, inset, width - 1 - inset, height - 1 - inset],
        radius=TILE_RADIUS_RATIO * width - inset,
        fill=255,
    )
    flat = Image.new("RGB", tile.size, NAVY)
    return Image.composite(tile, flat, mask)


def rounded_mask(size: int, supersample: int = 4) -> Image.Image:
    big = Image.new("L", (size * supersample, size * supersample), 0)
    draw = ImageDraw.Draw(big)
    radius = TILE_RADIUS_RATIO * size * supersample
    inset = 0.4 * supersample  # keep the antialiased edge inside the canvas
    draw.rounded_rectangle(
        [inset, inset, size * supersample - inset, size * supersample - inset],
        radius=radius,
        fill=255,
    )
    return big.resize((size, size), Image.LANCZOS)


def rounded_tile(size: int) -> Image.Image:
    """The logo tile as a rounded RGBA image for use on a light surface."""
    source = load_tile_source()
    image = source.resize((size, size), Image.LANCZOS).convert("RGBA")
    image.putalpha(rounded_mask(size))
    return image


def icon_canvas(size: int, tile_scale: float, circle: bool = False) -> Image.Image:
    """Navy field with the logo tile (navy on navy) centred at tile_scale."""
    ss = 4
    big = Image.new("RGBA", (size * ss, size * ss), NAVY + (255,))
    tile_size = max(1, round(size * ss * tile_scale))
    tile = rounded_tile(tile_size)
    offset = ((big.width - tile_size) // 2, (big.height - tile_size) // 2)
    big.alpha_composite(tile, offset)
    if circle:
        mask = Image.new("L", big.size, 0)
        ImageDraw.Draw(mask).ellipse([0, 0, big.width - 1, big.height - 1], fill=255)
        big.putalpha(mask)
    return big.resize((size, size), Image.LANCZOS)


def foreground(size: int) -> Image.Image:
    """Transparent adaptive foreground: the tile centred in the safe zone."""
    ss = 4
    big = Image.new("RGBA", (size * ss, size * ss), (0, 0, 0, 0))
    tile_size = max(1, round(size * ss * ADAPTIVE_TILE_SCALE))
    tile = rounded_tile(tile_size)
    big.alpha_composite(
        tile, ((big.width - tile_size) // 2, (big.height - tile_size) // 2)
    )
    return big.resize((size, size), Image.LANCZOS)


def monochrome(size: int) -> Image.Image:
    """Single-colour silhouette of the artwork (alpha-only, as Android expects)."""
    ss = 4
    src = load_tile_source()
    big_src = src.resize((size * ss, size * ss), Image.LANCZOS)
    alpha = Image.new("L", big_src.size, 0)
    src_px = big_src.load()
    alpha_px = alpha.load()
    for y in range(big_src.height):
        for x in range(big_src.width):
            r, g, b = src_px[x, y]
            distance = abs(r - NAVY[0]) + abs(g - NAVY[1]) + abs(b - NAVY[2])
            alpha_px[x, y] = max(0, min(255, int((distance - 60) * 255 / 90)))
    layer = Image.new("RGBA", big_src.size, (255, 255, 255, 0))
    layer.putalpha(alpha)
    scaled = layer.resize((size, size), Image.LANCZOS)

    big = Image.new("RGBA", (size * ss, size * ss), (0, 0, 0, 0))
    tile_size = round(size * ss * ADAPTIVE_TILE_SCALE)
    placed = scaled.resize((tile_size, tile_size), Image.LANCZOS)
    big.alpha_composite(
        placed, ((big.width - tile_size) // 2, (big.height - tile_size) // 2)
    )
    return big.resize((size, size), Image.LANCZOS)


def load_font(font_dir: Path | None, size: int, weight: str):
    candidates = []
    if font_dir:
        candidates.append((font_dir / "Avenir Next.ttc", 2 if weight == "bold" else 5))
        candidates.append((font_dir / "HelveticaNeue.ttc", 1 if weight == "bold" else 0))
    candidates.extend(
        [
            (Path("/System/Library/Fonts/Avenir Next.ttc"), 2 if weight == "bold" else 5),
            (Path("/System/Library/Fonts/HelveticaNeue.ttc"), 1 if weight == "bold" else 0),
            (Path("/System/Library/Fonts/Supplemental/Arial Bold.ttf"), 0),
            (Path("/System/Library/Fonts/Supplemental/Arial.ttf"), 0),
        ]
    )
    for path, index in candidates:
        if path.exists():
            try:
                return ImageFont.truetype(str(path), size, index=index)
            except OSError:
                continue
    return ImageFont.load_default(size=size)


def tracked_width(draw, text, font, tracking):
    if not text:
        return 0.0
    total = sum(draw.textlength(char, font=font) for char in text)
    return total + tracking * (len(text) - 1)


def draw_tracked(draw, xy, text, font, fill, tracking):
    x, y = xy
    for char in text:
        draw.text((x, y), char, font=font, fill=fill)
        x += draw.textlength(char, font=font) + tracking


def splash_lockup(width_px: int, font_dir: Path | None) -> Image.Image:
    """Logo tile + wordmark + tagline, rendered at width_px."""
    scale = width_px / SPLASH_WIDTH_DP
    ss = 2
    px = int(round(width_px * ss))

    wordmark_size = int(round(27 * scale * ss))
    tagline_size = int(round(13.5 * scale * ss))
    word_font = load_font(font_dir, wordmark_size, "bold")
    tagline_font = load_font(font_dir, tagline_size, "regular")

    probe = ImageDraw.Draw(Image.new("RGB", (8, 8)))
    word = "OCR PDF Studio"
    tagline = "Scan. Extract. Convert."
    word_tracking = -0.4 * scale * ss
    tagline_tracking = 0.9 * scale * ss
    word_width = tracked_width(probe, word, word_font, word_tracking)
    tagline_width = tracked_width(probe, tagline, tagline_font, tagline_tracking)

    tile_px = int(round(104 * scale * ss))
    gap_one = int(round(21 * scale * ss))
    gap_two = int(round(7 * scale * ss))
    padding = int(round(8 * scale * ss))

    word_bbox = word_font.getbbox(word)
    tagline_bbox = tagline_font.getbbox(tagline)
    word_height = word_bbox[3] - word_bbox[1]
    tagline_height = tagline_bbox[3] - tagline_bbox[1]

    content_width = max(tile_px, word_width, tagline_width)
    canvas_w = int(content_width + 2 * padding)
    canvas_h = int(
        tile_px + gap_one + word_height + gap_two + tagline_height + 2 * padding
    )

    canvas = Image.new("RGBA", (canvas_w, canvas_h), (0, 0, 0, 0))
    tile = rounded_tile(tile_px)
    canvas.alpha_composite(tile, ((canvas_w - tile_px) // 2, padding))

    y = padding + tile_px + gap_one
    x = (canvas_w - word_width) / 2
    draw_tracked(
        ImageDraw.Draw(canvas),
        (x - word_bbox[0], y - word_bbox[1]),
        word,
        word_font,
        PRIMARY + (255,),
        word_tracking,
    )

    y += word_height + gap_two
    x = (canvas_w - tagline_width) / 2
    draw_tracked(
        ImageDraw.Draw(canvas),
        (x - tagline_bbox[0], y - tagline_bbox[1]),
        tagline,
        tagline_font,
        MUTED + (255,),
        tagline_tracking,
    )

    return canvas.resize((canvas_w // ss, canvas_h // ss), Image.LANCZOS)


def play_icon(size: int = 512) -> Image.Image:
    """512x512 Play Store icon: full-bleed navy with the logo artwork."""
    return icon_canvas(size, LEGACY_TILE_SCALE).convert("RGB")


def feature_graphic(width: int = 1024, height: int = 500) -> Image.Image:
    """Play feature graphic: brand lockup on a navy field, no fake UI."""
    canvas = Image.new("RGB", (width, height), NAVY)
    draw = ImageDraw.Draw(canvas)

    # Quiet periwinkle glow behind the mark.
    glow = Image.new("L", (width, height), 0)
    ImageDraw.Draw(glow).ellipse(
        [width * 0.53, -height * 0.55, width * 1.15, height * 1.5], fill=60
    )
    glow = glow.filter(ImageFilter.GaussianBlur(130))
    canvas.paste(Image.new("RGB", (width, height), (66, 76, 148)), (0, 0), glow)

    tile_px = 260
    tile = rounded_tile(tile_px)
    tile_x = int(width * 0.11)
    tile_y = (height - tile_px) // 2
    canvas.paste(tile, (tile_x, tile_y), tile)

    word_font = load_font(None, 66, "bold")
    tagline_font = load_font(None, 26, "regular")
    text_x = tile_x + tile_px + 70

    word = "OCR PDF Studio"
    tagline = "Scan. Extract. Convert."
    word_bbox = word_font.getbbox(word)
    tagline_bbox = tagline_font.getbbox(tagline)
    word_tracking = -1.1
    tagline_tracking = 2.2

    block_h = (word_bbox[3] - word_bbox[1]) + 16 + (tagline_bbox[3] - tagline_bbox[1])
    y = (height - block_h) // 2
    draw_tracked(
        draw,
        (text_x - word_bbox[0], y - word_bbox[1]),
        word,
        word_font,
        WHITE,
        word_tracking,
    )
    y += (word_bbox[3] - word_bbox[1]) + 16
    draw_tracked(
        draw,
        (text_x - tagline_bbox[0], y - tagline_bbox[1]),
        tagline,
        tagline_font,
        (178, 190, 255),
        tagline_tracking,
    )
    return canvas


def write_png(image: Image.Image, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, "PNG", optimize=True)
    print(f"{path.relative_to(ROOT)}  {image.width}x{image.height}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--font-dir", type=Path, default=None)
    args = parser.parse_args()

    if not SOURCE.exists():
        raise SystemExit(f"source logo not found: {SOURCE}")

    for density, factor in DENSITIES.items():
        legacy_px = round(LEGACY_DP * factor)
        folder = RES / f"mipmap-{density}"
        write_png(icon_canvas(legacy_px, LEGACY_TILE_SCALE), folder / "ic_launcher.png")
        write_png(
            icon_canvas(legacy_px, ROUND_TILE_SCALE, circle=True),
            folder / "ic_launcher_round.png",
        )

        adaptive_px = round(ADAPTIVE_DP * factor)
        drawable = RES / f"drawable-{density}"
        write_png(foreground(adaptive_px), drawable / "ic_launcher_foreground.png")
        write_png(monochrome(adaptive_px), drawable / "ic_launcher_monochrome.png")

        splash = splash_lockup(round(SPLASH_WIDTH_DP * factor), args.font_dir)
        write_png(splash, drawable / "brand_splash.png")

    write_png(rounded_tile(HOME_MARK_PX), BRANDING / "logo_mark.png")

    # Play Store graphics are generated but the listing copy lives in
    # store-assets/ separately; screenshots are real device captures.
    write_png(play_icon(), STORE_GRAPHICS / "play_store_icon_512.png")
    write_png(feature_graphic(), STORE_GRAPHICS / "feature_graphic_1024x500.png")


if __name__ == "__main__":
    main()
