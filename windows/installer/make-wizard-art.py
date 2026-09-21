#!/usr/bin/env python3
"""Draw the Inno Setup wizard artwork (BMP) for the Remotype Host installer.

Inno wants BMPs, and at two sizes each so the wizard stays sharp on the HiDPI
laptops most people install on:

  wizard-large.bmp     164x314   welcome + finish pages
  wizard-large@2x.bmp  328x628
  wizard-small.bmp      55x58    the corner mark on every interior page
  wizard-small@2x.bmp  110x116

Palette matches the Mac host's HostTheme.swift and the phone's deck, so the
installer, the tray app and the app on the phone all read as one product.

Usage: python3 installer/make-wizard-art.py
"""
import os
import sys
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

DECK = (13, 21, 38)
DECK_BOTTOM = (7, 12, 24)
LEGEND = (238, 242, 251)
SUB = (167, 180, 207)
ACCENT = (61, 90, 254)

CUSTAVIA = os.path.join(ROOT, "custavia-wordmark-dark.png")
REMOTYPE = os.path.join(ROOT, "remotype-wordmark.png")


def font(size):
    for path in ("C:/Windows/Fonts/segoeui.ttf",
                 "/System/Library/Fonts/SFNSRounded.ttf",
                 "/System/Library/Fonts/Helvetica.ttc"):
        if os.path.exists(path):
            try:
                return ImageFont.truetype(path, size)
            except Exception:
                continue
    return ImageFont.load_default()


def gradient(w, h):
    """FLAT deck, not a gradient — despite the name, which is kept because it is
    what every caller says.

    Inno paints the panel around this image with WizardImageBackColor, a single
    flat colour. A vertical gradient meant the image's bottom edge was several
    shades darker than that panel, and the seam was visible as a box around the
    artwork. Every pixel this function does not draw over must be exactly DECK,
    or the image looks stuck on rather than part of the page.
    """
    return Image.new("RGB", (w, h), DECK)


def paste_fit(im, path, box_w, xy, alpha=1.0):
    """Paste a PNG scaled to box_w, returning the height used."""
    if not os.path.exists(path):
        return 0
    art = Image.open(path).convert("RGBA")
    h = max(1, int(art.height * box_w / art.width))
    art = art.resize((box_w, h), Image.LANCZOS)
    if alpha < 1.0:
        art.putalpha(art.getchannel("A").point(lambda a: int(a * alpha)))
    im.paste(art, xy, art)
    return h


# Everything is drawn at SS× and downsampled. Compositing a 256px icon straight
# into a 164px panel leaves visible stair-stepping on the tile's rounded corner,
# which is exactly the "logo is not good" of the first report.
SS = 4


def large(scale, out):
    """The welcome/finish panel: the Remotype logo, big, on the deck gradient.

    It used to carry the Custavia wordmark, a Remotype lockup, a three-line
    tagline and a URL — five things competing in a 164x314 strip, none of them
    legible. One logo, one line under it, and a lot of air.

    Only the wordmark is drawn, never the wordmark AND the app icon: the
    wordmark already contains the mark, so pasting both stacked two R tiles on
    top of each other.
    """
    w, h = 164 * scale, 314 * scale
    W, H = w * SS, h * SS
    im = gradient(W, H).convert("RGBA")

    # A soft accent glow behind the logo — the same signature the phone's home
    # screen and the Mac popover use, so all three read as one product.
    glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    cx, cy, r = W // 2, int(H * 0.40), int(W * 0.85)
    steps = 80
    for i in range(steps, 0, -1):
        rad = int(r * i / steps)
        a = int(46 * (1 - i / steps) ** 1.6)
        gd.ellipse([cx - rad, cy - rad, cx + rad, cy + rad],
                   fill=(ACCENT[0], ACCENT[1], ACCENT[2], a))
    im = Image.alpha_composite(im, glow)
    d = ImageDraw.Draw(im)

    used = paste_fit_centered(im, REMOTYPE, int(W * 0.80), 0)
    logo_y = (H - used) // 2 - int(H * 0.05)
    im.paste(Image.new("RGBA", (0, 0)), (0, 0))
    im = Image.alpha_composite(gradient(W, H).convert("RGBA"), glow)
    paste_fit_centered(im, REMOTYPE, int(W * 0.80), logo_y)
    d = ImageDraw.Draw(im)

    caption = "by Custavia"
    f = font(int(12 * scale * SS))
    tw = d.textbbox((0, 0), caption, font=f)[2]
    d.text(((W - tw) // 2, logo_y + used + int(H * 0.055)), caption, font=f, fill=SUB)

    im.convert("RGB").resize((w, h), Image.LANCZOS).save(out)
    print("wrote", out, (w, h))


def paste_fit_centered(im, path, box_w, y):
    """Paste a PNG scaled to box_w, horizontally centred. Returns height used."""
    if not os.path.exists(path):
        return 0
    art = Image.open(path).convert("RGBA")
    h = max(1, int(art.height * box_w / art.width))
    art = art.resize((box_w, h), Image.LANCZOS)
    im.paste(art, ((im.width - box_w) // 2, y), art)
    return h


def small(scale, out):
    """The corner mark: the app's own icon on the deck ground, so the interior
    pages carry the same glyph the user will look for in the system tray."""
    w, h = 55 * scale, 58 * scale
    W, H = w * SS, h * SS
    im = gradient(W, H)
    ico = os.path.join(ROOT, "tray.ico")
    if os.path.exists(ico):
        art = Image.open(ico).convert("RGBA")
        side = int(min(W, H) * 0.74)
        art = art.resize((side, side), Image.LANCZOS)
        im.paste(art, ((W - side) // 2, (H - side) // 2), art)
    im.resize((w, h), Image.LANCZOS).save(out)
    print("wrote", out, (w, h))


def main():
    large(1, os.path.join(HERE, "wizard-large.bmp"))
    large(2, os.path.join(HERE, "wizard-large@2x.bmp"))
    small(1, os.path.join(HERE, "wizard-small.bmp"))
    small(2, os.path.join(HERE, "wizard-small@2x.bmp"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
