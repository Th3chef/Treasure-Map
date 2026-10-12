
-- ======================================================================================================
-- Where the game keeps things
-- ======================================================================================================
-- RVAs on the build these were read from (game.dll SHA-256 2E2C3B7C..., the 2026-09-24 patch)
local KNOWN = {
  sha = '2E2C3B7C2500646DADD5F2B4C6E0504DBB7E7896139F64CDDC0D1813C718F51E',
  hud = 54973752, rewards = 53635432, loot = 53635016, rewards_at = 53635872, loot_at = 53635880, objectives = 53636512,
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
  -- (1.1.0) the objective manager: count +0x24, its per-objective synced records +0x68 (0x64 bytes each; the
  -- game's own "discovered" check reads +0x44)
  objectives = rip3({ '4c8b0d????????33c08bd0458b41244585c0', '488b05????????8bda486bfb6448037868488b4050488b0c',
                      '488b1d????????488b4368486bce64396c0144488b4360' }),
}
local NAMES = { 'hud', 'rewards', 'loot', 'rewards_at', 'loot_at', 'objectives' }
local LEARN = { 'rewards', 'loot', 'rewards_at', 'loot_at', 'objectives' }
-- (1.1.0) items the mod can do without: if one isn't found after a game update, only its kind goes off
local OPTIONAL = { objectives = true }
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
-- ((1.1.0 review) a cache hit is only trusted when the game code at each remembered spot still matches its pattern and
-- still points at the cached address; on any mismatch (or a cache written by an older version of the mod) the game is
-- scanned again)
local function cache_holds(cache, base)
  if type(cache.checks) ~= 'table' then return false, 'written by an older version of the mod' end
  local n = 0
  for _, name in ipairs(NAMES) do
    local want, list = cache.rva[name], cache.checks[name]
    -- (1.1.0) an optional item the last scan didn't find has nothing to check
    local skipped = want == nil and OPTIONAL[name] and type(cache.skipped) == 'table' and cache.skipped[name] ~= nil
    if type(want) ~= 'number' and not skipped then return false, name .. ' missing' end
    for _, c in ipairs(not skipped and type(list) == 'table' and list or {}) do
      local len = type(c.p) == 'string' and #c.p / 2 or 0
      if type(c.site) ~= 'number' or type(c.disp_at) ~= 'number' or len < c.disp_at + 4 then return false, name .. ': bad entry' end
      if not fetch(base + c.site, len) then return false, name .. ': code not readable' end
      local code = bstr(0, len)
      for _, seg in ipairs((compile(c.p))) do
        if code:sub(seg[1] + 1, seg[1] + #seg[2]) ~= seg[2] then return false, name .. ': the code changed' end
      end
      if c.site + c.disp_at + 4 + si32(code, c.disp_at) ~= want then return false, name .. ': the code points elsewhere' end
      n = n + 1
    end
  end
  return true, n
end
local function resolve_layout()
  local t0 = os.clock()
  local game = K32.TmGetModuleHandleA('game.dll')
  if game == nil then error('game.dll not loaded', 0) end
  local info = module_info(game)
  assert(info.code, 'no code section')
  local key = string.format('%08x-%08x-%08x', info.stamp, info.image, info.code.size)
  local cache = cache_load()
  local found
  local base = tonumber(ffi.cast('uintptr_t', game))
  if cache and cache.key == key and type(cache.rva) == 'table' then
    local holds, how = cache_holds(cache, base)
    if holds then
      found, session.layout = cache.rva, string.format('cached for this game build (%d code spots checked)', how)
      for _, v in pairs(type(cache.skipped) == 'table' and cache.skipped or {}) do session.layout = session.layout .. '; ' .. tostring(v) .. ' (that kind stays off)' end
    else event('cache not used (' .. how .. '); scanning the game code again') end
  end
  if not found then
    local sha = file_sha256(game)
    local text, rva = code_text(game, info)
    -- the patterns (baked + remembered from the last build), item by item
    local by_pattern, why, checks, skipped = {}, {}, {}, {}
    for _, name in ipairs(NAMES) do
      local pats = {}
      for _, p in ipairs(PATTERNS[name] or {}) do pats[#pats + 1] = p end
      for _, p in ipairs(cache and cache.learned and cache.learned[name] or {}) do pats[#pats + 1] = p end
      local ok, v, sites = pcall(resolve_item, text, rva, pats, name)
      if ok then by_pattern[name], checks[name] = v, sites
      elseif OPTIONAL[name] then skipped[name] = tostring(v)
      else why[#why + 1] = tostring(v) end
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
      for name, v in pairs(skipped) do session.layout = session.layout .. '; ' .. v .. ' (that kind stays off)' end
    end
    for name in pairs(found) do skipped[name] = nil end
    local wanted = {}
    for _, name in ipairs(LEARN) do wanted[name] = found[name] end
    local learned = learn(text, rva, wanted)
    text = nil
    -- the spots a cache hit checks: where the patterns matched (only those that point at the address in use) and
    -- the loads just learned, up to 4 per item
    for _, name in ipairs(NAMES) do
      local list, seen = {}, {}
      for _, from in ipairs({ by_pattern[name] == found[name] and checks[name] or {}, learned[name] or {} }) do
        for _, c in ipairs(from) do
          if #list < 4 and not seen[c.site] then seen[c.site] = true; list[#list + 1] = c end
        end
      end
      checks[name] = list
    end
    cache_save({ key = key, sha = sha, rva = found, learned = learned, checks = checks, skipped = skipped })
  end
  local A = { base = base }
  for _, name in ipairs(NAMES) do A[name] = found[name] and A.base + found[name] or nil end
  session.scan_seconds = os.clock() - t0
  return A
end

-- ======================================================================================================
-- The kinds (seven options; Poor Intel main objectives go with Objectives). Type hashes: the pickups' entity types, as
-- stored (byte-reversed). Objectives come from the objective manager instead (no types).
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
  -- (1.1.0) side objectives: a brighter cyan than the game's side objective cyan (Super Credits are that cyan), 1.5x
  -- the loot markers' size (big = size factor on the map; the ledger icon keeps the ledger's size)
  { id = 'objective', name = 'Objectives', list = 'objectives', layer = 26, rgb = { 185, 252, 255 }, types = {}, big = 1.5 },
  -- (1.1.0) main objectives the map only shows as an area (Poor Intel), in the game's main objective orange; no
  -- option of their own: on with Objectives (follows), at its opacity
  { id = 'main', name = 'Main Objectives (Poor Intel)', list = 'objectives', layer = 27, rgb = { 254, 140, 26 }, types = {},
    big = 1.5, follows = 'objective' },
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
local wants = { rewards = false, loot = false, objectives = false }
local function poll_options()
  local t = rawget(_G, 'ChefTreasureMapKinds')
  any_on, wants.rewards, wants.loot, wants.objectives = false, false, false, false
  for _, k in ipairs(KINDS) do
    k.on = type(t) == 'table' and t[k.follows or k.id] == true
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
    if k.on and not k.menu and not k.follows then
      local id = 'treasure_map.' .. k.id .. '.opacity'
      local ok, yes = pcall(menu.register_option, id, {
        type = 'slider', mod = 'Treasure Map', label = k.name .. ' Opacity', min = 0, max = 100, step = 5, default = 100,
        description = 'How solid the ' .. k.name .. ' markers on the tactical map are, in percent (0 hides them).' })
      if ok and yes then
        k.menu, added = true, added + 1
        local function apply(v)
          if type(v) ~= 'number' then return end
          k.opacity, dirty = math.max(0, math.min(100, v)) / 100, true
          for _, f in ipairs(KINDS) do if f.follows == k.id then f.opacity = k.opacity end end
        end
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
  rewards = { name = 'rewards', raw = nil, rows = {}, offset = 0, positions = true },
  loot = { name = 'loot', raw = nil, rows = {}, offset = 7, positions = true },   -- (offset: the lists are read on different frames)
  objectives = { name = 'objectives', raw = nil, rows = {}, offset = 11, count = 0, undiscovered = 0, area = 0, placed = 0 },
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
  for _, other in pairs(lists) do if other ~= st and other.positions then for _, r in ipairs(other.rows) do keep[r.id] = true end end end
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
-- (1.1.0) Objectives: the objective manager (count +0x24, synced records +0x68, 0x64 bytes each: the position the map
-- shows at +0/+4, the objective's real position at +0xC/+0x10, state +0x20 (2 or 3 when done), index +0x3c, +0x40's low
-- half 1 while the map only shows an area around it (Poor Intel: main objectives), +0x44 1 until the objective is
-- discovered; the game's own "discovered" is +0x44 == 0). Objectives still undiscovered, or only shown as an area, and
-- not done get a marker at their real position (Poor Intel main objectives in their own color); one goes away as soon
-- as the game shows it or it is done. Two reads, four times a second while the map is open; the fields used are
-- compared in place (no copies) and the rows only rebuilt on a change.
-- ======================================================================================================
local OBJ = { count = 0x24, synced = 0x68, stride = 0x64, real = 0x0C, state = 0x20, index = 0x3c, area = 0x40, hidden = 0x44,
              most = 32, reach = 2000 }
local obj_now = {}                    -- per record: real x, real y (raw bits), state, area, hidden (reused)
local function scan_objectives(st)
  stats.list_scans = stats.list_scans + 1
  local m = L.objectives and read_ptr(L.objectives)
  if not m or not fetch(m + OBJ.count, OBJ.synced - OBJ.count + 8) then st.ok = false; return false end
  local count, recs = b32(0), bptr(OBJ.synced - OBJ.count)
  if count > OBJ.most then st.ok = false; note('objective list', 'count ' .. count .. ' (too many)'); return false end
  if count > 0 and (not recs or not fetch(recs, count * OBJ.stride)) then st.ok = false; return false end
  -- the fields used, straight out of the read buffer; every record must look like one (after a game update that
  -- changed the records, no marker is drawn in a wrong place: the objectives just stay off and the log says why)
  local same = count == st.count and st.ok
  for i = 0, count - 1 do
    local o, j = i * OBJ.stride, i * 5
    local x, y = b32(o + OBJ.real), b32(o + OBJ.real + 4)
    local state, area, hidden, index = b32(o + OBJ.state), b32(o + OBJ.area) % 65536, b32(o + OBJ.hidden), b32(o + OBJ.index)
    local fx, fy = bf32(o + OBJ.real), bf32(o + OBJ.real + 4)
    -- (a record at exactly 0, 0 is the game's placeholder before a mission's objectives are in: never marked, not checked)
    if not (fx == 0 and fy == 0) and (state > 3 or area > 1 or hidden > 1 or (index ~= i and index ~= 4294967295) or not fx
       or not fy or math.abs(fx) > OBJ.reach or math.abs(fy) > OBJ.reach) then
      if st.ok ~= false or not st.bad then
        event(string.format('objectives: record %d does not look like an objective (index %d, state %d, flags %d/%d); objectives off until it does',
          i, index, state, area, hidden))
      end
      note('objective list', 'record layout not recognized (game update?)')
      if st.rows[1] then st.rows, dirty = {}, true end
      st.ok, st.bad, st.raw = false, true, nil
      return false
    end
    if same and (obj_now[j + 1] ~= x or obj_now[j + 2] ~= y or obj_now[j + 3] ~= state or obj_now[j + 4] ~= area
                 or obj_now[j + 5] ~= hidden) then same = false end
    obj_now[j + 1], obj_now[j + 2], obj_now[j + 3], obj_now[j + 4], obj_now[j + 5] = x, y, state, area, hidden
  end
  if st.bad then note('objective list', 'records recognized again'); st.bad = false end
  if same and st.raw then return true end
  st.ok, st.count, st.raw = true, count, true
  -- one row per objective the map doesn't pinpoint yet (undiscovered, or only an area under Poor Intel) that isn't done
  local rows, area_n, placed = {}, 0, 0
  for i = 0, count - 1 do
    local j = i * 5
    local o = i * OBJ.stride
    local x, y = bf32(o + OBJ.real), bf32(o + OBJ.real + 4)
    if x and y and (x ~= 0 or y ~= 0) then
      placed = placed + 1
      local state, fuzzy = obj_now[j + 3], obj_now[j + 4] ~= 0
      if (obj_now[j + 5] ~= 0 or fuzzy) and state ~= 2 and state ~= 3 then
        rows[#rows + 1] = { id = 'objective ' .. i, kind = fuzzy and KIND.main or KIND.objective, x = x, y = y }
        if fuzzy then area_n = area_n + 1 end
      end
    end
  end
  if #rows ~= st.undiscovered or count ~= (st.logged or -1) or area_n ~= st.area then
    event(string.format('objectives: %d in the mission, %d marked (%d main objectives under Poor Intel)', count, #rows, area_n))
    st.logged = count
  end
  -- the main objectives' ledger row: from the first Poor Intel objective of a mission on (a new mission = the first
  -- objective's real position changed; that position never changes within a mission)
  local sx, sy = count > 0 and obj_now[1] or -1, count > 0 and obj_now[2] or -1
  if sx ~= st.sx or sy ~= st.sy then st.sx, st.sy, st.poor_intel = sx, sy, false end
  if area_n > 0 then st.poor_intel = true end
  -- placed: objectives with a real position (the placeholder the game holds before a mission's objectives are in has none)
  st.rows, st.undiscovered, st.area, st.placed, st.located = rows, #rows, area_n, placed, true
  dirty = true
  return true
end
lists.rewards.scan, lists.loot.scan, lists.objectives.scan = scan_list, scan_list, scan_objectives

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
-- (1.1.0) every layer below is drawn LAYER_BASE higher, so the markers, counts and ledger sit above the game's own
-- map overlays (the Atmospheric Spores modifier's spore cloud covered them at layers 18-32)
local LAYER_BASE = 900
local function gui_for(key, layer)
  local g = gui.list[key]
  if g then return g end
  local ok, h = pcall(W.create_screen_gui, gui.world, 'scale', 1, 1)
  if not ok or h == nil then gui.state = 'create_screen_gui failed: ' .. tostring(h); return nil end
  g = { h = h, bitmaps = {}, tris = {}, layer = layer or 20 }
  gui.list[key] = g
  return g
end
-- the overlay world to draw in (the first world that isn't the main one) and whether our GUIs' world is still alive
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

-- ((1.1.0 review) a GUI handle is only used while its world is alive. gui_live() checks it (once a second, and right
-- before every redraw: positions and lists change in between, and a mission load can kill the world mid-second); a
-- dead world's GUIs are dropped without touching a handle, and the next draw makes new ones in the live overlay world)
local function gui_live()
  local target, live = overlay_world()
  if gui.world and not live then
    gui.world, gui.list = nil, {}
    event('the overlay world went away; the markers are drawn anew')
  end
  if not gui.world then
    if not target then gui.state = 'no overlay world'; return false end
    gui.world, gui.state, dirty = target, 'screen GUIs in the overlay world', true
  end
  return true
end
-- ((1.1.0 review) a bitmap slot can hold false for a moment (destroyed, its replacement refused), so destroys skip it)
local function clear(g)
  for _, id in ipairs(g.bitmaps) do if id then pcall(G.destroy_bitmap, g.h, id) end end
  for _, id in ipairs(g.tris) do pcall(G.destroy_triangle, g.h, id) end
  g.bitmaps, g.tris = {}, {}
end
-- ((1.1.0 review) only while the GUIs' world is alive (the map can close in the frame a mission load kills it);
-- otherwise their handles are just dropped)
local function clear_all()
  if not next(gui.list) then return end
  local _, live = overlay_world()
  if live then for _, g in pairs(gui.list) do clear(g) end else gui.world, gui.list = nil, {} end
end

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
    local pos, dims, color = V3(p[1] - side / 2, p[2] - side / 2, g.layer + LAYER_BASE), V2(side, side), (p[5] and C(p[4] or alpha, p[5][1], p[5][2], p[5][3]) or C(p[4] or alpha, 255, 255, 255))
    local id = old[i]
    local ok = false
    if id and gui.update then
      ok = pcall(G.update_bitmap, g.h, id, m, pos, dims, color)
      if not ok then gui.update = false; event('Gui.update_bitmap refused; bitmaps are replaced instead') end
    end
    if not ok then
      -- ((1.1.0 review) the slot forgets the destroyed id at once (false keeps the list without holes), so a refused
      -- replacement below doesn't leave it to be destroyed a second time by marks())
      if id then pcall(G.destroy_bitmap, g.h, id); old[i] = false end
      local okb, nid = pcall(G.bitmap, g.h, m, pos, dims, color)
      if not okb then icon_refused('bitmap refused: ' .. tostring(nid)); return false end
      old[i] = nid
    end
  end
  for i = #old, n + 1, -1 do if old[i] then pcall(G.destroy_bitmap, g.h, old[i]) end; old[i] = nil end
  gui.drawn = true
  return true
end
local function quad(g, x1, y1, x2, y2, x3, y3, x4, y4, layer, col)
  local a, b, c, d = V3(x1, 0, y1), V3(x2, 0, y2), V3(x3, 0, y3), V3(x4, 0, y4)
  g.tris[#g.tris + 1] = G.triangle(g.h, a, b, c, layer + LAYER_BASE, col)
  g.tris[#g.tris + 1] = G.triangle(g.h, a, c, d, layer + LAYER_BASE, col)
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
  for _, id in ipairs(g.bitmaps) do if id then pcall(G.destroy_bitmap, g.h, id) end end
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
  end
  -- ((1.1.0 review) also when our textures stopped being usable since the last redraw: the digits already on screen go)
  for ch in pairs(GLYPHS) do local g = gui.list['glyph ' .. ch]; if g and next(g.bitmaps) then clear(g) end end
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
-- The loot ledger: a panel at the bottom left, just outside the map (out of the way), one row per enabled kind
-- (in option order): its icon and how many are still in the mission. Kinds that are cleared are dimmed and checked off.
-- ======================================================================================================
local LEDGER = { gap = 8, pad = 7, row = 19, icon = 13, text = 12, div = 9 }
-- what is still lying in the mission: pickups the game still lists AND still has a map position for (a collected
-- pickup can stay listed for a while, but loses its position, so the count goes down as things are picked up).
local function remaining(k)
  local n = 0
  for _, r in ipairs(lists[k.list].rows) do if r.kind == k and r.x then n = n + 1 end end
  return n
end
-- the screen's width (the GUI draws in screen pixels), at most once a second, and only when the ledger doesn't fit
-- left of the map; nil when the game doesn't say
local screen = { w = nil, at = -1, side = nil }        -- ((1.1.0 review) side: nil until the ledger is drawn)
local function screen_width()
  local now = os.clock()
  if now < screen.at then return screen.w end
  screen.at = now + 1
  local w
  for _, f in ipairs({ A and A.back_buffer_size, G and G.resolution }) do
    if type(f) == 'function' then
      local ok, a = pcall(f)
      if ok and type(a) == 'number' and a > 100 then w = a; break end
    end
  end
  screen.w = w
  return w
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
  -- (1.1.0) a divider between the objective rows (on top) and the loot rows, when there are both: split = the
  -- number of objective rows; the rows below it move down by div
  local split = 0
  for i, r in ipairs(rows) do if r.kind.list == 'objectives' then split = i end end
  local div = (split > 0 and split < #rows) and L_.div * s or 0
  -- bottom-aligned with the map's frame (y up: the frame's bottom edge is v.y)
  local top = v.y + L_.gap * s + pad * 2 + row * #rows + div
  local width = 0
  for _, r in ipairs(rows) do width = math.max(width, text_width(r.text, th)) end
  local inner = icon + 6 * s + width + 4 * s + icon * 0.9
  local pw = pad * 2 + inner
  -- just left of the map, at its bottom (clear of the HUD at the screen's right edge, on any screen shape); where
  -- there's no room left of it, just right of the map; and never past the screen's edges
  local x0 = v.x - L_.gap * s - pw
  screen.side = 'left'
  if x0 < 0 then
    x0, screen.side = v.x + v.w * s + L_.gap * s, 'right'
    local sw = screen_width()                      -- only needed here
    if sw and x0 + pw > sw then x0, screen.side = math.max(0, sw - pw), 'screen edge' end
  end
  local x1, y1 = x0 + pw, top - pad * 2 - row * #rows - div
  -- the panel: dark, with a thin parchment-colored frame
  local edge = math.max(1, s)
  rect(g, x0, y1, x1, top, 18, C(150, 14, 11, 8))
  local tan = C(200, 205, 175, 120)
  rect(g, x0, top - edge, x1, top, 18.1, tan); rect(g, x0, y1, x1, y1 + edge, 18.1, tan)
  rect(g, x0, y1, x0 + edge, top, 18.1, tan); rect(g, x1 - edge, y1, x1, top, 18.1, tan)
  if div > 0 then
    -- a thin parchment-colored line across the panel, in the middle of the gap
    local ly = top - pad - row * split - div * 0.5
    rect(g, x0 + pad, ly - edge * 0.5, x1 - pad, ly + edge * 0.5, 18.1, tan)
  end
  for i, r in ipairs(rows) do
    local y = top - pad - row * (i - 0.5) - (i > split and div or 0)
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
      -- the ledger row: every kind, Super Credits included, just shows how many are left ((1.1.0) objectives: how many
      -- are still marked; no row until the mission's objectives are in, about 50 s after the drop; the Poor Intel main
      -- objectives' row only on missions that have them)
      if k.list ~= 'objectives' or (k.id == 'main' and st.poor_intel) or (k.id ~= 'main' and st.placed > 0) then
        local left = remaining(k)
        -- (1.1.0) the objectives' rows come first in the ledger (main objectives above side objectives; the others in
        -- option order)
        table.insert(rows, k.list == 'objectives' and 1 or #rows + 1,
          { kind = k, text = tostring(left), cleared = left == 0, icon_points = k.ledger_points })
      end
    end
    k.n = n
  end
  draw_ledger(rows)
  for _, k in ipairs(KINDS) do
    local g = gui.list[k.id]
    local n, pts = k.n, k.points
    local alpha = math.floor(255 * k.opacity * view.shown + 0.5)
    local ksize = size * (k.big or 1)
    -- group counts next to the grouped markers (bottom right of the icon)
    for i = 1, n do
      local p = pts[i]
      p[3], p[4], p[5] = nil, nil, nil
      -- the count is in the kind's color and at the kind's opacity, so a count never seems to belong to another
      -- kind's marker
      if p.count > 1 then text(tostring(p.count), p[1] + ksize * 0.42, p[2] - ksize * 0.38, size * 0.62, 'left', alpha, k.rgb) end
    end
    -- the ledger's icon for this kind goes into the same GUI (it holds this kind's texture)
    for _, lp in ipairs(k.ledger_points) do n = n + 1; pts[n] = pts[n] or {}; local p = pts[n]; p[1], p[2], p[3], p[4], p[5], p.count = lp[1], lp[2], lp[3], lp[4], nil, 0 end
    if n > 0 then
      g = g or gui_for(k.id, k.layer)
      if g then marks(g, k, pts, n, ksize, alpha) end
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
local LIST_ORDER = { lists.rewards, lists.loot, lists.objectives }

local function tick()
  stats.frames = stats.frames + 1
  local f = stats.frames
  local now = os.clock()
  if now >= next_second then
    next_second = now + 1
    poll_options()
    if not V19 and not menu_linked and f < 3600 then menu_linked = link_menu() end
    -- the HUD manager pointer: looked up again once a second ((1.1.0 review) while the map is closed; while it is
    -- open it is read every frame below)
    if not open_was then hud = nil end
  end
  if not any_on then TM.status = 'no kinds enabled'; return end
  if not L then
    if not ready then TM.status = 'waiting for start-up'; return end
    local ok, res = pcall(resolve_layout)
    if not ok then broken, last_error, TM.status = true, 'could not find the game addresses: ' .. tostring(res), 'off'; event(last_error); return end
    L = res
    event('game addresses: ' .. session.layout .. string.format(' (%.2f s)', session.scan_seconds))
  end
  if open_was then
    -- ((1.1.0 review) while the map is open the pointer is read every frame (one 8-byte read): a different one is a new
    -- mission's HUD (or none), so the map counts as closed, and if the new HUD's map is open it is drawn anew)
    local h = read_ptr(L.hud)
    if h ~= hud then
      event('the HUD manager changed while the map was open')
      clear_all(); open_was = false
      icons_proven()
    end
    hud = h
  else
    hud = hud or read_ptr(L.hud)
  end
  local open = hud and fetch(hud + VIEW + 405, 1) and b8(0) or nil
  if open ~= 1 then
    if open_was then
      clear_all(); open_was = false
      icons_proven()
    end
    -- ((1.1.0 review) no mission: the GUIs are forgotten without touching them (their world may go with the mission);
    -- the next map opened draws into new ones)
    if open == nil and (gui.world or next(gui.list)) then gui.world, gui.list = nil, {} end
    TM.status = open == nil and 'no mission' or 'map closed'
    return
  end
  TM.status = 'map open'
  stats.map_frames = stats.map_frames + 1
  local opened = not open_was
  open_was = true
  if not read_view(hud) then return end
  if not api_ok() then return end
  local checked = opened or not gui.world or now >= gui.next_check
  if checked then
    gui.next_check = now + 1
    if not gui_live() then return end
  end
  if opened then dirty = true end
  for i = 1, #LIST_ORDER do
    local st = LIST_ORDER[i]
    if wants[st.name] then
      if opened or (f + st.offset) % LIST_EVERY == 0 then
        st.scan(st)
      end
      if st.positions and st.ok and (opened or not st.located or (f + st.offset) % LOCATE_EVERY == 0) then locate(st) end
    elseif st.rows[1] then st.rows, st.raw = {}, nil end
  end
  -- ((1.1.0 review) the GUIs' world is checked right before every redraw (unless it was just checked above))
  if dirty and (checked or gui_live()) then dirty = false; draw() end
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
  for _, k in ipairs(KINDS) do if k.on and not k.follows then on[#on + 1] = string.format('%s %d%%', k.id, k.opacity * 100) end end
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
  local ob = lists.objectives
  if ob.ok ~= nil then
    f:write(string.format('objectives: %s\n', not L or not L.objectives and 'not found in this game build (kind off)'
      or ob.bad and 'record layout not recognized (off)' or not ob.ok and 'not readable'
      or string.format('%d in the mission, %d marked (%d main objectives under Poor Intel)', ob.count, ob.undiscovered, ob.area)))
  end
  if TESTER then
    f:write(string.format('map view: frame x %.1f y %.1f w %.1f h %.1f scale %.3f shown %.2f; center %.1f, %.1f pan %.1f, %.1f zoom %.4f\n',
      view.x, view.y, view.w, view.h, view.scale, view.shown, view.cx, view.cy, view.px, view.py, view.zoom))
    f:write(string.format('screen width %s; the ledger %s\n', screen.w and tostring(screen.w) or 'not needed', screen.side == nil and 'is not drawn yet'
      or screen.side == 'left' and 'sits left of the map' or screen.side == 'right' and 'sits right of the map (no room on the left)'
      or "sits at the screen's edge (no room beside the map)"))
    for k, v in pairs(session.notes) do f:write(k, ': ', v, '\n') end
    -- @research-begin
    -- ((1.1.0 review) the research's state, cost and game reads (kept out of the numbers above))
    local rs = TM.research
    if rs then
      local c = rs.cost
      f:write(string.format('research: %s, %d lines, %d passes; cost per frame average %.4f ms, highest %.3f ms, frames over 1 ms: %d; game reads %d (failed %d)\n',
        rs.note, rs.lines, rs.pass, c.n > 0 and c.sum / c.n or 0, c.max, c.over, rs.reads, rs.read_fails))
    end
    -- @research-end
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

-- @research-begin
-- ======================================================================================================
-- Research (numbered test builds only; left out of releases): side objectives and enemy structures.
-- Read-only. In a mission it writes Logs\test\TreasureMap-research.log:
--  * the game's component managers (one global pointer each in game.dll): which of them hold a list of entities,
--    how many, of which entity types, and where each entity is (its unit's position from helldivers2.exe's unit
--    table); every 3 s, which entities appeared or went away (a fabricator or bug hole destroyed, an objective done)
--  * the objective manager's per-objective records (state words that change: discovered? done?) and the
--    show-on-map manager (what the game's own map shows), whenever they change
--  * once a minute, the engine's own unit list: where the units of known gameplay models are (bug holes,
--    fabricators, Illuminate ships, objective buildings), by model name, to put names on the entity types
-- Offsets are from the game build of 2026-09-24 (game.dll 6AB3B43F, helldivers2.exe 6AB382E4); on any other build the
-- research stays off.
-- ((1.1.0 review) all of it sits in one do-block (only RS, research_step and research_close are seen outside), so it
-- costs the main chunk three locals. A pass is spread over frames (one job a frame); the research is timed and its
-- game reads are counted on their own (TreasureMap.log, research line), so the mod's own numbers stay its own.)
-- ======================================================================================================
local RS = { on = nil, note = 'not started', next_at = 0, mission = false, lines = 0, pass = 0, jobs = {}, job_i = 1,
             reads = 0, read_fails = 0, cost = { n = 0, sum = 0, max = 0, over = 0 } }
local research_step, research_close
do
  local RS_MODELS = {
    ['aa28caf964d05500']='bug_fog_generator', ['d6a27adb179ad4ff']='bug_spawner_large_01', ['a83587cbff25c79e']='bug_spawner_medium_01',
    ['3b3327050e8c2c23']='bug_spawner_medium_01_ceiling', ['095686275a113614']='bug_spawner_shrieker', ['2e454bd4d24eb04a']='bug_spawner_small_01',
    ['4caa534edab20521']='colony_bug_spawner_01', ['c3d5cf46872c6f14']='cyborg_bunker', ['56b7f620948be11e']='cyborg_turret_aa_base',
    ['9b6c199030d86085']='cyborg_turret_base', ['954ba31bee3388dc']='cyborg_turret_tall', ['a2a86454f67fbc47']='colony_cyborg_spawner',
    ['a57ae2a703c02899']='cyborg_spawner_factory', ['5c9fb9272608b8dc']='cyborg_spawner_factory_static', ['4c03c005fead19a4']='cy_landingpad_01',
    ['946f4ee6c568bc37']='cy_mine_01', ['bded1d9037c9f0f9']='cy_refinery_01', ['724dacb8e9096422']='il_laser_tower',
    ['01fe503dcd17847b']='il_spawner', ['14a5d7e66f994a69']='il_teslatower', ['0883366204e1ccc5']='il_turret_01',
    ['1448d494665d01a0']='il_turret_tactical_obj', ['217c82164bd80a13']='cache_interactable_box', ['30212b6e5858aeef']='exploration_reward_generic',
    ['64401291fcb4c36e']='smuggler_cache', ['64d1b10becf03a4c']='smuggler_cache_02', ['5e04d526646ff79f']='bunker_cache',
    ['688949109126ece4']='mechanical_bughole', ['0abed3586e397289']='super_earth_cache', ['64090088502435dd']='cha_shrieker',
    ['cd28a27a79be53d5']='cyborg_turret_command_bunker_hmg', ['d37e8d120d2836e3']='cyborg_spawner', ['c4feec77882ae03e']='blocking_chunk',
    ['df3c4f91e298bfa4']='central_core_drill_01', ['116a7d88cf17160f']='central_core_hole_01', ['f9f1ac3f0c2a358c']='central_core_hole_01_blocker',
    ['3b3ffd0bda28fac8']='central_core_hole_plug_01', ['e64b41f88d319d90']='central_core_hole_plug_02', ['06d3c4720e642fc1']='embryo_01',
    ['dd2dac48bc52d2be']='hive_world_spore_lung', ['ad0d70667007d0ea']='hive_world_spore_lung_tentacle', ['9ea89ceea6f8e766']='bug_larva_container_backpack',
    ['0b85c370d60f34d0']='super_syringe', ['e979fe35857c54d9']='bug_tcs_main_tower_01', ['9319f40e5bdc6155']='bug_tcs_main_tower_011',
    ['87dad37dd7c888da']='bug_tcs_support_base_charger_01', ['bf81ec7bb4c1630a']='bug_tcs_support_pillar_01', ['1e1ff43e60d4bb9a']='thumper',
    ['3de2415ea33b6897']='black_box_01', ['90001feac563d6a1']='briefcase', ['92521022e05ee0c7']='bug_container',
    ['bd9ac2bc441387e5']='bug_container_animated', ['db59777f0abaf6af']='cargo_container', ['f41432892465c5fd']='carry_data',
    ['705b0136a9a9d73a']='warhead_01', ['c58fa5d32a28c016']='civilian_spawn_door', ['dec441413d4f401f']='colony_relay_platform_01',
    ['62d2c45a8b9703cc']='objective_colony_relay', ['ea014a7f47052935']='objective_colony_relay_antenna_crank_01', ['206ac4aff536b8ff']='communications_relay',
    ['8e415f41c6b25519']='communications_relay_door', ['e6d3a961347be4e3']='dropoff_01', ['019f988fa225dd1c']='escape_pod',
    ['d8bc006f5c4b3e74']='escape_pod_heatshield', ['4b33e6db50c42a20']='automated_artillery', ['9a61cd939a7e0256']='ready_rack',
    ['d0444f56a7d86e2b']='generator', ['f48e9dec9cc20d8a']='generic_intel', ['b8a49f22d83d52cf']='icbm_lock',
    ['42786dc1dd1eacad']='icbm_rocket', ['b1d938c07e30c5db']='icbm_silo', ['df657367d712cd8e']='icbm_silo_wide',
    ['269d84708b7d5206']='media_drone_camera', ['e581d8561b6fb340']='oil_field_plane', ['47de712d8c63c0c5']='oil_hose_connection',
    ['eae962d85c0c2d4a']='oil_pump', ['813d73b22b65eb2d']='oil_pump_valve', ['a21f08920052c27e']='power_station',
    ['e15bcc903a3cd973']='power_station_horde', ['a3e6c76a0136c551']='power_station_non_interactive', ['7d8498cc8b90135b']='prospecting_drill_01',
    ['19ec43eff0ef043f']='carry_flag_01', ['9a1f728716da05b5']='hellpod_flag', ['60302481eef86dd1']='research_station',
    ['a1bdb3a13e3633dd']='sam_site', ['e0dc1d1dec92d23b']='sam_site_foundation_01', ['9bed1b857173e77b']='sam_trenchwall_01',
    ['c97a2e50e33a33a9']='seaf_shell_high_yield', ['2553aec0eb6547ee']='seaf_shell_mini_nuke', ['58d1655e5a32c274']='seaf_shell_napalm',
    ['677f2a846800309a']='seaf_shell_regular', ['54d1de83c7b4d84e']='seaf_shell_smoke', ['d8110093e04399e1']='seaf_shell_static_field',
    ['22c5179731f8e503']='seismic_probe', ['b6e76076e5c6fe44']='gen_footage_volume', ['372481e910c05a76']='shoulder_mounted_camera',
    ['d6c719e3fea7cdab']='shuttle_escape_hatch', ['7d96c57604e61c3a']='truth_transmitter_tower', ['5fbf41e3daedc606']='cyborg_airbase_control_tower_01',
    ['2dd812e1c46d341e']='cyborg_airbase_control_tower_01_static', ['3e993c23a25e6b88']='cyborg_carry_data', ['b8fe3a0fe1a58465']='cy_ammunition_stockpile_01',
    ['4aff102712823c1e']='cy_battery_carry_2h', ['9e0e5e86a44c62a1']='cy_carry_data', ['43ec60f66e7e046b']='cy_chemicals_backpack',
    ['6e499c5c95b019fc']='cyborg_command_bunker', ['298c464f7f4261e3']='cyborg_command_bunker_side', ['5336583c1f8ba745']='cyborg_command_bunker_spawner',
    ['485c04e03ccc969e']='cyborg_command_bunker_top', ['e432929e520fddfb']='cyborg_cooling_structure', ['2670e0047b2eb409']='cy_detector_tower',
    ['6ef13a2eaca2f67a']='cyborg_dropoff_01', ['ee85d252f2b4b03d']='cy_filling_station', ['a738eac4c8cfd970']='cy_filling_station_barrel',
    ['8504aad5d6404d79']='cy_objective_terminal', ['4a4bb603a28f40ef']='cy_generic_valve', ['a8ae6952b375ef6c']='cyborg_gunship_spawner',
    ['e1ad3fb42ecd1b80']='cyborg_hack_turrets', ['4e6a3daf2d221aa5']='cy_network_tower', ['dbeec18f32bd0f0d']='cy_network_tower_dish',
    ['7b5d7a0e4d0c368c']='cy_oil_hose_connection', ['99cb7f36f9a951f9']='cy_fleet_ship_01', ['6838d8c197cc9c78']='cy_orbital_cannon',
    ['48d71ca5d261c852']='cyborg_organic_assembly_site', ['750c8fd5f33d43f8']='cyborg_organic_assembly_site_base', ['56713cfd02183953']='cyborg_organic_assembly_site_cooler_01',
    ['680dc1888154bcd1']='cyborg_organic_assembly_site_doors', ['cdb573e646581547']='cyborg_strategem_blocker_base', ['415fb8f8013cc896']='cy_uranium_silo',
    ['251f3abff1723c1b']='cy_resource_silo_01', ['8d04f5fba4429556']='il_weather_device_battery', ['f5f3207ca1b3a5d6']='il_encounter_ship_landed',
    ['84ccf61fdbd15291']='il_encounter_ship_landed_shield', ['bb2984b9b83ebfd1']='il_harvester', ['6f435cef5664a629']='il_harvester_hole_01',
    ['8fda04d2d85e87ae']='il_encounter_ship_invasion', ['691d6c666bfaccf5']='il_monolith', ['baf9dbd86b22270a']='il_mothership',
    ['505b4a5eb5e1b6f6']='il_mothership_shield', ['59b105a809064464']='il_mothership_tentacles', ['0754ce7bfed7c43a']='il_mothership_tentacles_vista',
    ['5fc53b7b1d8a13fd']='il_mothership_vista', ['19fe882f5106dfc1']='il_water_temple_well', ['590ef15c6070de0d']='il_portal_batteries',
    ['9e0a200eb6db116b']='il_gate', ['89204ae7cb3a99d5']='il_gate_shield', ['24abcd0f24b69a74']='il_raise_building_02',
    ['6a2cc367d8023c76']='il_raise_building_02_shield', ['69b0997494767de2']='il_rounded_shield', ['015df1d36234b138']='il_sarcophagus',
    ['bdf743b3686eede4']='il_scrambler_battery', ['1445df29152c9be2']='il_stratagem_scrambler', ['01581038809418dd']='se_orbital_cannon',
    ['90c833b8e4f75323']='se_orbital_cannon_blocker', ['ec78da1825e15a1d']='se_orbital_cannon_lock', ['57b32bee25411c4e']='se_orbital_cannon_shrub',
  }

  local RS_GAME_STAMP, RS_EXE_STAMP, RS_UNITS_RVA = 0x6AB3B43F, 0x6AB382E4, 0x1A100F0
  -- component managers this build has (game.dll RVAs of their global pointers), by name
  local RS_NAMED = {
    [0x3326590] = 'show_on_map', [0x3326da0] = 'objective', [0x33267b0] = 'bughole', [0x33265c8] = 'ai_spawner',
    [0x3326618] = 'encounter', [0x33265c0] = 'guard_force', [0x3326600] = 'illuminate_attack_ship',
    [0x3326530] = 'upload_discovery', [0x3326430] = 'tag', [0x3326450] = 'spottable', [0x3326550] = 'destructible',
    [0x3326670] = 'seaf_objectives', [0x33264b8] = 'objective_widget_priority', [0x3326dd0] = 'objective_terminal',
    [0x33266f0] = 'extraction_zone', [0x33264e0] = 'hive_lord', [0x3326498] = 'siege_engine',
    [0x3326718] = 'prespawn_location', [0x33269c0] = 'reinforcement_location',
  }
  local RS_FROM, RS_TO = 0x3326380, 0x3326E80              -- the globals looked at (every 8 bytes)
  local RS_OBJ, RS_SHOW = 0x3326da0, 0x3326590
  -- ((1.1.0 review) the research log is appended to and moved to TreasureMap-research.old.log once it is past ~5 MB; at
  -- most RS_LINES lines a session (one line says when that is reached, and the research stops: nothing more would be
  -- logged); flushed and closed when the game closes and when the research stops on an error)
  local RS_LINES, RS_ROTATE = 40000, 5 * 1048576
  local RS_RECENSUS = 30                                   -- seconds between censuses of the globals not found yet
  local rlog
  function research_close(why)
    if not rlog then return end
    rlog:write(os.date('%H:%M:%S '), '==== research log closed (', why, ') ====\n')
    rlog:flush(); rlog:close(); rlog = nil
  end
  local function rline(s)
    if not rlog then return end
    if RS.lines >= RS_LINES then
      rlog:write(os.date('%H:%M:%S '), 'line cap reached (', tostring(RS_LINES), ' lines); the research stops for this session\n')
      RS.on, RS.note = false, 'stopped: line cap reached'
      research_close('line cap')
      return
    end
    RS.lines = RS.lines + 1
    rlog:write(os.date('%H:%M:%S '), s, '\n')
  end
  local function rflush() if rlog then rlog:flush() end end
  local function hexs(addr, n)
    if not fetch(addr, n) then return '(unreadable)' end
    local t = {}
    for i = 0, n - 1, 4 do t[#t + 1] = string.format('%08x', b32(i)) end
    return table.concat(t, ' ')
  end
  local function rs_setup()
    RS.on = false
    if not LOGDIR then RS.note = 'no log folder'; return end
    local g = K32.TmGetModuleHandleA('game.dll')
    local e = K32.TmGetModuleHandleA(nil)
    if g == nil or e == nil then RS.note = 'modules not loaded'; return end
    local gi, ei = module_info(g), module_info(e)
    if gi.stamp ~= RS_GAME_STAMP or ei.stamp ~= RS_EXE_STAMP then
      RS.note = string.format('off: game.dll %08x / exe %08x is not the build the offsets are from', gi.stamp, ei.stamp); return
    end
    RS.game, RS.exe = tonumber(ffi.cast('uintptr_t', g)), tonumber(ffi.cast('uintptr_t', e))
    RS.units = RS.exe + RS_UNITS_RVA
    local path = LOGDIR .. '\\TreasureMap-research.log'
    local f = io.open(path, 'r')
    if f then
      local size = f:seek('end') or 0
      f:close()
      if size > RS_ROTATE then
        local prev = LOGDIR .. '\\TreasureMap-research.old.log'
        os.remove(prev); os.rename(path, prev)
      end
    end
    rlog = io.open(path, 'a')
    if not rlog then RS.note = 'cannot write the research log'; return end
    rlog:setvbuf('full')
    RS.on, RS.note = true, 'on'
    rline('==== Treasure Map ' .. VERSION .. ' research started ====')
  end
  -- ((1.1.0 review) the unit table's header (objects, count, generations) is read once per research step and used for
  -- every entity in it, instead of once per entity)
  local UT = { ok = false }
  local function rs_units()
    UT.ok = false
    local reg = read_ptr(RS.units)
    if not reg or not fetch(reg + 0x88, 0x20) then return end
    UT.objs, UT.count, UT.gens = bptr(0), b32(0x10), bptr(0x18)
    UT.ok = UT.objs ~= nil and UT.gens ~= nil
  end
  -- a unit's position: the exe's unit table (index = id & 0x3FFFFF, generation byte = id >> 22), its root pose
  local function rs_pos(unit)
    if unit == 0 or unit == 0xFFFFFFFF or not UT.ok then return nil end
    local index, gen = bit.band(unit, 0x3FFFFF), bit.band(bit.rshift(unit, 22), 0xFF)
    if index >= UT.count then return nil end
    if not fetch(UT.gens + index, 1) or b8(0) ~= gen then return nil end
    local obj = read_ptr(UT.objs + 8 * index)
    if not obj or not fetch(obj + 8, 4) or b32(0) ~= unit then return nil end
    local poses = read_ptr(obj + 0x88)
    if not poses or not fetch(poses + 48, 12) then return nil end
    local x, y, z = bf32(0), bf32(4), bf32(8)
    if not x or not y or not z or math.abs(x) > 1e5 or math.abs(y) > 1e5 or math.abs(z) > 1e5 then return nil end
    return x, y, z
  end
  -- an entity object: type hash +0 (8 bytes), entity id +8, unit id +12
  local function rs_entity(q)
    if not q or not fetch(q, 16) then return nil end
    local lo, hi, eid, unit = b32(0), b32(4), b32(8), b32(12)
    if eid == 0 or eid == 0xFFFFFFFF or (lo == 0 and hi == 0) then return nil end
    local x, y, z = rs_pos(unit)
    if not x then return nil end
    return { t = string.format('%08x%08x', hi, lo), eid = eid, unit = unit, x = x, y = y, z = z }
  end
  -- which pointer in a manager's first 0x100 bytes leads to an array of entity objects, and its count field
  -- ((1.1.0 review) a full first window of 64 is followed on, up to 1024 entries; the count field is the u32 right after
  -- the array pointer when it lies between the leading run of readable entities and 1024, else (as before) the one field
  -- equal to that run)
  local function rs_probe(m)
    if not fetch(m, 0x100) then return nil end
    local head = ffi.string(BUF, 0x100)
    local best
    for o = 0, 0xF8, 8 do
      local p = su32(head, o) + su32(head, o + 4) * 4294967296
      local got = 0
      if p >= 65536 and p < 140737488355328 then got = fetch(p, 64 * 8) and 64 or fetch(p, 8 * 8) and 8 or 0 end
      if got > 0 then
        local ptrs = {}
        for i = 0, got - 1 do ptrs[i] = bptr(i * 8) end
        local valid, lead, broken = 0, 0, false
        for i = 0, got - 1 do
          if rs_entity(ptrs[i]) then valid = valid + 1; if not broken then lead = lead + 1 end else broken = true end
          if i == 7 and valid == 0 then break end
        end
        if valid > 0 and (not best or valid > best.valid) then best = { at = o, p = p, valid = valid, lead = lead, got = got } end
      end
    end
    if not best then return nil end
    if best.lead == 64 then
      local n = 1024
      while n > 64 and not fetch(best.p, n * 8) do n = n / 2 end
      if n > 64 then
        local ptrs = {}
        for i = 64, n - 1 do ptrs[i] = bptr(i * 8) end
        for i = 64, n - 1 do if rs_entity(ptrs[i]) then best.lead = best.lead + 1 else break end end
        best.got = n
      end
    end
    local counts = {}
    if best.lead > 0 then
      for o = 0, 0xFC, 4 do if su32(head, o) == best.lead then counts[#counts + 1] = string.format('+%02x', o) end end
      local after = best.at + 8 <= 0xFC and su32(head, best.at + 8) or 0
      if after >= best.lead and after <= 1024 then best.count_at = best.at + 8
      elseif #counts == 1 then best.count_at = tonumber(counts[1]:sub(2), 16) end
    end
    best.counts = table.concat(counts, ' ')
    return best
  end
  -- the entities a manager lists now (by entity id): its count field's worth (at most 1024), else as many as the probe read
  local function rs_list(m, lay)
    local p = read_ptr(m + lay.at); if not p then return nil end
    local n = lay.got or 64
    if lay.count_at and fetch(m + lay.count_at, 4) then n = math.min(b32(0), 1024) end
    if n <= 0 then return {} end
    if not fetch(p, n * 8) then return nil end
    local ptrs = {}
    for i = 0, n - 1 do ptrs[i] = bptr(i * 8) end
    local out = {}
    for i = 0, n - 1 do
      local e = rs_entity(ptrs[i])
      if e then e.i = i; out[e.eid] = e end
    end
    return out
  end
  local function rs_where(e) return string.format('%s eid %x at %.1f, %.1f, %.1f', e.t, e.eid, e.x, e.y, e.z) end


  -- the census: every global in the range that is a manager with an entity list, up to 8 globals a frame
  -- ((1.1.0 review) and only as many as fit in ~2000 game reads; repeated every RS_RECENSUS s for the globals that
  -- weren't a manager yet, since some managers only fill up during the mission)
  local function rs_census(now)
    local r0, rva = stats.reads, RS.census_at
    for _ = 1, 8 do
      if rva >= RS_TO or stats.reads - r0 > 2000 then break end
      local m = not RS.known[rva] and read_ptr(RS.game + rva)
      local lay = m and rs_probe(m)
      if lay then
        local name = RS_NAMED[rva] or string.format('global %x', rva)
        local list = rs_list(m, lay) or {}
        local types, n = {}, 0
        for _, e in pairs(list) do n = n + 1; types[e.t] = (types[e.t] or 0) + 1 end
        local tl = {}
        for t, c in pairs(types) do tl[#tl + 1] = t .. ' x' .. c end
        table.sort(tl)
        rline(string.format('manager %s (rva %x): entities at +%02x, %d now (count field %s; leading run %d; fields equal to it: %s)%s; types: %s',
          name, rva, lay.at, n, lay.count_at and string.format('+%02x', lay.count_at) or 'none', lay.lead,
          lay.counts ~= '' and lay.counts or 'none', RS.census_n > 0 and string.format(' (found by census %d)', RS.census_n + 1) or '',
          table.concat(tl, ', ')))
        if n <= 300 then
          local s = {}
          for _, e in pairs(list) do s[#s + 1] = e end
          table.sort(s, function(a, b) return a.i < b.i end)
          for _, e in ipairs(s) do rline('    ' .. rs_where(e)) end
        end
        RS.known[rva] = true
        RS.mgrs[#RS.mgrs + 1] = { rva = rva, name = name, m = m, lay = lay, last = list }
        RS.census_new = RS.census_new + 1
      end
      rva = rva + 8
    end
    RS.census_at = rva
    if rva >= RS_TO then
      RS.census_at, RS.census_n, RS.recensus_at = nil, RS.census_n + 1, now + RS_RECENSUS
      if RS.census_n == 1 or RS.census_new > 0 then
        rline(string.format('census %d: %d managers with entity lists (%d new)', RS.census_n, #RS.mgrs, RS.census_new))
      end
      RS.census_new = 0
    end
  end
  -- each pass: what appeared in and what went away from one manager
  local function rs_changes(g)
    local m = read_ptr(RS.game + g.rva)
    if m ~= g.m then rline(string.format('manager %s moved (%x)', g.name, m or 0)); g.m = m end
    local now = m and rs_list(m, g.lay)
    if now then
      for eid, e in pairs(now) do if not g.last[eid] then rline(string.format('%s: added %s', g.name, rs_where(e))) end end
      for eid, e in pairs(g.last) do if not now[eid] then rline(string.format('%s: gone %s', g.name, rs_where(e))) end end
      g.last = now
    end
  end
  -- word-level changes in a block of memory (each word reported at most `cap` times)
  local function rs_diff(key, addr, n, cap, label)
    RS.snaps = RS.snaps or {}
    if not fetch(addr, n) then return end
    local cur = ffi.string(BUF, n)
    local s = RS.snaps[key]
    if not s or s.n ~= n then RS.snaps[key] = { n = n, data = cur, seen = {} }; return true end
    if s.data == cur then return end
    local out = {}
    for o = 0, n - 4, 4 do
      local a, b = s.data:sub(o + 1, o + 4), cur:sub(o + 1, o + 4)
      if a ~= b and (s.seen[o] or 0) < cap then
        s.seen[o] = (s.seen[o] or 0) + 1
        if #out < 32 then out[#out + 1] = string.format('+%03x %08x->%08x', o, su32_at(a, 0), su32_at(b, 0)) end
      end
    end
    s.data = cur
    if #out > 0 then rline(label .. ': ' .. table.concat(out, ' ')) end
  end
  -- the objective manager: count +0x24, entities +0x50, objectives +0x60 (0x1078 each), synced records +0x68 (0x64 each)
  local function rs_objectives(first)
    local m = read_ptr(RS.game + RS_OBJ); if not m or not fetch(m, 0x80) then return end
    local n, ents, inst, sync = math.min(b32(0x24), 32), bptr(0x50), bptr(0x60), bptr(0x68)
    if not ents or not inst or not sync then return end
    for i = 0, n - 1 do
      local e = rs_entity(read_ptr(ents + i * 8))
      local key = e and e.eid or ('i' .. i)
      if first or not (RS.objseen and RS.objseen[key]) then
        RS.objseen = RS.objseen or {}
        RS.objseen[key] = true
        rline(string.format('objective %d: %s', i, e and rs_where(e) or 'entity unreadable'))
        rline('  synced: ' .. hexs(sync + i * 0x64, 0x64))
        rline('  record head: ' .. hexs(inst + i * 0x1078, 0x100))
        rline('  record tail: ' .. hexs(inst + i * 0x1078 + 0xF78, 0x100))
      end
      rs_diff('sync' .. tostring(key), sync + i * 0x64, 0x64, 6, string.format('objective %d synced', i))
      rs_diff('inst' .. tostring(key), inst + i * 0x1078, 0x1078, 3, string.format('objective %d record', i))
    end
  end
  -- the show-on-map manager: header, its arrays (+0x38 settings pointers, +0x48 20-byte, +0x50 24-byte records)
  -- and the entity-id -> index table (+0x20 buckets of { id, index }, +0x28 bucket count)
  local function rs_show(first)
    local m = read_ptr(RS.game + RS_SHOW); if not m or not fetch(m, 0x80) then return end
    local head = ffi.string(BUF, 0x80)
    local cap = su32_at(head, 0)
    local function hp(o) return su32_at(head, o) + su32_at(head, o + 4) * 4294967296 end
    local buckets, nb, settings, r20, r24 = hp(0x20), su32_at(head, 0x28), hp(0x38), hp(0x48), hp(0x50)
    local n = math.min(cap, 64)
    local sig = {}
    if buckets > 65536 and nb > 0 and nb <= 4096 and fetch(buckets, nb * 8) then
      for k = 0, nb - 1 do
        local id, idx = b32(k * 8), b32(k * 8 + 4)
        if idx < n and id ~= 0 and id ~= 0xFFFFFFFF then sig[#sig + 1] = string.format('%x=%d', id, idx) end
      end
    end
    table.sort(sig)
    local s = table.concat(sig, ' ')
    local recs = (r20 > 65536 and fetch(r20, n * 20) and ffi.string(BUF, n * 20) or '') .. '|' ..
                 (r24 > 65536 and fetch(r24, n * 24) and ffi.string(BUF, n * 24) or '')
    if first or s ~= RS.show_ids or recs ~= RS.show_recs then
      RS.show_ids, RS.show_recs = s, recs
      rline('show_on_map header: ' .. hexs(m, 0x80))
      rline('show_on_map ids: ' .. (s ~= '' and s or 'none'))
      local used = {}
      for _, kv in ipairs(sig) do used[tonumber(kv:match('=(%d+)'))] = kv:match('^(%x+)') end
      for i = 0, n - 1 do
        if used[i] then
          local x, y, z
          if r20 > 65536 and fetch(r20 + i * 20, 20) then x, y, z = bf32(0), bf32(4), bf32(8) end
          local tail = hexs(r20 + i * 20 + 12, 8)
          local line = string.format('  [%d] id %s: pos %s, %s, %s; rest %s; 24-byte: %s', i, used[i], tostring(x), tostring(y),
            tostring(z), tail, r24 > 65536 and hexs(r24 + i * 24, 24) or '-')
          local sp = settings > 65536 and read_ptr(settings + i * 8)
          if sp then line = line .. '; settings ' .. hexs(sp, 0x30) end
          rline(line)
        end
      end
    end
  end
  -- once a minute: the engine's unit list, units of known gameplay models (named) with their positions
  local function rs_models()
    local SR = rawget(_G, 'stingray')
    if not (SR and SR.World and SR.Unit and SR.Application) then rline('models: engine API not found'); return end
    local okw, world = pcall(SR.Application.main_world)
    if not okw or not world then return end
    local oku, list = pcall(SR.World.units, world)
    if not oku or type(list) ~= 'table' then rline('models: World.units failed'); return end
    local U = SR.Unit
    local by = {}
    for _, u in ipairs(list) do
      local oks, name = pcall(tostring, u)
      local h = oks and type(name) == 'string' and name:match('(%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x)')
      local model = h and RS_MODELS[h:lower()]
      if model then
        local where = ''
        local okh, has = pcall(U.has_node, u, 'root')
        if okh and has then
          local okn, nd = pcall(U.node, u, 'root')
          local okp, p = false, nil
          if okn then okp, p = pcall(U.world_position, u, nd) end
          if okp and p then
            local ok3, x, y, z = pcall(function() return p.x, p.y, p.z end)
            if ok3 and type(x) == 'number' then where = string.format('%.0f,%.0f', x, y) end
          end
        end
        local t = by[model] or {}; by[model] = t
        t[#t + 1] = where
      end
    end
    local names = {}
    for k in pairs(by) do names[#names + 1] = k end
    table.sort(names)
    local parts = {}
    for _, k in ipairs(names) do parts[#parts + 1] = string.format('%s x%d (%s)', k, #by[k], table.concat(by[k], ' ')) end
    local s = table.concat(parts, '; ')
    if s ~= RS.models then RS.models = s; rline(string.format('models (%d units in the world): %s', #list, s)) end
  end

  -- every 3 s in a mission, a pass: each manager's changes, the objectives, the map's list and (once a minute) the
  -- models, ((1.1.0 review) one of them a frame); the census first when one is due
  function research_step(now)
    if RS.on == nil then rs_setup(); TM.research = RS end
    if not RS.on then return end
    if RS.census_at then rs_units(); rs_census(now); return end
    local jobs = RS.jobs
    if RS.job_i <= #jobs then
      rs_units()
      local j = jobs[RS.job_i]
      RS.job_i = RS.job_i + 1
      if j == 'objectives' then rs_objectives(RS.first)
      elseif j == 'show' then rs_show(RS.first)
      elseif j == 'models' then rs_models()
      elseif RS.mgrs[j] then rs_changes(RS.mgrs[j]) end
      if RS.job_i > #jobs then rflush() end
      return
    end
    if now < RS.next_at then return end
    RS.next_at = now + 3
    local in_mission = L and hud and fetch(hud + VIEW + 405, 1) or false
    if not in_mission then
      if RS.mission then rline('---- mission ended (pass ' .. RS.pass .. ') ----'); RS.mission = false; rflush() end
      return
    end
    local first = not RS.mission
    for i = #jobs, 1, -1 do jobs[i] = nil end
    RS.job_i, RS.first = 1, first
    if first then
      RS.mission, RS.pass, RS.models, RS.show_ids, RS.objseen, RS.snaps = true, 0, nil, nil, nil, nil
      RS.model_at = now + 8
      rline('---- mission started ----')
      RS.mgrs, RS.known, RS.census_at, RS.census_n, RS.census_new = {}, {}, RS_FROM, 0, 0
    else
      for i = 1, #RS.mgrs do jobs[#jobs + 1] = i end
      if now >= RS.recensus_at then RS.census_at = RS_FROM end
    end
    RS.pass = RS.pass + 1
    jobs[#jobs + 1] = 'objectives'
    jobs[#jobs + 1] = 'show'
    if now >= (RS.model_at or 0) then RS.model_at = now + 60; jobs[#jobs + 1] = 'models' end
  end
end
-- @research-end


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
    -- @research-begin
    if TEST_BUILD then
      -- ((1.1.0 review) timed on its own, and its game reads moved out of the mod's own counts; an error stops it and
      -- closes its log)
      local r0, f0, b = stats.reads, stats.read_fails, nil
      if per_ms then K32.TmQueryPerformanceCounter(q); b = q[0] end
      local okr, er = pcall(research_step, now)
      if per_ms then
        K32.TmQueryPerformanceCounter(q)
        local ms, c = tonumber(q[0] - b) / per_ms, RS.cost
        c.n, c.sum = c.n + 1, c.sum + ms
        if ms > c.max then c.max = ms end
        if ms > 1 then c.over = c.over + 1 end
      end
      RS.reads, RS.read_fails = RS.reads + stats.reads - r0, RS.read_fails + stats.read_fails - f0
      stats.reads, stats.read_fails = r0, f0
      if not okr then
        if not session.notes.research then note('research', 'stopped: ' .. tostring(er)) end
        RS.on, RS.note = false, 'stopped after an error'
        pcall(research_close, 'stopped after an error')
      end
    end
    -- @research-end
    -- the log: looked at every 10 s, rewritten only when something in it changed
    if now >= next_log and any_on then
      next_log = now + 10
      -- ((1.1.0 review) read failures left out: the log no longer rewrites itself every 10 s over failed reads)
      local sig = TM.status .. #session.events .. ':' .. stats.redraws .. ':' .. tostring(session.events[#session.events])
      if sig ~= logged then logged = sig; pcall(write_log) end
    end
  end
  return game_update(...)
end)
rawset(_G, 'shutdown', function(...)
  if gui.icon_watch and gui.drawn then iconcheck('ok\n') end
  TM.status = 'closed'
  -- @research-begin
  if TEST_BUILD then pcall(research_close, 'the game closed') end
  -- @research-end
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
