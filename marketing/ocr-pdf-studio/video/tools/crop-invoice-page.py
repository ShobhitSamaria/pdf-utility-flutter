#!/usr/bin/env python3
"""Recreate the paper still-life crop from the real translation screenshot.

The problem scene uses only the invoice page, not the app chrome, so the prop
reads as paper rather than as a second app screen. The crop is taken from
store-assets/screenshots/04_translation.png (release build capture).

    python3 tools/crop-invoice-page.py
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "public" / "screenshots" / "04_translation.png"
TARGET = ROOT / "public" / "screenshots" / "invoice-page.png"

# Excludes the app bar above and the language selector below.
CROP = (0, 310, 1080, 1790)

with Image.open(SOURCE) as image:
    page = image.convert("RGB").crop(CROP)
    page.save(TARGET, optimize=True)
    print(f"{TARGET}  {page.width}x{page.height}")
