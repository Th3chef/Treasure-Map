"""Treasure Map release art: the hero scene (a tactical map with the mod's markers and the loot ledger, lying on an old
parchment map). hero(W, H, cx, cy, r) -> RGBA image; the text is added by the HTML cards (cards.py)."""
import math, os, random, sys
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont
from scipy.ndimage import gaussian_filter

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import icons

FONT = os.path.join(HERE, 'fonts', 'Inter-Bold.otf')   # Inter, SIL Open Font License
RGB = {'requisition': (244, 247, 56), 'common': (93, 255, 162), 'rare': (255, 151, 64), 'super': (255, 114, 211),
       'medal': (255, 221, 31), 'credit': (115, 233, 242)}
ORDER = ['requisition', 'common', 'rare', 'super', 'medal', 'credit']


def noise(w, h, sigma, seed):
    rnd = np.random.default_rng(seed)
    a = gaussian_filter(rnd.standard_normal((h, w)), sigma)
    return (a - a.min()) / (a.max() - a.min())


def parchment(W, H, seed=7):
    n1, n2 = noise(W, H, max(W, H) / 14, seed), noise(W, H, max(W, H) / 60, seed + 1)
    grain = noise(W, H, 1.2, seed + 2)
    base = np.array([196, 160, 104], float)
    t = (0.55 * n1 + 0.3 * n2 + 0.15 * grain)[..., None]
    img = base * (0.62 + 0.55 * t)
    # burnt, darker edges (vignette)
    yy, xx = np.mgrid[0:H, 0:W]
    d = np.maximum(np.abs(xx / W - 0.5) * 2, np.abs(yy / H - 0.5) * 2)
    img *= (1 - 0.55 * np.clip((d - 0.55) / 0.45, 0, 1) ** 1.6)[..., None]
    out = Image.fromarray(np.clip(img, 0, 255).astype(np.uint8)).convert('RGBA')
    d = ImageDraw.Draw(out)
    # old map ink: a faint grid, a coastline and a dotted trail to a red X (kept faint: the tactical map is the hero)
    ink = (92, 58, 28, 70)
    step = max(W, H) / 9
    for i in range(1, 10):
        d.line((i * step, 0, i * step, H), fill=ink, width=2)
        d.line((0, i * step, W, i * step), fill=ink, width=2)
    rnd = random.Random(seed)
    return out, rnd


def terrain(size, seed=3):
    """The in-game tactical map's look: dark olive ground, lighter patches, contour lines."""
    h = noise(size, size, size / 9, seed) * 0.75 + noise(size, size, size / 30, seed + 1) * 0.25
    patches = noise(size, size, size / 18, seed + 2)
    base = np.array([44, 48, 42], float)
    img = base * (0.75 + 0.6 * h[..., None])
    img += (np.array([20, 24, 14]) * np.clip((patches - 0.55) * 4, 0, 1)[..., None])
    # contours
    f = (h * 14) % 1.0
    line = np.clip(1 - np.abs(f - 0.5) * 2 / 0.06, 0, 1) * 0 + (np.minimum(f, 1 - f) < 0.035)
    img += line[..., None] * np.array([26, 28, 22])
    # roads / rivers: a couple of light curves
    out = Image.fromarray(np.clip(img, 0, 255).astype(np.uint8)).convert('RGBA')
    d = ImageDraw.Draw(out)
    rnd = random.Random(seed)
    for k in range(3):
        pts, x, y, a = [], rnd.uniform(0, size), 0, rnd.uniform(1.2, 1.9)
        for i in range(60):
            pts.append((x, y)); a += rnd.uniform(-0.25, 0.25); x += math.cos(a) * size / 40; y += math.sin(a) * size / 40
        d.line(pts, fill=(120, 116, 96, 120), width=max(2, size // 300), joint='curve')
    # a grid like the game's map
    for i in range(1, 8):
        p = size * i / 8
        d.line((p, 0, p, size), fill=(255, 255, 255, 14), width=max(1, size // 700))
        d.line((0, p, size, p), fill=(255, 255, 255, 14), width=max(1, size // 700))
    return out


def marker(kid, height, alpha=255):
    """The mod's marker as drawn in game (icons.py + a dark outline), `height` px tall."""
    a = icons.mask(kid, height)
    w = a.size[0]
    pad = max(2, height // 5)
    m = Image.new('L', (w + 2 * pad, height + 2 * pad), 0)
    m.paste(a, (pad, pad))
    edge = m.filter(ImageFilter.MaxFilter(2 * max(1, height // 9) + 1)).filter(ImageFilter.GaussianBlur(height / 40))
    out = Image.new('RGBA', m.size, (0, 0, 0, 0))
    dark = Image.new('RGBA', m.size, (12, 12, 12, 255)); dark.putalpha(edge.point(lambda p: p * 0.9 * alpha / 255))
    out = Image.alpha_composite(out, dark)
    body = Image.new('RGBA', m.size, RGB[kid] + (255,)); body.putalpha(m.point(lambda p: p * alpha / 255))
    return Image.alpha_composite(out, body)


def outlined_text(img, xy, s, size, rgb, alpha=255, anchor='lm'):
    font = ImageFont.truetype(FONT, int(size))
    m = Image.new('L', img.size, 0)
    ImageDraw.Draw(m).text(xy, s, font=font, fill=255, anchor=anchor)
    edge = m.filter(ImageFilter.MaxFilter(2 * max(1, int(size) // 10) + 1)).filter(ImageFilter.GaussianBlur(size / 50))
    dark = Image.new('RGBA', img.size, (10, 10, 10, 255)); dark.putalpha(edge.point(lambda p: p * 0.85 * alpha / 255))
    img.alpha_composite(dark)
    col = Image.new('RGBA', img.size, rgb + (255,)); col.putalpha(m.point(lambda p: p * alpha / 255))
    img.alpha_composite(col)


# markers in map-space (0..1 of the map's diameter), kind, stack count
PICKUPS = [
    (0.30, 0.27, 'medal', 1), (0.63, 0.20, 'requisition', 1), (0.74, 0.40, 'common', 1), (0.20, 0.52, 'common', 1),
    (0.47, 0.44, 'rare', 1), (0.58, 0.63, 'medal', 3), (0.36, 0.70, 'credit', 2), (0.80, 0.62, 'super', 1),
    (0.50, 0.85, 'common', 1), (0.15, 0.36, 'requisition', 1), (0.86, 0.47, 'medal', 1), (0.42, 0.14, 'credit', 1),
    (0.28, 0.86, 'rare', 1), (0.68, 0.80, 'common', 1),
]
LEDGER = [('requisition', '2'), ('common', '4'), ('rare', '2'), ('super', '1'), ('medal', '6'), ('credit', '3')]


def tactical_map(r):
    """The round tactical map, radius r, with its markers. Returns RGBA (2r+frame)."""
    D = 2 * r
    t = terrain(D)
    m = Image.new('L', (D, D), 0)
    ImageDraw.Draw(m).ellipse((0, 0, D - 1, D - 1), fill=255)
    m = m.filter(ImageFilter.GaussianBlur(1))
    disc = Image.new('RGBA', (D, D), (0, 0, 0, 0)); disc.paste(t, (0, 0), m)
    # a darker rim inside the frame
    yy, xx = np.mgrid[0:D, 0:D]
    rr = np.hypot(xx - r, yy - r) / r
    shade = np.clip((rr - 0.78) / 0.22, 0, 1) * 0.45
    arr = np.array(disc).astype(float)
    arr[..., :3] *= (1 - shade)[..., None]
    disc = Image.fromarray(arr.astype(np.uint8))
    pad = r // 10
    out = Image.new('RGBA', (D + 2 * pad, D + 2 * pad), (0, 0, 0, 0))
    # drop shadow
    sh = Image.new('L', out.size, 0)
    ImageDraw.Draw(sh).ellipse((pad, pad + r * 0.03, pad + D, pad + D + r * 0.03), fill=200)
    sh = sh.filter(ImageFilter.GaussianBlur(r / 22))
    shadow = Image.new('RGBA', out.size, (0, 0, 0, 255)); shadow.putalpha(sh)
    out.alpha_composite(shadow)
    out.alpha_composite(disc, (pad, pad))
    d = ImageDraw.Draw(out)
    fw = max(3, r // 110)
    d.ellipse((pad - fw, pad - fw, pad + D + fw, pad + D + fw), outline=(214, 208, 184, 255), width=fw)
    # your helldiver at the center: the game's yellow arrow
    cx, cy, s = pad + r * 0.98, pad + r * 1.06, r * 0.05
    d.polygon([(cx, cy - s), (cx + s * 0.7, cy + s * 0.75), (cx, cy + s * 0.4), (cx - s * 0.7, cy + s * 0.75)], fill=(255, 231, 16, 255),
              outline=(20, 20, 20, 255))
    h = int(r * 0.095)
    for x, y, kid, n in PICKUPS:
        g = marker(kid, h)
        px, py = pad + x * D, pad + y * D
        out.alpha_composite(g, (int(px - g.size[0] / 2), int(py - g.size[1] / 2)))
        if n > 1:
            outlined_text(out, (px + h * 0.42, py + h * 0.38), str(n), h * 0.62, RGB[kid])
    return out


def ledger(scale):
    """The loot ledger panel as drawn in game (rows: icon + how many are left), `scale` px per game px."""
    pad, row, icon, th = 7 * scale, 19 * scale, 13 * scale, 12 * scale
    font = ImageFont.truetype(FONT, int(th * 1.25))
    width = max(font.getbbox(t)[2] for _, t in LEDGER)
    W = int(pad * 2 + icon + 6 * scale + width + 4 * scale + icon * 0.9)
    H = int(pad * 2 + row * len(LEDGER))
    img = Image.new('RGBA', (W, H), (14, 11, 8, 150 * 255 // 255))
    d = ImageDraw.Draw(img)
    e = max(1, int(scale))
    d.rectangle((0, 0, W - 1, H - 1), outline=(205, 175, 120, 255), width=e)
    for i, (kid, t) in enumerate(LEDGER):
        y = pad + row * (i + 0.5)
        g = marker(kid, int(icon))
        img.alpha_composite(g, (int(pad + icon / 2 - g.size[0] / 2), int(y - g.size[1] / 2)))
        outlined_text(img, (pad + icon + 6 * scale, y), t, th * 1.25, (255, 255, 255))
    return img


def hero(W, H, cx, cy, r, ledger_scale=None, seed=7):
    img, _ = parchment(W, H, seed)
    m = tactical_map(r)
    pad = (m.size[0] - 2 * r) // 2
    img.alpha_composite(m, (int(cx - r - pad), int(cy - r - pad)))
    s = ledger_scale or r / 224 * 1.0
    L = ledger(s)
    # bottom right, just outside the map (as in game: aligned with the bottom of the map's frame)
    lx = int(cx + r + 8 * s)
    ly = int(cy + r - L.size[1])
    sh = Image.new('RGBA', L.size, (0, 0, 0, 120))
    img.alpha_composite(sh.filter(ImageFilter.GaussianBlur(4)), (lx + int(3 * s), ly + int(4 * s)))
    img.alpha_composite(L, (lx, ly))
    return img


if __name__ == '__main__':
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, 'hero_test.png')
    hero(1600, 1000, 640, 500, 420).save(out)
    print(out)
