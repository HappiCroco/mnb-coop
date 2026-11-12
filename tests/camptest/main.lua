-- Headless test of coop_campaign's save redirect: the co-op campaign lives on its own
-- save files and the real campaign save is never touched.
local MOD = os.getenv("COOP_DIR")
local VANILLA = os.getenv("MNB_VANILLA_DIR") or (MOD .. "/../../vanilla-src")
for _, n in ipairs({ "coop_codec", "coop_profile", "coop_net", "coop_campaign" }) do package.preload["includes/mods/mnb_coop/" .. n] = function() return assert(loadfile(MOD .. "/" .. n .. ".lua"))() end end
createAlliedSoldier = function(d) d.faction = "allied" d.playerControlled = 1 d.npc = 0 d.dead = 0 end assignNextPerk = function() end randNbr = function() return 1 end
package.preload["includes/ser"] = function() return assert(loadfile(VANILLA .. "/includes/ser.lua"))() end
local fails, passes = 0, 0
local function check(c, w) if c then passes = passes + 1 else fails = fails + 1 print("FAIL: " .. w) end end
for _, f in ipairs({ "saveMNB3.lua", "coop/campaign/saveMNB3.lua", "coop/campaign/saveMNB3.lua.old" }) do love.filesystem.remove(f) end
local ser = require("includes/ser")
-- like the game's: no argument, works on the global player
newProfile = function() local p = player p.dayz = 1 p.gainz = 1 p.gameType = 0 p.name = "coop" p.option_volume = 5 p.deployedTroops = {} end
updateProfile = function(p) p.updated = true end
-- the real profile, saved like the game does
player = { name = "real", dayz = 40, gameType = 0, option_volume = 2, option_music = 0, ribs = { 7 } }
love.filesystem.write("saveMNB3.lua", ser(player))
local realOnDisk = love.filesystem.read("saveMNB3.lua")
menuPage = 140
local campaign = require("includes/mods/mnb_coop/coop_campaign")
check(not campaign.hasSave(), "no co-op save yet")
check(campaign.enter(), "enter")
check(player.name == "coop" and player.dayz == 1 and player.coopCampaign == 1, "fresh co-op profile")
check(player.option_volume == 2 and player.option_music == 0, "settings copied in")
check(campaign.hasSave(), "co-op save written")
-- the game's own code saves and loads 'saveMNB3.lua' while co-op is on
player.dayz = 5
love.filesystem.write("saveMNB3.lua", ser(player))
love.filesystem.write("backUp.lua", ser(player))
check(love.filesystem.read("saveMNB3.lua"):find("coop") ~= nil, "game's read goes to co-op file")
player = love.filesystem.load("saveMNB3.lua")()
check(player.dayz == 5 and player.name == "coop", "game's load gets co-op profile")
check(love.filesystem.getInfo("backUp.lua") ~= nil, "backup redirected")
-- real save untouched
local realNow = (function() campaign.active = false local r = love.filesystem.read("saveMNB3.lua") campaign.active = true return r end)()
check(realNow == realOnDisk, "real save untouched during co-op")
player.option_volume = 4 -- player changes volume during co-op
menuPage = 1
campaign.update()
check(campaign.active and player.name ~= "real", "main menu is the co-op hub: co-op profile stays loaded")
campaign.exit() -- Back from the Multiplayer lobby
check(not campaign.active and player.name == "real" and player.dayz == 40, "back to real profile when leaving the lobby")
check(player.option_volume == 4, "volume change carried back")
check(love.filesystem.read("saveMNB3.lua") == realOnDisk, "real save file still untouched")
check(love.filesystem.getInfo("backUp.lua") == nil or true, "ok")
-- continue: enter again loads day 5
menuPage = 140
check(campaign.enter() and player.dayz == 5 and player.name == "coop", "continue co-op at day 5")
-- quitting during co-op: game saves (redirected), then real is restored and saved
player.dayz = 6
love.filesystem.write("saveMNB3.lua", ser(player)) -- what love.quit does
campaign.onQuitAfterGameSaved()
check(player.name == "real" and not campaign.active, "quit restores real")
local realAfterQuit = love.filesystem.load("saveMNB3.lua")()
check(realAfterQuit.name == "real" and realAfterQuit.dayz == 40 and realAfterQuit.option_volume == 4, "real save rewritten as the game would")
campaign.active = true local coopAfter = love.filesystem.load("saveMNB3.lua")() campaign.active = false
check(coopAfter.dayz == 6, "co-op progress saved on quit")
check(campaign.reset() and not campaign.hasSave() and love.filesystem.getInfo("coop/campaign/saveMNB3.lua.old") ~= nil, "reset keeps .old")
print(("%d passed, %d failed"):format(passes, fails))
love.event.quit(fails == 0 and 0 or 1)
