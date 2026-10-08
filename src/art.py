"""Treasure Map Arsenal art: an old parchment map with a dotted trail and a red X; the option pictures put that kind's
map marker on the parchment."""
import math, random
import icons
from PIL import Image, ImageDraw, ImageFilter, ImageFont

S = 256
BIG = 4 * S


def glyph(kid, rgb, height):
    """The kind's marker (icons.py), colored, with a dark outline, `height` px tall."""
    a = icons.mask(kid, height)
    w = a.size[0]
    pad = height // 6
    mask = Image.new('L', (w + 2 * pad, height + 2 * pad), 0)
    mask.paste(a, (pad, pad))
    edge = mask.filter(ImageFilter.MaxFilter(2 * (height // 22) + 1)).filter(ImageFilter.GaussianBlur(height / 120))
    out = Image.new('RGBA', mask.size, (0, 0, 0, 0))
    dark = Image.new('RGBA', mask.size, (25, 18, 10, 255)); dark.putalpha(edge)
    out = Image.alpha_composite(out, dark)
    body = Image.new('RGBA', mask.size, tuple(rgb) + (255,)); body.putalpha(mask)
    return Image.alpha_composite(out, body)


def parchment(seed):
    rnd = random.Random(seed)
    img = Image.new('RGBA', (BIG, BIG), (0, 0, 0, 0))
    # torn-edged sheet
    mask = Image.new('L', (BIG, BIG), 0)
    d = ImageDraw.Draw(mask)
    m = BIG * 0.06
    pts = []
    for i in range(80):
        t = i / 80
        side, f = int(t * 4), (t * 4) % 1
        x, y = [(m + f * (BIG - 2 * m), m), (BIG - m, m + f * (BIG - 2 * m)),
                (BIG - m - f * (BIG - 2 * m), BIG - m), (m, BIG - m - f * (BIG - 2 * m))][side]
        j = rnd.uniform(-BIG * 0.012, BIG * 0.012)
        pts.append((x + (j if side in (1, 3) else 0), y + (j if side in (0, 2) else 0)))
    d.polygon(pts, fill=255)
    mask = mask.filter(ImageFilter.GaussianBlur(2))
    paper = Image.new('RGBA', (BIG, BIG), (222, 196, 146, 255))
    # stains and grain
    stains = Image.new('L', (BIG, BIG), 0)
    sd = ImageDraw.Draw(stains)
    for _ in range(40):
        cx, cy, r = rnd.uniform(0, BIG), rnd.uniform(0, BIG), rnd.uniform(BIG * 0.03, BIG * 0.16)
        sd.ellipse((cx - r, cy - r, cx + r, cy + r), fill=rnd.randint(10, 40))
    stains = stains.filter(ImageFilter.GaussianBlur(BIG * 0.03))
    brown = Image.new('RGBA', (BIG, BIG), (120, 80, 40, 255)); brown.putalpha(stains)
    paper = Image.alpha_composite(paper, brown)
    # darker burnt rim
    rim = mask.filter(ImageFilter.GaussianBlur(BIG * 0.04))
    rim = Image.eval(rim, lambda p: 255 - p)
    burnt = Image.new('RGBA', (BIG, BIG), (90, 55, 25, 255)); burnt.putalpha(Image.eval(rim, lambda p: min(255, p * 2)))
    paper = Image.alpha_composite(paper, burnt)
    img.paste(paper, (0, 0), mask)
    # faint grid and a coastline
    d = ImageDraw.Draw(img)
    for i in range(1, 6):
        x = BIG * i / 6
        d.line((x, m * 1.5, x, BIG - m * 1.5), fill=(150, 115, 70, 70), width=3)
        d.line((m * 1.5, x, BIG - m * 1.5, x), fill=(150, 115, 70, 70), width=3)
    coast = []
    for i in range(60):
        a = 2 * math.pi * i / 60
        r = BIG * 0.30 * (1 + 0.12 * math.sin(3 * a + seed) + 0.07 * math.sin(7 * a + 2 * seed))
        coast.append((BIG * 0.5 + r * math.cos(a), BIG * 0.52 + r * math.sin(a) * 0.8))
    d.line(coast + [coast[0]], fill=(110, 75, 40, 160), width=7, joint='curve')
    return img, rnd


def trail(img, pts, color=(120, 30, 20, 255)):
    d = ImageDraw.Draw(img)
    for (x1, y1), (x2, y2) in zip(pts, pts[1:]):
        n = int(math.hypot(x2 - x1, y2 - y1) / 34)
        for i in range(n):
            t0, t1 = i / n, (i + 0.55) / n
            d.line((x1 + (x2 - x1) * t0, y1 + (y2 - y1) * t0, x1 + (x2 - x1) * t1, y1 + (y2 - y1) * t1), fill=color, width=12)


def x_mark(img, cx, cy, r):
    d = ImageDraw.Draw(img)
    for w, col in ((r * 0.42, (60, 10, 5, 255)), (r * 0.28, (200, 30, 25, 255))):
        d.line((cx - r, cy - r, cx + r, cy + r), fill=col, width=int(w))
        d.line((cx - r, cy + r, cx + r, cy - r), fill=col, width=int(w))


def compass(img, cx, cy, r):
    d = ImageDraw.Draw(img)
    col = (95, 60, 30, 230)
    d.ellipse((cx - r, cy - r, cx + r, cy + r), outline=col, width=6)
    for a in range(4):
        ang = a * math.pi / 2
        tip = (cx + r * 1.25 * math.sin(ang), cy - r * 1.25 * math.cos(ang))
        l = (cx + r * 0.25 * math.sin(ang - math.pi / 2), cy - r * 0.25 * math.cos(ang - math.pi / 2))
        rr = (cx + r * 0.25 * math.sin(ang + math.pi / 2), cy - r * 0.25 * math.cos(ang + math.pi / 2))
        d.polygon([tip, l, (cx, cy), rr], fill=(170, 30, 25, 240) if a == 0 else col)


def finish(img):
    shadow = Image.new('RGBA', (BIG, BIG), (0, 0, 0, 0))
    alpha = img.split()[3].filter(ImageFilter.GaussianBlur(BIG * 0.015))
    sh = Image.new('RGBA', (BIG, BIG), (0, 0, 0, 255)); sh.putalpha(Image.eval(alpha, lambda p: p // 2))
    shadow.paste(sh, (int(BIG * 0.012), int(BIG * 0.018)), sh)
    return Image.alpha_composite(shadow, img).resize((S, S), Image.LANCZOS)


def icon(kinds):
    img, rnd = parchment(3)
    trail(img, [(BIG * .2, BIG * .78), (BIG * .34, BIG * .6), (BIG * .3, BIG * .44), (BIG * .5, BIG * .36), (BIG * .66, BIG * .3)])
    x_mark(img, BIG * .72, BIG * .27, BIG * .07)
    compass(img, BIG * .78, BIG * .76, BIG * .06)
    # a few of the markers scattered on the map
    for i, (kid, folder, name, rgb, _) in enumerate(kinds):
        g = glyph(kid, rgb, int(BIG * 0.10))
        x, y = [(.17, .2), (.47, .62), (.6, .78), (.12, .48), (.43, .16), (.86, .5)][i]
        img.alpha_composite(g, (int(BIG * x - g.size[0] / 2 + BIG * .05), int(BIG * y - g.size[1] / 2 + BIG * .03)))
    return finish(img)


def option(kid, rgb):
    img, rnd = parchment(int(sum(rgb)) % 17)
    trail(img, [(BIG * .16, BIG * .82), (BIG * .3, BIG * .7), (BIG * .38, BIG * .72)])
    compass(img, BIG * .8, BIG * .2, BIG * .055)
    g = glyph(kid, rgb, int(BIG * 0.44))
    img.alpha_composite(g, (int(BIG * .52 - g.size[0] / 2), int(BIG * .5 - g.size[1] / 2)))
    return finish(img)
