#!/usr/bin/env python3
"""Draw the DMG window background (1x + 2x) and fuse them into a HiDPI TIFF.

Kept as a script rather than a one-off, because the background is a BUILD INPUT:
the arrow in it has to line up with the icon coordinates that release-mac.sh
passes to create-dmg, and the only way to keep those two in agreement over time
is for both to be written down. Change the icon positions there, change ICON_Y /
ARROW_X here.

Palette is lifted from Sources/HostTheme.swift so the image and the app agree.

Usage:  python3 installer/make-dmg-background.py
Output: installer/dmg-background.png, @2x.png, dmg-background.tiff
"""
import os
import subprocess
import sys
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

# --- geometry, mirrored in release-mac.sh's create-dmg call ------------------
W, H = 620, 420
ICON_Y = 210          # --icon "…app" 160 210   /   --app-drop-link 460 210
ARROW_X0, ARROW_X1 = 250, 372

# --- palette, from HostTheme.swift ------------------------------------------
DECK = (13, 21, 38)
DECK_BOTTOM = (9, 15, 28)
LEGEND = (238, 242, 251)
SUB = (167, 180, 207)
ACCENT = (61, 90, 254)

WORDMARK = os.path.join(ROOT, "Sources", "custavia-wordmark-dark.png")


def font(size, bold=False):
    for path in ("/System/Library/Fonts/SFNSRounded.ttf",
                 "/System/Library/Fonts/SFNS.ttf",
                 "/System/Library/Fonts/Helvetica.ttc"):
        if os.path.exists(path):
            try:
                return ImageFont.truetype(path, size)
            except Exception:
                continue
    return ImageFont.load_default()


def build(scale: int, out: str) -> None:
    w, h = W * scale, H * scale
    im = Image.new("RGB", (w, h), DECK)
    d = ImageDraw.Draw(im)

    # Vertical wash. Flat navy reads as unfinished; a gentle gradient reads as
    # chosen, and costs nothing.
    for y in range(h):
        t = y / h
        d.line([(0, y), (w, y)],
               fill=tuple(int(DECK[i] + (DECK_BOTTOM[i] - DECK[i]) * t) for i in range(3)))

    # The Custavia mark, top-left, as a real brand element rather than a
    # watermark. It was centred low before, where the two 128pt icons sat on top
    # of it — a logo half-hidden behind the thing the user is dragging is worse
    # than no logo. Up here it owns empty space and nothing overlaps it.
    text_top = 34 * scale
    if os.path.exists(WORDMARK):
        mark = Image.open(WORDMARK).convert("RGBA")
        target_w = 150 * scale
        mark = mark.resize((target_w, max(1, int(mark.height * target_w / mark.width))),
                           Image.LANCZOS)
        shown = mark.copy()
        shown.putalpha(shown.getchannel("A").point(lambda a: int(a * 0.92)))
        im.paste(shown, (40 * scale, 28 * scale), shown)
        text_top = 28 * scale + shown.height + 18 * scale

    d.text((40 * scale, text_top), "REMOTYPE HOST",
           font=font(17 * scale), fill=LEGEND)
    d.text((40 * scale, text_top + 26 * scale), "Drag the app onto Applications to install",
           font=font(13 * scale), fill=SUB)

    # The arrow lives in the gap between the two icon slots.
    y = (ICON_Y - 2) * scale
    x0, x1 = ARROW_X0 * scale, ARROW_X1 * scale
    d.line([(x0, y), (x1, y)], fill=ACCENT, width=max(2, 3 * scale))
    head = 11 * scale
    d.polygon([(x1 + head, y), (x1 - 2, y - head), (x1 - 2, y + head)], fill=ACCENT)

    d.text((40 * scale, h - 46 * scale),
           "Signed and notarized by Apple  ·  custavia.com",
           font=font(11 * scale), fill=SUB)

    im.save(out)
    print("wrote", out, im.size)


def main() -> int:
    one = os.path.join(HERE, "dmg-background.png")
    two = os.path.join(HERE, "dmg-background@2x.png")
    tiff = os.path.join(HERE, "dmg-background.tiff")
    build(1, one)
    build(2, two)
    # A multi-representation TIFF is how a DMG background gets a Retina variant;
    # Finder picks the right one per display.
    subprocess.run(["tiffutil", "-cathidpicheck", one, two, "-out", tiff], check=True)
    print("wrote", tiff)
    return 0


if __name__ == "__main__":
    sys.exit(main())
