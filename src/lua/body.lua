
-- ======================================================================================================
-- Where the game keeps things
-- ======================================================================================================
-- RVAs on the build these were read from (game.dll SHA-256 2E2C3B7C..., the 2026-09-24 patch)
local KNOWN = {
  sha = '2E2C3B7C2500646DADD5F2B4C6E0504DBB7E7896139F64CDDC0D1813C718F51E',
  hud = 54973752, rewards = 53635432, loot = 53635016, rewards_at = 53635872, loot_at = 53635880,
}
-- The code that loads each address ('??' = any byte; the address is the end of the 4-byte RIP displacement at
-- disp_at plus its value). Several per item; the ones that match exactly once must agree. On top of these, the
-- loads found in the current build are remembered in TreasureMap.cache for the next game update.
local function rip3(list) local t = {} for i, p in ipairs(list) do t[i] = { p = p, disp_at = 3 } end return t end
local PATTERNS = {
  hud = { { p = 'c780????????01000000488b0d????????4885c9', disp_at = 13 } },
  rewards = rip3({ '488b0d????????418bd4448b9128040000448b8920040000', '488b0d????????833c81010f84????????488b05????????',
                   '488b0d????????448b4708e8????????8b4f08e8????????' }),
  loot = rip3({ '488b05????????4c896424684533e48b481485c90f84c100', '488b05????????448b4030448b4838440fafcb418d70ff45',
                '488b05????????4c69c1b8010000488b48404c8945c0488b' }),
  rewards_at = rip3({ '488b0d????????448b4130448b4938440fafc8418d70ff45', '488b15????????8bcd448b4230448b4a38440fafcb458d70',
                      '488b15????????33c9448b4230448b4a38440fafcb418d68' }),
  loot_at = rip3({ '488b05????????418bcf448b4030448b4838440fafcf418d', '488b1d????????4533c0448b5330448b5b38440fafd8458d',
                   '488b2d????????7448448b553033c9448b5d38440fafd841' }),
}
local NAMES = { 'hud', 'rewards', 'loot', 'rewards_at', 'loot_at' }
local LEARN = { 'rewards', 'loot', 'rewards_at', 'loot_at' }
-- structure offsets (not scanned)
local LISTS = {
  rewards = { count = 12, list = 1072, inline = true, slots = 64, map = 40, recs = 80, stride = 12 },
  loot = { count = 16, list = 64, inline = false, slots = 128, map = 40, recs = 88, stride = 32 },
}
local VIEW = 4125032                  -- the tactical map inside the HUD manager
local V_FROM, V_SPAN = 288, 118       -- center x/y +288/+292, pan x/y +304/+308, zoom +328, open flag +405
local FRAME, F_FROM, F_SPAN = 10464, 36, 124   -- its frame: size +36/+40, shown +84, scale +100, screen x/y +148/+156
local ROW_OWNER = 8                   -- an owner row: type hash +0, owner id +8

local L
local function resolve_layout()
  local t0 = os.clock()
  local game = K32.TmGetModuleHandleA('game.dll')
  if game == nil then error('game.dll not loaded', 0) end
  local info = module_info(game)
  assert(info.code, 'no code section')
  local key = string.format('%08x-%08x-%08x', info.stamp, info.image, info.code.size)
  local cache = cache_load()
  local found
  if cache and cache.key == key and type(cache.rva) == 'table' then
    found, session.layout = cache.rva, 'cached for this game build'
  else
    local sha = file_sha256(game)
    local text, rva = code_text(game, info)
    -- the patterns (baked + remembered from the last build), item by item
    local by_pattern, why = {}, {}
    for _, name in ipairs(NAMES) do
      local pats = {}
      for _, p in ipairs(PATTERNS[name] or {}) do pats[#pats + 1] = p end
      for _, p in ipairs(cache and cache.learned and cache.learned[name] or {}) do pats[#pats + 1] = p end
      local ok, v = pcall(resolve_item, text, rva, pats, name)
      if ok then by_pattern[name] = v else why[#why + 1] = tostring(v) end
    end
    if sha == KNOWN.sha then
      found = {}
      for _, name in ipairs(NAMES) do found[name] = KNOWN[name] end
      local agree = 0
      for _, name in ipairs(NAMES) do if by_pattern[name] == KNOWN[name] then agree = agree + 1 end end
      session.layout = string.format('built-in (known game build; the code patterns agree on %d of %d)', agree, #NAMES)
    else
      if #why > 0 then error(table.concat(why, '; '), 0) end
      found, session.layout = by_pattern, 'found in the game code (new game build)'
    end
    local wanted = {}
    for _, name in ipairs(LEARN) do wanted[name] = found[name] end
    local learned = learn(text, rva, wanted)
    text = nil
    cache_save({ key = key, sha = sha, rva = found, learned = learned })
  end
  local A = { base = tonumber(ffi.cast('uintptr_t', game)) }
  for _, name in ipairs(NAMES) do A[name] = A.base + found[name] end
  session.scan_seconds = os.clock() - t0
  return A
end

-- ======================================================================================================
-- The six kinds (each its own option). Type hashes: the pickups' entity types, as stored (byte-reversed).
-- ======================================================================================================
local function type_bytes(h) return (h:gsub('..', function(x) return string.char(tonumber(x, 16)) end)):reverse() end
-- every marker the same size on the map (pixels at the map's scale 1)
local SIZE = 13
local KINDS = {                       -- in Arsenal and Mod Options Menu order
  { id = 'requisition', name = 'Requisition Slips', list = 'rewards', layer = 20, rgb = { 244, 247, 56 },
    types = { '6b72305013c2833f' } },
  { id = 'common', name = 'Common Samples', list = 'loot', layer = 21, rgb = { 93, 255, 162 },
    types = { '307e09e7698881ba', '4932cbf33cd47ef9', '4c63119f69165321', '5016ee397fdcfb6c', '64b49b9d8a445266',
              '700e9500e95541bf', '86f3cb87d97942b4', '92bcc263e751bd45', 'a2414ed6e129c19f', 'b39fcf5c73d5c383',
              'beb2a0f09e36bf72', 'd463836441cd0ba7', 'e4eeb96023df6a99' } },
  { id = 'rare', name = 'Rare Samples', list = 'loot', layer = 22, rgb = { 255, 151, 64 },
    types = { '8208ea6cb095be54', 'ad972a2e815a49aa', 'bd30758426ed2566', 'defe062c2567c23d' } },
  { id = 'super', name = 'Super Samples', list = 'loot', layer = 23, rgb = { 255, 114, 211 },
    types = { '9d4935fa69b6b41a', 'b4d6f2f83bde45a9' } },
  { id = 'medal', name = 'Medals', list = 'rewards', layer = 24, rgb = { 255, 221, 31 },
    types = { '147bd99513726f88' } },
  { id = 'credit', name = 'Super Credits', list = 'rewards', layer = 25, rgb = { 115, 233, 242 },
    types = { '818603ed54533506' } },
}
local KIND = {}
for _, k in ipairs(KINDS) do KIND[k.id] = k end
local GLYPHS
--@@ICONS@@
local KIND_OF = {}
for _, k in ipairs(KINDS) do
  k.opacity, k.on, k.points, k.n = 1, false, {}, 0
  for _, h in ipairs(k.types) do KIND_OF[type_bytes(h)] = k end
end

-- options: each option addon sets ChefTreasureMapKinds[<kind>] = true (read once a second; load order is free)
local any_on = false
local wants = { rewards = false, loot = false }
local function poll_options()
  local t = rawget(_G, 'ChefTreasureMapKinds')
  any_on, wants.rewards, wants.loot = false, false, false
  for _, k in ipairs(KINDS) do
    k.on = type(t) == 'table' and t[k.id] == true
    if k.on then any_on = true; wants[k.list] = true end
  end
end

-- Mod Options Menu (optional): an opacity slider per installed kind, in the TREASURE MAP section
local menu_state, dirty = 'not looked for yet', true
local function link_menu()
  local menu = rawget(_G, 'ModOptionsMenu')
  if type(menu) ~= 'table' or menu.api ~= 1 or type(menu.register_option) ~= 'function' then
    menu_state = 'Mod Options Menu not installed (every kind at 100%)'
    return false
  end
  poll_options()
  local added = 0
  for _, k in ipairs(KINDS) do
    if k.on and not k.menu then
      local id = 'treasure_map.' .. k.id .. '.opacity'
      local ok, yes = pcall(menu.register_option, id, {
        type = 'slider', mod = 'Treasure Map', label = k.name .. ' Opacity', min = 0, max = 100, step = 5, default = 100,
        description = 'How solid the ' .. k.name .. ' markers on the tactical map are, in percent (0 hides them).' })
      if ok and yes then
        k.menu, added = true, added + 1
        local function apply(v) if type(v) == 'number' then k.opacity = math.max(0, math.min(100, v)) / 100; dirty = true end end
        local got, value = pcall(menu.get, id)
        if got then apply(value) end
        pcall(menu.on_change, id, apply)
      end
    end
  end
  menu_state = 'Mod Options Menu: ' .. added .. ' slider(s)'
  return true
end

-- ======================================================================================================
-- The pickup lists. Each entry points at the pickup's owner row (type hash +0, owner id +8). A list is read four
-- times a second while the map is open; its rows only when the entries changed, all in one read.
-- ======================================================================================================
local lists = {
  rewards = { name = 'rewards', raw = nil, rows = {}, offset = 0 },
  loot = { name = 'loot', raw = nil, rows = {}, offset = 7 },        -- (offset: the two lists are read on different frames)
}
local known_rows = {}                 -- identity (entry + type + owner id) -> row, kept while the pickup is listed

local function scan_list(st)
  local spec = LISTS[st.name]
  stats.list_scans = stats.list_scans + 1
  local m = read_ptr(L[st.name])
  if not m then st.ok = false; return false end
  if not fetch(m, 24) then st.ok = false; return false end
  local count = b32(spec.count)
  local block = spec.inline and (m + spec.list) or nil
  if count > spec.slots then st.ok = false; note(st.name .. ' list', 'count ' .. count .. ' (too many)'); return false end
  if not spec.inline then
    if not fetch(m + spec.list, 8) then st.ok = false; return false end
    block = bptr(0)
  end
  local raw = ''
  if count > 0 then
    if not block or not fetch(block, count * 8) then st.ok = false; return false end
    raw = bstr(0, count * 8)
  end
  st.ok, st.count = true, count
  if raw == st.raw then return true end
  -- the entries changed: read the owner rows they point at, in one read when they are close together
  st.raw = raw
  local ptrs, lo, hi = {}, math.huge, 0
  for i = 0, count - 1 do
    ffi.copy(BUF, raw:sub(i * 8 + 1, i * 8 + 8), 8)
    local p = bptr(0)
    ptrs[i + 1] = p or false
    if p then lo, hi = math.min(lo, p), math.max(hi, p) end
  end
  local span = hi - lo + 16
  local bulk = hi > 0 and span <= 65536 and fetch(lo, span) and bstr(0, span) or nil
  local rows = {}
  for i = 1, count do
    local p = ptrs[i]
    local head = p and (bulk and bulk:sub(p - lo + 1, p - lo + 16) or read_string(p, 16)) or nil
    if head then
      local id = raw:sub(i * 8 - 7, i * 8) .. head
      local r = known_rows[id]
      if not r then
        r = { id = id, kind = KIND_OF[head:sub(1, 8)], owner = su32_at(head, ROW_OWNER) }
        known_rows[id] = r
      end
      rows[#rows + 1] = r
    end
  end
  -- forget rows no longer listed
  local keep = {}
  for _, r in ipairs(rows) do keep[r.id] = true end
  for _, other in pairs(lists) do if other ~= st then for _, r in ipairs(other.rows) do keep[r.id] = true end end end
  for id in pairs(known_rows) do if not keep[id] then known_rows[id] = nil end end
  st.rows, st.located = rows, false
  dirty = true
  return true
end

-- Positions: the list's position manager maps owner id -> record (x, y at +0/+4). Its slot table and the records
-- needed are each read in one go and the lookups are done here, straight out of the read buffer (no copies), not
-- with a read per probe. Only a position that actually changed asks for a redraw.
local want = {}                       -- row -> record index (reused)
local function locate(st)
  local spec = LISTS[st.name]
  local m = read_ptr(L[st.name .. '_at'])
  if not m or not fetch(m + spec.map, 20) then return false end
  local slots_at, cap, empty, mult = bptr(0), b32(8), b32(12), b32(16)
  if not slots_at or cap == 0 or cap > 131072 or bit.band(cap, cap - 1) ~= 0 then note('positions', 'map header not usable (capacity ' .. cap .. ')'); return false end
  local recs = read_ptr(m + spec.recs)
  if not recs or not fetch(slots_at, cap * 8) then return false end
  local mlo = mult % 65536
  local mhi = (mult - mlo) / 65536
  local top, changed = -1, false
  for r in pairs(want) do want[r] = nil end
  for _, r in ipairs(st.rows) do
    if r.kind and r.kind.on then
      local key = r.owner
      local hash = (key * mlo + (key * mhi % 65536) * 65536) % 4294967296
      local idx
      for i = 0, math.min(cap, 256) - 1 do
        local o = bit.band(hash + i, cap - 1) * 8
        local k = b32(o)
        if k == key then idx = b32(o + 4); break end
        if k == empty then break end
      end
      stats.lookups = stats.lookups + 1
      if idx and idx ~= 4294967295 then want[r] = idx; if idx > top then top = idx end
      elseif r.x then r.x, changed = nil, true end
    end
  end
  if top >= 0 then
    local stride = spec.stride
    local bulk = (top + 1) * stride <= 262144 and fetch(recs, (top + 1) * stride)
    for r, idx in pairs(want) do
      local x, y
      if bulk then x, y = bf32(idx * stride), bf32(idx * stride + 4)
      elseif fetch(recs + idx * stride, 8) then x, y = bf32(0), bf32(4) end
      if x ~= r.x or y ~= r.y then
        r.x, r.y, changed = x, y, true
        if x and not r.x0 then r.x0, r.y0 = x, y end
      end
    end
  end
  st.located = true
  if changed then dirty = true end
  return true
end

-- ======================================================================================================
-- The tactical map's view, read only while it is open (two reads)
-- ======================================================================================================
local view = { cx = 0, cy = 0, px = 0, py = 0, zoom = 0, x = 0, y = 0, w = 0, h = 0, scale = 0, shown = 0 }
local function read_view(hud)
  if not fetch(hud + VIEW + V_FROM, V_SPAN) then return false end
  local cx, cy, px, py, zoom = bf32(0), bf32(4), bf32(16), bf32(20), bf32(40)
  if not fetch(hud + VIEW + FRAME + F_FROM, F_SPAN) then return false end
  local w, h, shown, scale, x, y = bf32(0), bf32(4), bf32(48), bf32(64), bf32(112), bf32(120)
  if not (cx and cy and zoom and w and h and shown and scale and x and y) then return false end
  local v = view
  if v.cx ~= cx or v.cy ~= cy or v.px ~= (px or 0) or v.py ~= (py or 0) or v.zoom ~= zoom or v.x ~= x or v.y ~= y
     or v.w ~= w or v.h ~= h or v.scale ~= scale or v.shown ~= shown then
    v.cx, v.cy, v.px, v.py, v.zoom, v.x, v.y, v.w, v.h, v.scale, v.shown = cx, cy, px or 0, py or 0, zoom, x, y, w, h, scale, shown
    dirty = true
  end
  return true
end

-- ======================================================================================================
-- Drawing: one screen GUI per kind (and per digit) in the game's overlay world. Each GUI has its own
-- copy of the game's UI material, with that kind's icon bound to it; icons are bitmaps, kept between frames and only
-- moved, added or removed when something changed.
-- ======================================================================================================
local A, W, G, V2, V3, C, ID, MAT
local UI_MATERIAL, SLOT = 'e2d6ed90906c1e8b', '3aa8b87e00000000'   -- content/ui/shared/misc/yellow_logo, its texture slot
local gui = { world = nil, list = {}, state = 'not needed yet', next_check = 0, icons = nil, update = nil }
local function api_ok()
  if A then return true end
  if type(SR) ~= 'table' then return false end
  local a, w, g = SR.Application, SR.World, SR.Gui
  if not (a and a.worlds and a.main_world and a.can_get and w and w.create_screen_gui and g and g.bitmap and g.destroy_bitmap
          and g.triangle and g.destroy_triangle and g.material and SR.Material and SR.Material.set_texture and SR.Vector2
          and SR.Vector3 and SR.Color and SR.IdString64 and SR.IdString64.from_hex) then
    gui.state = 'this game version lacks a GUI function'; return false
  end
  A, W, G, V2, V3, C, ID, MAT = a, w, g, SR.Vector2, SR.Vector3, SR.Color, SR.IdString64, SR.Material
  gui.update = type(G.update_bitmap) == 'function'
  return true
end
local function loaded(kind, hexid)
  local ok, v = pcall(ID.from_hex, hexid)
  if not ok then return false end
  local okc, yes = pcall(A.can_get, kind, v)
  return okc and yes == true
end
local function gui_for(key, layer)
  local g = gui.list[key]
  if g then return g end
  local ok, h = pcall(W.create_screen_gui, gui.world, 'scale', 1, 1)
  if not ok or h == nil then gui.state = 'create_screen_gui failed: ' .. tostring(h); return nil end
  g = { h = h, bitmaps = {}, tris = {}, layer = layer or 20 }
  gui.list[key] = g
  return g
end
local function clear(g)
  for _, id in ipairs(g.bitmaps) do pcall(G.destroy_bitmap, g.h, id) end
  for _, id in ipairs(g.tris) do pcall(G.destroy_triangle, g.h, id) end
  g.bitmaps, g.tris = {}, {}
end
local function clear_all() for _, g in pairs(gui.list) do clear(g) end end

-- Safety net for our textures: a marker file says 'trying' until icons have been on screen 60 frames (or the map
-- closed with them shown); if the game closed in between, the next start draws plain diamonds instead (once).
local CHECK = LOGDIR and (LOGDIR .. '\\TreasureMap.iconcheck') or nil
local function iconcheck(text)
  if not CHECK then return nil end
  if text then local f = io.open(CHECK, 'w'); if f then f:write(text); f:close() end; return end
  local f = io.open(CHECK, 'r'); if not f then return nil end
  local t = f:read('*a'); f:close(); return t
end
local function icons_usable()
  if gui.icons ~= nil then return gui.icons end
  local last = iconcheck()
  if last and last:find('^trying') then
    iconcheck('skipped once\n'); gui.icons = false
    gui.icon_state = 'diamonds for now (the last try ended with the game closing; icons are tried again next start)'
    return false
  end
  local missing = {}
  if not loaded('material', UI_MATERIAL) then missing[#missing + 1] = 'UI material' end
  for _, k in ipairs(KINDS) do if not loaded('texture', k.texture) then missing[#missing + 1] = k.id end end
  for ch, gl in pairs(GLYPHS) do if not loaded('texture', gl.texture) then missing[#missing + 1] = 'digit ' .. ch end end
  gui.icons = #missing == 0
  gui.icon_state = gui.icons and 'icons' or ('diamonds (not loaded: ' .. table.concat(missing, ', ') .. ')')
  if gui.icons then iconcheck('trying\n'); gui.icon_watch = 60 end
  return gui.icons
end
local function icons_proven()
  if gui.icon_watch and gui.drawn then gui.icon_watch = nil; iconcheck('ok\n') end
end
local function icon_refused(why)
  gui.icons, gui.icon_watch = false, nil
  gui.icon_state = 'diamonds (' .. why .. ')'
  iconcheck('refused\n')
end

-- bitmaps of texture `tex` centered on the n points pts[1..n] into GUI g. A point is { x, y [, size [, alpha]] }; size
-- (the icon's height; the square bitmap is size * quad) and alpha default to the arguments. Existing bitmaps are moved
-- (Gui.update_bitmap) when the game has it, else replaced.
local function bitmaps(g, tex, quad, pts, n, size, alpha)
  local okm, m = pcall(ID.from_hex, UI_MATERIAL)
  local okt, t = pcall(ID.from_hex, tex)
  local oks, s = pcall(ID.from_hex, SLOT)
  local okg, mh = false, nil
  if okm and okt and oks then okg, mh = pcall(G.material, g.h, m) end
  if not okg or mh == nil or not pcall(MAT.set_texture, mh, s, t) then icon_refused('the UI material was refused'); return false end
  local old = g.bitmaps
  for i = 1, n do
    local p = pts[i]
    local side = (p[3] or size) * quad
    local pos, dims, color = V3(p[1] - side / 2, p[2] - side / 2, g.layer), V2(side, side), (p[5] and C(p[4] or alpha, p[5][1], p[5][2], p[5][3]) or C(p[4] or alpha, 255, 255, 255))
    local id = old[i]
    local ok = false
    if id ~= nil and gui.update then
      ok = pcall(G.update_bitmap, g.h, id, m, pos, dims, color)
      if not ok then gui.update = false; event('Gui.update_bitmap refused; bitmaps are replaced instead') end
    end
    if not ok then
      if id ~= nil then pcall(G.destroy_bitmap, g.h, id) end
      local okb, nid = pcall(G.bitmap, g.h, m, pos, dims, color)
      if not okb then icon_refused('bitmap refused: ' .. tostring(nid)); return false end
      old[i] = nid
    end
  end
  for i = #old, n + 1, -1 do pcall(G.destroy_bitmap, g.h, old[i]); old[i] = nil end
  gui.drawn = true
  return true
end
local function quad(g, x1, y1, x2, y2, x3, y3, x4, y4, layer, col)
  local a, b, c, d = V3(x1, 0, y1), V3(x2, 0, y2), V3(x3, 0, y3), V3(x4, 0, y4)
  g.tris[#g.tris + 1] = G.triangle(g.h, a, b, c, layer, col)
  g.tris[#g.tris + 1] = G.triangle(g.h, a, c, d, layer, col)
end
local function rect(g, x0, y0, x1, y1, layer, col) quad(g, x0, y0, x1, y0, x1, y1, x0, y1, layer, col) end
local function drop_tris(g)
  for _, id in ipairs(g.tris) do pcall(G.destroy_triangle, g.h, id) end
  g.tris = {}
end
-- diamonds: the fallback marker when our textures can't be used
local function diamonds(g, rgb, pts, n, size, alpha)
  drop_tris(g)
  for i = 1, n do
    local p = pts[i]
    local x, y, sz, a = p[1], p[2], p[3] or size, p[4] or alpha
    local r = sz * 0.6
    for pass = 1, 2 do
      local q = pass == 1 and r + math.max(1, sz * 0.12) or r
      local col = pass == 1 and C(a, 0, 0, 0) or C(a, rgb[1], rgb[2], rgb[3])
      quad(g, x, y + q, x + q, y, x, y - q, x - q, y, g.layer + pass * 0.1, col)
    end
  end
end
local function marks(g, k, pts, n, size, alpha)
  if n == 0 then clear(g); return end
  if icons_usable() and bitmaps(g, k.texture, k.quad, pts, n, size, alpha) then return end
  for _, id in ipairs(g.bitmaps) do pcall(G.destroy_bitmap, g.h, id) end
  g.bitmaps = {}
  diamonds(g, k.rgb, pts, n, size, alpha)
end

-- ======================================================================================================
-- Text: digits and '/' (white with a dark outline, one texture per character). Every piece of text in a redraw is
-- collected first, then each character's GUI is drawn once. Seven-segment shapes if our textures are refused.
-- ======================================================================================================
local spots = {}                      -- character -> { {x, y, height, alpha}, ... } (reused between redraws)
local spot_n = {}
local function text_begin() for ch in pairs(spot_n) do spot_n[ch] = 0 end end
local function text_width(str, h) local w = 0 for ch in str:gmatch('.') do w = w + GLYPHS[ch].adv * h end return w end
-- str with its middle at height y; align: 'left' (x = start), 'right' (x = end) or 'center'
-- rgb (optional): tint the characters (a group count takes its kind's color)
local function text(str, x, y, h, align, alpha, rgb)
  local w = text_width(str, h)
  local at = align == 'right' and x - w or align == 'center' and x - w / 2 or x
  for ch in str:gmatch('.') do
    local a = GLYPHS[ch].adv * h
    local list, n = spots[ch], (spot_n[ch] or 0) + 1
    if not list then list = {}; spots[ch] = list end
    local p = list[n]
    if p then p[1], p[2], p[3], p[4], p[5] = at + a / 2, y, h, alpha or 255, rgb else list[n] = { at + a / 2, y, h, alpha or 255, rgb } end
    spot_n[ch] = n
    at = at + a
  end
end
local SEG = { a = { .3, 1.7, .7, 2 }, b = { .7, 1.15, 1, 1.7 }, c = { .7, .3, 1, .85 }, d = { .3, 0, .7, .3 },
              e = { 0, .3, .3, .85 }, f = { 0, 1.15, .3, 1.7 }, g = { .3, .85, .7, 1.15 } }
local DIGIT = { ['0'] = 'abcdef', ['1'] = 'bc', ['2'] = 'abged', ['3'] = 'abgcd', ['4'] = 'fgbc', ['5'] = 'afgcd',
                ['6'] = 'afgedc', ['7'] = 'abc', ['8'] = 'abcdefg', ['9'] = 'abcdfg' }
local function text_end()
  if icons_usable() then
    local ok = true
    for ch, gl in pairs(GLYPHS) do
      local n, g = spot_n[ch] or 0, gui.list['glyph ' .. ch]
      if n > 0 then
        g = g or gui_for('glyph ' .. ch, 32)
        if not g or not bitmaps(g, gl.texture, gl.quad, spots[ch], n, nil, 255) then ok = false; break end
      elseif g then clear(g) end
    end
    if ok then return end
    for ch in pairs(GLYPHS) do local g = gui.list['glyph ' .. ch]; if g then clear(g) end end
  end
  -- fallback: seven-segment shapes, all in one GUI
  local g = gui.list.segments or gui_for('segments', 32)
  if not g then return end
  drop_tris(g)
  for ch, list in pairs(spots) do
    for i = 1, spot_n[ch] or 0 do
      local p = list[i]
      local h = p[3]
      local w, y0 = GLYPHS[ch].adv * h * 0.7, p[2] - h / 2
      local x = p[1] - w / 2
      for pass = 1, 2 do
        local o = pass == 1 and math.max(1, h / 12) or 0
        local col = pass == 1 and C(math.floor(p[4] * 0.8), 0, 0, 0) or C(p[4], 255, 255, 255)
        if ch == '/' then
          quad(g, x + o, y0 - o, x + w * .24 + o, y0 - o, x + w + o, y0 + h - o, x + w * .76 + o, y0 + h - o, 31 + pass, col)
        else
          for seg in (DIGIT[ch] or ''):gmatch('.') do
            local q = SEG[seg]
            rect(g, x + q[1] * w + o, y0 + q[2] * h * .5 - o, x + q[3] * w + o, y0 + q[4] * h * .5 - o, 31 + pass, col)
          end
        end
      end
    end
  end
end

-- ======================================================================================================
-- The map markers: every pickup gets its own marker. Only pickups of one kind lying on the same spot in the world
-- (stacked, like several in one bunker) share a marker, with how many it stands for next to it.
-- ======================================================================================================
local STACK = 2.0                     -- meters: same-kind pickups this close count as one stack
local function project(k, st, size)
  local v, s = view, view.scale
  local mx, my = v.x + v.w * s * 0.5, v.y + v.h * s * 0.5
  local radius = math.min(v.w, v.h) * s * 0.5
  local reach = radius * radius
  local left, top, zoom = v.cx - v.px, v.cy - v.py, v.zoom * s
  local pts, n = k.points, 0
  local near = STACK * STACK
  for _, r in ipairs(st.rows) do
    if r.kind == k and r.x then
      local dx, dy = (r.x - left) * zoom, (r.y - top) * zoom
      if dx * dx + dy * dy <= reach then
        local joined = false
        for i = 1, n do
          local p = pts[i]
          local ex, ey = r.x - p.wx, r.y - p.wy          -- compared in the world, not on screen: zoom doesn't matter
          if ex * ex + ey * ey < near then p.count, joined = p.count + 1, true; break end
        end
        if not joined and n < 128 then
          n = n + 1
          local p = pts[n]
          if not p then p = {}; pts[n] = p end
          p[1], p[2], p.wx, p.wy, p.count = mx + dx, my + dy, r.x, r.y, 1
        end
      end
    end
  end
  return n
end

-- ======================================================================================================
-- The loot ledger: a panel at the bottom right, just outside the map (out of the way), one row per enabled kind
-- (in option order): its icon and how many are still in the mission. Kinds that are cleared are dimmed and checked off.
-- ======================================================================================================
local LEDGER = { gap = 8, pad = 7, row = 19, icon = 13, text = 12 }
-- what is still lying in the mission: pickups the game still lists AND still has a map position for (a collected
-- pickup can stay listed for a while, but loses its position, so the count goes down as things are picked up).
local function remaining(k)
  local n = 0
  for _, r in ipairs(lists[k.list].rows) do if r.kind == k and r.x then n = n + 1 end end
  return n
end
local function draw_ledger(rows)
  local g = gui.list.ledger
  if g then drop_tris(g) end
  if #rows == 0 then return end
  g = g or gui_for('ledger', 18)
  if not g then return end
  local v, s = view, view.scale
  local L_ = LEDGER
  local pad, row, icon, th = L_.pad * s, L_.row * s, L_.icon * s, L_.text * s
  local x0 = v.x + v.w * s + L_.gap * s
  -- bottom-aligned with the map's frame (y up: the frame's bottom edge is v.y)
  local top = v.y + L_.gap * s + pad * 2 + row * #rows
  local width = 0
  for _, r in ipairs(rows) do width = math.max(width, text_width(r.text, th)) end
  local inner = icon + 6 * s + width + 4 * s + icon * 0.9
  local x1, y1 = x0 + pad * 2 + inner, top - pad * 2 - row * #rows
  -- the panel: dark, with a thin parchment-colored frame
  local edge = math.max(1, s)
  rect(g, x0, y1, x1, top, 18, C(150, 14, 11, 8))
  local tan = C(200, 205, 175, 120)
  rect(g, x0, top - edge, x1, top, 18.1, tan); rect(g, x0, y1, x1, y1 + edge, 18.1, tan)
  rect(g, x0, y1, x0 + edge, top, 18.1, tan); rect(g, x1 - edge, y1, x1, top, 18.1, tan)
  for i, r in ipairs(rows) do
    local y = top - pad - row * (i - 0.5)
    local alpha = r.cleared and 110 or 255
    local list = r.icon_points
    list[#list + 1] = { x0 + pad + icon * 0.5, y, icon, alpha }
    text(r.text, x0 + pad + icon + 6 * s, y, th, 'left', alpha)
    if r.cleared then
      -- a green check mark at the row's end
      local cx, w = x1 - pad - icon * 0.45, icon * 0.9
      local col, t = C(255, 90, 220, 90), math.max(1.5, w * 0.16)
      quad(g, cx - w * .45, y, cx - w * .45 + t, y + t, cx - w * .1 + t, y - w * .35 + t, cx - w * .1, y - w * .35, 18.3, col)
      quad(g, cx - w * .1, y - w * .35, cx - w * .1 + t, y - w * .35 + t, cx + w * .5 + t, y + w * .35, cx + w * .5, y + w * .35, 18.3, col)
    end
  end
end

local function draw()
  stats.redraws = stats.redraws + 1
  local s = view.scale
  local size = SIZE * s
  text_begin()
  local rows = {}
  for _, k in ipairs(KINDS) do
    local st = lists[k.list]
    local n = 0
    k.ledger_points = k.ledger_points or {}
    for i = #k.ledger_points, 1, -1 do k.ledger_points[i] = nil end
    if k.on and st.ok and view.shown > 0 then
      if k.opacity > 0 then n = project(k, st, size) end
      -- the ledger row: every kind, Super Credits included, just shows how many are left
      local left = remaining(k)
      rows[#rows + 1] = { kind = k, text = tostring(left), cleared = left == 0, icon_points = k.ledger_points }
    end
    k.n = n
  end
  draw_ledger(rows)
  for _, k in ipairs(KINDS) do
    local g = gui.list[k.id]
    local n, pts = k.n, k.points
    local alpha = math.floor(255 * k.opacity * view.shown + 0.5)
    -- group counts next to the grouped markers (bottom right of the icon)
    for i = 1, n do
      local p = pts[i]
      p[3], p[4], p[5] = nil, nil, nil
      -- the count is in the kind's color and at the kind's opacity, so a count never seems to belong to another
      -- kind's marker
      if p.count > 1 then text(tostring(p.count), p[1] + size * 0.42, p[2] - size * 0.38, size * 0.62, 'left', alpha, k.rgb) end
    end
    -- the ledger's icon for this kind goes into the same GUI (it holds this kind's texture)
    for _, lp in ipairs(k.ledger_points) do n = n + 1; pts[n] = pts[n] or {}; local p = pts[n]; p[1], p[2], p[3], p[4], p[5], p.count = lp[1], lp[2], lp[3], lp[4], nil, 0 end
    if n > 0 then
      g = g or gui_for(k.id, k.layer)
      if g then marks(g, k, pts, n, size, alpha) end
    elseif g then clear(g) end
  end
  text_end()
end

-- ======================================================================================================
-- Every frame. Map closed: one 1-byte read. Map open: two view reads; each list four times a second (on different
-- frames); positions when a list changes, when the map opens and twice a second; drawing only when something moved.
-- ======================================================================================================
local ready = not V19
local broken, last_error = false, nil
local hud, open_was, next_second, menu_linked = nil, false, 0, false
local LIST_EVERY, LOCATE_EVERY = 15, 30
local LIST_ORDER = { lists.rewards, lists.loot }

local function overlay_world()
  local okm, main = pcall(A.main_world)
  local okw, worlds = pcall(A.worlds)
  if not okm or not okw or type(worlds) ~= 'table' then return nil, nil end
  local target, live = nil, false
  for i = 1, #worlds do
    local x = worlds[i]
    if x ~= nil and x ~= main and not target then target = x end
    if gui.world ~= nil and x == gui.world then live = true end
  end
  return target, live
end

local function tick()
  stats.frames = stats.frames + 1
  local f = stats.frames
  local now = os.clock()
  if now >= next_second then
    next_second = now + 1
    poll_options()
    if not V19 and not menu_linked and f < 3600 then menu_linked = link_menu() end
    hud = nil                                    -- the HUD manager pointer: looked up again once a second
  end
  if not any_on then TM.status = 'no kinds enabled'; return end
  if not L then
    if not ready then TM.status = 'waiting for start-up'; return end
    local ok, res = pcall(resolve_layout)
    if not ok then broken, last_error, TM.status = true, 'could not find the game addresses: ' .. tostring(res), 'off'; event(last_error); return end
    L = res
    event('game addresses: ' .. session.layout .. string.format(' (%.2f s)', session.scan_seconds))
  end
  hud = hud or read_ptr(L.hud)
  local open = hud and fetch(hud + VIEW + 405, 1) and b8(0) or nil
  if open ~= 1 then
    if open_was then
      clear_all(); open_was = false
      icons_proven()
    end
    TM.status = open == nil and 'no mission' or 'map closed'
    return
  end
  TM.status = 'map open'
  stats.map_frames = stats.map_frames + 1
  local opened = not open_was
  open_was = true
  if not read_view(hud) then return end
  if not api_ok() then return end
  if opened or not gui.world or now >= gui.next_check then
    gui.next_check = now + 1
    local target, live = overlay_world()
    if gui.world and not live then gui.world, gui.list = nil, {} end
    if not gui.world then
      if not target then gui.state = 'no overlay world'; return end
      gui.world, gui.state, dirty = target, 'screen GUIs in the overlay world', true
    end
  end
  if opened then dirty = true end
  for i = 1, 2 do
    local st = LIST_ORDER[i]
    if wants[st.name] then
      if opened or (f + st.offset) % LIST_EVERY == 0 then
        scan_list(st)
      end
      if st.ok and (opened or not st.located or (f + st.offset) % LOCATE_EVERY == 0) then locate(st) end
    elseif st.rows[1] then st.rows, st.raw = {}, nil end
  end
  if dirty then dirty = false; draw() end
  if gui.icon_watch and gui.drawn then
    gui.icon_watch = gui.icon_watch - 1
    if gui.icon_watch <= 0 then icons_proven() end
  end
end

-- ======================================================================================================
-- The log (rewritten every 10 s, and when the game closes)
-- ======================================================================================================
local T = { n = 0, sum = 0, max = 0, over = 0, open_n = 0, open_sum = 0 }
local function write_log()
  if not LOGDIR then return end
  local f = io.open(LOGDIR .. '\\TreasureMap.log', 'w')
  if not f then return end
  f:write('Treasure Map ', VERSION, '  (started ', session.started, ', written ', os.date('%H:%M:%S'), ')\n')
  f:write('status: ', TM.status, broken and (' - ' .. tostring(last_error)) or '', '\n')
  f:write('Bingus Shared Loader: ', V19 and 'v19 or newer' or 'older than v19 (needs v19 or newer; using the old start-up)', '\n')
  f:write('game addresses: ', tostring(session.layout), session.scan_seconds and string.format(' (%.2f s)', session.scan_seconds) or '', '\n')
  local on = {}
  for _, k in ipairs(KINDS) do if k.on then on[#on + 1] = string.format('%s %d%%', k.id, k.opacity * 100) end end
  f:write('kinds: ', #on > 0 and table.concat(on, ', ') or 'none', '\n')
  f:write('options menu: ', menu_state, '\n')
  f:write('drawing: ', gui.state, '; ', tostring(gui.icon_state or 'icons not tried yet'),
          gui.update ~= nil and ('; bitmaps ' .. (gui.update and 'moved in place' or 'replaced')) or '', '\n')
  if T.n > 0 then
    f:write(string.format('cost per frame: average %.4f ms (map open %.4f ms), highest %.3f ms, frames over 1 ms: %d\n',
      T.sum / T.n, T.open_n > 0 and T.open_sum / T.open_n or 0, T.max, T.over))
  end
  f:write(string.format('frames %d (map open %d), game reads %d (%.2f per frame, failed %d), list scans %d, position lookups %d, redraws %d\n',
    stats.frames, stats.map_frames, stats.reads, stats.frames > 0 and stats.reads / stats.frames or 0, stats.read_fails,
    stats.list_scans, stats.lookups, stats.redraws))
  for _, name in ipairs({ 'rewards', 'loot' }) do
    local st = lists[name]
    if st.ok ~= nil then
      local counts, placed = {}, 0
      for _, r in ipairs(st.rows) do
        local id = r.kind and r.kind.id or 'other'
        counts[id] = (counts[id] or 0) + 1
        if r.x then placed = placed + 1 end
      end
      local t = {}
      for id, n in pairs(counts) do t[#t + 1] = id .. ' ' .. n end
      table.sort(t)
      f:write(string.format('%s list: %s, %s entries%s: %s; positions known %d\n', name, st.ok and 'read' or 'not readable',
        tostring(st.count), '', table.concat(t, ', '), placed))
    end
  end
  if TESTER then
    f:write(string.format('map view: frame x %.1f y %.1f w %.1f h %.1f scale %.3f shown %.2f; center %.1f, %.1f pan %.1f, %.1f zoom %.4f\n',
      view.x, view.y, view.w, view.h, view.scale, view.shown, view.cx, view.cy, view.px, view.py, view.zoom))
    for k, v in pairs(session.notes) do f:write(k, ': ', v, '\n') end
    -- how close same-kind pickups sit to each other
    local near = {}
    for _, k in ipairs(KINDS) do
      local pos, best, same = {}, nil, 0
      for _, r in ipairs(lists[k.list].rows) do if r.kind == k and r.x then pos[#pos + 1] = r end end
      for i = 1, #pos do for j = i + 1, #pos do
        local d = math.sqrt((pos[i].x - pos[j].x) ^ 2 + (pos[i].y - pos[j].y) ^ 2)
        if not best or d < best then best = d end
        if d < 0.5 then same = same + 1 end
      end end
      if best then near[#near + 1] = string.format('%s %.1f m%s', k.id, best, same > 0 and (' (' .. same .. ' pairs on the same spot)') or '') end
    end
    if #near > 0 then f:write('closest same-kind pickups: ', table.concat(near, ', '), '\n') end
    -- pickups the game still lists: how many have a map position, and how many moved more than 2 m since first seen
    local seen = {}
    for _, k in ipairs(KINDS) do
      local listed, placed, moved = 0, 0, 0
      for _, r in ipairs(lists[k.list].rows) do
        if r.kind == k then
          listed = listed + 1
          if r.x then placed = placed + 1; if r.x0 and ((r.x - r.x0) ^ 2 + (r.y - r.y0) ^ 2) > 4 then moved = moved + 1 end end
        end
      end
      if listed > 0 then seen[#seen + 1] = string.format('%s %d listed / %d on the map / %d moved', k.id, listed, placed, moved) end
    end
    if #seen > 0 then f:write('pickups: ', table.concat(seen, ', '), '\n') end
    f:write(string.format('stacks: same-kind pickups within %.1f m share a marker\n', STACK))
  end
  f:write('\nrecent events:\n')
  for _, e in ipairs(session.events) do f:write('  ', e, '\n') end
  f:close()
end
TM.write_log = write_log

-- ======================================================================================================
-- Hooks
-- ======================================================================================================
local game_update, game_shutdown = rawget(_G, 'update'), rawget(_G, 'shutdown')
if type(game_update) ~= 'function' then TM.status = 'off: game update function not found'; write_log(); return end
local q, per_ms = ffi.new('int64_t[1]'), nil
do
  local fq = ffi.new('int64_t[1]')
  if pcall(function() return K32.TmQueryPerformanceFrequency(fq) end) and fq[0] > 0 then per_ms = tonumber(fq[0]) / 1000 end
end
local next_log, logged = 0, nil
rawset(_G, 'update', function(...)
  if not broken then
    local a
    if per_ms then K32.TmQueryPerformanceCounter(q); a = q[0] end
    local ok, e = pcall(tick)
    if per_ms then
      K32.TmQueryPerformanceCounter(q)
      local ms = tonumber(q[0] - a) / per_ms
      T.n, T.sum = T.n + 1, T.sum + ms
      if open_was then T.open_n, T.open_sum = T.open_n + 1, T.open_sum + ms end
      if ms > T.max then T.max = ms end
      if ms > 1 then T.over = T.over + 1 end
    end
    if not ok then
      broken, last_error, TM.status = true, 'tick: ' .. tostring(e), 'off'
      event(last_error); pcall(clear_all); pcall(write_log)
    end
    local now = os.clock()
    -- the log: looked at every 10 s, rewritten only when something in it changed
    if now >= next_log and any_on then
      next_log = now + 10
      local sig = TM.status .. #session.events .. ':' .. stats.redraws .. ':' .. stats.read_fails .. ':' .. tostring(session.events[#session.events])
      if sig ~= logged then logged = sig; pcall(write_log) end
    end
  end
  return game_update(...)
end)
rawset(_G, 'shutdown', function(...)
  if gui.icon_watch and gui.drawn then iconcheck('ok\n') end
  TM.status = 'closed'
  pcall(write_log)
  if type(game_shutdown) == 'function' then return game_shutdown(...) end
end)
if V19 then
  local ok, why = LOADER.after_startup(function()
    ready = true
    poll_options()
    link_menu()
    event('start-up finished')
  end)
  if not ok then ready = true; event('after_startup refused: ' .. tostring(why)) end
else
  event('needs Bingus Shared Loader v19 or newer (running with the old start-up)')
end
TM.status = 'waiting'
write_log()
