-- Renders the co-op page and registers its buttons once, with stand-ins for the game's fonts and pictures.
local MOD = os.getenv("COOP_DIR")
local VANILLA = os.getenv("MNB_VANILLA_DIR") or (MOD .. "/../../vanilla-src")
for _, n in ipairs({ "coop_codec", "coop_profile", "coop_mods", "coop_net", "coop_campaign", "coop_lobby" }) do
  package.preload["includes/mods/mnb_coop/" .. n] = function() return assert(loadfile(MOD .. "/" .. n .. ".lua"))() end
end
package.preload["includes/ser"] = function() return assert(loadfile(VANILLA .. "/includes/ser.lua"))() end
local fails, passes = 0, 0
local function check(c, w) if c then passes = passes + 1 else fails = fails + 1 print("FAIL: " .. w) end end
love.filesystem.remove("coop/campaign/saveMNB3.lua")

randNbr = function(n) return love.math.random(1, n) end
local nid = 0
createAlliedSoldier = function(d) nid = nid + 1 d.id = nid d.name = "Pvt " .. nid d.faction = "allied" d.playerControlled = 1 d.npc = 0
  d.dead = 0 d.health = 100 d.xp = nid * 3 d.level = 1 d.eyes, d.nose, d.mouth, d.hair = 1, 1, 1, 1 end
assignNextPerk = function() end
newProfile = function() local p = player p.dayz = 4 p.deployedTroops = {} for i = 1, 6 do p.deployedTroops[i] = {} createAlliedSoldier(p.deployedTroops[i]) end end
updateProfile = function() end
currentVersion = "x"
player = { name = "real" }
local font = love.graphics.newFont(14)
bigFont, cardFont, nonoFont = font, font, font
local img = love.graphics.newImage(love.image.newImageData(8, 8))
profileIcon1, squadIcon1, campaingIcon1, classicIcon1, optionsIcon1, faceBase = img, img, img, img, img, img
for _, part in ipairs({ "eyes", "nose", "mouth", "hair" }) do _G["face_" .. part .. "1"] = img end
buttons = {}
Button = { new = function(x, y, w, h, label) return { X = x, Y = y, width = w, height = h, label = label } end }
local careerOpened = false
menu_careerButton = function() careerOpened = true menuPage = 2 end
menu_squadButton = function() menuPage = 3 end
menu_campaignButton = function() menuPage = 6 end

local campaign = require("includes/mods/mnb_coop/coop_campaign")
local lobby = require("includes/mods/mnb_coop/coop_lobby")
mnbCoop = { lobby = lobby, campaign = campaign }
menuPage = lobby.getPage()
coopCampaignButton()
check(campaign.active and menuPage == lobby.getHubPage(), "CO-OP CAMPAIGN opens the co-op page")
lobby.registerButtons()
local labels = {}
for _, b in ipairs(buttons) do labels[b.label] = true end
check(labels.coopHubCareer and labels.coopHubSquad and labels.coopHubCampaign and labels.coopHubBack, "co-op page buttons")
local ok, err = pcall(lobby.draw)
check(ok, "co-op page draws: " .. tostring(err))
coopHubCareerButton()
check(careerOpened and menuPage == 2, "Career opens the game's career screen")
menuPage = 1 -- the game's Back from career goes to the main menu
campaign.update()
check(menuPage == lobby.getHubPage(), "back from a co-op screen lands on the co-op page, not the main menu")
coopHubBackButton()
check(menuPage == lobby.getPage() and campaign.active, "Back goes to the Multiplayer screen, co-op still open")
coopBackButton()
check(menuPage == 1 and not campaign.active, "Back from Multiplayer leaves co-op for the main menu")

-- Career and Squad straight from the lobby, in the same spot as on the co-op page
menuPage = lobby.getPage()
buttons = {}
lobby.registerButtons()
local at = {}
for _, b in ipairs(buttons) do at[b.label] = b end
check(at.coopCareer and at.coopSquad and at.coopHost and at.coopJoin, "lobby has Career, Squad, Host and Join")
check(at.coopCareer and at.coopCareer.X == 50 and at.coopCareer.Y == 185 and at.coopSquad.Y == 430, "Career and Squad where the co-op page has them")
ok, err = pcall(lobby.draw)
check(ok, "lobby draws: " .. tostring(err))
careerOpened = false
coopCareerButton()
check(careerOpened and campaign.active and menuPage == 2, "lobby Career opens the co-op career")
menuPage = 1
campaign.update()
check(menuPage == lobby.getPage(), "back from a Career opened in the lobby lands on the lobby")
coopSquadButton()
check(menuPage == 3, "lobby Squad opens the squad screen")
coopBackButton()
check(menuPage == 1 and not campaign.active, "Back from the lobby still leaves co-op")

-- the ready room (READY is asked once the host picks a mode)
local net = require("includes/mods/mnb_coop/coop_net")
net.role, net.mySeat = "host", 1
net.seats = { { name = "Host" }, { name = "Bob", ready = false } }
menuPage = 77 -- the host's mode select
local started = 0
local function start() started = started + 1 end
check(not lobby.gate("CO-OP CLASSIC", start) and menuPage == lobby.getRoomPage() and net.stage == "CO-OP CLASSIC", "a teammate not ready: the ready room opens")
buttons = {}
lobby.registerButtons()
at = {}
for _, b in ipairs(buttons) do at[b.label] = b end
check(at.coopRoomStart and at.coopRoomCancel and not at.coopRoomReady, "host: START and Cancel")
ok, err = pcall(lobby.draw)
check(ok, "ready room draws (host): " .. tostring(err))
coopRoomStartButton()
check(started == 0 and menuPage == lobby.getRoomPage(), "START waits for Bob")
net.seats[2].ready = true
coopRoomStartButton()
check(started == 1 and menuPage == 77 and net.stage == nil and lobby.room == nil, "everyone ready: START replays the start from the page it came from")
check(lobby.gate("CO-OP CLASSIC", start), "everyone ready already: no ready room")
net.seats[2].ready = false
lobby.gate("CO-OP CAMPAIGN", start)
coopRoomCancelButton()
check(started == 1 and menuPage == 77 and net.stage == nil, "Cancel goes back without starting")
-- a teammate follows the host's stage
net.role, net.mySeat = "client", 2
net.stage = "CO-OP CLASSIC"
menuPage = lobby.getPage()
lobby.updateRoom()
check(menuPage == lobby.getRoomPage(), "a teammate is pulled into the ready room")
buttons = {}
lobby.registerButtons()
at = {}
for _, b in ipairs(buttons) do at[b.label] = b end
check(at.coopRoomReady and not at.coopRoomStart, "teammate: READY, no START")
ok, err = pcall(lobby.draw)
check(ok, "ready room draws (teammate): " .. tostring(err))
net.stage = nil
lobby.updateRoom()
check(menuPage == lobby.getPage(), "the room closes: the teammate is back in the lobby")
net.role, net.mySeat, net.seats = "offline", nil, {}
print(("%d passed, %d failed"):format(passes, fails))
love.event.quit(fails == 0 and 0 or 1)
