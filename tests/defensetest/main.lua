-- Headless test of coop_defense.lua: the middle layout, both-side waves, mirrored AI, the radar.
local MOD = os.getenv("COOP_DIR")
for _, n in ipairs({ "coop_codec", "coop_profile", "coop_net", "coop_defense" }) do
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

-- a wave: the game makes four Germans right of the players; two go left
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
    check(T[i].x == lo - 750 and T[i].targetx == T[i].x and T[i].trenchHome == T[i].x, "left German mirrored: same distance from the west flank")
  elseif T[i].coopSide == "R" then
    right = right + 1
    check(T[i].x == hi + 750, "right German where the game put him")
  end
end
check(left == 2 and right == 2, "solo: the wave split in two")
local gL, gR = T[n0 + 2], T[n0 + 1]

-- with friends: every German gets a twin on the left (double the attack)
local net = require("includes/mods/mnb_coop/coop_net")
net.seats = { { name = "Host" }, { name = "Ann" } }
local n2 = #T
wave()
local L2, R2, ids = 0, 0, {}
for i = n2 + 1, #T do
  if T[i].coopSide == "L" then L2 = L2 + 1 elseif T[i].coopSide == "R" then R2 = R2 + 1 end
  ids[T[i]] = true
end
check(L2 == 4 and R2 == 4, "with friends: the full wave on each side (" .. L2 .. " left, " .. R2 .. " right)")
local twin, orig = T[#T], T[n2 + 4] -- originals are n2+1..n2+4, their twins come after, in order
check(twin.coopSide == "L" and twin.x == lo - 750 and twin.y == orig.y, "a twin mirrored to the left at the same height")
check(twin ~= orig and twin.weapon ~= orig.weapon or orig.weapon == nil, "the twin has his own tables")
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
player.gameState = 1
local before = player.mnb2Miss
local late = troop("axis", 6300, 360) late.coopSide = "R"
table.insert(T, late)
defense.update()
check(player.mnb2Miss == before, "nothing scores once the battle is over")

print(("%d passed, %d failed"):format(passes, fails))
love.event.quit(fails == 0 and 0 or 1)
