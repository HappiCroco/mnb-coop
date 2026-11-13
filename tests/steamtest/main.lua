-- Headless test of coop_steam (Steam Join Game and invites): the connect string, a join that
-- comes in waits for the menus, and no Steam at all is harmless.
local MOD = os.getenv("COOP_DIR")
for _, n in ipairs({ "coop_codec", "coop_profile", "coop_mods", "coop_net", "coop_steam" }) do
  package.preload["includes/mods/mnb_coop/" .. n] = function() return assert(loadfile(MOD .. "/" .. n .. ".lua"))() end
end
local fails, passes = 0, 0
local function check(c, w) if c then passes = passes + 1 else fails = fails + 1 print("FAIL: " .. w) end end

local steam = require("includes/mods/mnb_coop/coop_steam")
check(steam.parseConnect("+mnb_coop name.playit.gg:12345#K7QXA") == "name.playit.gg:12345#K7QXA", "connect string parsed")
check(steam.parseConnect("mnb.exe -foo +mnb_coop 192.168.0.10:47913 -bar") == "192.168.0.10:47913", "found on a command line")
check(steam.parseConnect("+mnb_coop ;rm -rf") == nil and steam.parseConnect("+connect 1.2.3.4") == nil and steam.parseConnect(nil) == nil,
  "anything else is refused")

-- no Steam here (tests): init says so, nothing breaks
check(not steam.init() and not steam.ok and type(steam.why) == "string", "no Steam: off, with a reason (" .. tostring(steam.why) .. ")")
steam.update("1.2.3.4:5", true, function() return true end)
check(steam.pending == nil, "update without Steam does nothing")
check(select(1, steam.openInvite("x")) == false, "invite without Steam: false")

-- a join request waits until the menus can take it
steam.requestJoin(nil, "test")
check(steam.pending == nil, "an empty join is ignored")
steam.requestJoin("host.example:47913#ABCDE", "test")
check(steam.pending == "host.example:47913#ABCDE", "a join is kept")
steam.ok = true -- (pretend: the presence call fails quietly without the DLL)
local tries, joined = 0, nil
local function joinNow(a) tries = tries + 1 if tries < 3 then return false end joined = a return true end
steam.update(nil, false, joinNow)
steam.update(nil, false, joinNow)
check(steam.pending ~= nil and joined == nil, "kept while the menus can't take it")
steam.update(nil, false, joinNow)
check(steam.pending == nil and joined == "host.example:47913#ABCDE", "joined once they can")
steam.ok = false

-- ---- connections over Steam, with a fake Steam that delivers between two ids in this process
local ffi = require("ffi")
local H, C, X = "76561198000000001", "76561198000000002", "76561198000000003"
local me = nil                -- who is sending right now
local inbox = {}              -- [receiver][channel] = { { from, data } ... }
local keep = {}               -- cdata kept alive while Steam would own it
local function idOf(sni) return (tostring(sni.u.steamID64):gsub("ULL$", "")) end
local fake = {
  SteamAPI_SteamNetworkingIdentity_SetSteamID64 = function(sni, v) sni.u.steamID64 = v end,
  SteamAPI_SteamNetworkingIdentity_GetSteamID64 = function(sni) return sni.u.steamID64 end,
  SteamAPI_ISteamNetworkingMessages_SendMessageToUser = function(_, sni, data, size, flags, ch)
    local to = idOf(sni)
    inbox[to] = inbox[to] or {}
    inbox[to][ch] = inbox[to][ch] or {}
    table.insert(inbox[to][ch], { from = me, data = data:sub(1, size) })
    return 1
  end,
  SteamAPI_ISteamNetworkingMessages_ReceiveMessagesOnChannel = function(_, ch, out, max)
    local q = inbox[me] and inbox[me][ch]
    if not q then return 0 end
    local n = 0
    while #q > 0 and n < max do
      local e = table.remove(q, 1)
      local m = ffi.new("coop_snm")
      local buf = ffi.new("char[?]", #e.data + 1, e.data)
      m.data, m.size = buf, #e.data
      local v = ffi.new("uint64_t", 0)
      for d in e.from:gmatch("%d") do v = v * 10 + (d:byte() - 48) end
      m.peer.u.steamID64 = v
      keep[#keep + 1] = m keep[#keep + 1] = buf
      out[n] = m
      n = n + 1
    end
    return n
  end,
  SteamAPI_SteamNetworkingMessage_t_Release = function() end,
  SteamAPI_ISteamNetworkingMessages_CloseSessionWithUser = function() return true end,
  SteamAPI_RunCallbacks = function() end,
}
steam._install(fake, ffi.cast("void *", 1))
-- Steam's own layouts (steamnetworkingtypes.h, x64): SteamNetworkingIdentity is 136 bytes;
-- in SteamNetworkingMessage_t the identity is at 16 and the channel at 192
check(ffi.sizeof("coop_sni") == 136 and ffi.offsetof("coop_sni", "u") == 8, "SteamNetworkingIdentity layout")
check(ffi.offsetof("coop_snm", "peer") == 16 and ffi.offsetof("coop_snm", "connUserData") == 152
  and ffi.offsetof("coop_snm", "release") == 184 and ffi.offsetof("coop_snm", "channel") == 192
  and ffi.offsetof("coop_snm", "lane") == 208, "SteamNetworkingMessage_t layout")
check(ffi.offsetof("coop_steam_cb", "flags") == 8 and ffi.offsetof("coop_steam_cb", "icallback") == 12, "callback object layout")
local realTime = love.timer.getTime
local clock = 1000
love.timer.getTime = function() return clock end

me = H
local TH = steam.newTransport("host")
me = C
local TC = steam.newTransport("client")
local toHost = TC:connect(H)
check(TC:service() == nil, "joiner: not connected before the host answers")
me = H
local ev = TH:service()
check(ev and ev.type == "connect" and ev.peer.sid == C, "host: a Steam id said hi -> connect")
local hp = ev.peer
me = C
ev = TC:service()
check(ev and ev.type == "connect" and ev.peer == toHost, "joiner: the host answered -> connect")
toHost:send("hello", 0)
me = H
ev = TH:service()
check(ev and ev.type == "receive" and ev.data == "hello" and ev.peer == hp and ev.channel == 0, "data arrives, in order, on its channel")
hp:send("snap1", 1) hp:send("snap2", 1)
me = C
local a, b = TC:service(), TC:service()
check(a and b and a.data == "snap1" and b.data == "snap2" and a.channel == 1, "two in a row, in order")
-- a stranger's data without a hi is ignored; a joiner only listens to its host
me = X
fake.SteamAPI_ISteamNetworkingMessages_SendMessageToUser(nil, (function() local s = ffi.new("coop_sni") s.u.steamID64 = ffi.new("uint64_t", 0) local v = ffi.new("uint64_t", 0) for d in H:gmatch("%d") do v = v * 10 + (d:byte() - 48) end s.u.steamID64 = v return s end)(), "junk", 4, 8, 0)
me = H
check(TH:service() == nil, "data from an id that never said hi is ignored")
-- round trip: pings a second later
clock = clock + 1.1
me = H TH:service()
me = C clock = clock + 0.05 TC:service()
me = H clock = clock + 0.05 TH:service()
check(hp:round_trip_time() < 100 and hp:last_round_trip_time() >= 90 and hp:last_round_trip_time() <= 110,
  "round trip measured (" .. hp:last_round_trip_time() .. " ms)")
-- leaving: the other side gets a disconnect
me = C
toHost:disconnect_now()
me = H
ev = TH:service()
check(ev and ev.type == "disconnect" and ev.peer == hp, "bye -> disconnect on the host")
-- a peer that goes quiet is dropped after the timeout
me = C
local TC2 = steam.newTransport("client")
TC2:connect(H)
me = H
local ev2 = TH:service()
me = C TC2:service()
me = H TH:service() -- (what the joiner sent so far arrives now, not 25 s late)
clock = clock + 25
me = H
local gone = nil
for _ = 1, 3 do local e = TH:service() if e and e.type == "disconnect" then gone = e end end
check(ev2 and ev2.type == "connect" and gone and gone.peer == ev2.peer, "quiet for longer than the timeout -> disconnect")
TH:destroy() TC:destroy() TC2:destroy()
check(steam.acceptAll == false, "a closed host stops accepting")

-- ---- the real lobby code on top: a host and a joiner, joined with "steam:<id>#CODE"
currentVersion = "0.5.3b"
player = { rank = 1, mnb2Rank = 1, ribs = {}, eyes = 1, nose = 1, mouth = 1, hair = 1 }
rankTell = function(n) return "Rank" .. n end
mnb2RankTell = function(n) return "Cmd" .. n end
modLibrary = { option = function() return nil end, debugLog = function() end }
fake.SteamAPI_ISteamUser_GetSteamID = function() local v = ffi.new("uint64_t", 0) for d in me:gmatch("%d") do v = v * 10 + (d:byte() - 48) end return v end
local function freshNet()
  package.loaded["includes/mods/mnb_coop/coop_net"] = nil
  local n = require("includes/mods/mnb_coop/coop_net")
  n.steam = steam
  return n
end
local hostNet, joinNet = freshNet(), freshNet()
me = H
check(hostNet.hostGame(47998) and hostNet.steamAddress() == "steam:" .. H, "hosting: reachable through Steam (" .. tostring(hostNet.steamAddress()) .. ")")
local ownAddress = hostNet.steamAddress()
local selfNet = freshNet()
check(not selfNet.join(ownAddress) and selfNet.status:find("127.0.0.1", 1, true) ~= nil, "joining your own Steam address says to use 127.0.0.1")
me = C
check(joinNet.join(ownAddress .. "#" .. hostNet.joinCode) and joinNet.role == "connecting", "joining with steam:<id>#CODE")
local function pump(n)
  for _ = 1, n do
    clock = clock + 0.02
    me = H hostNet.update()
    me = C joinNet.update()
  end
end
pump(30)
check(joinNet.role == "client" and joinNet.mySeat == 2 and hostNet.playerCount() == 2, "seated through Steam (" .. joinNet.status .. ")")
pump(80)
check(joinNet.playerCount() == 2 and joinNet.seats[1] and joinNet.seats[1].name ~= nil, "the lobby list reaches the joiner")
me = C
joinNet.setReady(true)
pump(80)
check(hostNet.seats[2] and hostNet.seats[2].ready == true, "orders reach the host (READY)")
-- a big message (an avatar-sized one) goes in pieces and comes back whole
local got = nil
joinNet.onHostMessage = function(msg) if msg.t == "bigtest" then got = msg end end
me = H
hostNet.sendTo(2, { t = "bigtest", blob = ("x"):rep(30000) })
pump(20)
check(got and #got.blob == 30000, "a 30 KB message arrives whole")
-- a wrong join code is refused
me = X
local strangerNet = freshNet()
strangerNet.join("steam:" .. H .. "#WRONG")
for _ = 1, 40 do clock = clock + 0.02 me = H hostNet.update() me = X strangerNet.update() end
check(strangerNet.role == "offline" and strangerNet.status:find("join code") ~= nil, "wrong code refused through Steam too (" .. strangerNet.status .. ")")
-- the joiner leaves: the host frees the seat
me = C
joinNet.leave()
pump(10)
check(hostNet.playerCount() == 1, "leaving frees the seat")
me = H hostNet.leave()
love.timer.getTime = realTime
steam._install(nil, nil)

print(("%d passed, %d failed"):format(passes, fails))
love.event.quit(fails == 0 and 0 or 1)
