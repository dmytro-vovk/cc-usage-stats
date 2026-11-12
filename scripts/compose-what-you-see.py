#!/usr/bin/env python3
"""Composes docs/screenshots/what-you-see-{light,dark}.png: the app icon
beside the six menu-bar pill states, and docs/screenshots/app-icon.png
(the README header icon), rendered by
scripts/render-menubar-shots.sh, with captions. Needs a python3 with Pillow
(`uv run --with pillow scripts/compose-what-you-see.py`, or a venv) and
rsvg-convert (brew install librsvg). Run after render-menubar-shots.sh."""
import subprocess, sys, tempfile
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
SHOTS = ROOT / "docs" / "screenshots"
STATES = [
    ("menubar", "5-hour session, plenty left"),
    ("menubar-outage", "Filling up, plus an incident badge"),
    ("menubar-split", "Both windows tight: 5-hour │ 7-day"),
    ("menubar-codex", "Claude running hot, Codex has room"),
    ("menubar-sessions", "At the cap: countdown to the reset"),
    ("menubar-weekly", "No 5-hour limit: weekly leads"),
]
THEMES = {
    "light": dict(bg=(0, 0, 0, 0), text=(88, 88, 84, 255), rule=(214, 214, 210, 255)),
    "dark": dict(bg=(0, 0, 0, 0), text=(176, 176, 172, 255), rule=(66, 67, 72, 255)),
}
W, H = 1400, 620          # 2× pixels → display at width 700
ICON = 256


def font(size):
    for p in ("/System/Library/Fonts/SFNS.ttf", "/System/Library/Fonts/Helvetica.ttc"):
        try:
            return ImageFont.truetype(p, size)
        except OSError:
            pass
    return ImageFont.load_default()


def render_icon(tmp):
    out = Path(tmp) / "icon.png"
    subprocess.run(["rsvg-convert", "-w", str(ICON), "-h", str(ICON),
                    str(ROOT / "icon-master.svg"), "-o", str(out)], check=True)
    return Image.open(out).convert("RGBA")


def compose(theme, icon):
    t = THEMES[theme]
    im = Image.new("RGBA", (W, H), t["bg"])
    d = ImageDraw.Draw(im)
    im.paste(icon, (72, (H - ICON) // 2), icon)
    d.line([(392, 72), (392, H - 72)], fill=t["rule"], width=2)
    cap = font(24)
    col_w, row_h, x0, y0 = 480, 170, 456, 76
    for i, (name, label) in enumerate(STATES):
        cx, cy = x0 + (i % 2) * col_w, y0 + (i // 2) * row_h
        pill = Image.open(SHOTS / f"{name}-{theme}.png").convert("RGBA")
        pill = pill.resize((pill.width // 2, pill.height // 2), Image.LANCZOS)  # 4× → 2×
        im.paste(pill, (cx, cy), pill)
        d.text((cx, cy + pill.height + 22), label, font=cap, fill=t["text"])
    return im


def main():
    with tempfile.TemporaryDirectory() as tmp:
        icon = render_icon(tmp)
        icon.save(SHOTS / "app-icon.png")
        print((SHOTS / "app-icon.png").relative_to(ROOT))
        for theme in THEMES:
            out = SHOTS / f"what-you-see-{theme}.png"
            compose(theme, icon).save(out)
            print(out.relative_to(ROOT))


if __name__ == "__main__":
    sys.exit(main())
