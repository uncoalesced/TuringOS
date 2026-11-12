#!/usr/bin/env python3
# Engineered by uncoalesced
"""Render the TuringOS boot art from the design language.

Outputs (committed, so the build host needs no Pillow):
  isolinux-splash.png   640x480  BIOS boot menu (vesamenu)
  grub-splash.png       800x600  GRUB menu (BIOS and UEFI, both arches)
  logo-256.png          256x256  Calamares product logo
  plymouth/turingos/logo.png, dot.png, strip.png   plymouth theme images

Look (assets/design-language/DESIGN_LANGUAGE.md): black is the room, the logo
sits above the menu, one warm glow from the bottom (the desktop glow), and one
brand gradient strip, `to right`, never behind text. No new hues.

Run from anywhere:  python3 debian-live/branding/make-boot-art.py
"""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
LOGO = ROOT / "assets/logo/turing-os-no-bg-logopng.png"
SERIF = ROOT / "ui/web/fonts/TimelessSerifVF.ttf"

BLACK = (0, 0, 0)
WHITE = (249, 249, 249)
ORANGE = (232, 80, 2)
# Brand gradient stops (135deg in the UI; strips run left to right)
STOPS = [(0.0, (0, 0, 0)), (0.35, (193, 8, 1)), (0.70, (241, 96, 1)), (1.0, (217, 195, 171))]


def lerp(a, b, t):
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


def gradient_at(t):
    for (t0, c0), (t1, c1) in zip(STOPS, STOPS[1:]):
        if t <= t1:
            return lerp(c0, c1, (t - t0) / (t1 - t0))
    return STOPS[-1][1]


def strip(width, height):
    img = Image.new("RGB", (width, height))
    px = img.load()
    for x in range(width):
        c = gradient_at(x / max(width - 1, 1))
        for y in range(height):
            px[x, y] = c
    return img


def glow(size, alpha):
    """The desktop glow: radial-gradient(150% 110% at 50% 125%, var(--glow), transparent 72%)."""
    w, h = size
    rx, ry = 1.5 * w, 1.1 * h
    cx, cy = 0.5 * w, 1.25 * h
    mask = Image.new("L", size, 0)
    px = mask.load()
    for y in range(h):
        dy = ((y - cy) / ry) ** 2
        for x in range(w):
            d = (((x - cx) / rx) ** 2 + dy) ** 0.5
            if d < 0.72:
                px[x, y] = round(255 * alpha * (1 - d / 0.72))
    out = Image.new("RGB", size, BLACK)
    out.paste(Image.new("RGB", size, ORANGE), mask=mask)
    return out


def logo(px):
    src = Image.open(LOGO).convert("RGBA")
    src = src.crop(src.getbbox())
    src.thumbnail((px, px), Image.LANCZOS)
    return src


def serif(size, weight=400):
    font = ImageFont.truetype(str(SERIF), size)
    try:
        font.set_variation_by_axes([weight])
    except (OSError, AttributeError):
        pass
    return font


def splash(size, logo_px, logo_top, word_px, glow_alpha):
    w, h = size
    img = glow(size, glow_alpha)
    mark = logo(logo_px)
    img.paste(mark, ((w - mark.width) // 2, logo_top), mark)
    d = ImageDraw.Draw(img)
    font = serif(word_px)
    text = "TuringOS"
    box = d.textbbox((0, 0), text, font=font)
    tw = box[2] - box[0]
    d.text(((w - tw) // 2 - box[0], logo_top + mark.height + word_px // 2 - box[1]), text, font=font, fill=WHITE)
    sh = max(2, h // 200)
    img.paste(strip(w, sh), (0, h - sh))
    return img


SANS = ROOT / "ui/web/fonts/TimelessSansVF.ttf"
LIGHT_GRAY = (167, 167, 167)

# Installer slides: what the installed system does, in the product's own terms
SLIDES = [
    ("Agents work in a sandbox.", "Every change comes back as a diff you approve or roll back."),
    ("Tools from the Bazaar.", "A signed catalogue, checked before anything installs."),
    ("Game mode when you play.", "The agent keeps working at background priority."),
]


def gradient_135(size):
    """The brand gradient at 135deg: black top-left to cream bottom-right."""
    w, h = size
    img = Image.new("RGB", size)
    px = img.load()
    span = w + h
    for y in range(h):
        for x in range(w):
            px[x, y] = gradient_at((x + y) / span)
    return img


def slide(size, heading, body):
    """Text on black; the brand gradient is a hero band below it, never behind text."""
    w, h = size
    img = Image.new("RGB", size, BLACK)
    band = h * 9 // 20
    img.paste(gradient_135((w, band)), (0, h - band))
    d = ImageDraw.Draw(img)
    head = serif(40)
    d.text((48, 56), heading, font=head, fill=WHITE)
    sans = ImageFont.truetype(str(SANS), 17)
    d.text((48, 56 + 40 + 24), body, font=sans, fill=LIGHT_GRAY)
    mark = logo(48)
    img.paste(mark, (w - mark.width - 44, 52), mark)
    return img


def main():
    ply = HERE / "plymouth/turingos"
    ply.mkdir(parents=True, exist_ok=True)
    slides = HERE / "slides"
    slides.mkdir(exist_ok=True)
    for i, (heading, body) in enumerate(SLIDES, 1):
        slide((800, 440), heading, body).save(slides / f"slide-{i}.png", optimize=True)

    # isolinux: vesamenu draws the menu from row 12 (y=192), keep the art above it
    splash((640, 480), 104, 28, 22, 0.25).save(HERE / "isolinux-splash.png", optimize=True)
    # GRUB: live-theme's boot_menu starts at 52% (y=312)
    splash((800, 600), 150, 56, 30, 0.25).save(HERE / "grub-splash.png", optimize=True)

    logo(256).save(HERE / "logo-256.png", optimize=True)

    logo(180).save(ply / "logo.png", optimize=True)
    # The one live thing: an orange dot with a soft halo
    dot = Image.new("RGBA", (48, 48), (0, 0, 0, 0))
    halo = Image.new("L", (48, 48), 0)
    ImageDraw.Draw(halo).ellipse([8, 8, 40, 40], fill=90)
    halo = halo.filter(ImageFilter.GaussianBlur(6))
    dot.paste(Image.new("RGBA", (48, 48), ORANGE + (255,)), mask=halo)
    ImageDraw.Draw(dot).ellipse([18, 18, 30, 30], fill=ORANGE + (255,))
    dot.save(ply / "dot.png", optimize=True)
    strip(512, 3).save(ply / "strip.png", optimize=True)

    for p in sorted(HERE.rglob("*.png")):
        print(f"{p.relative_to(ROOT).as_posix()}  {p.stat().st_size // 1024} KB")


if __name__ == "__main__":
    main()
