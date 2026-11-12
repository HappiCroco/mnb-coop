-- Headless test of the co-op Classic profile (coop_campaign.lua, campaign.classic): while it is
-- open the game's Classic files go to coop/classic/ and the real Classic and campaign saves
-- are never read or written.
local MOD = os.getenv("COOP_DIR")
local VANILLA = os.getenv("MNB_VANILLA_DIR") or (MOD .. "/../../vanilla-src")
for _, n in ipairs({ "coop_codec", "coop_profile", "coop_mods", "coop_net", "coop_campaign" }) do package.preload["includes/mods/mnb_coop/" .. n] = function() return assert(loadfile(MOD .. "/" .. n .. ".lua"))() end end
createAlliedSoldier = function(d) d.faction = "allied" d.playerControlled = 1 d.npc = 0 d.dead = 0 end assignNextPerk = function() end randNbr = function() return 1 end
package.preload["includes/ser"] = function() return assert(loadfile(VANILLA .. "/includes/ser.lua"))() end
local fails, passes = 0, 0
local function check(c, w) if c then passes = passes + 1 else fails = fails + 1 print("FAIL: " .. w) end end
local fs = love.filesystem
for _, f in ipairs({ "saveMNB3.lua", "saveMNB2.lua", "backUp.lua", "coop/campaign/saveMNB3.lua", "coop/classic/saveMNB3.lua", "coop/classic/saveMNB2.lua" }) do fs.remove(f) end
local ser = require("includes/ser")

-- the game's pieces the Classic path uses, cut down to what touches files (urb_engine.lua:39939, mnb2.lua:960)
newProfile = function() local p = player p.dayz = 1 p.gameType = 0 p.name = "fresh" p.rank = 0 p.totalMNB2Game = 0 p.mnb2Rank = 0 p.maxWave = 0 p.ribs = {} p.deployedTroops = {} end
updateProfile = function(p) p.updated = true end
function fakeClassicButton()
    local volz, scroll = player.option_volume, player.scrollSpeed
    if player.gameType == 0 then fs.write("saveMNB3.lua", ser(player)) end
    if fs.getInfo("saveMNB2.lua") then
        player = fs.load("saveMNB2.lua")()
        player.gameType = 1
    else
        newProfile()
        player.gameState = 1
        player.gameType = 1
        fs.write("saveMNB2.lua", ser(player))
    end
    player.option_volume, player.scrollSpeed = volz, scroll
    if mnb3Tomnb2_maxWave ~= nil then player.maxWave = mnb3Tomnb2_maxWave end
    menuPage = 13
end
function fakeMissionEnd() -- postMNB2Mission: save the Classic profile, load the campaign one, copy the stats over
    player.totalMNB2Game = player.totalMNB2Game + 1
    player.mnb2Rank = player.mnb2Rank + 1
    player.maxWave = 7
    fs.write("saveMNB2.lua", ser(player))
    local rank, games, wave = player.mnb2Rank, player.totalMNB2Game, player.maxWave
    if fs.getInfo("saveMNB3.lua") then player = fs.load("saveMNB3.lua")() end
    player.mnb2Rank, player.totalMNB2Game = rank, games
    mnb3Tomnb2_maxWave = wave
    player.gameType = 0
    fs.write("saveMNB3.lua", ser(player))
end

-- the real profile and its Classic save, as on disk before co-op Classic
player = { name = "real", dayz = 40, gameType = 0, gameState = 1, option_volume = 2, scrollSpeed = 9, bloop = 0, rank = 3, mnb2Rank = 5, totalMNB2Game = 50 }
fs.write("saveMNB3.lua", ser(player))
fs.write("saveMNB2.lua", ser({ name = "realClassic", gameType = 1, mnb2Rank = 5, totalMNB2Game = 50, maxWave = 30, ribs = { 1 } }))
fs.write("backUp.lua", ser(player))
local real3, real2, realBackup = fs.read("saveMNB3.lua"), fs.read("saveMNB2.lua"), fs.read("backUp.lua")
local realPlayer = player
mnb3Tomnb2_maxWave = 30 -- left over from the real session
menuPage = 140
mnbCoop = { lobby = { getPage = function() return 140 end } }

local campaign = require("includes/mods/mnb_coop/coop_campaign")
local classic = campaign.classic
check(not classic.active and not classic.hasSave(), "nothing yet")

-- first co-op Classic game: fresh profile, real one aside
check(classic.enter(), "enter")
check(classic.active and player ~= realPlayer and player.name == "fresh" and player.gameType == 0 and player.coopCampaign == 1, "the co-op campaign profile loaded")
check(player.option_volume == 2 and player.scrollSpeed == 9, "settings carried in")
check(mnb3Tomnb2_maxWave == 0, "the co-op profile's max wave is handed on, not the real session's")
fakeClassicButton()
check(player.gameType == 1 and player.name == "fresh" and player.mnb2Rank == 0 and player.totalMNB2Game == 0, "fresh Classic profile (not the real rank)")
check(player.option_volume == 2 and player.scrollSpeed == 9, "settings carried into Classic")
check(fs.getInfo("coop/classic/saveMNB2.lua") ~= nil and fs.getInfo("coop/campaign/saveMNB3.lua") ~= nil, "Classic save in coop/classic, campaign profile in coop/campaign")
check(fs.getInfo("coop/classic/saveMNB3.lua") == nil, "no stand-in campaign profile any more")
check(fs.read("saveMNB2.lua") == fs.read("coop/classic/saveMNB2.lua"), "game's read of saveMNB2 sees the co-op file")
fakeMissionEnd()
fakeMissionEnd()
check(player.gameType == 0 and player.totalMNB2Game == 2 and player.mnb2Rank == 2, "ribbon counters grew on the co-op profile")
check(fs.read("saveMNB3.lua") == fs.read("coop/campaign/saveMNB3.lua"), "the game's campaign-profile writes go to the co-op campaign save")
-- real files untouched (read with the redirect off)
classic.active = false
check(fs.read("saveMNB3.lua") == real3 and fs.read("saveMNB2.lua") == real2 and fs.read("backUp.lua") == realBackup, "real saves untouched during co-op Classic")
classic.active = true
-- back on the lobby page: the real profile returns
player.option_volume = 4
menuPage = 140
classic.update()
check(not classic.active and player == realPlayer and player.name == "real" and player.dayz == 40, "back on the lobby page: real profile back")
check(player.option_volume == 4 and player.gameState == 1, "settings carried back")
check(mnb3Tomnb2_maxWave == 30, "real session's max wave restored")
check(fs.read("saveMNB3.lua") == real3 and fs.read("saveMNB2.lua") == real2 and fs.read("backUp.lua") == realBackup, "real saves still untouched")

-- second game continues the co-op profile
check(classic.enter() and player.name == "fresh", "enter again")
fakeClassicButton()
check(player.gameType == 1 and player.totalMNB2Game == 2 and player.mnb2Rank == 2, "co-op Classic continues where it was")
-- menus in the middle of Classic (mode select, battle) do not hand the real profile back
classic.update()
check(classic.active, "stays open on the Classic pages")
player.gameState = 0
menuPage = 140
classic.update()
check(classic.active, "stays open during a battle")
player.gameState = 1
menuPage = 1 -- the game's Back from the mode select
classic.update()
check(not classic.active and player.name == "real", "main menu: real profile back")
check(menuPage == 140, "the game's Back from co-op Classic lands on the Multiplayer lobby, not the main menu")
check(fs.read("saveMNB2.lua") == real2, "real Classic save untouched")

-- Back from the Multiplayer lobby / opening the co-op campaign while it is open
menuPage = 140
check(classic.enter() and classic.active, "enter 3")
classic.exit()
check(not classic.active and player == realPlayer, "exit by hand")
classic.exit() -- twice is harmless
check(player == realPlayer, "second exit does nothing")
classic.enter()
check(campaign.enter() and campaign.active and not classic.active and player.name == "fresh", "opening the co-op campaign closes Classic first")
check(player.mnb2Rank == 2 and player.totalMNB2Game == 2, "one co-op career: the co-op campaign profile has the co-op Classic rank")
check(select(1, classic.enter()) == false and not classic.active, "no co-op Classic while the campaign is open")
campaign.exit()
check(player == realPlayer, "campaign exit gives the real profile back")
check(fs.read("saveMNB3.lua") == real3, "real campaign save untouched")

-- quitting in co-op Classic: the game saves (redirected), then the real profile is back and saved
menuPage = 140
classic.enter()
fakeClassicButton()
player.totalMNB2Game = 9
fs.write("saveMNB2.lua", ser(player)) -- what love.quit does
campaign.onQuitAfterGameSaved()
check(not classic.active and player.name == "real", "quit restores the real profile")
check(fs.load("saveMNB3.lua")().name == "real" and fs.read("saveMNB2.lua") == real2, "real saves as before after quit")
classic.active = true
check(fs.load("saveMNB2.lua")().totalMNB2Game == 9, "co-op Classic progress saved on quit")
classic.active = false

-- a teammate watching the host's battle never reaches the files: no exit while viewing
classic.enter()
mnbCoop.battle = { viewing = true }
menuPage = 1
classic.update()
check(classic.active, "no hand-back while watching a battle")
mnbCoop.battle = nil
classic.exit()

print(("%d passed, %d failed"):format(passes, fails))
love.event.quit(fails == 0 and 0 or 1)
