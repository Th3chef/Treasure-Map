-- HD2-Addon: mods/chef/treasure_map
-- Treasure Map for Helldivers 2 (Bingus Shared Loader v19+ addon).
-- While the tactical map is open it marks what is still lying around in the mission: medals, Common, Rare and Super
-- Samples, Super Credits and Requisition Slips, each in its own color, and counts the mission's Super Credits.
-- Each kind is its own option; with CowboyBingus's Mod Options Menu each kind also gets an opacity slider.
-- Reads game memory only, never writes it, and finds the game's addresses again by itself after a game update.
local VERSION = '1.0.0'
local TESTER = false          -- Tester and numbered test builds: research details in the log
local TEST_BUILD = false      -- numbered test builds only: the log goes to Logs\test

if rawget(_G, 'ChefTreasureMap') then return end
local TM = { version = VERSION, status = 'starting' }
rawset(_G, 'ChefTreasureMap', TM)

local ffi = require('ffi')
local bit = require('bit')
local SR = rawget(_G, 'stingray')

-- ======================================================================================================
-- Windows API (private names, so they never clash with another mod's declarations)
-- ======================================================================================================
for _, d in ipairs({
  'void *TmGetModuleHandleA(const char *name) __asm__("GetModuleHandleA");',
  'uint32_t TmGetModuleFileNameW(void *module, uint16_t *path, uint32_t capacity) __asm__("GetModuleFileNameW");',
  'void *TmGetCurrentProcess(void) __asm__("GetCurrentProcess");',
  'int TmReadProcessMemory(void *process, const void *address, void *buffer, size_t size, size_t *done) __asm__("ReadProcessMemory");',
  'void *TmCreateFileW(const uint16_t *path, uint32_t access, uint32_t share, void *security, uint32_t disposition, uint32_t flags, void *tmpl) __asm__("CreateFileW");',
  'int TmReadFile(void *file, void *buffer, uint32_t size, uint32_t *done, void *overlapped) __asm__("ReadFile");',
  'int TmCloseHandle(void *handle) __asm__("CloseHandle");',
  'int TmCreateDirectoryA(const char *path, void *security) __asm__("CreateDirectoryA");',
  'int TmQueryPerformanceCounter(int64_t *count) __asm__("QueryPerformanceCounter");',
  'int TmQueryPerformanceFrequency(int64_t *freq) __asm__("QueryPerformanceFrequency");',
  'int32_t TmBCryptOpenAlgorithmProvider(void **alg, const uint16_t *id, const uint16_t *impl, uint32_t flags) __asm__("BCryptOpenAlgorithmProvider");',
  'int32_t TmBCryptCloseAlgorithmProvider(void *alg, uint32_t flags) __asm__("BCryptCloseAlgorithmProvider");',
  'int32_t TmBCryptCreateHash(void *alg, void **hash, void *obj, uint32_t objlen, const void *secret, uint32_t secretlen, uint32_t flags) __asm__("BCryptCreateHash");',
  'int32_t TmBCryptHashData(void *hash, const void *data, uint32_t len, uint32_t flags) __asm__("BCryptHashData");',
  'int32_t TmBCryptFinishHash(void *hash, void *out, uint32_t len, uint32_t flags) __asm__("BCryptFinishHash");',
  'int32_t TmBCryptDestroyHash(void *hash) __asm__("BCryptDestroyHash");',
}) do pcall(ffi.cdef, d) end
local K32, BCRYPT = ffi.load('kernel32'), ffi.load('bcrypt')
local PROCESS = K32.TmGetCurrentProcess()

-- ======================================================================================================
-- Log: Logs\TreasureMap.log (numbered test builds: Logs\test\TreasureMap.log)
-- ======================================================================================================
local LOADER = rawget(_G, 'CowboyBingusModLoader')
local V19 = type(LOADER) == 'table' and type(rawget(LOADER, 'capabilities')) == 'table'
  and type(rawget(LOADER, 'after_startup')) == 'function'
local LOGDIR
do
  local dir = type(LOADER) == 'table' and type(rawget(LOADER, 'log_directory')) == 'string' and LOADER.log_directory or nil
  if not dir then
    local base = os.getenv('LOCALAPPDATA')
    dir = base and (base .. '\\CowboyBingus\\Helldivers2\\Logs') or nil
  end
  if dir and TEST_BUILD then
    pcall(K32.TmCreateDirectoryA, dir .. '\\test', nil)
    local f = io.open(dir .. '\\test\\TreasureMap.log', 'a')
    if f then f:close(); dir = dir .. '\\test' end
  end
  LOGDIR = dir
end
local session = { started = os.date('%Y-%m-%d %H:%M:%S'), events = {}, notes = {} }
local function event(msg)
  local e = session.events
  e[#e + 1] = os.date('%H:%M:%S ') .. msg
  if #e > 60 then table.remove(e, 1) end
end
local function note(key, msg) session.notes[key] = msg end      -- the newest line per topic (shown in the log)

-- ======================================================================================================
-- Memory: ReadProcessMemory on our own process (a bad address fails cleanly instead of crashing) into one
-- reusable buffer; numbers are taken straight out of it with typed loads, so no strings are made per read.
-- ======================================================================================================
local stats = { reads = 0, read_fails = 0, frames = 0, map_frames = 0, redraws = 0, list_scans = 0, lookups = 0 }
local BUF_SIZE = 65536
local BUF = ffi.new('uint8_t[?]', BUF_SIZE)
local DONE = ffi.new('size_t[1]')
local PVOID = ffi.typeof('const void *')
local PU32, PU64, PF32 = ffi.typeof('const uint32_t *'), ffi.typeof('const uint64_t *'), ffi.typeof('const float *')
local cast = ffi.cast
local function fetch(addr, n)           -- addr..addr+n into BUF; true or false
  if type(addr) ~= 'number' or addr < 65536 or addr >= 140737488355328 or n <= 0 then return false end
  if n > BUF_SIZE then
    while BUF_SIZE < n do BUF_SIZE = BUF_SIZE * 2 end
    BUF = ffi.new('uint8_t[?]', BUF_SIZE)
  end
  stats.reads = stats.reads + 1
  if K32.TmReadProcessMemory(PROCESS, cast(PVOID, addr), BUF, n, DONE) == 0 or DONE[0] ~= n then
    stats.read_fails = stats.read_fails + 1
    return false
  end
  return true
end
local function b8(o) return BUF[o] end
local function b32(o) return tonumber(cast(PU32, BUF + o)[0]) end
local function b64(o) return tonumber(cast(PU64, BUF + o)[0]) end
local function bf32(o)
  local v = tonumber(cast(PF32, BUF + o)[0])
  if v == nil or v ~= v or v == math.huge or v == -math.huge then return nil end
  return v
end
local function bptr(o)
  local p = b64(o)
  if p < 65536 or p >= 140737488355328 then return nil end
  return p
end
local function bstr(o, n) return ffi.string(BUF + o, n) end
local function read_string(addr, n) return fetch(addr, n) and bstr(0, n) or nil end
local function read_ptr(addr) return fetch(addr, 8) and bptr(0) or nil end
-- numbers out of a kept string (bulk reads that are worked through after the buffer is reused)
local SU32 = ffi.new('uint32_t[1]')
local function su32_at(s, o) ffi.copy(SU32, s:sub(o + 1, o + 4), 4); return tonumber(SU32[0]) end
