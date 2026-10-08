"""Treasure Map marker icons, drawn as vector shapes (copies of the game's own pickup icons, re-rendered cleanly).
Each shape is laid out on a 36-unit-high grid (y down) and rendered at any height with 4x supersampling.
mask(kind, height) -> 'L' image: 255 = the icon's body, 0 = empty (cut-outs show the map through)."""
import math
from PIL import Image, ImageDraw

GRID = 36
WIDTH = {'medal': 26, 'common': 36, 'rare': 36, 'super': 36, 'credit': 36, 'requisition': 36}


def octagon(cx, cy, rx, ry):
    return [(cx + rx * math.sin(math.radians(45 * k)), cy - ry * math.cos(math.radians(45 * k))) for k in range(8)]


def ellipse(d, cx, cy, r, fill):
    d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=fill)


def draw_medal(d):
    # ribbons above and below: two triangles meeting in the middle
    for top in (True, False):
        def p(x, y): return (x, y if top else GRID - y)
        d.polygon([p(5, 0), p(8.6, 0), p(13, 1.6), p(17.4, 0), p(21, 0), p(21, 5), p(13, 1.9), p(5, 5)], fill=255)
    d.polygon(octagon(13, 17.8, 13, 12.9), fill=255)
    # the skull, cut out
    d.polygon([(9.5, 10.6), (16.5, 10.6), (19, 12.6), (19, 16.8), (20, 17.6), (20, 21.2), (18.6, 22.6), (16.4, 22.6),
               (16.4, 25.6), (9.6, 25.6), (9.6, 22.6), (7.4, 22.6), (6, 21.2), (6, 17.6), (7, 16.8), (7, 12.6)], fill=0)
    ellipse(d, 9.7, 19.2, 1.75, 255)
    ellipse(d, 16.3, 19.2, 1.75, 255)
    d.polygon([(12.2, 21.1), (13.8, 21.1), (13.8, 22.8), (12.2, 22.8)], fill=255)
    d.rectangle((11.7, 24.2, 12.3, 25.6), fill=255)
    d.rectangle((13.7, 24.2, 14.3, 25.6), fill=255)


def draw_common(d):
    ellipse(d, 18, 18, 18, 255)
    d.rectangle((15.2, 0, 20.4, 36), fill=0)


def draw_rare(d):
    d.rectangle((0, 0, 36, 36), fill=255)
    d.rectangle((0, 15, 21, 21), fill=0)
    d.rectangle((15, 21, 21, 36), fill=0)


def draw_super(d):
    d.rectangle((0, 0, 36, 36), fill=255)
    d.rectangle((15, 0, 21, 36), fill=0)
    d.rectangle((0, 15, 36, 21), fill=0)


def draw_credit(d):
    d.rectangle((0, 0, 36, 36), fill=255)
    d.polygon([(15, 4.2), (22.8, 4.2), (22.8, 13), (15.9, 13), (15.9, 19.5), (8, 19.5), (8, 11.2)], fill=0)
    d.polygon([(21, 16.3), (28.8, 16.3), (28.8, 25.2), (21.9, 32), (14, 32), (14, 23), (21, 23)], fill=0)


def draw_requisition(d):
    d.rectangle((0, 0, 36, 36), fill=255)
    d.rectangle((9, 4, 13, 33), fill=0)                                                   # stem
    d.rectangle((9, 4, 20, 20), fill=0)                                                   # bowl
    d.ellipse((12, 4, 28.2, 20), fill=0)
    d.rectangle((13, 8, 20, 16.2), fill=255)                                              # its hole
    d.ellipse((15.8, 8, 24.2, 16.2), fill=255)
    d.rectangle((13, 8, 15.8, 16.2), fill=255)
    d.polygon([(19.6, 19), (24.6, 19), (28.6, 33), (23.6, 33)], fill=0)                  # leg


DRAW = {'medal': draw_medal, 'common': draw_common, 'rare': draw_rare, 'super': draw_super, 'credit': draw_credit,
        'requisition': draw_requisition}


def mask(kind, height):
    ss = 4
    scale = height * ss / GRID
    w = WIDTH[kind]
    img = Image.new('L', (max(1, round(w * scale)), round(GRID * scale)), 0)
    d = ImageDraw.Draw(img)

    class Scaled:
        def polygon(self, pts, fill): d.polygon([(x * scale, y * scale) for x, y in pts], fill=fill)
        def rectangle(self, box, fill):
            x0, y0, x1, y1 = box
            d.rectangle((x0 * scale, y0 * scale, x1 * scale - 1, y1 * scale - 1), fill=fill)
        def ellipse(self, box, fill):
            x0, y0, x1, y1 = box
            d.ellipse((x0 * scale, y0 * scale, x1 * scale, y1 * scale), fill=fill)
    DRAW[kind](Scaled())
    return img.resize((max(1, round(w * height / GRID)), height), Image.LANCZOS)


def aspect(kind):
    return WIDTH[kind] / GRID
