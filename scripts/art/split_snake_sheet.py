#!/usr/bin/env python3
"""Split the nano-banana snake sheets into the board sprites the viewer draws.

Sources (committed under scripts/art/source/, generated with
gemini-2.5-flash-image per coworld-builder playbooks/art-nanobanana.md):

  snakes_sheet.png  4 rows (amber, teal, violet, lime) x 3 columns
                    (head-up, straight body segment, 90-degree corner).
                    The generator drew row 1's body/corner in teal rather than
                    amber, so the TEAL body/corner double as the shape masters
                    and are re-tinted for the amber row.
  tails_sheet.png   the same style, from which this script takes the APPLE and
                    the grey WRECK (the dead-snake remains).

Derived, deterministically, from those renders -- never drawn from scratch:

  * the three other head facings are the head-up render rotated 90/180/270;
  * the tail is the colourway's own body segment with a rounded taper mask,
    which is what a tail is in this art (the body plate, narrowing).

Outputs (128 px RGBA, committed; CI does not regenerate art):

  data/snake_<colour>_head_u.png   data/snake_<colour>_head_r.png
  data/snake_<colour>_head_d.png   data/snake_<colour>_head_l.png
  data/snake_<colour>_body.png     data/snake_<colour>_corner.png
  data/snake_<colour>_tail.png
  data/food_apple.png              data/wreck.png

Usage:  python3 scripts/art/split_snake_sheet.py
"""

from __future__ import annotations

import colorsys
import os
from collections import deque

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
SOURCE = os.path.join(HERE, "source")
OUT = os.path.join(ROOT, "data")

SIZE = 128
COLOURS = ["amber", "teal", "violet", "lime"]
# Target hue/saturation anchors for the re-tint of the shape masters, matching
# the design note's four colourways.
TINTS = {
    "amber": (0.088, 0.79),
    "teal": (0.478, 0.55),
    "violet": (0.727, 0.51),
    "lime": (0.213, 0.60),
}


def key_background(image: Image.Image, tolerance: int = 60) -> Image.Image:
    """Flood-fill the flat chroma backdrop from the border and make it alpha.

    Flood fill (not a global colour match) so a green pixel *inside* a sprite
    survives -- the lime snake is green.
    """
    image = image.convert("RGBA")
    width, height = image.size
    pixels = image.load()

    border = []
    for x in range(width):
        border.append(pixels[x, 0][:3])
        border.append(pixels[x, height - 1][:3])
    for y in range(height):
        border.append(pixels[0, y][:3])
        border.append(pixels[width - 1, y][:3])
    border.sort()
    key = border[len(border) // 2]

    def near(rgb):
        return (
            abs(rgb[0] - key[0]) <= tolerance
            and abs(rgb[1] - key[1]) <= tolerance
            and abs(rgb[2] - key[2]) <= tolerance
        )

    seen = bytearray(width * height)
    queue = deque()
    for x in range(width):
        for y in (0, height - 1):
            if not seen[y * width + x] and near(pixels[x, y][:3]):
                seen[y * width + x] = 1
                queue.append((x, y))
    for y in range(height):
        for x in (0, width - 1):
            if not seen[y * width + x] and near(pixels[x, y][:3]):
                seen[y * width + x] = 1
                queue.append((x, y))

    while queue:
        x, y = queue.popleft()
        pixels[x, y] = (0, 0, 0, 0)
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            nx, ny = x + dx, y + dy
            if 0 <= nx < width and 0 <= ny < height and not seen[ny * width + nx]:
                if near(pixels[nx, ny][:3]):
                    seen[ny * width + nx] = 1
                    queue.append((nx, ny))
    return image


def components(image: Image.Image, min_area: int = 2500):
    """Opaque connected components, as (x0, y0, x1, y1) boxes."""
    width, height = image.size
    alpha = image.getchannel("A").load()
    seen = bytearray(width * height)
    boxes = []
    for sy in range(height):
        for sx in range(width):
            if seen[sy * width + sx] or alpha[sx, sy] < 24:
                continue
            queue = deque([(sx, sy)])
            seen[sy * width + sx] = 1
            x0 = x1 = sx
            y0 = y1 = sy
            area = 0
            while queue:
                x, y = queue.popleft()
                area += 1
                x0, x1 = min(x0, x), max(x1, x)
                y0, y1 = min(y0, y), max(y1, y)
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    nx, ny = x + dx, y + dy
                    if 0 <= nx < width and 0 <= ny < height:
                        if not seen[ny * width + nx] and alpha[nx, ny] >= 24:
                            seen[ny * width + nx] = 1
                            queue.append((nx, ny))
            if area >= min_area:
                boxes.append((x0, y0, x1 + 1, y1 + 1))
    return boxes


def grid_order(boxes, row_tolerance=60):
    """Boxes sorted into reading order: rows top to bottom, then left to right."""
    rows = []
    for box in sorted(boxes, key=lambda b: b[1]):
        centre = (box[1] + box[3]) / 2
        for row in rows:
            if abs(row[0] - centre) <= row_tolerance:
                row[1].append(box)
                break
        else:
            rows.append((centre, [box]))
    out = []
    for _, row in rows:
        out.append(sorted(row, key=lambda b: b[0]))
    return out


def square(image: Image.Image, size: int = SIZE) -> Image.Image:
    """Pad to a square and resize, keeping the sprite centred."""
    width, height = image.size
    side = max(width, height)
    canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    canvas.paste(image, ((side - width) // 2, (side - height) // 2))
    return canvas.resize((size, size), Image.LANCZOS)


def retint(image: Image.Image, hue: float, saturation: float) -> Image.Image:
    """Re-tint a shape master into another colourway, keeping its shading.

    Value (the baked lighting, rivets and outline) is preserved exactly; only
    hue and saturation move, and near-grey pixels (the screen face, the dark
    outline) are left alone so the cog's visor stays cyan-on-dark.
    """
    out = image.copy()
    pixels = out.load()
    width, height = out.size
    for y in range(height):
        for x in range(width):
            r, g, b, a = pixels[x, y]
            if a == 0:
                continue
            h, s, v = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)
            if s < 0.18 or v < 0.16:
                continue
            nr, ng, nb = colorsys.hsv_to_rgb(hue, min(1.0, s * saturation / max(s, 1e-6) * 0.55 + saturation * 0.45), v)
            pixels[x, y] = (int(nr * 255), int(ng * 255), int(nb * 255), a)
    return out


def taper(image: Image.Image) -> Image.Image:
    """A tail: the body plate narrowed to a rounded point toward the bottom."""
    out = image.copy()
    pixels = out.load()
    width, height = out.size
    cx = width / 2
    for y in range(height):
        t = y / max(1, height - 1)
        half = (0.5 - 0.44 * t * t) * width
        for x in range(width):
            if abs(x + 0.5 - cx) > half:
                pixels[x, y] = (0, 0, 0, 0)
    return out


def main() -> None:
    os.makedirs(OUT, exist_ok=True)

    sheet = key_background(Image.open(os.path.join(SOURCE, "snakes_sheet.png")))
    rows = grid_order(components(sheet))
    rows = [row for row in rows if len(row) >= 3][:4]
    if len(rows) != 4:
        raise SystemExit(f"snakes_sheet.png: expected 4 sprite rows, found {len(rows)}")

    heads = {}
    bodies = {}
    corners = {}
    for index, colour in enumerate(COLOURS):
        row = rows[index]
        heads[colour] = square(sheet.crop(row[0]))
        bodies[colour] = square(sheet.crop(row[1]))
        corners[colour] = square(sheet.crop(row[2]))

    # The generator drew the amber row's body and corner in teal. Re-tint the
    # teal shape master rather than re-running the model.
    hue, saturation = TINTS["amber"]
    bodies["amber"] = retint(bodies["teal"], hue, saturation)
    corners["amber"] = retint(corners["teal"], hue, saturation)

    for colour in COLOURS:
        head = heads[colour]
        head.save(os.path.join(OUT, f"snake_{colour}_head_u.png"))
        head.rotate(-90, expand=False).save(
            os.path.join(OUT, f"snake_{colour}_head_r.png"))
        head.rotate(180, expand=False).save(
            os.path.join(OUT, f"snake_{colour}_head_d.png"))
        head.rotate(90, expand=False).save(
            os.path.join(OUT, f"snake_{colour}_head_l.png"))
        bodies[colour].save(os.path.join(OUT, f"snake_{colour}_body.png"))
        corners[colour].save(os.path.join(OUT, f"snake_{colour}_corner.png"))
        taper(bodies[colour]).save(os.path.join(OUT, f"snake_{colour}_tail.png"))

    tails = key_background(Image.open(os.path.join(SOURCE, "tails_sheet.png")))
    trows = [row for row in grid_order(components(tails)) if len(row) >= 4]
    if not trows:
        raise SystemExit("tails_sheet.png: no sprite row with an apple and a wreck")
    apple_row = trows[0]
    square(tails.crop(apple_row[-1])).save(os.path.join(OUT, "food_apple.png"))
    wreck_row = trows[-1]
    square(tails.crop(wreck_row[-1])).save(os.path.join(OUT, "wreck.png"))

    print(f"wrote {4 * 7 + 2} sprites to {OUT}")


if __name__ == "__main__":
    main()
