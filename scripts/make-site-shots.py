#!/usr/bin/env python3
"""Turns the demo snapshots (Binders --selftest-demo-shots) into the window images the site uses.

    BINDERS_DATA_DIR=/tmp/binders-demo Binders --selftest-demo-shots /tmp/binders-shots --appearance light
    python3 scripts/make-site-shots.py /tmp/binders-shots site/assets

Run it once on a light set and once on a dark one (--appearance dark, a fresh BINDERS_DATA_DIR): the dark images get a
-dark suffix, and the site shows the set that matches the visitor's appearance.
"""
import sys
from pathlib import Path
from PIL import Image, ImageDraw

shots, out = Path(sys.argv[1]), Path(sys.argv[2])
out.mkdir(parents=True, exist_ok=True)
SIDEBAR_COLUMN = 496      # px the real window gives its sidebar column (248 pt at 2x)
HEIGHT = 1520             # 760 pt window

def flat(path: Path, background) -> Image.Image:
    """Scroll captures are transparent where the window shows through; put the window colour behind them."""
    image = Image.open(path).convert("RGBA")
    base = Image.new("RGBA", image.size, background + (255,))
    return Image.alpha_composite(base, image).convert("RGB")

# The window capture of the meeting page carries the real background colour.
PAPER = Image.open(shots / "demo-meeting.png").convert("RGB").getpixel((1400, 24))
DARK = sum(PAPER) < 384
SUFFIX = "-dark" if DARK else ""
SEPARATOR = (48, 46, 60) if DARK else (222, 220, 232)

def window(page: str, sidebar: str, name: str, top: int = 0):
    content = flat(shots / page, PAPER)
    side = flat(shots / sidebar, PAPER)
    body = content.crop((SIDEBAR_COLUMN, top, 2240, top + HEIGHT))
    canvas = Image.new("RGB", (side.width + body.width, HEIGHT), body.getpixel((body.width - 4, 4)))
    canvas.paste(side, (0, 0))
    canvas.paste(body, (side.width, 0))
    draw = ImageDraw.Draw(canvas)
    draw.line([(side.width, 0), (side.width, HEIGHT)], fill=SEPARATOR, width=2)
    for index, color in enumerate([(255, 95, 87), (254, 188, 46), (40, 200, 64)]):
        x = 40 + index * 40
        draw.ellipse([x, 36, x + 24, 60], fill=color)
    canvas.save(out / f"{name}{SUFFIX}.webp", "WEBP", quality=88, method=6)
    print(name + SUFFIX, canvas.size)

window("demo-home-scroll0.png", "demo-sidebar-home.png", "shot-home")
# The notes pane on its own: the window capture clips the meetings list where the sidebar overlaps it.
meeting = flat(shots / "demo-meeting.png", PAPER)
meeting.crop((1040, 330, 2248, 1520)).save(out / f"shot-meeting{SUFFIX}.webp", "WEBP", quality=90, method=6)
print("shot-meeting" + SUFFIX, (1208, 1190))

# A close look at two captured messages and the to-dos found in them.
writing = flat(shots / "demo-writing-scroll0.png", PAPER)
writing.crop((500, 520, 2010, 1130)).save(out / f"detail-writing{SUFFIX}.webp", "WEBP", quality=90, method=6)
print("detail-writing" + SUFFIX, (1510, 610))
window("demo-binder-scroll0.png", "demo-sidebar-binder.png", "shot-binder")
window("demo-writing-scroll0.png", "demo-sidebar-writing.png", "shot-writing")

# The graph sits on its own dark card in both appearances: the light run trims the margin around it.
if DARK:
    sys.exit(0)
graph = flat(shots / "demo-graph.png", (255, 255, 255))
dark = graph.point(lambda v: 255 if v < 90 else 0).convert("L")
box = dark.getbbox()
graph.crop(box).save(out / "shot-graph.webp", "WEBP", quality=88, method=6)
print("shot-graph", box)
