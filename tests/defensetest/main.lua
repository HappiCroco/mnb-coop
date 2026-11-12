-- Headless test of coop_defense.lua: the middle layout, both-side waves, mirrored AI, the radar.
local MOD = os.getenv("COOP_DIR")
for _, n in ipairs({ "coop_codec", "coop_profile", "coop_mods", "coop_net", "coop_defense" }) do
  package.preload["includes/mods/mnb_coop/" .. n] = function() return assert(loadfile(MOD .. "/" .. n .. ".lua"))() end
end
local fails, passes = 0, 0
local function check(c, w) if c then passes = passes + 1 else fails = fails + 1 print("FAIL: " .. w) end end

currentVersion = "x"
modLibrary = { option = function() return nil end }
-- the game's helpers this needs
function randNbr(n) return math.floor(n / 2) end
function enemyCqc() return 0 end
function underCover() return false end
function distanceCheck2(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end
local announced = 0
function anounceStuff() announced = announced + 1 end
radarBase, radarTop = "radarImg", "radarTopImg"

local defense = require("includes/mods/mnb_coop/coop_defense")

local nextId = 0
local function troop(faction, x, y, pc)
  nextId = nextId + 1
  return { id = nextId, faction = faction, x = x, y = y or 360, targetx = x, targety = y or 360, playerControlled = pc or 0,
    dead = 0, health = 100, momentum = 0, tag = faction == "axis" and "axis" or "", trenchHome = x }
end
player = { gameType = 1, gameState = 0, mnb2SubGame = 0, endLine = 12600, mnb2Miss = 0, placeables = {}, textCue = {},
  screenx = 0, masterScreenx = 0, deployedTroops = {} }
for i = 1, 4 do player.deployedTroops[i] = troop("allied", 300, 200 + i * 50, 1) end
local mapLeft = troop("axis", 2000)
local mapRight = troop("axis", 9000)
table.insert(player.deployedTroops, mapLeft)
table.insert(player.deployedTroops, mapRight)

-- not from the co-op tile: nothing changes
defense.wanted = false
defense.afterSetup()
check(not defense.on and player.deployedTroops[1].x == 300, "the game's own Classic is left alone")

-- the map around the middle
player.forest = { { x = 6350, y = 380 }, { x = 6300, y = 50 } }           -- one near, one far (y 50: 310 away)
player.rocks = { { x = 6100, y = 360 }, { x = 9000, y = 360 } }
player.placeables = { { name = "plant", x = 6400, y = 300 }, { name = "barbWire", x = 2000, y = 300 } }
player.mineField = { { x = 6250, y = 400 } }
player.groundType = { { x = 6320, y = 360 }, { name = "noXY" } }
player.buildings = { { name = "smallHouse", x = 6300 + 400, y = 360, radius = 200 }, { name = "far", x = 9000, y = 360, radius = 200 } }
player.deco = { { name = "wallPiece", x = 6300 + 520, y = 360 }, { name = "flowers", x = 3000, y = 100 }, { name = "near", x = 6300, y = 300 } }
player.decoStart = 3
player.lootables = { { name = "gunCrate", x = 6300, y = 360 } }

-- from the co-op tile
defense.wanted = true
defense.afterSetup()
local T = player.deployedTroops
check(#player.forest == 1 and player.forest[1].y == 50, "trees near the radar cleared, far ones stay")
check(#player.rocks == 1 and player.rocks[1].x == 9000, "rocks near the radar cleared")
check(#player.mineField == 0 and #player.groundType == 1, "mines and mud near the radar cleared")
check(#player.buildings == 1 and player.buildings[1].name == "far", "a house reaching into the clearing goes whole")
check(#player.deco == 1 and player.deco[1].name == "flowers", "the house's wall pieces went with it")
check(player.decoStart == 1, "the map's deco count follows (battle mess trimming stays right)")
check(#player.lootables == 1, "loot stays")
check(defense.on and defense.radarX == 6300, "defense on, radar in the middle")
local inRing = true
for i = 1, 4 do if math.abs(T[i].x - 6300) > 100 or math.abs(T[i].y - 360) > 100 then inRing = false end end
check(inRing, "squad in a ring around the radar")
local names = {}
for _, p in ipairs(player.placeables) do names[p.name] = (names[p.name] or 0) + 1 end
check(names.coopRadar == 1 and names.coopRadarTop == 1 and names.barbWire == 1 and not names.plant,
  "radar placed (own names), the bush by it cleared, far wire kept")
check(coopRadar == "radarImg" and coopRadarTop == "radarTopImg", "radar pictures borrowed from the game's radar")
check(player.masterScreenx == 6300 - 640, "camera on the radar")
check(mapLeft.coopSide == "L" and mapRight.coopSide == "R", "Germans already on the map sorted by side")

-- trench mode keeps its own layout
player.mnb2SubGame = 8
defense.afterSetup()
check(not defense.on, "trench mode isn't laid out as a defense")
player.mnb2SubGame = 0
defense.afterSetup()

-- a wave: the game makes four Germans right of the players; each gets a twin on the left
-- (solo too: "if the original spawns 4, co-op has 8, 4 on each side")
local lo, hi = 6300 - 90, 6300 + 90
local wave = defense.wrapWave(function()
  for k = 1, 4 do table.insert(player.deployedTroops, troop("axis", hi + 750, 100 + k * 100)) end
end)
local n0 = #T
wave()
local left, right = 0, 0
for i = n0 + 1, #T do
  if T[i].coopSide == "L" then
    left = left + 1
    check(T[i].x <= 6300 - defense.SPAWN_CLEAR and T[i].targetx == T[i].x and T[i].trenchHome == T[i].x, "left German mirrored, outside the radar's clear zone (" .. T[i].x .. ")")
  elseif T[i].coopSide == "R" then
    right = right + 1
    check(T[i].x >= 6300 + defense.SPAWN_CLEAR and T[i].targetx == T[i].x, "right German pushed out of the clear zone (game put him at " .. (hi + 750) .. ", now " .. T[i].x .. ")")
  end
end
check(left == 4 and right == 4, "solo: the full wave on each side (" .. left .. " left, " .. right .. " right)")
local gL, gR = T[n0 + 5], T[n0 + 1]

-- with teammates: every German gets a twin on the left (double the attack)
local net = require("includes/mods/mnb_coop/coop_net")
net.seats = { { name = "Host" }, { name = "Ann" } }
local n2 = #T
wave()
local L2, R2, ids = 0, 0, {}
for i = n2 + 1, #T do
  if T[i].coopSide == "L" then L2 = L2 + 1 elseif T[i].coopSide == "R" then R2 = R2 + 1 end
  ids[T[i]] = true
end
check(L2 == 4 and R2 == 4, "with teammates: the full wave on each side (" .. L2 .. " left, " .. R2 .. " right)")
local twin, orig = T[#T], T[n2 + 4] -- originals are n2+1..n2+4, their twins come after, in order
check(twin.coopSide == "L" and twin.x <= 6300 - defense.SPAWN_CLEAR and twin.y == orig.y, "a twin mirrored to the left at the same height")
-- a wave the game puts far out stays where it is (and its twin mirrors it)
local farWave = defense.wrapWave(function() table.insert(player.deployedTroops, troop("axis", hi + 3000, 300)) end)
local n3 = #T
farWave()
check(T[n3 + 1].x == hi + 3000 and T[n3 + 2].x == lo - 3000, "a far wave isn't moved; its twin mirrors it")
for i = #T, n3 + 1, -1 do table.remove(T, i) end
check(twin ~= orig and twin.weapon ~= orig.weapon or orig.weapon == nil, "the twin has his own tables")
-- special waves: whole from one side, alternating, never doubled (even with teammates)
local special = defense.wrapSpecial(function()
  for k = 1, 3 do table.insert(player.deployedTroops, troop("axis", hi + 3000, 100 + k * 100)) end
end)
local inWave = defense.wrapWave(function() special() end) -- they run inside spawnMNB2Wave
local function sides(from)
  local l, r = 0, 0
  for i = from, #T do if T[i].coopSide == "L" then l = l + 1 elseif T[i].coopSide == "R" then r = r + 1 end end
  return l, r
end
local n4 = #T
defense.specialFlip = 0
inWave()
local sl, sr = sides(n4 + 1)
check(sl + sr == 3 and (sl == 0 or sr == 0), "with teammates: a special wave comes from one side, not doubled (" .. sl .. " left, " .. sr .. " right)")
local n5 = #T
inWave()
local sl2, sr2 = sides(n5 + 1)
check(sl2 + sr2 == 3 and (sl2 == 3) == (sr == 3), "the next special wave comes from the other side")
local leftOnes = sl == 3 and n4 or n5
check(T[leftOnes + 1].x <= 6300 - defense.SPAWN_CLEAR, "a left special wave is mirrored past the clear zone")
for i = #T, n4 + 1, -1 do table.remove(T, i) end
-- two specials rolled in the same wave share one side; the next wave's go to the other
local special2 = defense.wrapSpecial(function()
  for k = 1, 2 do table.insert(player.deployedTroops, troop("axis", hi + 2500, 150 + k * 100)) end
end)
local twoInWave = defense.wrapWave(function() special() special2() end)
local n6 = #T
twoInWave()
local dl, dr = sides(n6 + 1)
check(dl + dr == 5 and (dl == 0 or dr == 0), "two specials in one wave: one side for both (" .. dl .. " left, " .. dr .. " right)")
local n7 = #T
twoInWave()
local dl2, dr2 = sides(n7 + 1)
check(dl2 + dr2 == 5 and (dl2 == 5) == (dr == 5), "the next wave's specials: the other side")
for i = #T, n6 + 1, -1 do table.remove(T, i) end
-- Jägers appear behind the front (west of the radar here): the wave's side still decides
local jagers = defense.wrapSpecial(function()
  for k = 1, 3 do table.insert(player.deployedTroops, troop("axis", 5400, 150 + k * 100)) end
end)
local jagWave = defense.wrapWave(function() jagers() end)
local seen = {}
for _ = 1, 2 do
  local n8 = #T
  jagWave()
  local jl, jr = sides(n8 + 1)
  check(jl + jr == 3 and (jl == 0 or jr == 0), "Jägers: one side, not doubled (" .. jl .. " left, " .. jr .. " right)")
  if jr == 3 then
    seen.R = true
    check(T[n8 + 1].x >= 6300 + defense.SPAWN_CLEAR, "Jägers sent right: past the clear zone on the east")
  elseif jl == 3 then
    seen.L = true
    check(T[n8 + 1].x <= 6300 - defense.SPAWN_CLEAR, "Jägers sent left: past the clear zone on the west")
  end
end
check(seen.L and seen.R, "Jägers come from either side, by turns")
for i = #T, n6 + 1, -1 do table.remove(T, i) end
-- a paradrop that is part of a special wave drops on its side only
local dropsS = {}
local fjS = defense.wrapFjDrop(function(x) dropsS[#dropsS + 1] = x end)
defense.specialSide = "L"
fjS(hi + 3000, 360)
defense.specialSide = nil
check(#dropsS == 1 and dropsS[1] < 6300, "special-wave paradrop: one drop, on the wave's side")
net.seats = {}
-- the twins leave the test's list again
for i = #T, n2 + 1, -1 do table.remove(T, i) end

-- the AI: forward and back are mirrored for the left side
local origFwd = 0
local mf = defense.wrapMoveForward(function(d) origFwd = origFwd + 1 d.targetx = d.x - 300 end)
moveForward = mf
mf(gL)
check(gL.targetx > gL.x, "left German moves forward to the right")
mf(gR)
check(origFwd == 1 and gR.targetx < gR.x, "right German uses the game's moveForward")
local rt = defense.wrapRetreat(function(d) d.targetx = d.x + 1000 end)
rt(gL)
check(gL.targetx < gL.x and gL.retreating == 10, "left German retreats to the left")
gL.x = 600
rt(gL)
check(gL.targetx >= defense.LEFT_EDGE, "left retreat stays off the game's miss line")
gL.x = lo - 750
-- in front: same side only
local inFront = defense.wrapInFront(function() return 99 end)
local ahead = troop("axis", gL.x + 300) ahead.coopSide = "L"
table.insert(T, ahead)
check(inFront(gL) == 1, "left German sees his side's man ahead (to the right)")
check(inFront(gR) == 0, "right German doesn't count the left side's men as 'in front'")
-- advance: same side behind
gL.targetx = gL.x
local adv = defense.wrapAdvance(function() end)
local behind = troop("axis", ahead.x - 100) behind.coopSide = "L"
table.insert(T, behind)
local further = troop("axis", ahead.x + 100) further.coopSide = "L" further.targetx = further.x
table.insert(T, further)
adv(ahead)
check(behind.targetx > behind.x, "the man behind on the left side comes along (to the right)")
check(further.targetx == further.x, "a left man AHEAD of him is not pushed (the and/or trap)")
-- a fire nearby: the left German sidesteps, like the game's moveForward
function fireInFront() return 1 end
gL.targetx = gL.x
mf(gL)
check(gL.targetx == gL.x, "fire ahead: no advance")
function fireInFront() return 0 end

-- German support from both fronts (squad ring: west front 6210, east front 6390)
local lo2, hi2 = defense.frontLines()
check(lo2 == 6210 and hi2 == 6390, "the two fronts: westmost and eastmost of our soldiers (" .. lo2 .. ", " .. hi2 .. ")")
check(defense.mirrorX(hi2 + 1000) == lo2 - 1000, "1000 past the east front mirrors to 1000 past the west front")
local drops = {}
local fj = defense.wrapFjDrop(function(x, y) drops[#drops + 1] = x end)
local dropEdge = 6300 + defense.SPAWN_CLEAR + 500
fj(hi2 + 3000, 360)
check(#drops == 2 and drops[1] == hi2 + 3000 and drops[2] == lo2 - 3000, "solo: a drop on each front, like the waves")
net.seats = { { name = "Host" }, { name = "Ann" } }
drops = {}
fj(hi2 + 3000, 360)
check(#drops == 2 and drops[1] == hi2 + 3000 and drops[2] == lo2 - 3000, "with teammates: a drop on each front")
drops = {}
fj(hi2, 350) -- urb_engine.lua:42718 drops right on the front line
check(drops[1] == dropEdge and drops[2] == 12600 - dropEdge, "a drop on the front line lands past the clear zone, both sides (" .. drops[1] .. ", " .. drops[2] .. ")")
net.seats = {}
function alliedFrontLine() return hi2 end
local shells = {}
local arty = defense.wrapFrontStrike(function(x) shells[#shells + 1] = x end)
defense.strikeFlip = 0
arty(hi2, 200) arty(hi2, 200) arty(5000, 200)
check(shells[1] == hi2 and shells[2] == lo2 and shells[3] == 5000, "front-line artillery alternates; a strike on a spot stays put")

-- friendly arrivals: the game puts them at the far left; they come in at the radar from above/below
player.deployedVehicles = player.deployedVehicles or {}
local rookie = troop("allied", 10, 360, 1) rookie.targetx = 6000
table.insert(T, rookie)
local jeep = { faction = "allied", x = 100, y = 400, targetx = 900, targety = 400 }
table.insert(player.deployedVehicles, jeep)
local farAlly = troop("allied", 7000, 360, 1) -- a para landing near the front: left alone
table.insert(T, farAlly)
defense.update()
check(math.abs(rookie.x - 6300) <= 150 and (rookie.y < 0 or rookie.y > 720), "hired soldier comes in at the radar, from the edge")
check(rookie.targetx == rookie.x and math.abs(rookie.targety - 360) <= 180, "and walks to the radar")
check(math.abs(jeep.x - 6300) <= 250 and (jeep.y < 0 or jeep.y > 720), "bought vehicle comes in at the radar too")
check((rookie.y < 0) ~= (jeep.y < 0), "arrivals alternate top and bottom")
check(farAlly.x == 7000, "allies that arrive elsewhere stay where they are")
local startSquad = T[1].x
defense.update()
check(T[1].x == startSquad and rookie.x == rookie.targetx, "nobody is moved twice; the starting squad stays")

-- tactical withdrawal: out by the nearest top/bottom edge, then the game's own take-off
local leaver = troop("allied", 6400, 300, 1) leaver.tacDraw = 1
table.insert(T, leaver)
defense.update() -- (seen as an arrival first: not at the left edge, left alone)
leaver.targetx = -500 -- what the game's AI sets every frame (ai.lua:1691)
defense.withdraw(leaver)
check(leaver.targetx == 6400 and leaver.targety == 0, "withdrawing soldier heads for the nearest edge (top)")
leaver.y = 20
defense.update()
check(leaver.x == 50, "at the edge he's handed to the game's take-off (x < 100)")

-- resuming a battle under way: nothing moved, defense back on if the radar is there
local radarCount = 0
for _, p in ipairs(player.placeables) do if p.name == "coopRadar" then radarCount = radarCount + 1 end end
local sx = T[1].x
T[1].x = 6000
defense.on = false
defense.afterSetup(false)
local after = 0
for _, p in ipairs(player.placeables) do if p.name == "coopRadar" then after = after + 1 end end
check(defense.on and T[1].x == 6000 and after == radarCount, "resume: defense on, squad not moved, no second radar")
T[1].x = sx
local saved = player.placeables
player.placeables = {}
defense.afterSetup(false)
check(not defense.on, "resume without a radar: an ordinary Classic battle")
player.placeables = saved
defense.afterSetup(false)

-- wave pace: living Germans count half in the defense (the qm.toml patch on the wave timer)
check(defense.on and defense.wavePace() == 2, "defense: the wave timer counts the living Germans / 2")
player.gameState = 1
check(defense.wavePace() == 1, "not in a battle: pace 1")
player.gameState = 0
defense.on = false
check(defense.wavePace() == 1, "an ordinary Classic battle: the game's own pace (1)")
defense.on = true
player.gameType = 0
check(defense.wavePace() == 1, "not Classic: pace 1")
player.gameType = 1
do
  local axis = 0
  for _, t in ipairs(player.deployedTroops) do if t.faction == "axis" and t.health > 10 then axis = axis + 1 end end
  -- the patched expression, as qm.toml writes it
  coopWavePace = defense.wavePace
  check((axis / (coopWavePace and coopWavePace() or 1)) == axis / 2, "patched wave timer expression: half the Germans")
  coopWavePace = nil
  check((axis / (coopWavePace and coopWavePace() or 1)) == axis, "without the co-op the expression is the game's own count")
end

-- the radar
player.mnb2Miss = 0
local runner = troop("axis", 6300 + 50, 360) runner.coopSide = "R"
table.insert(T, runner)
defense.update()
check(player.mnb2Miss == 1 and runner.x == 12000 and announced == 1, "a German at the radar: one iron cross, sent back right")
local sneaky = troop("axis", 6300 + 200, 700) sneaky.coopSide = "L" -- far from the radar, but past its line
table.insert(T, sneaky)
defense.update()
check(player.mnb2Miss == 2 and sneaky.x == defense.LEFT_EDGE + 200, "a left German through the line counts too, sent back left")
local edge = troop("axis", 100, 300) edge.coopSide = "L"
table.insert(T, edge)
defense.update()
check(edge.x >= 300 and player.mnb2Miss == 2, "left Germans kept off the game's own miss line")
local jager = troop("axis", 6300, 360) jager.tag = "jager" jager.coopSide = "R"
table.insert(T, jager)
defense.update()
check(player.mnb2Miss == 2, "Jagers don't score (as in the game)")
local fresh = troop("axis", 1500, 200) -- a paradrop, say: no side yet
table.insert(T, fresh)
defense.update()
check(fresh.coopSide == "L", "a German who appears on the left is the left side's")
local onRadar = troop("axis", 6300 + 100, 300) -- a German the game drops right by the radar
local onRadarL = troop("axis", 6300 - 400, 300)
table.insert(T, onRadar) table.insert(T, onRadarL)
local misses = player.mnb2Miss
defense.update()
check(onRadar.coopSide == "R" and onRadar.x >= 6300 + defense.SPAWN_CLEAR and onRadar.targetx == onRadar.x,
  "a new German by the radar is pushed out to the clear zone's edge (" .. onRadar.x .. ")")
check(onRadarL.coopSide == "L" and onRadarL.x <= 6300 - defense.SPAWN_CLEAR, "on the left too (" .. onRadarL.x .. ")")
check(player.mnb2Miss == misses, "and doesn't score for appearing there")
local halftrack = { faction = "axis", x = 6300 + 400, y = 500 }
player.deployedVehicles = player.deployedVehicles or {}
table.insert(player.deployedVehicles, halftrack)
local dismount = troop("axis", 6300 + 400, 550) -- his squad gets out by the radar
table.insert(T, dismount)
defense.update()
check(dismount.x == 6700 and dismount.coopSide == "R", "men getting out of a German vehicle stay where it is")
table.remove(player.deployedVehicles)
local fighting = troop("axis", 6300 + 300, 300) -- saved mid-battle: already near the squad
table.insert(T, fighting)
defense.afterSetup(false)
defense.update()
check(fighting.x == 6600, "loading a battle under way: Germans already fighting keep their place")

-- German vehicles from both sides (owner: "make the vehicles alternate left and right"; then
-- "vehicles being half is weird": a normal wave's vehicles get a twin on the left, like its men)
local V = player.deployedVehicles
local function veh(tag, x, targetx)
  return { faction = "axis", tag = tag, x = x, y = 300, targetx = targetx or x, targety = 300,
    rotation = math.rad(90), intendedRotation = math.rad(90), turretCurrentAngle = math.rad(90),
    turretTargetAngle = math.rad(90), sideRoller = 0, buff = { { tag = "x" } }, passengers = { 1, 1 } }
end
local vlo, vhi = defense.frontLines()
local vWave = defense.wrapWave(function()
  table.insert(V, veh("panzer4", 13000, 6400))   -- drives at the front
  table.insert(V, veh("sdkfz", 13000, 6400))
  table.insert(V, veh("pak38", 7700))           -- a gun put down past the front (targetx = x)
  table.insert(V, veh("goliath", 12000, 6400))   -- stays right
end)
local nv = #V
vWave()
-- the four the game made stay right; the panzer, the halftrack and the gun get twins (nv+5..nv+7)
local a, gun, gol, b = V[nv + 1], V[nv + 3], V[nv + 4], V[nv + 5]
check(#V == nv + 7, "three twins added (the Goliath has none): " .. (#V - nv) .. " vehicles")
check(a.coopSide == "R" and V[nv + 2].coopSide == "R" and gun.coopSide == "R", "the game's vehicles stay right")
check(b.coopSide == "L" and b.tag == "panzer4" and V[nv + 6].tag == "sdkfz" and V[nv + 7].tag == "pak38"
  and V[nv + 7].coopSide == "L", "each gets a twin on the left")
check(b.id ~= a.id and b.buff ~= a.buff and b.passengers ~= a.passengers and #b.passengers == 2,
  "a twin has its own id and tables")
check(b.x < 0 and b.x >= -300, "a left vehicle starts off the map on the left (" .. b.x .. ")")
check(math.abs(b.rotation - math.rad(270)) < 1e-6 and math.abs(b.turretTargetAngle - math.rad(270)) < 1e-6,
  "a left vehicle faces right, turret too")
check(b.targetx == math.floor(vlo + vhi - 6400), "its target mirrored to the west front (" .. b.targetx .. ")")
check(a.x == 13000 and a.rotation == math.rad(90), "a right vehicle is left as the game made it")
check(gol.coopSide == "R" and gol.x == 12000, "Goliaths stay right")
-- a stationary gun sent left lands outside the radar's clear zone, staying put
local gun2 = veh("pak38", 7700)
defense.sendVehicleLeft(gun2)
check(gun2.x <= 6300 - defense.SPAWN_CLEAR and gun2.targetx == gun2.x, "a gun sent left: past the clear zone, stays put")
-- driving rules (the qm.toml patches in vehicleUpdate)
b.x, b.targetx = 3000, 5500
check(defense.vehicleBacks(b) == false, "left vehicle heading right (at us): drives normally, not backing up")
b.targetx = 1000
check(defense.vehicleBacks(b) and defense.vehicleBackSign(b) == -1 and math.abs(defense.vehicleBackRot(b) - math.rad(270)) < 1e-6,
  "left vehicle retreating west: backs up to the left, facing right")
a.x, a.targetx = 9000, 12000
check(defense.vehicleBacks(a) and defense.vehicleBackSign(a) == 1 and defense.vehicleBackRot(a) == math.rad(90),
  "right vehicle retreating east: the game's own rule")
a.targetx = 7000
check(defense.vehicleBacks(a) == false, "right vehicle heading at us: drives normally")
-- the AIs: each side's own German front; a left vehicle's target comes back mirrored
for i = #T, 1, -1 do if T[i].faction == "axis" then table.remove(T, i) end end
local gR, gL = troop("axis", 7800, 300), troop("axis", 4600, 300)
gR.coopSide, gL.coopSide = "R", "L"
table.insert(T, gR) table.insert(T, gL)
function axisFrontLine() return 4600 end -- the game's: the west-most German anywhere
local seenFront
local ai = defense.wrapVehicleAI(function(v) seenFront = axisFrontLine() v.targetx = axisFrontLine() + 200 end)
a.x = 9500
ai(a)
check(seenFront == 7800 and a.targetx == 8000, "a right vehicle's German front is the right side's (it went to the left's)")
b.x = 2500
ai(b)
check(b.targetx == 4600 - 200, "a left vehicle's target: just behind the left's front German (" .. b.targetx .. ")")
check(axisFrontLine() == 4600, "the game's axisFrontLine is back afterwards")
local ai2 = defense.wrapVehicleAI(function(v) v.targetx = 14000 end)
ai2(b)
check(b.targetx == defense.LEFT_EXIT, "a left vehicle's retreat to the far right becomes the left edge")
b.targetx = 14000 -- set outside the AIs (no crew, ai.lua:4281)
defense.update()
check(b.targetx == defense.LEFT_EXIT, "a left vehicle's retreat set elsewhere also goes left")
local stray = veh("puma", 3000) -- a vehicle from somewhere else: its side by where it is
table.insert(V, stray)
defense.update()
check(stray.coopSide == "L", "a vehicle with no side gets one by where it is")
for i = #V, nv + 1, -1 do table.remove(V, i) end

-- our soldiers falling back go to the radar, not left (owner: "they should retreat to the radio")
local function nearRadar(t) return math.sqrt((t.targetx - 6300) ^ 2 + (t.targety - 360) ^ 2) <= defense.FALLBACK_R + 25 end
local retreat = defense.wrapAlliedRetreat(function(d) d.targetx = d.x - 400 d.state = "idle" d.retreating = 10 end)
local eastGuy = troop("allied", 6800, 300, 1)
retreat(eastGuy)
check(nearRadar(eastGuy) and eastGuy.targetx > 6300 and eastGuy.retreating == 10,
  "a shaken soldier east of the radar falls back to it, on his side (" .. eastGuy.targetx .. ", " .. eastGuy.targety .. ")")
local westGuy = troop("allied", 5600, 420, 1)
retreat(westGuy)
check(nearRadar(westGuy) and westGuy.targetx < 6300, "west of it: to the radar too, not further west (" .. westGuy.targetx .. ")")
local cqc = troop("allied", 6800, 300, 1)
defense.wrapAlliedRetreat(function() end)(cqc) -- the game didn't move him (a German at arm's length)
check(cqc.targetx == 6800, "when the game doesn't move him, neither do we")
local panicky = troop("allied", 7000, 500, 1)
panicky.targetx = 7000 - 1280
defense.panicked(panicky)
check(nearRadar(panicky), "a panicking soldier runs to the radar instead of a screen to the left")
local leaving = troop("allied", 7000, 500, 1)
leaving.tacDraw, leaving.targetx = 2, -500
defense.panicked(leaving)
check(leaving.targetx == -500, "a tactical withdrawal still leaves")
player.gameState = 1
local before = player.mnb2Miss
local late = troop("axis", 6300, 360) late.coopSide = "R"
table.insert(T, late)
defense.update()
check(player.mnb2Miss == before, "nothing scores once the battle is over")

print(("%d passed, %d failed"):format(passes, fails))
love.event.quit(fails == 0 and 0 or 1)
