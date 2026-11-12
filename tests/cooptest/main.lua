-- Headless test of coop_codec / coop_profile / coop_net: codec safety, showcase, addresses,
-- a real lobby over enet on localhost (join code, version check, kick, leave) and the guard.
local MOD = os.getenv("COOP_DIR")
local function pre(name, file)
  package.preload[name] = function() return assert(loadfile(MOD .. "/" .. file))() end
end
pre("includes/mods/mnb_coop/coop_codec", "coop_codec.lua")
pre("includes/mods/mnb_coop/coop_profile", "coop_profile.lua")
pre("includes/mods/mnb_coop/coop_net", "coop_net.lua")

local fails, passes = 0, 0
local function check(cond, what) if cond then passes = passes + 1 else fails = fails + 1 print("FAIL: " .. what) end end

-- codec
local codec = require("includes/mods/mnb_coop/coop_codec")
local v = { t = "x", n = 3, f = 1.5, b = true, list = { 1, 2, "three" }, nested = { a = { b = { c = "d" } } }, bin = "\0\1\255:;" }
local back = codec.decode(codec.encode(v))
check(back and back.t == "x" and back.n == 3 and back.f == 1.5 and back.b == true and back.list[3] == "three" and back.nested.a.b.c == "d" and back.bin == v.bin, "codec roundtrip")
check(codec.decode("s999:abc") == nil, "codec rejects bad length")
check(codec.decode("t5;") == nil, "codec rejects truncated table")
check(codec.decode("return os.exit()") == nil, "codec rejects code")
local deep = {} local cur = deep for i = 1, 20 do cur.x = {} cur = cur.x end
check(not pcall(codec.encode, deep), "codec refuses deep encode")
check(codec.decode(("t1;n1;"):rep(30) .. "N") == nil, "codec rejects deep decode")

-- game stubs
currentVersion = "0.5.3b"
player = { rank = 5, mnb2Rank = 3, ribs = { 7, 12 }, eyes = 2, nose = 3, mouth = 4, hair = 5 }
rankTell = function(n) return "Rank" .. n end
mnb2RankTell = function(n) return "Cmd" .. n end
for i = 1, 13 do _G["playerRank" .. i] = true _G["command_" .. i] = true end
_G.rib7, _G.rib12 = true, true
_G.ribName_7, _G.ribDesc_7 = "Seven", "desc"
modLibrary = { option = function() return nil end, debugLog = function() end }

local net = require("includes/mods/mnb_coop/coop_net")
local profile = require("includes/mods/mnb_coop/coop_profile")

-- showcase cycling
profile.settings.showKind = "campaign"
check(profile.showcase().kind == "campaign" and profile.showcase().n == 5, "showcase campaign")
profile.nextShowcase(); check(profile.showcase().kind == "classic" and profile.showcase().n == 3, "showcase classic")
profile.nextShowcase(); check(profile.showcase().kind == "ribbon" and profile.showcase().n == 7, "showcase rib 7")
profile.nextShowcase(); check(profile.showcase().n == 12, "showcase rib 12")
profile.nextShowcase(); check(profile.showcase().kind == "none", "showcase none")
profile.nextShowcase(); check(profile.showcase().kind == "campaign", "showcase wraps")
check(profile.showcaseText({ kind = "ribbon", n = 7 }) == "Seven: desc", "ribbon text")

-- address parsing
local a, p, c = net.parseAddress(" name.playit.gg:12345#k7qxa ")
check(a == "name.playit.gg" and p == 12345 and c == "K7QXA", "parse playit + code")
a, p, c = net.parseAddress("192.168.0.10"); check(a == "192.168.0.10" and p == net.DEFAULT_PORT and c == nil, "parse ip")
a, p, c = net.parseAddress("192.168.0.151:47913DJXVV"); check(a == "192.168.0.151" and p == 47913 and c == "DJXVV", "parse code without #")
check(net.parseAddress("") == nil and net.parseAddress("a:b:c") == nil and net.parseAddress("#ABC") == nil, "parse rejects")

-- big messages go out in pieces under net.CHUNK bytes, and come back whole
local wire = {}
local fakePeer = { send = function(_, data, ch) wire[#wire + 1] = { data = data, ch = ch } end }
local big = codec.encode({ t = "avatar", data = ("PNG\0\1\2"):rep(9000) }) -- ~54 KB, like a Steam avatar
net._put(fakePeer, big, 0)
local biggest, whole = 0, nil
for i, w in ipairs(wire) do
  biggest = math.max(biggest, #w.data)
  local got = net._reassemble(fakePeer, 0, w.data, 200 * 1024)
  if got then whole = got check(i == #wire, "whole only after the last piece") end
end
check(#wire > 50 and biggest <= net.CHUNK, "split into " .. #wire .. " pieces, largest " .. biggest .. " bytes")
check(whole == big and codec.decode(whole).t == "avatar", "reassembled exactly")
wire = {}
net._put(fakePeer, codec.encode({ t = "lobby" }), 0)
check(#wire == 1 and wire[1].data:byte(1) ~= 0 and net._reassemble(fakePeer, 0, wire[1].data, 1000) == wire[1].data, "small messages go as they are")
check(select(2, net._reassemble({}, 0, "\0" .. 999999 .. ":x", 200 * 1024)) == "bad", "a piece claiming too big a total is refused")

local function freshNet()
  package.loaded["includes/mods/mnb_coop/coop_net"] = nil
  return require("includes/mods/mnb_coop/coop_net")
end
local hostNet = net
local PORT = 47999
local ADDR = "127.0.0.1:" .. PORT
local clients = {}
local function pump(n) for i = 1, n do hostNet.update() for _, cl in ipairs(clients) do cl.update() end love.timer.sleep(0.01) end end
local function waitSec(s) local t0 = love.timer.getTime() while love.timer.getTime() - t0 < s do pump(1) end end

-- ---- lobby with a join code (the default)
check(hostNet.hostGame(PORT), "host opens port")
local code = hostNet.joinCode
check(type(code) == "string" and #code == 5, "join code made: " .. tostring(code))
local c1, c2 = freshNet(), freshNet()
clients = { c1, c2 }
c1.join(ADDR .. "#" .. code:lower())
pump(60)
check(c1.role == "client" and c1.mySeat == 2, "client with code seated (" .. c1.status .. ")")
c2.join(ADDR) -- no code
pump(60)
check(c2.role == "offline" and c2.status:find("join code") ~= nil, "no code refused: " .. c2.status)
c2.join(ADDR .. "#WRONG")
pump(60)
check(c2.role == "offline" and c2.status:find("join code") ~= nil, "wrong code refused")
c2.join(ADDR .. "#" .. code)
pump(60)
check(c2.mySeat == 3 and hostNet.playerCount() == 3, "second client seated")
waitSec(1.2)
check(c1.playerCount() == 3 and c2.playerCount() == 3, "clients see 3 players")
c1.setReady(true) hostNet.setReady(true) c2.setReady(true)
waitSec(1.2)
check(hostNet.allReady() and c2.seats[2] and c2.seats[2].ready, "ready synced")
-- a big avatar over real enet (sent in pieces): it arrives, nobody is dropped for "flooding",
-- and the lobby keeps flowing after it (owner, 2026-11-11: a friend stuck at 0/3)
local png = "\137PNG\r\n\26\n" .. ("x"):rep(60 * 1024)
c1.sendToHost({ t = "avatar", data = png })
waitSec(1.5)
check(hostNet.playerCount() == 3 and c1.role == "client", "big avatar: nobody dropped")
check(c2.playerCount() == 3 and c2.seats[2] and c2.seats[2].ready, "lobby still arrives after it")

-- version mismatch
local c3 = freshNet() c3.VERSION = "9.9.9"
clients = { c1, c2, c3 }
c3.join(ADDR .. "#" .. code)
pump(80)
check(c3.role == "offline" and c3.status:find("version") ~= nil, "mismatch refused: " .. c3.status)
check(hostNet.playerCount() == 3, "refused client got no seat")

-- new code: old address stops working, players stay
local old = code
hostNet.newJoinCode()
check(hostNet.joinCode ~= old and hostNet.playerCount() == 3, "new code keeps players")

-- kick: seat freed, can't come back
local kickedId = hostNet.seats[3] and hostNet.seats[3].steamId
hostNet.kick(3)
pump(60)
check(hostNet.seats[3] == nil and c2.role == "offline" and c2.status:find("removed") ~= nil, "kick: " .. c2.status)

-- leaving frees the seat
c1.leave()
pump(60)
check(hostNet.seats[2] == nil and hostNet.playerCount() == 1, "seat freed after leave")

-- ---- GUARD against strangers (raw enet, not our client)
local enet = require("enet")
local blockedBefore = hostNet.blocked
-- 1. a connection that never says hello is dropped after the timeout
local raw = enet.host_create()
local silent = raw:connect(ADDR, 2)
local t0 = love.timer.getTime()
local gotDisconnect = false
while love.timer.getTime() - t0 < hostNet.GUARD.HELLO_TIMEOUT + 1.5 do
  hostNet.update()
  local e = raw:service(0)
  if e and e.type == "disconnect" then gotDisconnect = true end
  love.timer.sleep(0.01)
end
check(gotDisconnect and hostNet.blocked > blockedBefore, "silent connection dropped after timeout")
-- 2. junk earns strikes, then a drop
local raw2 = enet.host_create()
local junk = raw2:connect(ADDR, 2)
local dropped2, sent = false, false
for i = 1, 120 do
  hostNet.update()
  local e = raw2:service(0)
  if e and e.type == "connect" and not sent then
    sent = true
    for k = 1, 6 do junk:send("t99999;garbage" .. k) end
  elseif e and e.type == "disconnect" then dropped2 = true end
  love.timer.sleep(0.01)
end
check(dropped2, "junk sender dropped after strikes")
-- 3. flooding (valid-looking messages, too many) is cut off
local raw3 = enet.host_create()
local flood = raw3:connect(ADDR, 2)
local dropped3, flooded = false, false
for i = 1, 150 do
  hostNet.update()
  local e = raw3:service(0)
  if e and e.type == "connect" and not flooded then
    flooded = true
    for k = 1, 200 do flood:send(codec.encode({ t = "ready", on = true })) end
  elseif e and e.type == "disconnect" then dropped3 = true end
  love.timer.sleep(0.01)
end
check(dropped3, "flooder dropped")
-- 3b. byte flooding with big packets in one piece (few messages, many bytes) is cut off too
local raw5 = enet.host_create()
local bigFlood = raw5:connect(ADDR, 2)
local dropped5, sent5 = false, false
local blob = codec.encode({ t = "ready", pad = ("x"):rep(150 * 1024) })
for i = 1, 200 do
  hostNet.update()
  local e = raw5:service(0)
  if e and e.type == "connect" and not sent5 then
    sent5 = true
    for k = 1, 4 do bigFlood:send(blob) end -- 600 KB in 4 messages: over the 400 KB/s byte limit
  elseif e and e.type == "disconnect" then dropped5 = true end
  love.timer.sleep(0.01)
end
check(dropped5, "big unsplit packets count their bytes: byte flooder dropped")
check(hostNet.playerCount() == 1 and hostNet.role == "host", "host still fine after attacks (blocked " .. hostNet.blocked .. ")")
-- 4. a real player can still get in afterwards
local c4 = freshNet()
clients = { c4 }
c4.join(ADDR .. "#" .. hostNet.joinCode)
pump(60)
check(c4.role == "client", "real player joins after attacks (" .. c4.status .. ")")
hostNet.leave()
pump(60)
check(c4.role == "offline", "client offline after host closes")

-- ---- open lobby (join code switched off)
check(hostNet.hostGame(PORT, false) and hostNet.joinCode == nil, "open lobby")
local c5 = freshNet()
clients = { c5 }
c5.join(ADDR)
pump(60)
check(c5.role == "client", "joins open lobby without code")
hostNet.shutdown()
print(("%d passed, %d failed"):format(passes, fails))
love.event.quit(fails == 0 and 0 or 1)
