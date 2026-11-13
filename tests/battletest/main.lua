-- Headless test of coop_battle.lua: host capture -> pack -> client apply, compared field by field.
local MOD = os.getenv("COOP_DIR")
local function pre(name, file)
  package.preload[name] = function() return assert(loadfile(MOD .. "/" .. file))() end
end
pre("includes/mods/mnb_coop/coop_codec", "coop_codec.lua")
pre("includes/mods/mnb_coop/coop_profile", "coop_profile.lua")
pre("includes/mods/mnb_coop/coop_mods", "coop_mods.lua")
pre("includes/mods/mnb_coop/coop_net", "coop_net.lua")
pre("includes/mods/mnb_coop/coop_battle", "coop_battle.lua")

local fails, passes = 0, 0
local function check(cond, what) if cond then passes = passes + 1 else fails = fails + 1 print("FAIL: " .. what) end end

currentVersion = "0.5.3b"
modLibrary = { option = function() return nil end, debugLog = function() end }
player = { rank = 1, ribs = {} }
-- the game's stepScale, short form (urb_engine.lua:17306): loud near the camera, silent far away
function stepScale(dude)
  local d = math.sqrt((dude.x - 640 - player.screenx) ^ 2 + (dude.y - 360 - player.screeny) ^ 2)
  return d < 700 and 1 or (d < 1500 and 0.05 or 0)
end

local codec = require("includes/mods/mnb_coop/coop_codec")
local net = require("includes/mods/mnb_coop/coop_net")
local battle = require("includes/mods/mnb_coop/coop_battle")
local T = battle._test

-- codec number text
check(codec.encode(123.45) == "n123.45;", "short float text: " .. codec.encode(123.45))
check(codec.decode(codec.encode(0.1 + 0.2)) == 0.1 + 0.2, "exact float roundtrip")
check(codec.decode(codec.encode(1/3)) == 1/3, "1/3 roundtrip")

-- ---- fake host battle
local function troop(id, x, y)
  return { id = id, x = x, y = y, rotation = 0.5, state = "idle", dead = 0, selected = true, health = 100,
           weapon = { tag = "m1", ammo = 8 }, perks = { 1, 2 }, timer = 0.123456 }
end
local hostP = {
  gameState = 0, screenx = 100, screeny = 0, masterScreenx = 100, masterScreeny = 0, option_volume = 7,
  dayz = 3, tp = 50, name = "Host", skill = { 1, 2, 3 }, career = { a = { b = 1 } },
  deployedTroops = { troop(11, 10, 10), troop(22, 20, 20), troop(33, 30, 30) },
  deployedVehicles = {}, deco = {}, particles = { { sprite = "smoke", x = 1, y = 2, alpha = 50 } },
  explosions = {}, delayedAction = { { action = "createExplosion" } }, rainParticles = { { x = 1 } },
}
for i = 1, 50 do hostP.deco[i] = { name = "blood" .. i, x = i, y = i * 2, size = 10, rotation = 0 } end

local clientReal = { gameState = 1, rank = 9, screenx = 5, option_volume = 3, myCampaign = { secret = true }, deployedTroops = { { id = 999 } } }

local IGNORE = { screenx = 1, screeny = 1, masterScreenx = 1, masterScreeny = 1, gameState = 1, delayedAction = 1,
  troopBin = 1, rainParticles = 1, fluffBalls = 1, clouds = 1, particles = 1, topParticles = 1, explosions = 1,
  textCue = 1, damageCue = 1, uiCue = 1, iconCue = 1, tipCue = 1, waterCircles = 1, mineCircles = 1 }

local function near(a, b)
  if type(a) == "number" and type(b) == "number" then return math.abs(a - b) <= 0.006 end
  return a == b
end
local function same(h, c, path, depth, top)
  if type(h) ~= "table" then
    if not near(h, c) then return false, path .. " host=" .. tostring(h) .. " client=" .. tostring(c) end
    return true
  end
  if type(c) ~= "table" then return false, path .. " missing table" end
  for k, v in pairs(h) do
    local skip = (top and (IGNORE[k] or (type(k) == "string" and k:sub(1, 7) == "option_"))) or (depth == 2 and k == "selected")
    if not skip then
      local ok, why = same(v, c[k], path .. "." .. tostring(k), depth + 1)
      if not ok then return false, why end
    end
  end
  for k in pairs(c) do
    local skip = (top and (IGNORE[k] or (type(k) == "string" and k:sub(1, 7) == "option_"))) or (depth == 2 and k == "selected")
    if not skip and h[k] == nil then return false, path .. "." .. tostring(k) .. " extra on client" end
  end
  return true
end

local function settle()
  -- let smoothing finish
  love.timer.sleep(0.3)
  battle.clientUpdate(0)
end

local st = T.newCaptureState()
local function send(msg)
  local data = T.pack(msg)
  local m = codec.decode(data, codec.HOST_LIMITS)
  player = clientReal
  if T.getClient() then player = battle._mirror end
  battle.onHostMessage(m)
  battle._mirror = player
  return #data
end
local function tick(what)
  player = hostP
  local msg = T.capture(st)
  msg.t = "snap"
  local n = send(msg)
  settle()
  local ok, why = same(hostP, battle._mirror, "player", 0, true)
  check(ok, what .. ": " .. tostring(why))
  return n
end

-- full state
player = hostP
local full = T.fullMessage(st)
local fullBytes = send(full)
check(battle.viewing, "client is watching after full state")
local m = battle._mirror
check(m ~= clientReal and m.option_volume == 3 and m.screenx == 100, "mirror keeps client settings, starts at host camera")
check(m.myCampaign == nil and m.rank == nil, "client's own profile does not leak into the mirror")
check(#m.deployedTroops == 3 and m.deployedTroops[1].id == 11, "troops arrive")
check(m.deployedTroops[1].selected == nil, "selection not mirrored")
check(m.delayedAction == nil, "host-only lists not sent")
check(#m.particles == 1 and m.particles[1].sprite == "smoke", "effects in full state")
check(#m.rainParticles == 0, "local weather lists empty")
local ok, why = same(hostP, m, "player", 0, true)
check(ok, "full state equal: " .. tostring(why))
print("full state bytes: " .. fullBytes)

-- nothing changed -> tiny message
local idle = tick("idle tick")
check(idle < 60, "unchanged tick is tiny (" .. idle .. " bytes)")

-- movement + nested + timers
for _, t in ipairs(hostP.deployedTroops) do t.x = t.x + 3.14159 t.y = t.y - 1.5 t.timer = t.timer + 0.016 end
hostP.deployedTroops[2].weapon.ammo = 7
hostP.deployedTroops[3].weapon = { tag = "bar", ammo = 20 }
hostP.tp = 49.5
hostP.career.a.b = nil
hostP.career.a.c = "x"
local moveBytes = tick("move + nested")
print("move tick bytes: " .. moveBytes)

-- smoothing: right after a snap the client shows the old position, then catches up
player = hostP
hostP.deployedTroops[1].x = hostP.deployedTroops[1].x + 50
local msg = T.capture(st) msg.t = "snap"
send(msg)
local shownX = battle._mirror.deployedTroops[1].x
check(math.abs(shownX - (hostP.deployedTroops[1].x - 50)) < 0.01, "smoothing starts from the old position")
settle()
check(math.abs(battle._mirror.deployedTroops[1].x - hostP.deployedTroops[1].x) < 0.01, "smoothing reaches the new position")

-- a moving soldier whose next update changes something else (here his timer) keeps gliding:
-- he used to jump to the end of his move (jitter)
player = hostP
hostP.deployedTroops[1].x = hostP.deployedTroops[1].x + 60
msg = T.capture(st) msg.t = "snap"
send(msg)
local startX = battle._mirror.deployedTroops[1].x
player = hostP
hostP.deployedTroops[1].timer = (hostP.deployedTroops[1].timer or 0) + 1
msg = T.capture(st) msg.t = "snap"
send(msg)
local midX = battle._mirror.deployedTroops[1].x
check(math.abs(midX - startX) < 1 and math.abs(midX - hostP.deployedTroops[1].x) > 50,
  "another field changing doesn't make a moving soldier jump (" .. midX .. ")")
settle()
check(math.abs(battle._mirror.deployedTroops[1].x - hostP.deployedTroops[1].x) < 0.01, "and he still arrives")

-- remove a troop in the middle, add one
table.remove(hostP.deployedTroops, 2)
hostP.deployedTroops[#hostP.deployedTroops + 1] = troop(44, 40, 40)
tick("remove + add troop")
check(#battle._mirror.deployedTroops == 3 and battle._mirror.deployedTroops[3].id == 44, "troop order follows host")

-- deco trimmed from the front, then appended: must not resend everything
for _ = 1, 10 do table.remove(hostP.deco, 1) end
for i = 1, 5 do hostP.deco[#hostP.deco + 1] = { name = "crater" .. i, x = i, y = i, size = 10, rotation = 1 } end
local trimBytes = tick("deco trim + append")
check(trimBytes < 600, "deco trim sends only the change (" .. trimBytes .. " bytes)")

-- reorder (sort) -> full order
table.sort(hostP.deployedTroops, function(a, b) return a.id > b.id end)
tick("reordered troops")

-- whole list replaced, list removed, new list, generic table that becomes a list
hostP.deco = { { name = "new", x = 0, y = 0, size = 10, rotation = 0 } }
hostP.deployedVehicles = nil
hostP.planes = { { id = 5, x = 1, y = 1, rotationz = 0 } }
hostP.foo = { a = 1 }
tick("lists replaced/removed/added")
hostP.foo = { { k = 1 }, { k = 2 } }
tick("generic table became a list")
hostP.foo = { a = 2 }
tick("list became a generic table")
hostP.planes = {}
tick("list emptied")
check(type(battle._mirror.planes) == "table" and #battle._mirror.planes == 0, "empty list stays a table")

-- player replaced wholesale on the host (the game does this)
local copy = {}
for k, v in pairs(hostP) do copy[k] = v end
copy.deployedTroops = { troop(77, 1, 1) }
hostP = copy
tick("player replaced")

-- roofs: fading fields arrive with a new building, then each player keeps their own
hostP.buildings = { { name = "house", x = 50, y = 50, fading = 0, roofAlpha = 255, targetRoofAlpha = 255, hp = 10 } }
player = hostP
local rmsg = T.capture(st) rmsg.t = "snap"
send(rmsg)
local mb = battle._mirror.buildings[1]
check(mb and mb.roofAlpha == 255 and mb.fading == 0, "new building arrives with its roof fields")
mb.roofAlpha, mb.fading = 25, 3 -- the teammate hovers it
hostP.buildings[1].roofAlpha, hostP.buildings[1].fading, hostP.buildings[1].hp = 100, 2, 9 -- the host hovers too
player = hostP
rmsg = T.capture(st) rmsg.t = "snap"
send(rmsg)
check(mb.roofAlpha == 25 and mb.fading == 3 and mb.hp == 9, "teammate's roof stays his own, other fields still sync")

-- spawn effects
player = battle._mirror
local before = #battle._mirror.particles
T.applySnap({ sp = { particles = { { sprite = "flash", x = 5, y = 5 } }, explosions = { { tag = "fragExplosion", x = 1, y = 1, currentFrame = 1 } } } })
check(#battle._mirror.particles == before + 1 and #battle._mirror.explosions == 1, "spawned effects appended")

-- client particle mover: looks only, never the game's particleUpdate
local gameUpdateRan = false
function particleUpdate() gameUpdateRan = true end
local m = battle._mirror
m.particles = {
  { typez = "muzzleFlash", sprite = "muzzleFlash1", x = 100, y = 100, lifeSpan = 0.05, velocity = 0, drag = 0, alpha = 100, fade = 0, expand = 0, shrink = 0, spin = 0, drift = 0, rotationz = 0, innerRotation = 0, scale = 1 },
  { typez = "tracer", sprite = "tracer", x = 0, y = 0, lifeSpan = 1, velocity = 600, drag = 0, alpha = 255, fade = 0, expand = 0, shrink = 0, spin = 0, drift = 0, rotationz = math.pi / 2, innerRotation = 0, scale = 1 },
  { typez = "smoke", sprite = "smoke1", x = 0, y = 0, lifeSpan = 5, velocity = 10, drag = 1, alpha = 100, fade = 1, expand = 1, shrink = 0, spin = 0.1, drift = 0, rotationz = 0, innerRotation = 0, scale = 1 },
  { sprite = "broken" }, -- junk is dropped, not an error
}
m.waterCircles = { { x = 1, y = 1, timer = 299 } }
battle.clientUpdate(0.016)
check(not gameUpdateRan, "the game's particleUpdate never runs on a client")
check(#m.particles == 3, "junk particle dropped (" .. #m.particles .. ")")
check(math.abs(m.particles[2].x - (-600 * 0.016)) < 0.01 or math.abs(m.particles[2].x - 600 * 0.016) < 0.01, "tracer flies along its angle: x=" .. m.particles[2].x)
check(m.particles[3].alpha < 100 and m.particles[3].scale > 1 and m.particles[3].innerRotation > 0, "smoke fades, grows and spins")
battle.clientUpdate(0.05)
check(m.particles[1].typez ~= "muzzleFlash", "muzzle flash gone after its 0.05 s")
check(#m.waterCircles == 0, "water ripple finished")
for _ = 1, 100 do battle.clientUpdate(0.016) end
check(#m.particles == 1 and m.particles[1].typez == "smoke", "tracer gone after its lifetime, smoke still there")

-- saves blocked while watching
love.filesystem.setIdentity("coopbattletest")
love.filesystem.createDirectory("coop")
local wrote = love.filesystem.write("saveMNB3.lua", "mirror!")
check(wrote == true and love.filesystem.getInfo("saveMNB3.lua") == nil, "save write blocked while watching")
check(love.filesystem.write("coop/ok.txt", "x") and love.filesystem.getInfo("coop/ok.txt") ~= nil, "coop/ writes still allowed")
love.filesystem.remove("coop/ok.txt")

-- image globals: the host's background reaches the client by file name
love.image.newImageData(4, 4):encode("png", "testbg.png")
local hostBg = love.graphics.newImage("testbg.png")
bg = hostBg
player = hostP
send(T.fullMessage(T.newCaptureState()))
check(type(bg) == "userdata" and bg ~= hostBg and bg:getWidth() == 4, "client loaded the host's background from its file")
-- draw errors on the client are kept, not thrown
battle.noteDrawError("includes/drawFiles.lua:56: bad argument #1 to 'draw'\nstack")
check(T.getClient().drawError == "includes/drawFiles.lua:56: bad argument #1 to 'draw'", "draw error noted")
battle.noteDrawError(nil)
check(T.getClient().drawError == nil, "draw error cleared when a frame draws")
-- the D-Day boat ride: sea colour, and the host's start choices hidden from the teammate
local mp = battle._mirror
player = mp
local saved = { mp.gainz, mp.landed, mp.beachFade, mp.gameState }
mp.gainz, mp.landed, mp.beachFade, mp.gameState = 1, 0, -3, 0
local restore = battle.beforeDraw()
local r, g, b = love.graphics.getBackgroundColor()
check(math.abs(r - 28 / 255) < 0.01 and math.abs(b - 49 / 255) < 0.01, "teammate's sea is the host's water colour, not black")
check(mp.beachFade == -2 and T.getClient().hostChoosing == "difficulty", "difficulty buttons hidden; the host is choosing")
restore()
check(mp.beachFade == -3, "the mirrored step is put back after drawing")
mp.beachFade = -9
check(battle.beforeDraw() == nil and T.getClient().hostChoosing == nil, "other intro steps draw as they are")
mp.landed = 1
battle.beforeDraw()
r = love.graphics.getBackgroundColor()
check(r == 0, "landed: background black again")
mp.gainz, mp.landed, mp.beachFade, mp.gameState = saved[1], saved[2], saved[3], saved[4]

-- the host pauses (Esc): teammates get a PAUSED banner; their own game isn't paused
player = hostP
pause = 1
local pmsg = T.capture(st)
pmsg.t, pmsg.view = "snap", T.viewState()
pause = 0 -- the teammate's own pause, before the update arrives
send(pmsg)
check(T.getClient().hostPaused == true and pause == 0, "host paused: the teammate's window shows it, their own game keeps running")
player = hostP
local umsg = T.capture(st)
umsg.t, umsg.view = "snap", T.viewState()
send(umsg)
check(T.getClient().hostPaused == false, "host resumed: the banner goes")

-- playout buffer: the host sends every 1/30 s; they arrive in clumps; the teammate plays them
-- back on the host's schedule, a short moment behind, one by one
do
  local realTime = love.timer.getTime
  local tt = 5000
  love.timer.getTime = function() return tt end
  local c = T.getClient()
  c.queue, c.offset, c.spread, c.sendGap, c.lastHt = {}, nil, nil, nil, nil
  c.pclock, c.lastPlayed, c.playedAt, c.behind = nil, nil, nil, nil
  c.minA, c.minB, c.winAt = nil, nil, nil
  local hostClock = 100
  local function snapAt(ht, x)
    player = hostP
    hostP.deployedTroops[1].x = x
    local m = T.capture(st)
    m.t, m.ht = "snap", ht
    send(m)
  end
  -- warm up: steady updates teach the buffer the trip time and the send interval
  for i = 1, 30 do
    tt = tt + 1 / 30
    snapAt(hostClock + i / 30, 200 + i)
    battle.playSnaps()
  end
  local played = battle._mirror.deployedTroops[1].x
  -- now four updates sent 1/30 s apart arrive together, 0.1 s late
  local base = hostClock + 31 / 30
  tt = tt + 0.1 + 1 / 30
  for i = 0, 3 do snapAt(base + i / 30, 300 + i * 10) end
  check(#c.queue >= 4, "a clump waits in the buffer (" .. #c.queue .. " waiting)")
  local seen = {}
  for _ = 1, 30 do
    tt = tt + 1 / 60
    battle.playSnaps()
    seen[#seen + 1] = #c.queue
  end
  local steps, prev = 0, seen[1]
  for i = 2, #seen do if seen[i] < prev then steps = steps + 1 end prev = seen[i] end
  check(steps >= 3 and #c.queue == 0, "they come out one by one on the host's schedule, not all at once (" .. steps .. " steps)")
  check(c.playDelay >= 0.04 and c.playDelay <= 0.35, "the delay stays small (" .. string.format("%.0f ms", c.playDelay * 1000) .. ")")
  check(c.interval > 0.02 and c.interval < 0.06, "each one is smoothed over the send interval (" .. string.format("%.3f", c.interval) .. " s)")
  -- a lost packet on a real line: nothing for 0.4 s, then everything held back comes at once
  -- (owner, 2026-11-13: "popcorning"). It's played through faster, never in one hop.
  local h0 = base + 4 / 30
  for i = 1, 30 do -- steady again
    tt = tt + 1 / 30
    snapAt(h0 + i / 30, 400 + i)
    battle.playSnaps()
  end
  local h1 = h0 + 30 / 30
  local K = tt - h1 -- the trip: the host's clock is tt - K
  for _ = 1, 24 do tt = tt + 1 / 60 battle.playSnaps() end -- the stall
  check(#c.queue == 0, "during the stall the screen waits on the last update")
  for i = 1, 12 do snapAt(h1 + i / 30, 500 + i * 5) end
  local most, frames = 0, 0
  while #c.queue > 0 and frames < 200 do
    local before = #c.queue
    tt = tt + 1 / 60
    battle.playSnaps()
    most = math.max(most, before - #c.queue)
    frames = frames + 1
  end
  check(most <= 2, "the held-back updates play one or two a frame, not all at once (" .. most .. ")")
  check(frames > 8 and frames < 60, "and catch up within a second (" .. frames .. " frames)")
  -- (the host went on meanwhile; the trip is now longer than at the start: within a few
  -- seconds the buffer follows it, smoothing again instead of playing each one as it comes)
  for i = 1, 300 do tt = tt + 1 / 30 snapAt(tt - K, 600 + i) battle.playSnaps() end
  check(math.abs(c.offset - K) < 0.01, "the trip it expects follows the longer route (" .. string.format("%.0f ms off", (c.offset - K) * 1000) .. ")")
  check(#c.queue >= 1, "updates wait in the buffer again, to be smoothed")
  check((c.behind or 0) < 0.05, "caught up: back on the normal delay (" .. string.format("%.0f ms", (c.behind or 0) * 1000) .. ")")
  -- the banner options draw without errors
  for _, mode in ipairs({ 1, 2, 3 }) do
    local saved = net.option
    net.option = function(id, d) if id == "watchBanner" then return mode end return d end
    tt = tt + 10
    local okd, errd = pcall(battle.drawOverlay)
    check(okd, "banner mode " .. mode .. " draws: " .. tostring(errd))
    net.option = saved
  end
  love.timer.getTime = realTime
end

-- mission-end page: the host's page and its animation timers, nothing else
player = hostP
hostP.gameState = 1
menuPage = 4
box3Timer, uiFade, tempMVPName = 2.5, 255, "Pvt. Test"
hostOnlySecret = 42
local dmsg = T.fullMessage(T.newCaptureState())
check(dmsg.g and dmsg.g.box3Timer == 2.5 and dmsg.g.hostOnlySecret == nil, "host sends the debrief timers only")
dmsg.g.love = 5 -- a forged name must be refused by the client
menuPage = 0
box3Timer = 0
send(dmsg)
check(menuPage == 4 and battle._mirror.gameState == 1 and battle.inDebrief(), "teammate shows the host's mission-end page")
check(box3Timer == 2.5 and tempMVPName == "Pvt. Test", "debrief timers arrive")
check(type(love) == "table", "a forged global name is refused")
hostP.gameState = 0

-- the host leaves the report first: the teammate keeps theirs open until their own Back
send({ t = "bend" })
check(battle.viewing and battle.inDebrief() and menuPage == 4 and box3Timer == 2.5 and T.getClient().hostLeft == true,
    "host left the report: the teammate's copy stays open as it was")

-- the teammate's Esc menu
battle.keypressed("escape")
check(battle.menuOpen, "Esc opens the teammate's menu")
check(battle.menuClick(1, 1) and battle.menuOpen and battle.viewing, "a click beside the buttons keeps it open")
local okm, errm = pcall(battle.drawOverlay)
check(okm, "the menu draws: " .. tostring(errm))
local sw, sh = love.graphics.getWidth(), love.graphics.getHeight()
local firstY = (sh - (3 * 44 + 2 * 10)) / 2 + 20
check(battle.menuClick(sw / 2, firstY + 5) and not battle.menuOpen and battle.viewing, "Back to the battle closes it, still watching")
battle.keypressed("f10")
battle.keypressed("escape")
check(not battle.menuOpen, "F10 opens it too, Esc closes it")

-- the teammate leaves the report on their own (Back), before the host does
battle.leaveReport()
check(not battle.viewing and player == clientReal, "teammate left the mission report: back in their own game, no waiting")
send({ t = "snap", players = {} }) -- the host still on its report: ignored
check(not battle.viewing, "the host's report updates don't pull them back")
-- end of battle restores the real player (here: already done; must stay harmless)
send({ t = "bend" })
check(box3Timer == 0, "teammate's own timer global restored after leaving")
check(bg == hostBg, "client's own background global restored")
love.filesystem.remove("testbg.png")
check(not battle.viewing and player == clientReal and player.gameState == 1, "real player restored after bend")
check(clientReal.myCampaign.secret == true and clientReal.deployedTroops[1].id == 999, "real player untouched")
check(love.filesystem.write("plain.txt", "x") and love.filesystem.getInfo("plain.txt") ~= nil, "writes allowed again")
love.filesystem.remove("plain.txt")

-- sounds: host names clones by their global and records them
check(battle.soundHooked, "Source methods hooked")
local okSd, sd = pcall(love.sound.newSoundData, 64)
if okSd then
  testBeep = love.audio.newSource(sd, "static")
  testLoop = love.audio.newSource(sd, "static")
  T.scanSourceNames()
  local Hs = { snd = {}, pend = {} }
  T.setHost(Hs)
  local c = testBeep:clone() c:setVolume(0.5) c:play()
  local l = testLoop:clone() l:setLooping(true) l:play() l:stop()
  T.setHost(nil)
  check(#Hs.snd == 3 and Hs.snd[1].n == "testBeep" and Hs.snd[1].v == 0.5, "sound recorded by global name")
  check(Hs.snd[2].n == "testLoop" and Hs.snd[2].i and Hs.snd[3].s == Hs.snd[2].i, "loop start/stop recorded")
  check(Hs.snd[1].k == nil, "a sound with a plain volume has no place")
  -- sound distance: a footstep near the host's camera, far from the teammate's
  local savedP = player
  player = { screenx = 0, screeny = 0 }
  Hs = { snd = {}, pend = {} }
  T.setHost(Hs)
  local s = testBeep:clone() s:setVolume(stepScale({ x = 700, y = 400 }) / 2.3) s:play()
  -- far from the host: silent there, but placed (the usual factor is assumed)
  local f = testBeep:clone() f:setVolume(stepScale({ x = 9000, y = 400 }) / 2.3) f:play()
  T.setHost(nil)
  local e = Hs.snd[1]
  check(e.k == "s" and e.x == 700 and e.y == 400 and math.abs(e.f - 1 / 2.3) < 0.01, "footstep placed with its factor")
  check(Hs.snd[2].k == "s" and Hs.snd[2].v == 0, "far footstep placed even though the host hears nothing")
  player = { screenx = 8000, screeny = 0 } -- the teammate's camera is far right
  check(battle.placedVolume(e) < 0.01, "the teammate hears the host's footstep faintly or not at all")
  local v2 = battle.placedVolume(Hs.snd[2])
  check(v2 and math.abs(v2 - 1 / 2.3) < 0.01, "the teammate hears his own side's footstep at full loudness")
  player = savedP
else
  print("no audio in this LOVE build, sound test skipped")
end

-- the automatic rate: a teammate falling behind brings the host's updates down, and back up once current
do
  local savedSeats, savedOption = net.seats, net.option
  net.option = function(id, d) if id == "syncRate" then return 30 end return d end
  net.seats = { { name = "Host" }, { name = "Ann", ping = 100 } }
  local now = 1000
  local h = { seq = 10, sentAt = {}, lag = {} }
  h.sentAt[5] = { n = 5, t = now - 1.2 } -- update 5 left 1.2 s ago
  T.setHost(h)
  local realTime = love.timer.getTime
  love.timer.getTime = function() return now end
  check(battle.onClientMessage(2, { t = "lag", n = 5 }) and math.abs(h.lag[2].v - 1.1) < 0.01, "Ann is 1.1 s behind (ping taken off)")
  check(battle.onClientMessage(2, { t = "lag", n = 99 }) and h.lag[2].v < 1.2, "a report of an update not sent yet is ignored")
  check(not battle.onClientMessage(2, { t = "other" }), "other messages aren't the battle's")
  T.updateRate(now)
  check(battle.currentRate() == 20, "behind: 30 -> 20 updates per second")
  T.updateRate(now + 1)
  check(battle.currentRate() == 20, "one step at a time (2 s apart)")
  T.updateRate(now + 2.1)
  check(battle.currentRate() == 10, "still behind: 20 -> 10")
  T.updateRate(now + 4.2)
  check(battle.currentRate() == 10, "never below 10")
  h.lag[2] = { v = 0.05, at = now + 5 }
  T.updateRate(now + 5)
  T.updateRate(now + 7.5)
  check(battle.currentRate() == 10, "caught up: waits a while before climbing")
  h.lag[2].at = now + 15.1
  T.updateRate(now + 15.1)
  check(battle.currentRate() == 20, "current for 10 s: 10 -> 20")
  h.lag[2].at = now + 25.2
  T.updateRate(now + 25.2)
  h.lag[2].at = now + 35.3
  T.updateRate(now + 35.3)
  check(battle.currentRate() == 30, "back to the chosen 30, and no higher")
  net.option = function(id, d) if id == "syncRate" then return 30 end if id == "autoRate" then return false end return d end
  h.rate = 10
  check(battle.currentRate() == 30, "automatic rate off: always the chosen rate")
  love.timer.getTime = realTime
  T.setHost(nil)
  net.seats, net.option = savedSeats, savedOption
end

-- a vehicle's engine loop on a teammate's screen: as loud as it is from their own camera,
-- every frame (owner, 2026-11-13: "can hear the engine of my halftrack no matter where they are")
do
  local savedC = T.getClient()
  local c = {}
  T.setClient(c)
  local savedScale, savedVeh = rawget(_G, "gunScale"), player.deployedVehicles
  gunScale = function(d) return math.max(0, 1 - math.abs((d.x or 0) - 640) / 2000) end
  local vol = {}
  local function src() return { setVolume = function(s, v) vol[s] = v end } end
  local idle, track, other = src(), src(), src()
  player.deployedVehicles = { { id = 4415569038, tag = "halfTrack", x = 5000, y = 300 } }
  c.inst = { [1] = idle, [2] = track, [3] = other }
  c.instName = { [idle] = "opelIdle4415569038", [track] = "hvyTankIdle24415569038", [other] = "rainLoop" }
  battle._updateLoopVolumes()
  check(vol[idle] == 0 and vol[track] == 0, "an engine far from my camera is silent")
  check(vol[other] == nil, "a loop that isn't a vehicle's is left alone")
  player.deployedVehicles[1].x = 700
  battle._updateLoopVolumes()
  check(vol[idle] > 0.9, "and loud once it's near (" .. tostring(vol[idle]) .. ")")
  gunScale, player.deployedVehicles = savedScale, savedVeh
  T.setClient(savedC)
end

-- a thrown grenade on a teammate's screen lands on its spot and rolls off it, never flies on
-- past it (owner, 2026-11-13: "they fly past target")
do
  -- thrown to the right, with the game's slightly-off start angle (throwFrag: atan2 + 1.5)
  local g = { typez = "fragGrenade", x = 100, y = 300, targetx = 400, targety = 300, velocity = 300, drag = 0,
    rotationz = math.atan2(0, -300) + 1.5, lob = 300, bounce = 0, walled = 0, scale = 1, expand = 0, shrink = 0,
    lifeSpan = 10, spin = 0, fade = 0, drift = 0 }
  local list = { g }
  local far = 0
  for _ = 1, 120 do
    T.moveParticles(list, 1 / 60)
    if g.bounce == 0 then far = math.max(far, g.x) end
  end
  check(g.bounce == 1, "the grenade reached its spot and bounced")
  check(far <= 410, "it never went past the spot before landing (" .. far .. ")")
  check(math.abs(g.x - 400) <= 160 and math.abs(g.y - 300) <= 160, "and rolled only a little way from it")
  local rg = { typez = "rifleGrenade", x = 0, y = 0, targetx = 0, targety = 300, velocity = 400, drag = 0, rotationz = 0,
    lob = 300, bounce = 0, walled = 0, scale = 1, expand = 0, shrink = 0, lifeSpan = 10, spin = 0, fade = 0, drift = 0 }
  local rgl = { rg }
  T.moveParticles(rgl, 1 / 60)
  check(rg.y > 0 and math.abs(rg.x) < 1, "a rifle grenade turns toward its spot")
  for _ = 1, 120 do T.moveParticles(rgl, 1 / 60) end
  check(#rgl == 0, "and is gone when it lands (it goes off there), it doesn't roll on")
  local molly = { typez = "fragGrenade", sprite = "loot_molotov", x = 0, y = 0, targetx = 5, targety = 0, velocity = 300,
    drag = 0, rotationz = 0, lob = 5, bounce = 0, walled = 0, scale = 1, expand = 0, shrink = 0, lifeSpan = 10, spin = 0, fade = 0, drift = 0 }
  local ml = { molly }
  T.moveParticles(ml, 1 / 60)
  check(#ml == 0, "a molotov bursts where it lands")
end

-- flashes and banners kept in the game's globals reach teammates (sync audit 2026-11-13)
do
  lightningFlash, ambientLight, ambientLightFlash, majorTimer, majorEvent = 0, 0, 0, 0, nil
  battle._applyFx({ lf = 200, af = 60, mt = 355, me = "Operation Test" })
  check(lightningFlash == 200 and ambientLight == 100, "lightning flashes on a teammate's screen too")
  check(ambientLightFlash == 60, "and gunfire lights the night sky")
  check(majorTimer == 355 and majorEvent == "Operation Test", "the critical engagement banner shows")
  battle._applyFx({ mt = 0 })
  check(majorTimer == 0, "and goes when the host's does")
end

print(("%d passed, %d failed"):format(passes, fails))
love.event.quit(fails == 0 and 0 or 1)
