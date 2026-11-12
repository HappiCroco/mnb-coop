-- =============================================================================
-- CO-OP NETWORK + LOBBY SESSION
-- LÖVE's built-in enet (UDP). The host owns the lobby: seats 1-4 (1 = host),
-- who is ready, and everyone's card data. Clients only ask; the host decides
-- and broadcasts the result.
--
-- Channels: 0 = reliable (lobby, later events and orders), 1 = snapshots (step 2).
--
-- The host guards itself (our own free "firewall", see GUARD below): a join code,
-- a short deadline to say hello, per-connection rate limits, strikes for junk,
-- and kicks. Anything that fails is dropped before it costs more than a check.
-- =============================================================================
local codec = require("includes/mods/mnb_coop/coop_codec")
local profile = require("includes/mods/mnb_coop/coop_profile")
local modcheck = require("includes/mods/mnb_coop/coop_mods")

local net = {}
-- Mod differences (coop_mods.lua): host: [seat] = that friend's list of differences;
-- friend: [1] = theirs against the host's. Swapped at hello / welcome.
net.modDiffs = {}

local function noteMods(diffs, who)
    if #diffs == 0 or modcheck.worst(diffs) < 2 then return end
    if mnbCoop and mnbCoop.notice then
        mnbCoop.notice(who .. ": " .. modcheck.summary(diffs) .. " (hover the card)")
    end
end

net.VERSION = "0.9.10" -- co-op protocol; must match on both sides
net.DEFAULT_PORT = 47913
-- enet peer timeout (ms): give up on a peer after `min` once its unanswered packets have
-- been resent the limit, and after `max` in any case. Was 3000/8000 (a crashed game noticed
-- fast), but a slow college line or a VPN stalls for longer and the friend was dropped
-- after a few seconds of play (owner, 2026-11-12). 8 s / 20 s rides that out; a crash is
-- still noticed within ~20 s instead of enet's 30.
net.TIMEOUT = { 8000, 20000 }
net.MAX_SEATS = 3     -- up to 3 players for now (owner, 2026-11-11); 4 players with 3 soldiers each comes later
net.SEAT_COLORS = { { 101, 24, 24 }, { 40, 90, 160 }, { 70, 130, 50 }, { 190, 140, 30 } }

net.role = "offline" -- "offline" | "host" | "client" | "connecting"
net.status = "Offline"
net.mySeat = nil
net.seats = {} -- [seat] = { name, steamId, show, face, ready, ping, avatar (Image) }
net.port = net.DEFAULT_PORT

local enet = nil
local host = nil        -- enet host
local server = nil      -- client: the peer we connected to
local peerSeat = {}     -- host: peer -> seat
local seatPeer = {}     -- host: seat -> peer
local avatarBytes = {}  -- host: seat -> png bytes, to forward to late joiners
local avatarImages = {} -- client: seat -> Image (avatars can arrive before the lobby list)
local lastLobbySent = 0
local myJoinCode = nil  -- client: the code we join with

net.joinCode = nil      -- host: code joiners must give (nil = open lobby)
net.blocked = 0         -- host: connections the guard has thrown out

-- A co-op option: modLibrary if it's installed, else the menu's saved value (QuarterMaster 1.8's
-- QM.settings, or the old standalone GMenu's), else `default` (the same default as config.lua).
-- Co-op works without modLibrary and without a menu.
function net.option(id, default)
    local v
    if modLibrary and modLibrary.option then
        v = modLibrary.option("mnb_coop", id)
    else
        local qm = rawget(_G, "QM")
        local qs = type(qm) == "table" and type(rawget(qm, "settings")) == "table" and qm.settings.mnb_coop
        if type(qs) == "table" then v = qs[id] end
        if v == nil then
            local gm = rawget(_G, "GMenu")
            local saved = gm and gm.savedSettings and gm.savedSettings.mnb_coop
            if saved then v = saved[id] end
        end
    end
    if v == nil then return default end
    return v
end

function net.isOn(id, default)
    local v = net.option(id, default)
    return v == true or v == 1
end

local function log(fmt, ...)
    if net.isOn("debug", false) then print("[mnb_coop] " .. string.format(fmt, ...)) end
end

local function loadEnet()
    if enet then return true end
    local ok, mod = pcall(require, "enet")
    if ok then
        enet = mod
        return true
    end
    net.status = "Networking (enet) is not available in this game build"
    return false
end

-- ---------------------------------------------------------------- stats
-- Shown by the network stats panel (coop_hud.lua). Rates are per second, measured
-- over the last full second; byte counts come from enet and include its overhead.
net.stats = { upRate = 0, downRate = 0, totalUp = 0, totalDown = 0, msgsOutRate = 0, msgsInRate = 0 }
local statWindow = { at = 0, up = 0, down = 0, msgsOut = 0, msgsIn = 0 }

local function countIn() statWindow.msgsIn = statWindow.msgsIn + 1 end

local function updateStats(h)
    local now = love.timer.getTime()
    local s = net.stats
    s.totalUp, s.totalDown = h:total_sent_data(), h:total_received_data()
    local dt = now - statWindow.at
    if dt >= 1 then
        s.upRate = (s.totalUp - statWindow.up) / dt
        s.downRate = (s.totalDown - statWindow.down) / dt
        s.msgsOutRate = statWindow.msgsOut / dt
        s.msgsInRate = statWindow.msgsIn / dt
        statWindow.at, statWindow.up, statWindow.down, statWindow.msgsOut, statWindow.msgsIn = now, s.totalUp, s.totalDown, 0, 0
    end
end

-- Ping (round trip, ms) per seat as this machine sees it: the host measures every
-- player, a client only measures the host (seat 1).
function net.pings()
    local out = {}
    if net.role == "host" then
        for seat, peer in pairs(seatPeer) do out[seat] = { avg = peer:round_trip_time(), last = peer:last_round_trip_time() } end
    elseif server and net.role == "client" then
        out[1] = { avg = server:round_trip_time(), last = server:last_round_trip_time() }
    end
    return out
end

-- ---------------------------------------------------------------- sending
-- Every packet on the wire stays under CHUNK bytes. enet splits a bigger one into
-- fragments of its own MTU (1400 + headers), and on some routes (a playit.gg tunnel,
-- PPPoE, a VPN) packets that size never arrive: small ones get through, so the join
-- works, but the first big message (an avatar) never completes, and since channel 0 is
-- reliable and ordered, nothing after it arrives either (owner, 2026-11-11: a friend on
-- another PC sat "Connected" with 0/3 players). So we split big messages ourselves:
--   "\0<total>:<first piece>" then "\0<piece>"..., in order on the same channel,
-- reassembled before decoding. A codec message never starts with "\0".
local CHUNK = 1000
net.CHUNK = CHUNK

local function put(peer, data, channel)
    channel = channel or 0
    if #data <= CHUNK then
        peer:send(data, channel, "reliable")
    else
        local head = "\0" .. #data .. ":"
        local first = CHUNK - #head
        peer:send(head .. data:sub(1, first), channel, "reliable")
        for i = first + 1, #data, CHUNK - 1 do
            peer:send("\0" .. data:sub(i, i + CHUNK - 2), channel, "reliable")
        end
    end
    statWindow.msgsOut = statWindow.msgsOut + 1
end
net._put = put

-- Receiving: returns the whole message once its last piece is in (nil before), or
-- nil, "bad" for a malformed or too-big one. `pending` is per peer and channel.
local pending = setmetatable({}, { __mode = "k" })
local function reassemble(peer, channel, data, maxTotal)
    if data:byte(1) ~= 0 then return data end
    local byPeer = pending[peer]
    if not byPeer then byPeer = {} pending[peer] = byPeer end
    local p = byPeer[channel]
    if not p then
        local total, rest = data:match("^%z(%d+):(.*)$")
        total = tonumber(total)
        if not total or total <= CHUNK or total > maxTotal then return nil, "bad" end
        p = { total = total, got = #rest, parts = { rest } }
        byPeer[channel] = p
    else
        local piece = data:sub(2)
        p.parts[#p.parts + 1] = piece
        p.got = p.got + #piece
    end
    if p.got > p.total then
        byPeer[channel] = nil
        return nil, "bad"
    end
    if p.got == p.total then
        byPeer[channel] = nil
        return table.concat(p.parts)
    end
    return nil
end
net._reassemble = reassemble

local function send(peer, msg, channel)
    if not peer then return end
    local ok, data = pcall(codec.encode, msg)
    if ok then put(peer, data, channel) end
end

local function broadcast(msg, except)
    for seat, peer in pairs(seatPeer) do
        if peer ~= except then send(peer, msg) end
    end
end

-- Battle sync (coop_battle.lua) sends data it has already encoded and packed.
function net.sendRawTo(seat, data, channel)
    local peer = seatPeer[seat]
    if not peer then return end
    put(peer, data, channel)
end

-- skipSeats: optional set of seats that don't get this one
function net.broadcastRaw(data, channel, skipSeats)
    for seat, peer in pairs(seatPeer) do
        if not (skipSeats and skipSeats[seat]) then put(peer, data, channel) end
    end
end

-- Send what's queued now instead of at the next frame's service call.
function net.flush()
    if host then pcall(host.flush, host) end
end

-- Client: an order or a roster for the host (coop_squad.lua, coop_campaign.lua).
function net.sendToHost(msg)
    if net.role == "client" and server then send(server, msg) end
end

-- Host: a message for one seat (mission results).
function net.sendTo(seat, msg)
    if net.role == "host" then send(seatPeer[seat], msg) end
end

-- Hooks set by coop_battle.lua / coop_squad.lua:
--   net.onHostMessage(msg)            client: a message from the host that the lobby doesn't handle
--   net.onSeatJoined(seat)            host: a player got a seat
--   net.onReset()                     the session closed (left, kicked, disconnected, new lobby)
--   net.onClientMessage(seat, msg)    host: an order from a seated player; returns true if understood
--   net.onSeatLeft(seat)              host: a seated player left or was removed
--   net.onWelcome()                   client: the host gave us a seat

-- ---------------------------------------------------------------- GUARD
-- What a stranger who finds the address can do: open a connection and send data.
-- Every connection gets a few seconds to prove it's a co-op player (right version,
-- right join code). Until then, and afterwards too, each one is limited in how
-- much it may send; junk earns strikes; too much of either and it's cut off.
local GUARD = {
    MAX_PEERS = 16,          -- enet slots: room for players plus a few strangers being turned away
    HELLO_TIMEOUT = 5,       -- seconds to send a valid hello
    MAX_PACKET = 200 * 1024, -- an avatar is ~50 KB; nothing legit is bigger
    MAX_MSGS = 60,           -- per second per connection
    MAX_BYTES = 400 * 1024,  -- per second per connection
    MAX_STRIKES = 5,         -- malformed or unexpected messages
}
net.GUARD = GUARD
local guard = {}                               -- host: peer -> { joinedAt, strikes, msgs, bytes, window }
local kickedIds = {}                           -- host: steamId -> true, refused for the rest of this lobby
local CODE_CHARS = "ACDEFGHJKMNPQRTUVWXY34679" -- no look-alikes (0/O, 1/I, 5/S, 8/B)

local hostDisconnect                           -- defined below

local function drop(peer, why)
    if peerSeat[peer] then hostDisconnect(peer) end
    guard[peer] = nil
    pcall(peer.disconnect_now, peer)
    net.blocked = net.blocked + 1
    log("dropped a connection: %s", why)
end

local function strike(peer, why)
    local g = guard[peer]
    if not g then return end
    g.strikes = g.strikes + 1
    if g.strikes >= GUARD.MAX_STRIKES then drop(peer, "too much junk (" .. why .. ")") end
end

-- true if this packet may be looked at. kind "piece": a piece of a split message, counts
-- its bytes; kind "whole": that message once it's reassembled, counts once as a message
-- (its bytes were counted piece by piece); otherwise a plain packet counts both.
local function admit(peer, size, kind)
    local g = guard[peer]
    if not g then return false end
    local now = love.timer.getTime()
    if now - g.window >= 1 then g.window, g.msgs, g.bytes = now, 0, 0 end
    if kind == "piece" then
        g.bytes = g.bytes + size
        if g.bytes > GUARD.MAX_BYTES then
            drop(peer, "flooding")
            return false
        end
        return true
    end
    g.msgs = g.msgs + 1
    if kind ~= "whole" then g.bytes = g.bytes + size end
    if g.msgs > GUARD.MAX_MSGS or g.bytes > GUARD.MAX_BYTES then
        drop(peer, "flooding")
        return false
    end
    if size > GUARD.MAX_PACKET then
        strike(peer, "oversized packet")
        return false
    end
    return true
end

function net.newJoinCode()
    local code = {}
    for i = 1, 5 do
        local n = love.math.random(1, #CODE_CHARS)
        code[i] = CODE_CHARS:sub(n, n)
    end
    net.joinCode = table.concat(code)
    return net.joinCode
end

-- ---------------------------------------------------------------- my card
local function myCard()
    return {
        name = profile.name(),
        steamId = profile.steamId(),
        show = profile.showcase(),
        face = profile.face(),
        ready = false,
    }
end

local function cleanCard(c)
    -- a remote card: keep only the fields we know, with the types we expect
    if type(c) ~= "table" then return nil end
    local out = {}
    out.name = type(c.name) == "string" and c.name:sub(1, 32) or "Soldier"
    out.steamId = type(c.steamId) == "string" and c.steamId:match("^%d+$") and c.steamId or nil
    out.show = type(c.show) == "table" and { kind = tostring(c.show.kind or "none"):sub(1, 10), n = tonumber(c.show.n) } or { kind = "none" }
    local f = type(c.face) == "table" and c.face or {}
    out.face = { eyes = tonumber(f.eyes) or 1, nose = tonumber(f.nose) or 1, mouth = tonumber(f.mouth) or 1, hair = tonumber(f.hair) or 1 }
    out.ready = c.ready == true
    out.ping = tonumber(c.ping)
    out.where = net.WHERE[c.where] and c.where or nil
    return out
end

-- lobby view sent to clients: cards without the avatar images
local function lobbyView()
    local seats = {}
    for i = 1, net.MAX_SEATS do
        local s = net.seats[i]
        if s then
            seats[i] = { name = s.name, steamId = s.steamId, show = s.show, face = s.face, ready = s.ready, ping = s.ping,
                where = s.where }
        else
            seats[i] = false
        end
    end
    return seats
end

local function freeSeat()
    for i = 2, net.MAX_SEATS do
        if not net.seats[i] then return i end
    end
    return nil
end

local function setAvatar(seat, data)
    local s = net.seats[seat]
    if s and data then s.avatar = profile.imageFromBytes(data, "seat" .. seat) end
end

-- ---------------------------------------------------------------- host side
local function hostReceive(peer, msg)
    local seat = peerSeat[peer]
    if msg.t == "hello" then
        if seat then
            strike(peer, "second hello")
            return
        end
        if net.joinCode and tostring(msg.code or ""):upper() ~= net.joinCode then
            send(peer, { t = "refuse", why = "Wrong or missing join code (ask the host to COPY ADDRESS again)" })
            peer:disconnect_later()
            net.blocked = net.blocked + 1
            return
        end
        if msg.v ~= net.VERSION then
            send(peer, { t = "refuse", why = "Co-op version mismatch: host has " .. net.VERSION .. ", you have " .. tostring(msg.v) })
            peer:disconnect_later()
            return
        end
        if msg.game ~= currentVersion then
            send(peer, { t = "refuse", why = "Game version mismatch: host runs " .. tostring(currentVersion) })
            peer:disconnect_later()
            return
        end
        if msg.samePC == true then net.friendOnSamePC = true end -- the windows get stacked (mnb_coop_main)
        local free = freeSeat()
        if not free then
            send(peer, { t = "refuse", why = "Lobby is full" })
            peer:disconnect_later()
            return
        end
        local card = cleanCard(msg.card) or myCard()
        if card.steamId and kickedIds[card.steamId] then
            send(peer, { t = "refuse", why = "The host removed you from this lobby" })
            peer:disconnect_later()
            return
        end
        card.ready = false
        net.seats[free] = card
        peerSeat[peer], seatPeer[free] = free, peer
        -- the mod check: their list against ours (an older co-op sends none: no check)
        local mine, theirs = modcheck.mine(), modcheck.clean(msg.mods)
        net.modDiffs[free] = (mine and theirs) and modcheck.compare(mine, theirs, card.name) or nil
        if net.modDiffs[free] then noteMods(net.modDiffs[free], card.name) end
        send(peer, { t = "welcome", seat = free, mods = mine or nil })
        -- everyone's avatar to the newcomer
        for s, bytes in pairs(avatarBytes) do send(peer, { t = "avatar", seat = s, data = bytes }) end
        net.status = card.name .. " joined"
        log("seat %d: %s joined", free, card.name)
        lastLobbySent = 0
        if net.onSeatJoined then
            local ok, err = pcall(net.onSeatJoined, free)
            if not ok then print("[mnb_coop] seat joined: " .. tostring(err)) end
        end
    elseif not seat then
        strike(peer, "message before hello") -- nothing else is accepted before hello
    elseif msg.t == "ready" then
        net.seats[seat].ready = msg.on == true
        lastLobbySent = 0
    elseif msg.t == "where" then
        -- where this player is (lobby, campaign, battle report...), shown on their card
        if net.WHERE[msg.w] and net.seats[seat].where ~= msg.w then
            net.seats[seat].where = msg.w
            lastLobbySent = 0
        end
    elseif msg.t == "card" then
        local card = cleanCard(msg.card)
        if card then
            card.ready, card.avatar, card.where = net.seats[seat].ready, net.seats[seat].avatar, net.seats[seat].where
            net.seats[seat] = card
            lastLobbySent = 0
        end
    elseif msg.t == "avatar" then
        if profile.isPng(msg.data) then
            avatarBytes[seat] = msg.data
            setAvatar(seat, msg.data)
            broadcast({ t = "avatar", seat = seat, data = msg.data }, peer)
        else
            strike(peer, "bad avatar")
        end
    else
        -- battle orders (coop_squad.lua) say whether they understood the message
        local ok, handled = false, false
        if net.onClientMessage then ok, handled = pcall(net.onClientMessage, seat, msg) end
        if not (ok and handled) then strike(peer, "unknown message") end
    end
end

function hostDisconnect(peer)
    local seat = peerSeat[peer]
    if not seat then return end
    local name = net.seats[seat] and net.seats[seat].name or "A player"
    net.seats[seat], peerSeat[peer], seatPeer[seat], avatarBytes[seat] = nil, nil, nil, nil
    net.modDiffs[seat] = nil
    broadcast({ t = "gone", seat = seat })
    net.status = name .. " left"
    lastLobbySent = 0
    if net.onSeatLeft then
        local ok, err = pcall(net.onSeatLeft, seat)
        if not ok then print("[mnb_coop] seat left: " .. tostring(err)) end
    end
end

-- ---------------------------------------------------------------- client side
local function clientReceive(msg)
    if msg.t == "welcome" then
        net.role, net.mySeat = "client", tonumber(msg.seat)
        net.status = "Connected"
        local mine, hostMods = modcheck.mine(), modcheck.clean(msg.mods)
        net.modDiffs = { [1] = (mine and hostMods) and modcheck.compare(hostMods, mine, "you") or nil }
        if net.modDiffs[1] then noteMods(net.modDiffs[1], "The host") end
        local bytes = profile.avatarBytes()
        if bytes then
            send(server, { t = "avatar", data = bytes })
            -- our own card: the host forwards our avatar to everyone but us, so set it here
            -- (without this a friend saw a default soldier's face on their own card)
            if net.mySeat then
                avatarImages[net.mySeat] = profile.imageFromBytes(bytes, "seat" .. net.mySeat)
                if net.seats[net.mySeat] then net.seats[net.mySeat].avatar = avatarImages[net.mySeat] end
            end
        end
        if net.onWelcome then
            local ok, err = pcall(net.onWelcome)
            if not ok then print("[mnb_coop] welcome: " .. tostring(err)) end
        end
    elseif msg.t == "refuse" then
        net.status = "Refused: " .. tostring(msg.why)
    elseif msg.t == "lobby" and type(msg.seats) == "table" then
        -- what the host is getting ready to start (the ready room), or nil
        net.stage = type(msg.stage) == "string" and (msg.stage:gsub("[%c]", " "):sub(1, 40)) or nil
        for i = 1, net.MAX_SEATS do
            local card = msg.seats[i] and cleanCard(msg.seats[i]) or nil
            if card then card.avatar = avatarImages[i] end
            net.seats[i] = card
        end
        -- my READY click is on its way to the host: show it until the host's lobby agrees
        -- (or 3 s pass), so a lobby update sent before the click doesn't flip it back
        local mine = net.mySeat and net.seats[net.mySeat]
        if net.pendingReady ~= nil and mine then
            if mine.ready == net.pendingReady or love.timer.getTime() - (net.pendingReadyAt or 0) > 3 then
                net.pendingReady = nil
            else
                mine.ready = net.pendingReady
            end
        end
    elseif msg.t == "avatar" then
        local seat = tonumber(msg.seat)
        if seat and seat >= 1 and seat <= net.MAX_SEATS then
            avatarImages[seat] = profile.imageFromBytes(msg.data, "seat" .. seat)
            if net.seats[seat] then net.seats[seat].avatar = avatarImages[seat] end
        end
    elseif msg.t == "gone" then
        local seat = tonumber(msg.seat)
        if seat then net.seats[seat], avatarImages[seat] = nil, nil end
    elseif net.onHostMessage and net.role == "client" then
        local ok, err = pcall(net.onHostMessage, msg)
        if not ok then print("[mnb_coop] battle message: " .. tostring(err)) end
    end
end

-- ---------------------------------------------------------------- public
local function reset(status)
    if host then
        for _, peer in pairs(seatPeer) do pcall(peer.disconnect_now, peer) end
        if server then pcall(server.disconnect_now, server) end
        pcall(host.flush, host)
        pcall(host.destroy, host)
    end
    host, server = nil, nil
    peerSeat, seatPeer, avatarBytes, avatarImages = {}, {}, {}, {}
    guard, kickedIds, myJoinCode = {}, {}, nil
    statWindow = { at = love.timer.getTime(), up = 0, down = 0, msgsOut = 0, msgsIn = 0 }
    net.stats = { upRate = 0, downRate = 0, totalUp = 0, totalDown = 0, msgsOutRate = 0, msgsInRate = 0 }
    net.joinCode, net.blocked = nil, 0
    net.pendingReady, net.pendingReadyAt = nil, nil
    net.modDiffs = {}
    net.stage = nil
    net.role, net.mySeat, net.seats = "offline", nil, {}
    net.status = status or "Offline"
    if net.onReset then
        local ok, err = pcall(net.onReset)
        if not ok then print("[mnb_coop] reset: " .. tostring(err)) end
    end
end

-- requireCode: joiners must give the join code (shared inside the copied address).
function net.hostGame(port, requireCode)
    reset()
    if not loadEnet() then return false end
    net.port = tonumber(port) or net.DEFAULT_PORT
    local ok, h = pcall(enet.host_create, "*:" .. net.port, GUARD.MAX_PEERS, 2)
    if not ok or not h then
        net.status = "Could not open port " .. net.port .. " (already in use?)"
        return false
    end
    host = h
    net.role, net.mySeat = "host", 1
    net.seats[1] = myCard()
    local bytes = profile.avatarBytes()
    if bytes then
        avatarBytes[1] = bytes
        setAvatar(1, bytes)
    end
    if requireCode ~= false then net.newJoinCode() end
    net.status = "Hosting on UDP port " .. net.port
    return true
end

-- "1.2.3.4", "1.2.3.4:5000" or "name.playit.gg:5000", optionally followed by "#CODE".
-- Returns address, port, code (code may be nil).
function net.parseAddress(text)
    text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local rest, code = text:match("^(.-)#(%w+)$")
    if rest then text = rest end
    if text == "" then return nil end
    local addr, port = text:match("^([^:]+):(%d+)$")
    if addr then return addr, tonumber(port), code and code:upper() end
    -- "1.2.3.4:47913ABCDE": the "#" got lost somewhere, the code still follows the port
    local addr2, port2, code2 = text:match("^([^:]+):(%d+)(%a%w*)$")
    if addr2 and not code then return addr2, tonumber(port2), code2:upper() end
    if text:find(":") then return nil end
    return text, net.DEFAULT_PORT, code and code:upper()
end

-- Host: throw a player out; they can't come back into this lobby.
function net.kick(seat)
    if net.role ~= "host" or seat == 1 then return end
    local peer, s = seatPeer[seat], net.seats[seat]
    if not peer then return end
    if s and s.steamId then kickedIds[s.steamId] = true end
    send(peer, { t = "refuse", why = "The host removed you from this lobby" })
    pcall(host.flush, host)
    hostDisconnect(peer)
    guard[peer] = nil
    peer:disconnect_later()
    net.status = (s and s.name or "Player") .. " was removed"
end

function net.join(text)
    local addr, port, code = net.parseAddress(text)
    if not addr then
        net.status = "Type an address, like 192.168.0.10 or name.playit.gg:12345"
        return false
    end
    reset()
    myJoinCode = code
    -- 127.0.0.1 / localhost: both game copies run on this PC (the two-window test setup).
    -- (A host can't tell this from its side: behind playit.gg every friend comes from 127.0.0.1.)
    net.samePC = addr == "127.0.0.1" or addr:lower() == "localhost"
    if not loadEnet() then return false end
    local ok, h = pcall(enet.host_create, nil, 1, 2)
    if not ok or not h then
        net.status = "Could not start networking"
        return false
    end
    host = h
    local ok2, peer = pcall(host.connect, host, addr .. ":" .. port, 2)
    if not ok2 or not peer then
        reset("Could not find " .. addr)
        return false
    end
    server = peer
    pcall(peer.timeout, peer, 32, net.TIMEOUT[1], net.TIMEOUT[2]) -- same for a host that vanished
    net.role = "connecting"
    net.status = "Connecting to " .. addr .. ":" .. port .. "..."
    net.connectStarted = love.timer.getTime()
    return true
end

function net.leave()
    reset("Left the lobby")
end

function net.setReady(on)
    on = on == true
    if net.role == "host" then
        if net.seats[1] then net.seats[1].ready = on end
        lastLobbySent = 0
    elseif net.role == "client" then
        send(server, { t = "ready", on = on })
        -- shown at once; the next click flips from this, not from the host's older view
        net.pendingReady, net.pendingReadyAt = on, love.timer.getTime()
        local mine = net.mySeat and net.seats[net.mySeat]
        if mine then mine.ready = on end
    end
end

-- Where a player is, shown on their lobby card (owner, 2026-11-12: "show the other players: he's
-- in the battle report, he's in the main menu, he's in the campaign"). [code] = { card label, tooltip }
net.WHERE = {
    lobby = { "LOBBY", "In the lobby" },
    campaign = { "CAMPAIGN", "In the co-op campaign menus" },
    classic = { "CLASSIC", "In Classic" },
    battle = { "IN BATTLE", "In the battle" },
    report = { "REPORT", "Reading the battle report" },
    menu = { "MENU", "In the game's menus" },
    room = { "READY UP", "In the ready room" },
}

-- This machine's place: mine on my card (the host's at once; a friend's goes to the host).
function net.setWhere(w)
    if not net.WHERE[w] then return end
    local mine = net.mySeat and net.seats[net.mySeat]
    if net.role == "host" then
        if mine and mine.where ~= w then
            mine.where = w
            lastLobbySent = 0
        end
    elseif net.role == "client" then
        if mine then mine.where = w end
        send(server, { t = "where", w = w })
    end
end

-- The ready room (owner, 2026-11-12): the host picked a mode and waits for every friend's READY.
-- net.stage is its title ("CO-OP CLASSIC"); it rides on the lobby update, so a friend who joins
-- late is pulled in too. nil = no ready room. Host only sets it.
net.stage = nil
function net.setStage(title)
    if net.role ~= "host" then return end
    if net.stage ~= title then
        net.stage = title
        lastLobbySent = 0
    end
end

-- Host: everyone back to "not ready" (a battle just started: the next one needs a new ready).
function net.resetReady()
    if net.role ~= "host" then return end
    for i = 1, net.MAX_SEATS do
        if net.seats[i] then net.seats[i].ready = false end
    end
    lastLobbySent = 0
end

-- The friends (not the host: starting is the host's "ready") who haven't pressed READY.
function net.notReady()
    local names = {}
    for i = 2, net.MAX_SEATS do
        local s = net.seats[i]
        if s and not s.ready then names[#names + 1] = s.name or ("Player " .. i) end
    end
    return names
end

function net.myReady()
    local s = net.mySeat and net.seats[net.mySeat]
    return s and s.ready or false
end

-- Re-send our card (after changing showcase).
function net.refreshCard()
    local card = myCard()
    if net.role == "host" and net.seats[1] then
        card.ready, card.avatar, card.where = net.seats[1].ready, net.seats[1].avatar, net.seats[1].where
        net.seats[1] = card
        lastLobbySent = 0
    elseif net.role == "client" then
        send(server, { t = "card", card = card })
    end
end

function net.playerCount()
    local n = 0
    for i = 1, net.MAX_SEATS do if net.seats[i] then n = n + 1 end end
    return n
end

-- Every friend is ready (true with no friends: the host plays alone).
function net.allReady()
    return #net.notReady() == 0
end

-- Host about to start a battle: true if it may. Otherwise it names who isn't ready (a pop-up)
-- and returns false. Always true offline, as a client (who can't start anyway) or alone.
function net.readyToStart()
    if net.role ~= "host" then return true end
    local missing = net.notReady()
    if #missing == 0 then return true end
    local who = table.concat(missing, ", ")
    if mnbCoop and mnbCoop.notice then
        mnbCoop.notice("Waiting for " .. who .. " to press READY")
    end
    net.status = "Waiting for " .. who .. " to press READY"
    return false
end

-- Called every frame from love.update.
function net.update()
    if not host then return end
    for _ = 1, 64 do
        local ok, ev = pcall(host.service, host, 0)
        if not ok then
            reset("Network error: " .. tostring(ev))
            return
        end
        if not ev then break end
        if ev.type == "connect" then
            if net.role == "connecting" and ev.peer == server then
                send(server, { t = "hello", v = net.VERSION, game = currentVersion, card = myCard(), code = myJoinCode,
                    samePC = net.samePC or nil, mods = modcheck.mine() or nil })
                net.status = "Joining lobby..."
            elseif net.role == "host" then
                local now = love.timer.getTime()
                guard[ev.peer] = { joinedAt = now, strikes = 0, msgs = 0, bytes = 0, window = now }
                -- notice a player whose game closed or crashed sooner than enet's ~30 s,
                -- but ride out a bad patch on a slow or lossy line (net.TIMEOUT)
                pcall(ev.peer.timeout, ev.peer, 32, net.TIMEOUT[1], net.TIMEOUT[2])
            end
        elseif ev.type == "receive" then
            countIn()
            if net.role == "host" then
                local data, bad, kind = ev.data, nil, nil
                if data:byte(1) == 0 then
                    kind = "whole"
                    if admit(ev.peer, #data, "piece") then
                        data, bad = reassemble(ev.peer, ev.channel or 0, data, GUARD.MAX_PACKET)
                        if bad then strike(ev.peer, "bad piece") end
                    else
                        data = nil
                    end
                end
                if data and admit(ev.peer, #data, kind) then
                    local msg = codec.decode(data)
                    if type(msg) == "table" and type(msg.t) == "string" then
                        hostReceive(ev.peer, msg)
                    else
                        strike(ev.peer, "not a co-op message")
                    end
                end
            elseif ev.peer == server then
                local data = reassemble(ev.peer, ev.channel or 0, ev.data, codec.HOST_LIMITS.string)
                if data then
                    local msg = codec.decode(data, codec.HOST_LIMITS) -- battle state is big
                    if type(msg) == "table" and type(msg.t) == "string" then clientReceive(msg) end
                end
            end
        elseif ev.type == "disconnect" then
            if net.role == "host" then
                guard[ev.peer] = nil
                hostDisconnect(ev.peer)
            else
                local why = net.status:find("^Refused") and net.status or
                    (net.role == "connecting" and "Could not reach the host" or "Disconnected from the host")
                reset(why)
                return
            end
        end
    end
    if host then updateStats(host) end
    if net.role == "connecting" and net.connectStarted and love.timer.getTime() - net.connectStarted > 10 then
        reset("No answer from the host (wrong address, or the port is not reachable)")
        return
    end
    if net.role == "host" then
        local now = love.timer.getTime()
        -- connections that never proved they're players
        for peer, g in pairs(guard) do
            if not peerSeat[peer] and now - g.joinedAt > GUARD.HELLO_TIMEOUT then drop(peer, "no hello in time") end
        end
        if now - lastLobbySent > 1 then
            for seat, peer in pairs(seatPeer) do
                if net.seats[seat] then net.seats[seat].ping = peer:round_trip_time() end
            end
            broadcast({ t = "lobby", seats = lobbyView(), stage = net.stage })
            lastLobbySent = now
        end
    end
end

function net.shutdown()
    reset()
end

-- Our address on the local network (no packet is sent: a UDP "connect" only picks a route).
function net.lanAddress()
    local ok, socket = pcall(require, "socket")
    if not ok then return nil end
    local u = socket.udp()
    if not u then return nil end
    u:setpeername("8.8.8.8", 9)
    local ip = u:getsockname()
    u:close()
    if ip and ip ~= "0.0.0.0" then return ip end
    return nil
end

return net
