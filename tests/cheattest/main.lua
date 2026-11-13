-- Headless test of the co-op test cheats (coop_cheats.lua): the panel knows where it is and
-- changes the right profile.
local MOD = os.getenv("COOP_DIR")
local VANILLA = os.getenv("MNB_VANILLA_DIR") or (MOD .. "/../../vanilla-src")
for _, n in ipairs({ "coop_codec", "coop_profile", "coop_mods", "coop_net", "coop_campaign", "coop_cheats" }) do
  package.preload["includes/mods/mnb_coop/" .. n] = function() return assert(loadfile(MOD .. "/" .. n .. ".lua"))() end
end
package.preload["includes/ser"] = function() return assert(loadfile(VANILLA .. "/includes/ser.lua"))() end
local fails, passes = 0, 0
local function check(c, w) if c then passes = passes + 1 else fails = fails + 1 print("FAIL: " .. w) end end
local fs = love.filesystem
for _, f in ipairs({ "saveMNB3.lua", "saveMNB2.lua", "coop/campaign/saveMNB3.lua", "coop/classic/saveMNB2.lua" }) do fs.remove(f) end
local ser = require("includes/ser")

createAlliedSoldier = function(d) d.faction = "allied" d.playerControlled = 1 d.npc = 0 d.dead = 0 end
assignNextPerk = function() end
randNbr = function() return 1 end
newProfile = function() local p = player p.dayz = 1 p.gainz = 1 p.gameType = 0 p.name = "coop" p.deployedTroops = {} end
updateProfile = function() end
nextLevel = function(rank) return rank * 1000 + 500 end -- (rank 0 -> 1 past 500 XP, 1 -> 2 past 1500)
giveXp = function(s, xp) s.xp = (s.xp or 0) + xp end
local placed = {}
createLootByName = function(name, x, y) placed[#placed + 1] = { name, x, y } end
local notes = {}
modLibrary = { option = function(_, id) if id == "testCheats" then return true end return nil end, debugLog = function() end }
local campaign = require("includes/mods/mnb_coop/coop_campaign")
local cheats = require("includes/mods/mnb_coop/coop_cheats")
local lobby = { page = 140, hubPage = 141, roomPage = 142 }
mnbCoop = { lobby = lobby, notice = function(t) notes[#notes + 1] = t end }

local function find(list, text)
  for _, it in ipairs(list) do if it.text:find(text, 1, true) then return it end end
end

-- main menu: your own profile, saved at once (Classic XP into the real Classic save too)
player = { name = "real", gameType = 0, gameState = 1, rank = 0, experience = 0, skillCredit = 0,
  deployedTroops = { { xp = 0, dead = 0 }, { xp = 0, dead = 0 } } }
fs.write("saveMNB2.lua", ser({ name = "realClassic", mnb2Experience = 0, mnb2Rank = 0 }))
menuPage = 1
check(cheats.context() == "menu", "main menu: your own profile")
local items = cheats.items("menu")
find(items, "Career").fn()
check(player.experience == 1000 and player.rank == 1 and player.skillCredit == 1, "career XP with the game's promotion")
check(fs.load("saveMNB3.lua")().experience == 1000, "saved at once")
find(items, "Classic").fn()
check(player.mnb2Experience == 1000 and fs.load("saveMNB2.lua")().mnb2Rank == 1, "Classic XP: profile and the Classic save")
find(items, "Squad").fn()
check(player.deployedTroops[1].xp == 200 and player.deployedTroops[2].xp == 200, "squad XP")

-- co-op pages: the co-op profile, the real one untouched
local realBefore = fs.read("saveMNB3.lua")
check(campaign.enter(), "co-op opened")
menuPage = 141
check(cheats.context() == "coop", "co-op page: the co-op profile")
find(cheats.items("coop"), "Career").fn()
check(campaign.profile.experience == 1000, "co-op career XP")
check(fs.read("saveMNB3.lua") ~= nil and (function() campaign.active = false local r = fs.read("saveMNB3.lua") campaign.active = true return r end)() == realBefore,
  "the real save isn't touched")
campaign.exit()

-- a battle on this machine: TP, heal, items at the next click
player = { gameType = 1, gameState = 0, tp = 5, screenx = 100, screeny = 0, skill = { { id = 3, timer = 50, use = 1 } },
  deployedTroops = { { faction = "allied", playerControlled = 1, health = 10, maxHealth = 100, xp = 0 } } }
check(cheats.context() == "battle", "in a battle")
items = cheats.items("battle")
find(items, "+20 TP").fn()
check(player.tp == 25, "TP")
find(items, "Heal").fn()
check(player.deployedTroops[1].health == 100, "heal")
find(items, "Abilities").fn()
check(player.skill[1].timer == 0, "abilities ready")
check(find(items, "Next wave") ~= nil, "Classic: next wave is offered")
find(items, "frag").fn()
check(cheats.armed and cheats.armed.loot == "loot_frag", "an item waits for a click")
check(cheats.mousepressed(300, 200, 1) and placed[1] and placed[1][1] == "loot_frag" and placed[1][2] == 400,
  "placed where clicked (camera counted)")
check(cheats.mousereleased(300, 200, 1), "and its release is swallowed")

-- watching the host's battle: nothing to do
mnbCoop.battle = { viewing = true }
check(cheats.context() == "watching" and cheats.items("watching")[1].fn == nil, "watching: nothing")
mnbCoop.battle = nil

-- the key: F6 toggles; off in the options: it says so
check(cheats.keypressed("f6") and cheats.open, "F6 opens the panel")
modLibrary.option = function() return nil end
cheats.open = false
check(cheats.keypressed("f6") and not cheats.open and notes[#notes]:find("off") ~= nil, "option off: F6 says so")

print(("%d passed, %d failed"):format(passes, fails))
love.event.quit(fails == 0 and 0 or 1)
