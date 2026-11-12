-- Headless test of coop_ribbons.lua: the registry, the game's globals, awarding only in co-op,
-- the game's own ids passing through checkRibCondition, and the +2 TP cap of Two-Front War.
local MOD = os.getenv("COOP_DIR")
package.preload["includes/mods/mnb_coop/coop_ribbons"] = function() return assert(loadfile(MOD .. "/coop_ribbons.lua"))() end

local fails, passes = 0, 0
local function check(c, w) if c then passes = passes + 1 else fails = fails + 1 print("FAIL: " .. w) end end

-- stubs for the game's globals
local announced = {}
function hasRib(n) for _, r in ipairs(player.ribs) do if r == n then return true end end return false end
function announceRibbon(n) announced[#announced + 1] = n end
local gameCalls = {}
function checkRibCondition(n) gameCalls[#gameCalls + 1] = n; return "game" .. n end
-- the game's giveTp: tpMax is a global, the pool is clamped to it (mnb2.lua:894-952)
function giveTp(nbr)
  tpMax = 20
  if hasRib(67) then tpMax = tpMax + 1 end
  player.tp = player.tp + nbr
  if player.tp > tpMax then player.tp = tpMax end
end
local function fresh(wave, miss)
  player = { ribs = {}, gameType = 1, currentWave = wave or 0, mnb2Miss = miss or 0, tp = 0, mnb2SubGame = 0 }
  announced = {}
end
local function coop(on) mnbCoop = { campaign = { active = false }, defense = { on = on } } end

local ribbons = require("includes/mods/mnb_coop/coop_ribbons")

-- 1. registry and globals
check(#ribbons.list == 3, "three starter ribbons")
check(ribbons.byId[201] and ribbons.byId[202] and ribbons.byId[203], "ids 201, 202, 203")
for _, id in ipairs({ 201, 202, 203 }) do
  check(type(_G["ribName_" .. id]) == "string" and #_G["ribName_" .. id] > 0, "ribName_" .. id .. " defined")
  check(type(_G["ribDesc_" .. id]) == "string" and #_G["ribDesc_" .. id] > 0, "ribDesc_" .. id .. " defined")
end
check(ribbons.byId[201].name == "Two-Front War" and ribbons.byId[203].name == "Brothers in Arms", "names")

-- 2. pictures: the real sprites from the repo, and a flat fallback when the file is missing
ribbons.dir = MOD
ribbons.loadImages()
for _, id in ipairs({ 201, 202, 203 }) do
  local img = _G["rib" .. id]
  check(img ~= nil and img:getWidth() == 75 and img:getHeight() == 28, "rib" .. id .. " is a 75x28 Image")
end
rib201 = nil
ribbons.dir = MOD .. "/nowhere"
ribbons.loadImages()
check(rib201 ~= nil and rib201:getWidth() == 75, "missing png: a flat fallback picture, never nil")
ribbons.dir = MOD

-- 3. awarding only in co-op
fresh(100, 0); coop(false)
check(ribbons.check(201) == false and #player.ribs == 0, "outside co-op: no award")
mnbCoop = nil
check(ribbons.check(201) == false, "no mnbCoop at all: no award")
coop(true)
fresh(99, 0)
check(ribbons.check(201) == false, "wave 99: not yet")
fresh(100, 0)
check(ribbons.check(201) == true and hasRib(201) and announced[1] == 201, "wave 100 in a defense: 201 awarded and announced")
check(ribbons.check(201) == false and #player.ribs == 1, "only once")
fresh(50, 0)
ribbons.checkAll()
check(hasRib(202) and not hasRib(201), "wave 50, no radar hits: only 202")
fresh(50, 1)
ribbons.checkAll()
check(not hasRib(202), "a German reached the radar: no 202")
fresh(100, 0); coop(false)
mnbCoop = { campaign = { active = true }, defense = { on = false } }
ribbons.checkAll()
check(not hasRib(201), "co-op campaign has no waves: 201 needs a defense")
fresh(0, 0)
player.coopStats = { revives = 24 }
ribbons.checkAll()
check(not hasRib(203), "24 revives: not yet")
ribbons.addStat("revives", 1)
ribbons.checkAll()
check(hasRib(203), "25 revives in the campaign: 203")

-- 4. checkRibCondition: the game's ids pass through, ours go to the registry
ribbons.install()
fresh(100, 0); coop(true)
gameCalls = {}
check(checkRibCondition(63) == "game63" and gameCalls[1] == 63, "the game's id 63 goes to the game")
check(checkRibCondition(998) == "game998", "998 too")
check(#player.ribs == 0, "63 and 998 did not touch our ribbons")
checkRibCondition(65) -- the game's per-wave call: our check runs too
check(hasRib(201), "after the game's wave call 65, wave 100 awards 201")
fresh(100, 0); coop(false)
checkRibCondition(65)
check(#player.ribs == 0, "same call outside co-op: nothing")
fresh(100, 0); coop(true)
gameCalls = {}
checkRibCondition(202)
check(#gameCalls == 0, "our id 202 never reaches the game")
check(hasRib(202), "202 asked directly at wave 100 with no radar hits: earned through the registry")

-- 5. the TP cap
local function tpTest(label, rib, on, give, startTp, want)
  fresh(0, 0); coop(on); player.tp = startTp
  if rib then player.ribs[1] = 201 end
  local before = player.tp
  giveTp(give)
  ribbons.afterGiveTp(before, give)
  check(player.tp == want, label .. ": tp " .. player.tp .. " want " .. want)
end
tpTest("no ribbon, over the cap", false, true, 5, 18, 20)
tpTest("201 in a defense: cap 22", true, true, 5, 18, 22)
tpTest("201 in a defense, a small gift", true, true, 1, 18, 19)
tpTest("201 in a defense, hits 22 only", true, true, 10, 21, 22)
tpTest("201 outside co-op: cap stays 20", true, false, 5, 18, 20)
do -- with the game's other cap ribbon (67: +1) the bonus stacks
  fresh(0, 0); coop(true); player.ribs = { 67, 201 }; player.tp = 20
  local b = player.tp; giveTp(5); ribbons.afterGiveTp(b, 5)
  check(player.tp == 23, "67 and 201: cap 23, got " .. player.tp)
end
do -- spending TP (negative) is left alone
  fresh(0, 0); coop(true); player.ribs = { 201 }; player.tp = 22
  local b = player.tp; giveTp(-5); ribbons.afterGiveTp(b, -5)
  check(player.tp == 17, "spending 5 from 22: 17, got " .. player.tp)
end

print(("%d passed, %d failed"):format(passes, fails))
love.event.quit(fails)
