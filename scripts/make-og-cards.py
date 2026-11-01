#!/usr/bin/env python3
"""Renders the Open Graph cards for the public pages into site/assets/.

Each card is a 1200x630 picture with that page's own words on it: the pages point at these by name, so a page's
title, description and card have to say the same thing. Binders Hub pages use the Hub's light palette; the Mac and
the policy pages use the landing page's dark one.

    python3 scripts/make-og-cards.py            # all of them
    python3 scripts/make-og-cards.py --check    # fail if a file is missing or the wrong size

Needs Pillow. The fonts are macOS system fonts (SF Pro, SF Pro Rounded, New York); elsewhere, point --fonts at a
folder holding SFNS.ttf, SFNSRounded.ttf and NewYorkItalic.ttf.
"""

import argparse
import pathlib
import sys

from PIL import Image, ImageDraw, ImageFont

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "site" / "assets"
ICON = OUT / "icon-128.png"

DARK = {
    "bg": (8, 8, 13),
    "glow": (75, 63, 214),
    "text": (242, 239, 232),
    "muted": (179, 173, 194),
    "faint": (130, 125, 147),
    "accent": (185, 176, 255),
    "line": (238, 233, 255, 26),
    "rounded": False,
}
LIGHT = {
    "bg": (247, 245, 240),
    "glow": (67, 56, 202),
    "text": (23, 21, 31),
    "muted": (81, 77, 99),
    "faint": (143, 137, 163),
    "accent": (67, 56, 202),
    "line": (23, 21, 31, 18),
    "rounded": True,
}

CARDS = [
    # file, palette, tag, headline, italic accent, description, footer, footer right
    ("og-home.png", DARK, "HUB + MAC", "Binders Hub,\nand Binders for Mac.", None,
     "Your Mac keeps what you heard. The Hub gets what you chose to share.",
     "binders.io", "hello@binders.io"),
    ("og-hub.png", LIGHT, "BINDERS HUB", "From a note\nto production.", None,
     "Agents do the work. You make the decisions. Cards are GitHub Issues, and related pull requests are one change set.",
     "binders.io/hub", "Request access: hello@binders.io"),
    ("og-docs.png", LIGHT, "BINDERS HUB", "Using\nBinders Hub.", None,
     "Notes, Distill, the board, agents, change sets, Challenge and Delivery.",
     "binders.io/docs", "hello@binders.io"),
    ("og-hub-privacy.png", LIGHT, "BINDERS HUB", "What a Hub\nkeeps.", None,
     "Where it goes, who can read it, and what deleting does.",
     "binders.io/hub-privacy", "hello@binders.io"),
    ("og-hub-terms.png", LIGHT, "BINDERS HUB", "The terms for\na Hub.", None,
     "Using or running a Binders Hub, in plain language.",
     "binders.io/hub-terms", "hello@binders.io"),
    ("og-help.png", DARK, "BINDERS FOR MAC", "Getting Binders\nworking.", None,
     "Setting up, fixing the usual problems, and what happens to your data.",
     "binders.io/help", "Free and open source"),
    ("og-privacy.png", DARK, "BINDERS FOR MAC", "Your data\nstays yours.", None,
     "Where Binders keeps your data, what leaves your Mac, and when.",
     "binders.io/privacy", "Free and open source"),
    ("og-terms.png", DARK, "BINDERS FOR MAC", "The terms,\nin plain language.", None,
     "Using Binders for Mac and iPhone.",
     "binders.io/terms", "Free and open source"),
    ("og-licenses.png", DARK, "BINDERS FOR MAC", "What Binders\nis built with.", None,
     "The open-source software and models Binders is built with.",
     "binders.io/licenses", "Free and open source"),
]


def font(fonts, name, size, variation=None):
    face = ImageFont.truetype(str(fonts / name), size)
    if variation:
        try:
            face.set_variation_by_name(variation)
        except (AttributeError, OSError):
            pass
    return face


def spaced(draw, xy, text, face, fill, tracking):
    x, y = xy
    for char in text:
        draw.text((x, y), char, font=face, fill=fill)
        x += draw.textlength(char, font=face) + tracking


def glow(card, centre, radius, colour):
    layer = Image.new("RGBA", card.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    steps = 48
    for i in range(steps, 0, -1):
        r = radius * i / steps
        alpha = int(46 * (1 - i / steps) ** 2)
        draw.ellipse(
            [centre[0] - r, centre[1] - r * 0.62, centre[0] + r, centre[1] + r * 0.62],
            fill=colour + (alpha,),
        )
    card.alpha_composite(layer)


def grid(card, colour):
    layer = Image.new("RGBA", card.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    for x in range(0, card.width, 60):
        draw.line([(x, 0), (x, card.height)], fill=colour, width=1)
    for y in range(0, card.height, 60):
        draw.line([(0, y), (card.width, y)], fill=colour, width=1)
    card.alpha_composite(layer)


def render(spec, fonts, destination):
    name, palette, tag, headline, italic, description, footer, footer_right = spec
    card = Image.new("RGBA", (1200, 630), palette["bg"] + (255,))
    glow(card, (930, 90), 620, palette["glow"])
    grid(card, palette["line"])
    draw = ImageDraw.Draw(card)

    icon = Image.open(ICON).convert("RGBA").resize((56, 56), Image.LANCZOS)
    card.alpha_composite(icon, (72, 62))
    wordmark = font(fonts, "SFNSRounded.ttf" if palette["rounded"] else "SFNS.ttf", 30, "Semibold")
    draw.text((142, 72), "Binders", font=wordmark, fill=palette["text"])

    tag_face = font(fonts, "SFNS.ttf", 15, "Semibold")
    tag_width = sum(draw.textlength(c, font=tag_face) + 2 for c in tag)
    tag_left = 142 + draw.textlength("Binders", font=wordmark) + 18
    draw.rounded_rectangle(
        [tag_left, 74, tag_left + tag_width + 24, 74 + 28], radius=14,
        outline=palette["accent"] + (150,), width=1,
    )
    spaced(draw, (tag_left + 12, 80), tag, tag_face, palette["accent"], 2)

    head_face = font(
        fonts,
        "SFNSRounded.ttf" if palette["rounded"] else "SFNS.ttf",
        78 if max(len(line) for line in headline.split("\n")) < 20 else 68,
        "Bold",
    )
    head_lines = headline.split("\n")
    line_height = int(head_face.size * 1.06)
    head_top = 196
    for index, line in enumerate(head_lines):
        draw.text((72, head_top + index * line_height), line, font=head_face, fill=palette["text"])

    sub_top = head_top + len(head_lines) * line_height + 34
    if italic:
        italic_face = font(fonts, "NewYorkItalic.ttf", 66, "Medium Italic")
        draw.text((72, sub_top), italic, font=italic_face, fill=palette["accent"])
        sub_top += int(italic_face.size * 1.25) + 16

    body = font(fonts, "SFNS.ttf", 27, "Regular")
    words, line, lines = description.split(), "", []
    for word in words:
        trial = f"{line} {word}".strip()
        if draw.textlength(trial, font=body) <= 700:
            line = trial
        else:
            lines.append(line)
            line = word
    if line:
        lines.append(line)
    for index, line in enumerate(lines[:3]):
        draw.text((72, sub_top + index * 38), line, font=body, fill=palette["muted"])

    draw.line([(72, 544), (1128, 544)], fill=palette["line"], width=1)
    foot_face = font(fonts, "SFNS.ttf", 18, "Regular")
    draw.text((72, 566), footer, font=foot_face, fill=palette["faint"])
    right = draw.textlength(footer_right, font=foot_face)
    draw.text((1128 - right, 566), footer_right, font=foot_face, fill=palette["faint"])

    card.convert("RGB").save(destination, optimize=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fonts", default="/System/Library/Fonts", help="folder with SFNS.ttf, SFNSRounded.ttf and NewYorkItalic.ttf")
    parser.add_argument("--check", action="store_true", help="only check the files that are there")
    options = parser.parse_args()
    fonts = pathlib.Path(options.fonts)

    if options.check:
        bad = []
        for name, *_ in CARDS:
            path = OUT / name
            if not path.exists():
                bad.append(f"{name}: missing")
                continue
            with Image.open(path) as image:
                if image.size != (1200, 630):
                    bad.append(f"{name}: {image.width}x{image.height}, not 1200x630")
        print("\n".join(bad) if bad else "✓ all Open Graph cards are present at 1200x630")
        return 1 if bad else 0

    OUT.mkdir(parents=True, exist_ok=True)
    for spec in CARDS:
        destination = OUT / spec[0]
        render(spec, fonts, destination)
        print(f"✓ {destination.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
