-- Own rosters: a whole co-op mission with three players, headless.
local MOD = os.getenv("COOP_DIR")
local VANILLA = os.getenv("MNB_VANILLA_DIR") or (MOD .. "/../../vanilla-src")
for _, n in ipairs({ "coop_codec", "coop_profile", "coop_mods", "coop_net", "coop_campaign" }) do
  package.preload["includes/mods/mnb_coop/" .. n] = function() return assert(loadfile(MOD .. "/" .. n .. ".lua"))() end
end
package.preload["includes/ser"] = function() return assert(loadfile(VANILLA .. "/includes/ser.lua"))() end
local fails, passes = 0, 0
local function check(c, w) if c then passes = passes + 1 else fails = fails + 1 print("FAIL: " .. w) end end
love.filesystem.remove("coop/campaign/saveMNB3.lua")

local nextId = 0
randNbr = function(n) return love.math.random(1, n) end
createAlliedSoldier = function(d)
  nextId = nextId + 1
  d.id = 1000 + nextId d.name = "Pvt" .. nextId d.faction = "allied" d.tag = "allied" d.playerControlled = 1 d.npc = 0
  d.dead = 0 d.health = 100 d.maxHealth = 100 d.xp = 0 d.weapon = {} d.perks = {} d.awards = {}
end
assignNextPerk = function() end
giveXp = function(s, n) s.xp = (s.xp or 0) + n end
newProfile = function()
  local p = player
  p.dayz, p.gainz, p.landed, p.gameType, p.diff, p.name = 1, 1, 0, 0, 0, "coop"
  p.deployedTroops = {}
  for i = 1, 6 do p.deployedTroops[i] = {} createAlliedSoldier(p.deployedTroops[i]) end
end
updateProfile = function() end
currentVersion = "x"
player = { name = "real", gameType = 0, bloop = 0 }
menuPage = 6
local campaign = require("includes/mods/mnb_coop/coop_campaign")
local net = require("includes/mods/mnb_coop/coop_net")
local function T() return player.deployedTroops end

-- ---- the host opens its co-op save: a roster of 6 with stable ids
check(campaign.enter(), "enter")
check(#T() == 6 and T()[1].coopUid and T()[6].coopUid, "roster of 6, each with a coopUid")
local hostUid = {}
for i = 1, 6 do hostUid[i] = T()[i].coopUid end

-- ---- trio: two teammates sent their rosters (top 3, by position)
net.role, net.mySeat = "host", 1
net.seats = { { name = "Host", steamId = "111" }, { name = "Ann", steamId = "222" }, { name = "Bob", steamId = "333" } }
local function friendSoldier(name, uid, xp)
  return { name = name, coopUid = uid, xp = xp, health = 100, maxHealth = 100, dead = 0, faction = "axis", playerControlled = 0,
           weapon = { tag = "m1" }, perks = { 3 }, awards = {}, id = 1001, evil = function() end }
end
check(campaign.onClientMessage(2, { t = "roster", soldiers = {
  { pos = 1, soldier = friendSoldier("Ann1", "A1", 50) }, { pos = 3, soldier = friendSoldier("Ann3", "A3", 40) },
  { pos = 5, soldier = friendSoldier("Ann5", "A5", 30) } } }), "roster understood")
campaign.onClientMessage(3, { t = "roster", soldiers = {
  { pos = 3, soldier = friendSoldier("Bob3", "B3", 20) }, { pos = 1, soldier = friendSoldier("Bob1", "B1", 10) } } })

campaign.arrangeSquad()
local seatsOf = {}
for i = 1, 6 do seatsOf[i] = T()[i].coopSeat end
check(table.concat(seatsOf, ",") == "1,1,2,2,3,3", "trio: 2 each in seat order (" .. table.concat(seatsOf, ",") .. ")")
check(T()[1].coopUid == hostUid[1] and T()[2].coopUid == hostUid[3], "host brings roster cards 1 and 3 (top row)")
check(T()[3].name == "Ann1" and T()[4].name == "Ann3", "Ann brings her top two")
check(T()[5].name == "Bob1" and T()[6].name == "Bob3", "Bob's sorted by position: card 1 before card 3")
check(T()[3].faction == "allied" and T()[3].playerControlled == 1 and T()[3].evil == nil, "teammate soldiers sanitized")
check(T()[3].id ~= 1001 or T()[5].id ~= 1001, "duplicate ids re-rolled")
check(player.coopHome[2] and player.coopHome[4] and player.coopHome[5] and player.coopHome[6], "host's cards 2, 4, 5, 6 stay home")
campaign.retag()
check(T()[4].coopSeat == 2, "retag keeps seats during the mission")

-- ---- the battle: host soldiers +10 XP, Ann1 killed, Bob3 killed and replaced on the field
T()[1].xp = T()[1].xp + 10
T()[2].xp = T()[2].xp + 10
T()[3].health, T()[3].dead = 0, 1
T()[6] = {} createAlliedSoldier(T()[6]) -- the game's replacement, no coop tags
T()[7] = { faction = "axis", playerControlled = 0 } -- an enemy left in the list
campaign.retag()
check(T()[6].coopSeat == 3, "replacement in Bob's slot is Bob's")

-- ---- settle: host roster back in order, home soldiers +5 (half of 10), results to teammates
local sent = {}
net.sendTo = function(seat, msg) sent[seat] = msg end
local homeXpBefore = player.coopHome[4].xp
campaign.settleMission()
check(T()[1].coopUid == hostUid[1] and T()[3].coopUid == hostUid[3] and T()[2].coopUid == hostUid[2], "host roster back in its order")
check(T()[1].xp == 10 and T()[4].xp == homeXpBefore + 5, "fielded +10, home +5 (half the average)")
check(T()[1].coopSeat == nil and player.coopMission == nil, "battle tags and mission cleared")
check(T()[7] and T()[7].faction == "axis", "non-squad entries kept after the roster")
check(sent[2] and #sent[2].soldiers == 2 and sent[3] and #sent[3].soldiers == 2, "results sent to Ann and Bob")
local annDead
for _, e in ipairs(sent[2].soldiers) do if e.soldier.coopUid == "A1" then annDead = e end end
check(annDead and annDead.pos == 1 and annDead.soldier.dead == 1, "Ann's card 1 comes back killed")
local bobNew
for _, e in ipairs(sent[3].soldiers) do if e.pos == 3 then bobNew = e end end
check(bobNew and bobNew.soldier.coopUid == nil, "Bob's card 3 comes back as the replacement")
campaign.settleMission()
check(#T() == 7, "settling twice changes nothing")

-- ---- a player leaves mid-mission: their soldiers walk off the map; a newcomer comes in
campaign.arrangeSquad()
player.gameState = 0
T()[5].y, T()[6].y = 100, 600
local bob5 = T()[5]
net.seats[3] = nil
campaign.onSeatLeft(3)
check(T()[5].coopLeaving == 1 and T()[5].coopNpc == 1, "Bob's soldiers pull out")
campaign.updateLeavers()
check(T()[5].targety < 0 and T()[6].targety > 720, "each heads for the nearest edge (top / bottom)")
campaign.retag()
check(T()[5].coopSeat == 3 and T()[5].coopSquad == nil, "retag leaves the leavers alone")
T()[5].y = -100 -- walked off the top
campaign.updateLeavers()
check(T()[5].coopGone == 1 and T()[5].x == -9999 and T()[5].playerControlled == 0, "off the map: taken off")
check(T()[6].coopLeaving == 1, "the other is still walking")
-- Cid joins during the mission and sends his roster: in from the left as reinforcements
net.seats[3] = { name = "Cid", steamId = "444" }
campaign.onClientMessage(3, { t = "roster", soldiers = {
  { pos = 1, soldier = friendSoldier("Cid1", "C1", 5) }, { pos = 3, soldier = friendSoldier("Cid3", "C3", 5) } } })
check(T()[5].name == "Cid1" and T()[5].x == 50 and T()[5].coopSeat == 3, "Cid's first soldier takes the free slot, from the left edge")
check(T()[6].coopLeaving == 1, "the slot of a soldier still walking out isn't taken yet")
check(T()[#T()] == bob5, "the parked leaver moved out of the squad slots")
T()[6].y = 900
campaign.updateLeavers()
check(T()[6].name == "Cid3" and T()[6].coopSeat == 3, "once Bob's second is off the map, Cid's second comes in")
sent = {}
player.gameState = 1
campaign.settleMission()
check(sent[3] and #sent[3].soldiers == 2 and sent[3].soldiers[1].soldier.coopUid == "C1", "Cid gets his soldiers' results")
local leftovers = 0
for _, t in ipairs(T()) do if t.coopNpc == 1 then leftovers = leftovers + 1 end end
check(leftovers == 0, "Bob's soldiers are gone after the mission")
check(#T() >= 6 and T()[1].coopUid == hostUid[1], "host roster fine after a leaver")

-- ---- Squad screen: right-drag card 1 onto card 4 swaps them
menuPage = 3
local u1, u4 = T()[1].coopUid, T()[4].coopUid
check(campaign.squadPress(60, 200, 2), "press on card 1")
check(campaign.squadRelease(290, 450, 2), "drop on card 4")
check(T()[1].coopUid == u4 and T()[4].coopUid == u1, "cards 1 and 4 swapped")
check(campaign.isGoing(1, 2) and campaign.isGoing(3, 2) and campaign.isGoing(5, 2) and not campaign.isGoing(2, 2), "duo: top row goes")
check(campaign.isGoing(1, 3) and campaign.isGoing(3, 3) and not campaign.isGoing(5, 3), "trio: first two of the top row go")

-- ---- XP day cap
floatyText = function() end
local wrapped = campaign.wrapGiveXp(function(s, n) s.xp = (s.xp or 0) + n end)
player.gameType, player.gameState = 0, 0
local s = T()[1]
player.gainz, s.xp = 1, 5
wrapped(s, 50)
check(s.xp > 19 and s.xp < 20, "day 1: stops just under level 3 (" .. s.xp .. ")")
wrapped(s, 10)
check(s.xp < 20 and s.coopCapNoted == 1, "at the cap nothing more, the soldier is told once")
player.gainz, s.xp = 2, 0
wrapped(s, 100)
check(s.xp > 39 and s.xp < 40, "day 2: stops under level 5")
player.gainz, s.xp = 3, 0
wrapped(s, 100)
check(s.xp == 100, "day 3: no cap")
player.coopMission, player.gainz, s.xp = { gainz = 1 }, 2, 0 -- the game moved the day on before the journal XP
wrapped(s, 50)
check(s.xp < 20, "during the mission-end the mission's own day counts")
player.coopMission = nil
player.gameType, s.xp = 1, 0
wrapped(s, 50)
check(s.xp == 50, "Classic is not capped")
player.gameType, player.gameState = 0, 1

-- ---- D-Day: veterans keep their perks and rifle, rookies get the game's
local vet, rookie = T()[1], T()[2]
vet.xp, vet.perks, vet.weapon = 30, { 5, 7 }, { tag = "bar" }
rookie.xp, rookie.perks = 0, { 1 }
local kept = campaign.stashVeterans()
vet.perks, vet.weapon, rookie.perks = { 9 }, { tag = "m1" }, { 3 } -- what preGameAdmin does on D-Day
campaign.restoreVeterans(kept)
check(vet.perks[1] == 5 and vet.perks[2] == 7 and vet.weapon.tag == "bar", "veteran keeps perks and weapon")
check(rookie.perks[1] == 3, "rookie gets the D-Day perk")

-- ---- an edited save can't bring a god soldier
local god = campaign.sanitize({ xp = 99999, level = 40, skill = 999, health = 5000, maxHealth = 9000, promo = 50 })
check(god.xp == 10000 and god.level == 11 and god.skill == 150 and god.maxHealth == 400 and god.health == 400 and god.promo == 11,
  "impossible values clamped")
-- crafted names the game would look up as sprites/texts: replaced by safe ones
spec_medic, spec_, allied_idle, face_eyes2, perk_1, perk_2, award5 = {}, {}, {}, {}, {}, {}, {}
local savedWC = weaponCreator
weaponCreator = function(w, tag)
  w.tag = (tag == "m1" or tag == "tommy") and tag or "k98"
  w.damage, w.maxAmmo = 40, 8
end
local bad = campaign.sanitize({ spec = "medic", state = "nope", eyes = 2, nose = 99, perks = { 1, 2, 999, "x" },
  awards = { { name = "Star", icon = 5, called = 0 }, { name = "Bad", icon = 4000 } },
  weapon = { tag = "tommy", damage = 99999, ammo = 500 }, name = ("N"):rep(500), stress = 1 / 0 })
check(bad.spec == "medic" and bad.state == "idle" and bad.eyes == 2 and bad.nose == 1, "spec/state/face: known ones kept, others reset")
check(#bad.perks == 2 and #bad.awards == 1 and bad.awards[1].icon == 5, "only perks and awards the game has pictures for")
check(bad.weapon.tag == "tommy" and bad.weapon.damage == 40 and bad.weapon.ammo == 8, "weapon rebuilt from its tag (no crafted damage)")
check(#bad.name == 40 and bad.stress == 0, "long names cut, infinite numbers zeroed")
check(campaign.sanitize({ spec = "hacker" }).spec == "", "an unknown spec becomes none")
weaponCreator = savedWC
spec_medic, spec_, allied_idle, face_eyes2, perk_1, perk_2, award5 = nil, nil, nil, nil, nil, nil, nil

-- ---- New war: day 1 again, the six soldiers come along
player.dayz, player.gainz = 30, 25
local uids = {}
for i = 1, 6 do uids[i] = T()[i].coopUid end
local xpBefore = T()[3].xp
check(campaign.newWar(), "new war")
check(player.gainz == 1 and player.dayz == 1 and player.gameState == 1, "back at day 1")
check(T()[1].coopUid == uids[1] and T()[6].coopUid == uids[6] and T()[3].xp == xpBefore, "the six soldiers came along with their XP")
local backup = false
for _, f in ipairs(love.filesystem.getDirectoryItems("coop/campaign")) do if f:match("%.war%d+$") then backup = true end end
check(backup, "the old war kept as a backup")
-- a save left in the middle of a mission: New war closes the mission (soldiers home) and goes ahead
player.coopMission = { gainz = 1, seats = { true } }
player.coopSquadTarget = 6
player.coopSlotSeats, player.coopSlotPos = { 1, 1, 1, 1, 1, 1 }, { 1, 2, 3, 4, 5, 6 }
local uid1 = T()[1].coopUid
player.dayz, player.gainz = 9, 7
check(campaign.newWar(), "new war from a save with a mission under way")
check(player.coopMission == nil and player.gainz == 1 and T()[1].coopUid == uid1, "mission closed, day 1, soldiers kept")
-- fresh start: day 1 with new rookies
check(campaign.newWar(true), "fresh start")
local sameAny = false
for i = 1, 6 do if T()[i] and T()[i].coopUid ~= nil and T()[i].coopUid == uids[i] then sameAny = true end end
check(player.gainz == 1 and #T() >= 6 and not sameAny, "fresh start: day 1, six new soldiers")
campaign.exit()

-- ---- the teammate's side: results land in their own co-op save
net.role, net.mySeat = "client", 2
local toHost = {}
net.sendToHost = function(msg) toHost[#toHost + 1] = msg end
local before
campaign.withProfile(function(p) before = campaign.copyData(p.deployedTroops, 0) end)
local res = { t = "results", day = 9, soldiers = {
  { pos = 1, soldier = (function() local s = campaign.copyData(before[1], 0) s.xp = s.xp + 8 return s end)() },
  { pos = 3, soldier = (function() local s = campaign.copyData(before[3], 0) s.dead, s.health = 1, 0 return s end)() },
} }
mnbCoop = { battle = { viewing = true } }
campaign.queueResults(res)
check(campaign.pendingResults ~= nil, "results wait while watching the battle")
mnbCoop.battle.viewing = false
campaign.update()
check(campaign.pendingResults == nil, "results applied once back in the menus")
local after, cim
campaign.withProfile(function(p) after = campaign.copyData(p.deployedTroops, 0) cim = #(p.cimetery or {}) end)
check(after[1].coopUid == before[1].coopUid and after[1].xp == before[1].xp + 8, "card 1 came back with +8 XP")
check(after[3].coopUid ~= before[3].coopUid and after[3].xp == 0, "card 3 fell: a recruit takes the place")
check(cim >= 1, "the fallen soldier is on the memorial")
check(after[2].xp == before[2].xp + 4 and after[6].xp == before[6].xp + 4, "home soldiers +4 (half of 8)")
check(#toHost >= 1 and toHost[#toHost].t == "roster" and #toHost[#toHost].soldiers == 3, "updated top 3 sent to the host")

print(("%d passed, %d failed"):format(passes, fails))
love.event.quit(fails == 0 and 0 or 1)
