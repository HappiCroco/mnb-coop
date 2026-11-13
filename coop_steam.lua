-- =============================================================================
-- STEAM JOIN: "Join Game" in the Steam friends list, and Steam's invite window
-- (owner, 2026-11-12: "URB doesn't need to do anything? Let's go!")
-- The game ships Steam's own steam_api64.dll (a recent SDK: Friends v017, Apps v008,
-- NetworkingMessages v002...). Its flat C functions are called here through LuaJIT's FFI;
-- the game's luasteam is not changed and no file in the game folder is touched.
--   * Host: Steam rich presence key "connect" = "+mnb_coop <address>". Steam shows friends a
--     Join Game button; the overlay's invite window sends the same string.
--   * Friend, game closed: Steam starts the game with that string on the command line (`arg`).
--   * Friend, game running: Steam posts GameRichPresenceJoinRequested_t (callback 337). The
--     game's luasteam already runs Steam's callbacks (steamz, every second, external.lua:27);
--     ours is registered next to its own with SteamAPI_RegisterCallback, as a hand-built
--     callback object (a vtable of LuaJIT callbacks).
--   * Either way the address is joined the usual way (coop_net). Step 2 (later) moves the
--     game data itself onto Steam's relays (ISteamNetworkingMessages).
-- Anything missing (no Steam, an older DLL, tests) and this module just reports unavailable.
-- =============================================================================
local net = require("includes/mods/mnb_coop/coop_net")

local steam = {}

steam.PREFIX = "+mnb_coop"     -- the connect string: "+mnb_coop <address#code>"
steam.JOIN_REQUESTED = 337      -- k_iSteamFriendsCallbacks (300) + 37
local JOIN_SIZE = 8 + 256       -- GameRichPresenceJoinRequested_t: CSteamID, char[256] (pack 8)

local ffi, lib = nil, nil
local friends, apps, user = nil, nil, nil
steam.ok = false
steam.why = "not started"
steam.pending = nil            -- an address a Steam join asked for, waiting for the menus
local anchors = {}             -- the callback object, its vtable and the LuaJIT callbacks (kept alive)
local presence = nil           -- the "connect" value Steam has now

local function log(fmt, ...)
    if net.isOn("debug", false) then print("[mnb_coop] steam: " .. string.format(fmt, ...)) end
end

-- the address inside a connect string (or a command line), or nil
function steam.parseConnect(s)
    if type(s) ~= "string" then return nil end
    local a = s:match("%+mnb_coop%s+([%w%.%-:_#]+)")
    if a and #a >= 3 and #a <= 64 then return a end
    return nil
end

-- Called when a join came in (callback or command line): kept until the menus can take it.
function steam.requestJoin(address, from)
    if type(address) ~= "string" then return end
    local a = steam.parseConnect(steam.PREFIX .. " " .. address)
    if not a then return end
    steam.pending = a
    print("[mnb_coop] steam: join requested (" .. tostring(from) .. ")")
end

function steam.init()
    if steam.ok then return true end
    if not net.isOn("steamJoin", true) then steam.why = "turned off in the co-op options" return false end
    local okf, f = pcall(require, "ffi")
    if not okf then steam.why = "no ffi" return false end
    ffi = f
    local okd, err = pcall(ffi.cdef, [[
        void *SteamAPI_SteamFriends_v017(void);
        void *SteamAPI_SteamApps_v008(void);
        void *SteamAPI_SteamUser_v021(void);
        uint64_t SteamAPI_ISteamUser_GetSteamID(void *self);
        bool SteamAPI_ISteamFriends_SetRichPresence(void *self, const char *key, const char *value);
        void SteamAPI_ISteamFriends_ActivateGameOverlayInviteDialogConnectString(void *self, const char *connect);
        int SteamAPI_ISteamApps_GetLaunchCommandLine(void *self, char *buf, int size);
        void SteamAPI_RegisterCallback(void *cb, int icallback);
        void SteamAPI_UnregisterCallback(void *cb);
        typedef struct { void **vtbl; uint8_t flags; int32_t icallback; } coop_steam_cb;
        typedef struct { uint64_t friendId; char connect[256]; } coop_steam_join;
    ]])
    if not okd then steam.why = "cdef: " .. tostring(err) return false end
    local okl, l = pcall(ffi.load, "steam_api64")
    if not okl then steam.why = "no steam_api64.dll" return false end
    lib = l
    local oki = pcall(function()
        friends, apps, user = lib.SteamAPI_SteamFriends_v017(), lib.SteamAPI_SteamApps_v008(), lib.SteamAPI_SteamUser_v021()
    end)
    if not oki or friends == nil or friends == ffi.NULL or apps == nil or apps == ffi.NULL then
        steam.why = "Steam isn't running for this game"
        return false
    end
    steam.ok = true
    steam.why = nil
    steam.hookJoinRequests()
    steam.readCommandLine()
    print("[mnb_coop] steam: ready (Join Game and invites)")
    return true
end

-- GameRichPresenceJoinRequested_t, while the game runs. The object Steam calls is
-- { vtable, flags, callback id }; the vtable has Run(param), Run(param, ioFailure, call)
-- (MSVC puts overloads in reverse order, so both slots get the same function: the
-- extra arguments are ignored) and GetCallbackSizeBytes.
function steam.hookJoinRequests()
    if anchors.cb then return end
    local ok, err = pcall(function()
        local run = ffi.cast("void (*)(void *, void *, bool, uint64_t)", function(_, param)
            -- inside Steam's callback run: copy the string out, nothing else
            pcall(function()
                local j = ffi.cast("coop_steam_join *", param)
                local s = ffi.string(j.connect, 255)
                s = s:match("^[^%z]*")
                steam.requestJoin(steam.parseConnect(s), "invite or Join Game")
            end)
        end)
        local size = ffi.cast("int (*)(void *)", function() return JOIN_SIZE end)
        local vtbl = ffi.new("void *[3]")
        vtbl[0], vtbl[1], vtbl[2] = ffi.cast("void *", run), ffi.cast("void *", run), ffi.cast("void *", size)
        local cb = ffi.new("coop_steam_cb")
        cb.vtbl, cb.flags, cb.icallback = vtbl, 0, steam.JOIN_REQUESTED
        lib.SteamAPI_RegisterCallback(cb, steam.JOIN_REQUESTED)
        anchors.cb, anchors.vtbl, anchors.run, anchors.size = cb, vtbl, run, size
    end)
    if not ok then print("[mnb_coop] steam: join requests while running not available: " .. tostring(err)) end
end

-- The game was started by Steam for a join: the connect string is on the command line.
function steam.readCommandLine()
    local parts = {}
    if type(arg) == "table" then
        for _, v in pairs(arg) do if type(v) == "string" then parts[#parts + 1] = v end end
    end
    pcall(function()
        local buf = ffi.new("char[1024]")
        local n = lib.SteamAPI_ISteamApps_GetLaunchCommandLine(apps, buf, 1024)
        if n and n > 0 then parts[#parts + 1] = ffi.string(buf) end
    end)
    local a = steam.parseConnect(table.concat(parts, " "))
    if a then steam.requestJoin(a, "game started from Steam") end
end

function steam.mySteamId()
    if not steam.ok then return nil end
    local ok, id = pcall(function() return lib.SteamAPI_ISteamUser_GetSteamID(user) end)
    if ok and id then return (tostring(id):gsub("ULL$", "")) end
    return nil
end

local function setPresence(value)
    if not steam.ok or presence == value then return end
    local ok = pcall(function() return lib.SteamAPI_ISteamFriends_SetRichPresence(friends, "connect", value or "") end)
    if ok then
        presence = value
        log("Join Game %s", value and value ~= "" and "on" or "off")
    end
end

-- Host: the overlay's invite window, with our connect string.
function steam.openInvite(address)
    if not steam.ok then return false, steam.why end
    local ok, err = pcall(function()
        return lib.SteamAPI_ISteamFriends_ActivateGameOverlayInviteDialogConnectString(friends, steam.PREFIX .. " " .. tostring(address))
    end)
    if not ok then return false, tostring(err) end
    return true
end

-- Every frame. `address` = what friends would type to reach this host (nil when not hosting);
-- `canJoin(a)` = this machine may join `a` now (in the menus, not connected): then it does.
function steam.update(address, room, joinNow)
    if not steam.ok then return end
    -- host: Join Game while there's a free seat
    if net.role == "host" and address and room then
        setPresence(steam.PREFIX .. " " .. address)
    else
        setPresence("")
    end
    -- a join that came in: once the menus can take it
    if steam.pending and joinNow then
        local a = steam.pending
        if joinNow(a) then steam.pending = nil end
    end
end

function steam.shutdown()
    if steam.ok then setPresence("") end
end

return steam
