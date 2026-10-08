local function su32(t, o) local a, b, c, d = t:byte(o + 1, o + 4); return a + b * 256 + c * 65536 + d * 16777216 end
local function si32(t, o) local v = su32(t, o); return v >= 2147483648 and v - 4294967296 or v end

local function compile(p)
  local segs, cur_off, cur = {}, nil, {}
  for k = 0, #p / 2 - 1 do
    local h = p:sub(2 * k + 1, 2 * k + 2)
    if h == '??' then
      if cur_off then segs[#segs + 1] = { cur_off, table.concat(cur) }; cur_off, cur = nil, {} end
    else
      cur_off = cur_off or k
      cur[#cur + 1] = string.char(tonumber(h, 16))
    end
  end
  if cur_off then segs[#segs + 1] = { cur_off, table.concat(cur) } end
  local anchor = 1
  for j = 2, #segs do if #segs[j][2] > #segs[anchor][2] then anchor = j end end
  return segs, anchor, #p / 2
end
-- 0-based offset of the single place the pattern matches, or nil + why
local function find_once(text, p)
  local segs, anchor, n = compile(p)
  local a = segs[anchor]
  local init, found, count = 1, nil, 0
  while true do
    local s = string.find(text, a[2], init, true)
    if not s then break end
    local start = s - 1 - a[1]
    local ok = start >= 0 and start + n <= #text
    if ok then
      for j, seg in ipairs(segs) do
        if j ~= anchor and text:sub(start + seg[1] + 1, start + seg[1] + #seg[2]) ~= seg[2] then ok = false; break end
      end
    end
    if ok then
      count = count + 1; found = start
      if count > 1 then return nil, 'matches more than once' end
    end
    init = s + 1
  end
  if count == 0 then return nil, 'not found' end
  return found
end

local function module_info(module)
  local b = ffi.cast('uint8_t *', module)
  local function r32(p) return tonumber(ffi.cast('uint32_t *', p)[0]) end
  local function r16(p) return tonumber(ffi.cast('uint16_t *', p)[0]) end
  local pe = r32(b + 0x3c)
  local stamp, image = r32(b + pe + 8), r32(b + pe + 24 + 56)
  local count, optsize = r16(b + pe + 6), r16(b + pe + 20)
  local sec = b + pe + 24 + optsize
  local code
  for i = 0, count - 1 do
    local s = sec + 40 * i
    local vsize, rva, flags = r32(s + 8), r32(s + 12), r32(s + 36)
    if bit.band(flags, 0x20000000) ~= 0 and vsize > 0x100000 and not code then code = { rva = rva, size = vsize } end
  end
  return { stamp = stamp, image = image, code = code }
end
local function code_text(module, info)
  local text = read_string(tonumber(ffi.cast('uintptr_t', module)) + info.code.rva, info.code.size)
  assert(text, 'cannot read the game code')
  return text, info.code.rva
end

local function file_sha256(module)
  local path = ffi.new('uint16_t[4096]')
  local n = K32.TmGetModuleFileNameW(module, path, 4096)
  assert(n > 0 and n < 4096, 'module path')
  local file = K32.TmCreateFileW(path, 0x80000000, 7, nil, 3, 0x08000000, nil)
  assert(file ~= ffi.cast('void *', -1), 'cannot open module file')
  local alg, hash = ffi.new('void *[1]'), ffi.new('void *[1]')
  local ok, res = pcall(function()
    assert(BCRYPT.TmBCryptOpenAlgorithmProvider(alg, ffi.new('uint16_t[?]', 7, { 83, 72, 65, 50, 53, 54, 0 }), nil, 0) == 0, 'sha256')
    assert(BCRYPT.TmBCryptCreateHash(alg[0], hash, nil, 0, nil, 0, 0) == 0, 'sha256')
    local buf, got = ffi.new('uint8_t[262144]'), ffi.new('uint32_t[1]')
    while true do
      assert(K32.TmReadFile(file, buf, 262144, got, nil) ~= 0, 'read module file')
      if got[0] == 0 then break end
      assert(BCRYPT.TmBCryptHashData(hash[0], buf, got[0], 0) == 0, 'sha256')
    end
    local out = ffi.new('uint8_t[32]')
    assert(BCRYPT.TmBCryptFinishHash(hash[0], out, 32, 0) == 0, 'sha256')
    local t = {}
    for i = 0, 31 do t[#t + 1] = string.format('%02X', out[i]) end
    return table.concat(t)
  end)
  if hash[0] ~= nil then BCRYPT.TmBCryptDestroyHash(hash[0]) end
  if alg[0] ~= nil then BCRYPT.TmBCryptCloseAlgorithmProvider(alg[0], 0) end
  K32.TmCloseHandle(file)
  if not ok then error(res, 0) end
  return res
end

-- the address a pattern points at: the end of its RIP displacement + the displacement
local function target_of(text, rva, o, disp_at) return rva + o + disp_at + 4 + si32(text, o + disp_at) end
local function resolve_item(text, rva, pats, what)
  local val
  for _, p in ipairs(pats) do
    local o = find_once(text, p.p)
    if o then
      local v = target_of(text, rva, o, p.disp_at)
      if val and val ~= v then error(what .. ': patterns disagree', 0) end
      val = v
    end
  end
  if not val then error(what .. ': not found', 0) end
  return val
end

-- Learning: every 'mov reg, [rip+disp]' (48/4c 8b, modrm 00 xxx 101) that loads one of the wanted addresses, with
-- 24 bytes from the instruction on as a pattern. Bytes that change between builds are wildcarded: the load's own
-- displacement, call/jmp/jcc targets and other RIP-relative displacements. Only patterns that match exactly once
-- in this build are kept (up to 3 per item).
local function learn(text, rva, wanted)
  local by_target = {}
  for name, v in pairs(wanted) do by_target[v] = name end
  local found = {}
  local needles = {}
  for _, rex in ipairs({ 0x48, 0x4C }) do
    for reg = 0, 7 do needles[#needles + 1] = string.char(rex, 0x8B, reg * 8 + 5) end
  end
  for _, needle in ipairs(needles) do
    local init = 1
    while true do
      local s = string.find(text, needle, init, true)
      if not s then break end
      init = s + 1
      if s + 6 <= #text then
        local o = s - 1
        local name = by_target[target_of(text, rva, o, 3)]
        if name and o + 24 <= #text then
          found[name] = found[name] or {}
          local list = found[name]
          if #list < 12 then list[#list + 1] = o end
        end
      end
    end
  end
  local out = {}
  for name, sites in pairs(found) do
    out[name] = {}
    for _, o in ipairs(sites) do
      local hex, wild = {}, {}
      for k = 3, 6 do wild[k] = true end
      for k = 7, 23 do
        local b, prev = text:byte(o + k + 1), text:byte(o + k)
        if k + 4 <= 24 and (prev == 0xE8 or prev == 0xE9 or (prev and prev >= 0x80 and prev <= 0x8F and text:byte(o + k - 1) == 0x0F)
            or (prev and bit.band(prev, 0xC7) == 5 and k >= 9 and (text:byte(o + k - 1) == 0x8B or text:byte(o + k - 1) == 0x8D
            or text:byte(o + k - 1) == 0x89 or text:byte(o + k - 1) == 0x3B or text:byte(o + k - 1) == 0x39))) then
          for q = k, k + 3 do wild[q] = true end
        end
        local _ = b
      end
      for k = 0, 23 do hex[#hex + 1] = wild[k] and '??' or string.format('%02x', text:byte(o + k + 1)) end
      local p = table.concat(hex)
      if find_once(text, p) == o and #out[name] < 3 then out[name][#out[name] + 1] = { p = p, disp_at = 3, site = rva + o } end
    end
  end
  return out
end

-- cache: one small Lua table file next to the log
local CACHE = LOGDIR and (LOGDIR .. '\\TreasureMap.cache') or nil
local function serialize(v)
  if type(v) == 'table' then
    local keys, t = {}, {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(keys) do
      t[#t + 1] = '[' .. (type(k) == 'number' and tostring(k) or string.format('%q', k)) .. ']=' .. serialize(v[k])
    end
    return '{' .. table.concat(t, ',') .. '}'
  elseif type(v) == 'string' then return string.format('%q', v) end
  return tostring(v)
end
local function cache_load()
  if not CACHE then return nil end
  local f = io.open(CACHE, 'r'); if not f then return nil end
  local s = f:read('*a'); f:close()
  local fn = loadstring('return ' .. s)
  if not fn then return nil end
  setfenv(fn, {})
  local ok, t = pcall(fn)
  return ok and type(t) == 'table' and t or nil
end
local function cache_save(t)
  if not CACHE then return end
  local f = io.open(CACHE, 'w'); if not f then return end
  f:write(serialize(t)); f:close()
end

