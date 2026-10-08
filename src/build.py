"""Treasure Map - build.

python build.py <out dir>              the release (Treasure-Map-<ver>.zip)
python build.py <out dir> --tester     the release's Tester build (research details in the normal log, test GUID)
python build.py <out dir> --test N     numbered test build N (log in Logs\\test, test GUID)
  - icons: one 32x32 RGBA8 texture per kind, drawn by icons.py (vector copies of the game's pickup icons), all the same
    height, colored in the kind's color with a dark outline (192-byte texture header + DDS header with DX10
    extension, DXGI 28, one mip)
  - glyphs: 0-9 and / for the counts, one 32x32 texture each
  - core/9ba626afa44a3aa3.patch_0: the core Lua + the textures; <KIND>/...: each option's one-line addon
  - manifest.json, icon.png, options/*.png, README.txt; zip
"""
import json, os, shutil, struct, sys, zipfile
from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import patch_writer

VERSION = '1.0.0'
GUID_RELEASE = '17ea513f-651a-492c-b98d-3103795e8876'
GUID_TEST = 'a7d3c915-2e64-4b8f-9c07-5e1f8b2d64a0'      # Tester and numbered test builds
LUA, TEXTURE = 0xa14e8dfa2cd117e2, 0xcd4238c6a0c69e32
SIZE = 32          # texture side
FILL = 26          # the icon's larger side inside it (the rest is outline and margin)

# kind: (folder, option name, color, color name), in Arsenal (and Mod Options Menu) order
KINDS = [
    ('requisition', 'REQUISITION', 'Requisition Slips', (244, 247, 56), 'requisition yellow'),
    ('common', 'COMMON', 'Common Samples', (93, 255, 162), 'green'),
    ('rare', 'RARE', 'Rare Samples', (255, 151, 64), 'orange'),
    ('super', 'SUPER', 'Super Samples', (255, 114, 211), 'pink'),
    ('medal', 'MEDAL', 'Medals', (255, 221, 31), 'medal yellow'),
    ('credit', 'CREDIT', 'Super Credits', (115, 233, 242), 'Super Credit blue'),
]


def resource_hash(name):
    """The game's 64-bit resource name hash (MurmurHash64A, seed 0)."""
    data = name.encode(); mask, mix = (1 << 64) - 1, 0xC6A4A7935BD1E995
    v = len(data) * mix & mask; end = len(data) // 8 * 8
    for (w,) in struct.iter_unpack('<Q', data[:end]):
        w = w * mix & mask; w ^= w >> 47; v = (v ^ (w * mix & mask)) * mix & mask
    if data[end:]: v = (v ^ int.from_bytes(data[end:], 'little')) * mix & mask
    v ^= v >> 47; v = v * mix & mask; v ^= v >> 47
    return v


assert resource_hash('lua') == LUA and resource_hash('texture') == TEXTURE     # checked against the game's type ids
import art
import icons


def lua_resource(text):
    b = text.encode('utf-8')
    return struct.pack('<II', len(b), 2) + b


def texture_resource(size):
    """340-byte texture header (as the Turret Skull): 192 bytes (0, 0, ffffffff, zeros) + DDS header + DX10."""
    head = bytearray(192); head[8:12] = b'\xff\xff\xff\xff'
    dds = b'DDS ' + struct.pack('<7I', 124, 0x100F, size, size, size * 4, 0, 1) + b'\0' * 44
    dds += struct.pack('<2I4s5I', 32, 4, b'DX10', 0, 0, 0, 0, 0)
    dds += struct.pack('<5I', 0x1000, 0, 0, 0, 0)
    dds += struct.pack('<5I', 28, 3, 0, 1, 0)
    out = bytes(head) + dds
    assert len(out) == 340, len(out)
    return out


def icon(kid, rgb):
    """The kind's marker (icons.py, vector), every one FILL px tall and centered, colored, with a dark outline.
    Returns (RGBA image, quad factor = texture side / icon height, aspect)."""
    big, fill = 4 * SIZE, 4 * FILL
    a = icons.mask(kid, fill)
    w, h = a.size
    mask = Image.new('L', (big, big), 0)
    mask.paste(a, ((big - w) // 2, (big - h) // 2))
    outline = mask.filter(ImageFilter.MaxFilter(9)).filter(ImageFilter.GaussianBlur(1.2))
    img = Image.new('RGBA', (big, big), (0, 0, 0, 0))
    dark = Image.new('RGBA', (big, big), (12, 12, 12, 255)); dark.putalpha(outline.point(lambda p: round(p * 0.9)))
    img = Image.alpha_composite(img, dark)
    body = Image.new('RGBA', (big, big), rgb + (255,)); body.putalpha(mask)
    img = Image.alpha_composite(img, body)
    return img.resize((SIZE, SIZE), Image.LANCZOS), SIZE / FILL, icons.aspect(kid)


FONT = os.path.join(HERE, 'artwork', 'fonts', 'Inter-Bold.otf')   # Inter, SIL Open Font License
GLYPH_H = 22       # digit height inside the 32x32 texture


def glyph(ch):
    """A white character with a dark outline, its digit height GLYPH_H px, centered in a 32x32 texture.
    Returns (image, quad factor = texture side / digit height, advance / digit height)."""
    big = 4 * SIZE
    font = ImageFont.truetype(FONT, 400)
    l, t, r, b = font.getbbox('0')
    scale = 4 * GLYPH_H / (b - t)
    font = ImageFont.truetype(FONT, round(400 * scale))
    l0, t0, r0, b0 = font.getbbox('0')
    l, t, r, b = font.getbbox(ch)
    mask = Image.new('L', (big, big), 0)
    d = ImageDraw.Draw(mask)
    # digits share the baseline of '0'; centered horizontally
    d.text(((big - (r - l)) / 2 - l, (big - (b0 - t0)) / 2 - t0), ch, font=font, fill=255)
    outline = mask.filter(ImageFilter.MaxFilter(11)).filter(ImageFilter.GaussianBlur(1.0))
    img = Image.new('RGBA', (big, big), (0, 0, 0, 0))
    dark = Image.new('RGBA', (big, big), (10, 10, 10, 255)); dark.putalpha(outline.point(lambda p: round(p * 0.85)))
    img = Image.alpha_composite(img, dark)
    white = Image.new('RGBA', (big, big), (255, 255, 255, 255)); white.putalpha(mask)
    img = Image.alpha_composite(img, white)
    adv = 0.62 if ch == '/' else 0.78        # digits at a fixed width so the count doesn't jump around
    return img.resize((SIZE, SIZE), Image.LANCZOS), SIZE / GLYPH_H, adv


def rgba_bytes(img):
    return img.tobytes()   # row 0 at the top, RGBA


def main():
    out, args = sys.argv[1], sys.argv[2:]
    tester = '--tester' in args
    test = int(args[args.index('--test') + 1]) if '--test' in args else None
    full = VERSION + (' Test %d' % test if test else ' (tester)' if tester else '')
    guid = GUID_TEST if (test or tester) else GUID_RELEASE
    if os.path.isdir(out): shutil.rmtree(out)
    os.makedirs(out)
    pkg = os.path.join(out, 'pkg'); os.makedirs(pkg)
    previews = Image.new('RGBA', (SIZE * 6 * 4, SIZE * 4), (60, 60, 60, 255))
    icons_lua, textures = [], []
    for i, (kid, folder, name, rgb, _) in enumerate(KINDS):
        img, quad, aspect = icon(kid, rgb)
        tex_id = resource_hash('mods/chef/treasure_map/icon_' + kid)
        textures.append((tex_id, TEXTURE, texture_resource(SIZE), rgba_bytes(img), b'', 64))
        icons_lua.append("KIND.%s.texture, KIND.%s.quad, KIND.%s.aspect = '%016x', %.4f, %.4f" % (kid, kid, kid, tex_id, quad, aspect))
        previews.alpha_composite(img.resize((SIZE * 4, SIZE * 4), Image.NEAREST), (i * SIZE * 4, 0))
    glyph_lua, sheet = [], Image.new('RGBA', (SIZE * 4 * 11, SIZE * 4), (60, 60, 60, 255))
    for i, ch in enumerate('0123456789/'):
        img, quad, adv = glyph(ch)
        tex_id = resource_hash('mods/chef/treasure_map/glyph_%d' % ord(ch))
        textures.append((tex_id, TEXTURE, texture_resource(SIZE), rgba_bytes(img), b'', 64))
        glyph_lua.append("['%s'] = { texture = '%016x', quad = %.4f, adv = %.2f }" % (ch, tex_id, quad, adv))
        sheet.alpha_composite(img.resize((SIZE * 4, SIZE * 4), Image.NEAREST), (i * SIZE * 4, 0))
    sheet.save(os.path.join(out, 'glyphs_preview.png'))
    icons_lua.append('GLYPHS = {\n  ' + ',\n  '.join(glyph_lua) + '\n}')
    previews.save(os.path.join(out, 'icons_preview.png'))
    core = ''.join(open(os.path.join(HERE, 'lua', f), encoding='utf-8').read() for f in ('head.lua', 'scan.lua', 'body.lua'))
    assert '--@@ICONS@@' in core
    core = core.replace('--@@ICONS@@', '\n'.join(icons_lua))
    core = core.replace("local VERSION = '1.0.0'", "local VERSION = '%s'" % full)
    core = core.replace('local TESTER = false', 'local TESTER = %s' % ('true' if (test or tester) else 'false'))
    core = core.replace('local TEST_BUILD = false', 'local TEST_BUILD = %s' % ('true' if test else 'false'))
    assert ("'%s'" % full) in core
    open(os.path.join(out, 'core.built.lua'), 'w', encoding='utf-8').write(core)

    def write_patch(folder, entries, types):
        d = os.path.join(pkg, folder); os.makedirs(d, exist_ok=True)
        toc, gpu, stream = patch_writer.write(entries, types)
        patch_writer.check(toc, gpu, stream)
        base = os.path.join(d, '9ba626afa44a3aa3.patch_0')
        open(base, 'wb').write(toc); open(base + '.gpu_resources', 'wb').write(gpu); open(base + '.stream', 'wb').write(stream)

    write_patch('core', [(resource_hash('mods/chef/treasure_map'), LUA, lua_resource(core), b'', b'', 64)] + textures,
                [(LUA, 64), (TEXTURE, 64)])
    for kid, folder, name, rgb, color in KINDS:
        addon = ('-- HD2-Addon: mods/chef/treasure_map_%s\n'
                 '-- Treasure Map option: %s (the core reads this flag once a second).\n'
                 "local t = rawget(_G, 'ChefTreasureMapKinds')\n"
                 "if type(t) ~= 'table' then t = {}; rawset(_G, 'ChefTreasureMapKinds', t) end\n"
                 "t.%s = true\n" % (kid, name, kid))
        write_patch(folder, [(resource_hash('mods/chef/treasure_map_' + kid), LUA, lua_resource(addon), b'', b'', 64)], [(LUA, 64)])
    # art: Treasure Map's own (art.py)
    os.makedirs(os.path.join(pkg, 'options'))
    thumb = os.path.join(HERE, 'artwork', 'thumbnail.png')     # the release art (1254x1254, artwork/cards.py), 512 in Arsenal
    if os.path.exists(thumb):
        Image.open(thumb).convert('RGBA').resize((512, 512), Image.LANCZOS).save(os.path.join(pkg, 'icon.png'), optimize=True)
    else:
        art.icon(KINDS).save(os.path.join(pkg, 'icon.png'))
    for kid, folder, name, rgb, color in KINDS:
        art.option(kid, rgb).save(os.path.join(pkg, 'options', 'option_%s.png' % kid))
    opts = [{'Name': 'Treasure Map (core)', 'Description': 'The map markers (one per pickup; pickups of a kind stacked on the same spot share one, with a count) and the loot ledger at the bottom right of the map: how many of each enabled kind are left. Keep this on, then pick the kinds below.',
             'Image': 'icon.png', 'Include': ['core']}]
    for kid, folder, name, rgb, color in KINDS:
        d = 'Marks the %s left in the mission on the tactical map, in %s.' % (name, color)
        opts.append({'Name': name, 'Description': d, 'Image': 'options/option_%s.png' % kid, 'Include': [folder]})
    man = {'Version': 1, 'Guid': guid, 'Name': 'Treasure Map ' + full,
           'Description': 'Marks the medals, samples, Super Credits and Requisition Slips still lying around in the mission on the '
                          'tactical map, each kind in its own color, shows stacked pickups as one marker with a count, and keeps a loot ledger at the bottom right of the map with what is left of each kind. Requires Bingus '
                          'Shared Loader v19 or newer. With Mod Options Menu, each kind gets an opacity slider (TREASURE MAP section).',
           'IconPath': 'icon.png', 'Options': opts}
    open(os.path.join(pkg, 'manifest.json'), 'w').write(json.dumps(man, indent=2))
    shutil.copyfile(os.path.join(HERE, 'README.txt'), os.path.join(pkg, 'README.txt'))
    z = os.path.join(out, 'Treasure-Map-%s.zip' % (VERSION + ('-Test-%d' % test if test else '-Tester' if tester else '')))
    with zipfile.ZipFile(z, 'w', zipfile.ZIP_DEFLATED) as zf:
        for root, _, files in os.walk(pkg):
            for f in sorted(files):
                p = os.path.join(root, f)
                zf.write(p, os.path.relpath(p, pkg))
    print(z, os.path.getsize(z))


if __name__ == '__main__':
    main()
