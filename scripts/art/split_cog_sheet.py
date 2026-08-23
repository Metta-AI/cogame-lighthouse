#!/usr/bin/env python3
"""Splits the nano-banana cog sheet into the four seat sprites.

scripts/art/source/cogs_sheet.png is a single Gemini ("nano-banana") render
of the Softmax cog in four kits — the red keeper with a brass lantern and
spyglass, the blue runner with a striped life ring, the green runner with a
canvas backpack and coiled rope, the yellow runner with a signal flag — on
a flat green backdrop. This script keys the backdrop out with an edge flood
fill (so the green runner's kit survives), splits the row into four, crops
each to content, pads to a square and writes 192 px RGBA sprites under the
starter's soldier_<colour>_front.png names, so the viewer, the bundle
script and the tests are untouched:

    python3 scripts/art/split_cog_sheet.py [outdir]

Default outdir is data/.
"""

import os
import sys
from collections import deque

from PIL import Image

SRC = os.path.join(os.path.dirname(__file__), "source", "cogs_sheet.png")
ROLES = ["soldier_red_front.png", "soldier_blue_front.png",
         "soldier_green_front.png", "soldier_yellow_front.png"]
SIZE = 192
TOL = 60  # colour distance from the backdrop that still counts as backdrop


def key_background(img):
    img = img.convert("RGBA")
    w, h = img.size
    px = img.load()
    # median of the border is robust to corner smudges in the render
    border = [px[x, y][:3] for x in range(w) for y in (0, h - 1)] + \
        [px[x, y][:3] for y in range(h) for x in (0, w - 1)]
    bg = tuple(sorted(c[i] for c in border)[len(border) // 2] for i in range(3))

    def near(p):
        return sum((a - b) ** 2 for a, b in zip(p[:3], bg)) ** 0.5 <= TOL

    seen = bytearray(w * h)
    q = deque()
    for x in range(w):
        for y in (0, h - 1):
            q.append((x, y))
    for y in range(h):
        for x in (0, w - 1):
            q.append((x, y))
    while q:
        x, y = q.popleft()
        if x < 0 or y < 0 or x >= w or y >= h or seen[y * w + x]:
            continue
        seen[y * w + x] = 1
        if not near(px[x, y]):
            continue
        px[x, y] = (0, 0, 0, 0)
        q.extend(((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)))
    # soften the keyed edge: fade pixels still tinted toward the backdrop
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a and g > r + 40 and g > b + 40 and abs(g - bg[1]) < 30 and abs(r - bg[0]) < 40:
                px[x, y] = (r, g, b, 0)
    drop_specks(px, w, h)
    return img


def drop_specks(px, w, h, min_area=None):
    """Clears opaque blobs far smaller than a character (corner smudges)."""
    min_area = min_area or w * h // 500
    seen = bytearray(w * h)
    for sy in range(h):
        for sx in range(w):
            if seen[sy * w + sx] or not px[sx, sy][3]:
                continue
            blob, q = [], deque([(sx, sy)])
            seen[sy * w + sx] = 1
            while q:
                x, y = q.popleft()
                blob.append((x, y))
                for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
                    if 0 <= nx < w and 0 <= ny < h and not seen[ny * w + nx] \
                            and px[nx, ny][3]:
                        seen[ny * w + nx] = 1
                        q.append((nx, ny))
            if len(blob) < min_area:
                for x, y in blob:
                    px[x, y] = (0, 0, 0, 0)


def split(img):
    alpha = img.getchannel("A")
    w, h = img.size
    cols = [any(alpha.getpixel((x, y)) for y in range(h)) for x in range(w)]
    runs, start = [], None
    for x, on in enumerate(cols + [False]):
        if on and start is None:
            start = x
        elif not on and start is not None:
            if x - start > 20:
                runs.append((start, x))
            start = None
    # Two neighbours whose kit touches (the keeper's spyglass and the life
    # ring do) merge into one run; cut the widest run at its thinnest
    # column near the proportional split, so a thin wrist inside a kit
    # (the hand holding the lantern) is not mistaken for the boundary.
    while len(runs) < len(ROLES):
        i = max(range(len(runs)), key=lambda k: runs[k][1] - runs[k][0])
        x0, x1 = runs[i]
        mid = (x0 + x1) // 2
        span = (x1 - x0) * 15 // 100
        cut = min(range(mid - span, mid + span), key=lambda x: sum(
            1 for y in range(h) if alpha.getpixel((x, y))))
        runs[i:i + 1] = [(x0, cut), (cut, x1)]
    assert len(runs) == len(ROLES), runs
    out = []
    for x0, x1 in runs:
        part = img.crop((x0, 0, x1, h))
        # a sliver of the neighbour's kit can cross the cut; drop it
        drop_specks(part.load(), part.width, part.height,
                    part.width * part.height // 60)
        part = part.crop(part.getbbox())
        side = max(part.size)
        sq = Image.new("RGBA", (side, side), (0, 0, 0, 0))
        sq.paste(part, ((side - part.width) // 2, side - part.height))
        out.append(sq.resize((SIZE, SIZE), Image.LANCZOS))
    return out


def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else "data"
    os.makedirs(outdir, exist_ok=True)
    for name, sprite in zip(ROLES, split(key_background(Image.open(SRC)))):
        sprite.save(os.path.join(outdir, name))
    print("cog sprites written to", outdir)


if __name__ == "__main__":
    main()
