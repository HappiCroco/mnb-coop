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
local msgs = nil               -- ISteamNetworkingMessages
steam.p2p = false              -- the game data can go over Steam
steam.SESSION_REQUEST = 1251   -- SteamNetworkingMessagesSessionRequest_t (k_iSteamNetworkingMessagesCallbacks + 1)
local SNI_SIZE = 136           -- SteamNetworkingIdentity
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
        typedef struct { int32_t eType; int32_t cbSize; union { uint64_t steamID64; char buf[128]; } u; } coop_sni;
        typedef struct {
            void *data; int32_t size; uint32_t conn; coop_sni peer; int64_t connUserData;
            int64_t usecTime; int64_t msgNum; void *freeData; void *release; int32_t channel;
            int32_t flags; int64_t userData; uint16_t lane; uint16_t pad;
        } coop_snm;
        void *SteamAPI_SteamNetworkingMessages_SteamAPI_v002(void);
        void *SteamAPI_SteamNetworkingUtils_SteamAPI_v004(void);
        void SteamAPI_ISteamNetworkingUtils_InitRelayNetworkAccess(void *self);
        int SteamAPI_ISteamNetworkingMessages_SendMessageToUser(void *self, const coop_sni *id, const void *data,
            uint32_t size, int flags, int channel);
        int SteamAPI_ISteamNetworkingMessages_ReceiveMessagesOnChannel(void *self, int channel, coop_snm **out, int max);
        bool SteamAPI_ISteamNetworkingMessages_AcceptSessionWithUser(void *self, const coop_sni *id);
        bool SteamAPI_ISteamNetworkingMessages_CloseSessionWithUser(void *self, const coop_sni *id);
        void SteamAPI_SteamNetworkingMessage_t_Release(coop_snm *self);
        void SteamAPI_SteamNetworkingIdentity_SetSteamID64(coop_sni *self, uint64_t id);
        uint64_t SteamAPI_SteamNetworkingIdentity_GetSteamID64(coop_sni *self);
        void SteamAPI_RunCallbacks(void);
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
    -- Steam's peer-to-peer messages (the game data over Steam's relays: no address, no port)
    pcall(function()
        msgs = lib.SteamAPI_SteamNetworkingMessages_SteamAPI_v002()
        local utils = lib.SteamAPI_SteamNetworkingUtils_SteamAPI_v004()
        if utils ~= nil and utils ~= ffi.NULL then lib.SteamAPI_ISteamNetworkingUtils_InitRelayNetworkAccess(utils) end
    end)
    steam.p2p = msgs ~= nil and msgs ~= ffi.NULL
    if steam.p2p then steam.hookSessionRequests() end
    print("[mnb_coop] steam: ready (Join Game and invites" .. (steam.p2p and ", connections over Steam)" or ")"))
    return true
end

-- A Steam callback, registered next to the game's own: Steam calls an object
-- { vtable, flags, callback id } whose vtable has Run(param), Run(param, ioFailure, call)
-- (MSVC puts overloads in reverse order, so both slots get the same function: the
-- extra arguments are ignored) and GetCallbackSizeBytes. `fn(param)` runs inside Steam's
-- callback run: it must be quick and must not fail (it is wrapped).
local function hookCallback(id, size, fn)
    local run = ffi.cast("void (*)(void *, void *, bool, uint64_t)", function(_, param)
        local ok, err = pcall(fn, param)
        if not ok then print("[mnb_coop] steam callback " .. id .. ": " .. tostring(err)) end
    end)
    local sizeFn = ffi.cast("int (*)(void *)", function() return size end)
    local vtbl = ffi.new("void *[3]")
    vtbl[0], vtbl[1], vtbl[2] = ffi.cast("void *", run), ffi.cast("void *", run), ffi.cast("void *", sizeFn)
    local cb = ffi.new("coop_steam_cb")
    cb.vtbl, cb.flags, cb.icallback = vtbl, 0, id
    lib.SteamAPI_RegisterCallback(cb, id)
    anchors[#anchors + 1] = { cb, vtbl, run, sizeFn }
end

-- GameRichPresenceJoinRequested_t, while the game runs
function steam.hookJoinRequests()
    if anchors.join then return end
    local ok, err = pcall(hookCallback, steam.JOIN_REQUESTED, JOIN_SIZE, function(param)
        local j = ffi.cast("coop_steam_join *", param)
        local s = ffi.string(j.connect, 255):match("^[^%z]*")
        steam.requestJoin(steam.parseConnect(s), "invite or Join Game")
    end)
    anchors.join = ok
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

-- =============================================================================
-- CONNECTIONS OVER STEAM (ISteamNetworkingMessages: Steam's relays, no address, no port)
-- owner, 2026-11-12: "do step 2, I really hate playit.gg"
-- coop_net talks to an enet host and enet peers; this is a stand-in with the same calls:
--   transport:service(0) -> { type = "connect"|"receive"|"disconnect", peer, data, channel } or nil
--   transport:flush(), :destroy(), :total_sent_data(), :total_received_data(), :connect(steamId)
--   peer:send(data, channel), :round_trip_time(), :last_round_trip_time(), :disconnect_now(),
--   :disconnect_later(), :timeout() (no-op)
-- Steam's messages have no connections, so a small handshake on channel 2 makes them:
--   "\1hi" (joiner, repeated until answered) -> "\1ok" (host) = connected;
--   "\1p<t>" / "\1q<t>" every second = keep-alive and round trip; "\1by" = leaving;
--   nothing heard for net.TIMEOUT[2] = gone.
-- Data (channels 0 and 1) is sent reliable and in order, as with enet. A host only takes
-- data from a Steam id that said hi; a joiner only from the host it called. The co-op's
-- own guard (join code, rate limits, strikes) works on top, as with enet.
-- =============================================================================
local SEND_RELIABLE = 8 + 1 + 32   -- reliable, no Nagle delay, restart a broken session
local SEND_UNRELIABLE = 1 + 32
local CTRL = 2                     -- the handshake channel
local MAX_PER_PUMP = 64

local acceptFrom = {}              -- steam id -> true: sessions this machine accepts (callback 1251)
steam.acceptAll = false            -- hosting over Steam: anyone may knock (the guard decides)

-- SteamNetworkingMessagesSessionRequest_t: someone wants to talk. Accepted when hosting
-- over Steam, or when it's the host this machine is joining.
function steam.hookSessionRequests()
    if anchors.session then return end
    local ok, err = pcall(hookCallback, steam.SESSION_REQUEST, SNI_SIZE, function(param)
        local id = ffi.cast("coop_sni *", param)
        local sid = (tostring(id.u.steamID64):gsub("ULL$", ""))
        if steam.acceptAll or acceptFrom[sid] then
            lib.SteamAPI_ISteamNetworkingMessages_AcceptSessionWithUser(msgs, id)
        end
    end)
    anchors.session = ok
    if not ok then print("[mnb_coop] steam: session requests: " .. tostring(err)) end
end

local function identity(sid)
    local id = ffi.new("coop_sni")
    -- (a 17-digit id doesn't fit a double: build the uint64 from its text)
    local v = ffi.new("uint64_t", 0)
    for d in tostring(sid):gmatch("%d") do v = v * 10 + (d:byte() - 48) end
    lib.SteamAPI_SteamNetworkingIdentity_SetSteamID64(id, v)
    return id
end

function steam.validId(s)
    return type(s) == "string" and s:match("^%d+$") ~= nil and #s >= 15 and #s <= 20
end

local Peer = {}
Peer.__index = Peer

function Peer:send(data, channel)
    if self.closed then return end
    self.T:sendRaw(self, data, channel or 0, true)
end
function Peer:round_trip_time() return self.rtt end
function Peer:last_round_trip_time() return self.lastRtt end
function Peer:timeout() end
function Peer:disconnect_now()
    if self.closed then return end
    self.T:sendRaw(self, "\1by", CTRL, true)
    self.T:forget(self)
end
Peer.disconnect_later = Peer.disconnect_now

local Transport = {}
Transport.__index = Transport

-- role "host": anyone may say hi; role "client": only the host called with :connect.
function steam.newTransport(role)
    if not (steam.ok and steam.p2p) then return nil end
    local T = setmetatable({ role = role, peers = {}, queue = {}, sent = 0, recv = 0, lastPing = 0 }, Transport)
    if role == "host" then steam.acceptAll = true end
    return T
end

function Transport:newPeer(sid)
    local now = love.timer.getTime()
    local p = setmetatable({ T = self, sid = sid, id = identity(sid), heard = now, rtt = 100, lastRtt = 100,
        connected = false, closed = false }, Peer)
    self.peers[sid] = p
    acceptFrom[sid] = true
    return p
end

function Transport:forget(p)
    p.closed = true
    if self.peers[p.sid] == p then self.peers[p.sid] = nil end
    acceptFrom[p.sid] = nil
    pcall(function() lib.SteamAPI_ISteamNetworkingMessages_CloseSessionWithUser(msgs, p.id) end)
end

function Transport:sendRaw(p, data, channel, reliable)
    local r = lib.SteamAPI_ISteamNetworkingMessages_SendMessageToUser(msgs, p.id, data, #data,
        reliable and SEND_RELIABLE or SEND_UNRELIABLE, channel)
    self.sent = self.sent + #data
    return r == 1
end

-- client: call the host (its Steam id). The connect event comes when it answers.
function Transport:connect(sid)
    local p = self:newPeer(sid)
    self.server = p
    self:sendRaw(p, "\1hi", CTRL, true)
    p.hiAt = love.timer.getTime()
    return p
end

local function ms(t) return math.floor(t * 1000 + 0.5) end

-- read what Steam has for us, turn it into enet-like events
function Transport:pump()
    local now = love.timer.getTime()
    self.out = self.out or ffi.new("coop_snm *[?]", MAX_PER_PUMP)
    local out = self.out
    local byes = {}
    for _, ch in ipairs({ CTRL, 0, 1 }) do
        local n = lib.SteamAPI_ISteamNetworkingMessages_ReceiveMessagesOnChannel(msgs, ch, out, MAX_PER_PUMP)
        for i = 0, n - 1 do
            local m = out[i]
            local sid = (tostring(m.peer.u.steamID64):gsub("ULL$", "")) -- (SteamNetworkingIdentity: type, size, id)
            local data = ffi.string(m.data, m.size)
            lib.SteamAPI_SteamNetworkingMessage_t_Release(m)
            self.recv = self.recv + #data
            local p = self.peers[sid]
            if ch == CTRL then
                local kind = data:sub(1, 3)
                if kind == "\1hi" and self.role == "host" then
                    if not p then
                        p = self:newPeer(sid)
                        p.connected = true
                        self.queue[#self.queue + 1] = { type = "connect", peer = p }
                    end
                    p.heard = now
                    self:sendRaw(p, "\1ok", CTRL, true)
                elseif p then
                    p.heard = now
                    if kind == "\1ok" and self.role == "client" and p == self.server and not p.connected then
                        p.connected = true
                        self.queue[#self.queue + 1] = { type = "connect", peer = p }
                    elseif data:sub(1, 2) == "\1p" then
                        self:sendRaw(p, "\1q" .. data:sub(3, 40), CTRL, false)
                    elseif data:sub(1, 2) == "\1q" then
                        local t = tonumber(data:sub(3, 40))
                        if t then
                            p.lastRtt = math.max(0, ms(now) - t)
                            p.rtt = math.floor(p.rtt * 0.8 + p.lastRtt * 0.2)
                        end
                    elseif kind == "\1by" then
                        -- after this pump's data: a "refuse" sent just before the bye comes first
                        byes[#byes + 1] = p
                    end
                end
            elseif p and p.connected then
                p.heard = now
                self.queue[#self.queue + 1] = { type = "receive", peer = p, data = data, channel = ch }
            end
        end
    end
    for _, p in ipairs(byes) do
        if not p.closed then
            self:forget(p)
            self.queue[#self.queue + 1] = { type = "disconnect", peer = p }
        end
    end
    -- keep-alive, round trip, the joiner's repeated hi, and peers gone quiet
    local quiet = ((net.TIMEOUT and net.TIMEOUT[2]) or 20000) / 1000
    for _, p in pairs(self.peers) do
        if not p.connected and self.role == "client" and now - (p.hiAt or 0) > 0.5 then
            p.hiAt = now
            self:sendRaw(p, "\1hi", CTRL, true)
        end
        if p.connected and now - self.lastPing >= 1 then self:sendRaw(p, "\1p" .. ms(now), CTRL, false) end
        if p.connected and now - p.heard > quiet then
            self:forget(p)
            self.queue[#self.queue + 1] = { type = "disconnect", peer = p }
        end
    end
    if now - self.lastPing >= 1 then self.lastPing = now end
end

function Transport:service()
    if #self.queue == 0 then
        local ok, err = pcall(self.pump, self)
        if not ok then error("Steam: " .. tostring(err), 0) end
    end
    return table.remove(self.queue, 1)
end

function Transport:flush() end
function Transport:total_sent_data() return self.sent end
function Transport:total_received_data() return self.recv end

function Transport:destroy()
    for _, p in pairs(self.peers) do
        pcall(function() self:sendRaw(p, "\1by", CTRL, true) end)
        self:forget(p)
    end
    self.peers, self.queue = {}, {}
    if self.role == "host" then steam.acceptAll = false end
end

-- tests: a stand-in for Steam's DLL (after init has declared the types)
function steam._install(fakeLib, fakeMsgs)
    lib, msgs = fakeLib, fakeMsgs
    ffi = ffi or require("ffi")
    steam.ok, steam.p2p = fakeLib ~= nil, fakeLib ~= nil
end

-- Steam callbacks (session requests, join requests) also run here every frame while a
-- Steam connection is up, not only once a second when the game itself asks.
function steam.runCallbacks()
    if steam.ok then pcall(function() lib.SteamAPI_RunCallbacks() end) end
end

return steam
