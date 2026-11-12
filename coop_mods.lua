-- =============================================================================
-- CO-OP MOD CHECK
-- Which mods each player has, and how much a difference matters (owner, 2026-11-12:
-- "say which mod is missing on which side, and how serious it is"). The host runs
-- the battle and friends only watch and give orders, so:
--   * a picture/sound mod (no code) only changes how things look: fine either way;
--   * a code mod only the FRIEND has runs on their screen only: it can't change the
--     host's battle (the host checks every order). Fine;
--   * a code mod only the HOST has changes the battle for everyone. Usually fine, but
--     if it adds new things (soldiers, weapons, pictures), a friend without it may see
--     gaps or errors: CHECK;
--   * a mod marked "both" (below) missing on one side, or with different versions: SERIOUS.
-- A mod can say what co-op needs in its mod.json: "coop": "host" (only the host needs it,
-- e.g. a host's F7 spawn menu), "both" (everyone needs the same version) or "any".
-- Mods are read from <game>/Mods (mod.json, qm.toml, top-level .lua files), as plain text.
-- =============================================================================
local mods = {}

mods.MAX = 64 -- mods listed per player (more are cut off)
local SKIP = { qm = true, mnb_coop = true } -- QuarterMaster's own folder, and the co-op itself (version-checked)

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

-- folder listing through Windows (LuaJIT ffi): no console window, unlike io.popen("dir")
local listDir
do
    local okFfi, ffi = pcall(require, "ffi")
    local okBit, bit = pcall(require, "bit")
    if okFfi and okBit and ffi.os == "Windows" then
        pcall(ffi.cdef, [[
            typedef struct {
                uint32_t attrs; uint32_t t1[2]; uint32_t t2[2]; uint32_t t3[2];
                uint32_t sizeHigh; uint32_t sizeLow; uint32_t r0; uint32_t r1;
                char name[260]; char alt[14];
            } coopFindData;
            void* FindFirstFileA(const char* pattern, coopFindData* data);
            int FindNextFileA(void* handle, coopFindData* data);
            int FindClose(void* handle);
        ]])
        local okType = pcall(ffi.typeof, "coopFindData")
        if okType then
            listDir = function(pattern, wantDirs)
                local out = {}
                local ok = pcall(function()
                    local data = ffi.new("coopFindData")
                    local h = ffi.C.FindFirstFileA(pattern, data)
                    if ffi.cast("intptr_t", h) == -1 then return end
                    repeat
                        local name = ffi.string(data.name)
                        local isDir = bit.band(data.attrs, 0x10) ~= 0
                        if name ~= "." and name ~= ".." and isDir == wantDirs then out[#out + 1] = name end
                    until ffi.C.FindNextFileA(h, data) == 0
                    ffi.C.FindClose(h)
                end)
                if not ok then return nil end
                return out
            end
        end
    end
end
mods._setLister = function(fn) listDir = fn end -- tests
mods._setReader = function(fn) readFile = fn end

function mods.modsDir()
    local base = love.filesystem.getSourceBaseDirectory and love.filesystem.getSourceBaseDirectory()
    if not base then return nil end
    return base .. "/Mods"
end

local function jsonString(text, key)
    return text and text:match('"' .. key .. '"%s*:%s*"([^"]*)"') or nil
end

local function clip(s, n)
    if type(s) ~= "string" then return nil end
    s = s:gsub("[%c]", "")
    return s:sub(1, n)
end

-- One mod folder: { id, n (name), v (version), c (has code: true/false), co (co-op hint) }, or nil.
function mods.describe(dir, folder)
    if SKIP[folder] or folder:sub(1, 1) == "_" or folder:sub(1, 1) == "." then return nil end
    local path = dir .. "/" .. folder
    local json = readFile(path .. "/mod.json")
    if json and json:find('"enabled"%s*:%s*false') then return nil end
    local id = clip(jsonString(json, "id"), 40) or clip(folder, 40)
    if SKIP[id] then return nil end
    local toml = readFile(path .. "/qm.toml")
    local code = toml ~= nil and (toml:find("%[%[patches%]%]") ~= nil or toml:find("%[patches%.") ~= nil)
    if not code and listDir then
        local lua = listDir(path .. "/*.lua", false)
        code = lua ~= nil and #lua > 0
    end
    if not json and not toml then return nil end -- not a QuarterMaster mod (a stray folder)
    local co = jsonString(json, "coop")
    if co ~= "host" and co ~= "both" and co ~= "any" then co = nil end
    return { id = id, n = clip(jsonString(json, "name"), 40) or id, v = clip(jsonString(json, "version"), 20) or "?",
        c = code and true or false, co = co }
end

-- This machine's mods, sorted by id (cached: the folder doesn't change while playing).
local cache
function mods.mine(refresh)
    if cache and not refresh then return cache end
    local list = {}
    local dir = mods.modsDir()
    local folders = dir and listDir and listDir(dir .. "/*", true)
    if folders then
        table.sort(folders)
        for _, folder in ipairs(folders) do
            local ok, m = pcall(mods.describe, dir, folder)
            if ok and m and #list < mods.MAX then list[#list + 1] = m end
        end
        table.sort(list, function(a, b) return a.id < b.id end)
        cache = list
    else
        cache = false -- couldn't read the folder: no check, nothing claimed
    end
    return cache
end

-- A received list, cleaned: only the fields above, with the types and lengths we expect.
function mods.clean(list)
    if type(list) ~= "table" then return nil end
    local out = {}
    for i = 1, math.min(#list, mods.MAX) do
        local m = list[i]
        if type(m) == "table" and type(m.id) == "string" then
            local co = (m.co == "host" or m.co == "both" or m.co == "any") and m.co or nil
            out[#out + 1] = { id = clip(m.id, 40), n = clip(m.n, 40) or clip(m.id, 40), v = clip(m.v, 20) or "?",
                c = m.c == true, co = co }
        end
    end
    return out
end

mods.SEVERITY = { [3] = "SERIOUS", [2] = "CHECK", [1] = "FINE" }

-- Differences between the host's list and one friend's: { { id, n, sev (1-3), text }, ... },
-- worst first. friendName names the friend in the texts.
function mods.compare(hostList, friendList, friendName)
    local out = {}
    if type(hostList) ~= "table" or type(friendList) ~= "table" then return out end
    friendName = friendName or "the friend"
    local byId = {}
    for _, m in ipairs(hostList) do byId[m.id] = { host = m } end
    for _, m in ipairs(friendList) do
        byId[m.id] = byId[m.id] or {}
        byId[m.id].friend = m
    end
    for id, p in pairs(byId) do
        local h, f = p.host, p.friend
        local m = h or f
        local code = (h and h.c) or (f and f.c)
        local co = (h and h.co) or (f and f.co)
        local sev, text
        if h and f then
            if h.v ~= f.v then
                if not code or co == "any" then
                    sev, text = 1, "different versions (" .. h.v .. " / " .. f.v .. "), looks only"
                elseif co == "host" then
                    sev, text = 1, "different versions (" .. h.v .. " / " .. f.v .. "); only the host's counts"
                elseif co == "both" then
                    sev, text = 3, "different versions (host " .. h.v .. ", " .. friendName .. " " .. f.v .. "): update both"
                else
                    sev, text = 2, "different versions (host " .. h.v .. ", " .. friendName .. " " .. f.v .. ")"
                end
            end
        elseif h then
            if not code or co == "any" or co == "host" then
                sev, text = 1, "only the host has it" .. (code and "" or " (pictures/sounds only)")
            elseif co == "both" then
                sev, text = 3, "only the host has it: " .. friendName .. " needs it too"
            else
                sev, text = 2, "only the host has it: if it adds new things, " .. friendName .. " needs it too"
            end
        else
            if co == "both" then
                sev, text = 3, "only " .. friendName .. " has it: the host needs it too"
            else
                sev, text = 1, "only " .. friendName .. " has it" .. (code and " (runs on their screen only)" or " (pictures/sounds only)")
            end
        end
        if sev then out[#out + 1] = { id = id, n = m.n or id, sev = sev, text = text } end
    end
    table.sort(out, function(a, b)
        if a.sev ~= b.sev then return a.sev > b.sev end
        return a.id < b.id
    end)
    return out
end

-- "1 serious, 2 to check, 1 fine" / "Mods match"
function mods.summary(diffs)
    if type(diffs) ~= "table" then return "Mods: not checked" end
    if #diffs == 0 then return "Mods match" end
    local n = { 0, 0, 0 }
    for _, d in ipairs(diffs) do n[d.sev] = n[d.sev] + 1 end
    local parts = {}
    if n[3] > 0 then parts[#parts + 1] = n[3] .. " serious" end
    if n[2] > 0 then parts[#parts + 1] = n[2] .. " to check" end
    if n[1] > 0 then parts[#parts + 1] = n[1] .. " fine" end
    return "Mods differ: " .. table.concat(parts, ", ")
end

function mods.worst(diffs)
    local w = 0
    for _, d in ipairs(diffs or {}) do w = math.max(w, d.sev) end
    return w
end

-- Tooltip lines: "SERIOUS  Name: text"
function mods.lines(diffs, limit)
    local lines = {}
    for i, d in ipairs(diffs or {}) do
        if limit and i > limit then
            lines[#lines + 1] = "... and " .. (#diffs - limit) .. " more"
            break
        end
        lines[#lines + 1] = mods.SEVERITY[d.sev] .. "  " .. d.n .. ": " .. d.text
    end
    return lines
end

return mods
