-- Headless test of coop_squad.lua: ownership, host rules, teammates' orders (moves, loot, right click,
-- promotions, skills, prompts, H/Alt, HUD buttons, face swaps), client input, Classic dealing.
local MOD = os.getenv("COOP_DIR")
for _, n in ipairs({ "coop_codec", "coop_profile", "coop_mods", "coop_net", "coop_wallet", "coop_squad" }) do
  package.preload["includes/mods/mnb_coop/" .. n] = function() return assert(loadfile(MOD .. "/" .. n .. ".lua"))() end
end
local fails, passes = 0, 0
local function check(c, w) if c then passes = passes + 1 else fails = fails + 1 print("FAIL: " .. w) end end

currentVersion = "x"
modLibrary = { option = function() return nil end }
local net = require("includes/mods/mnb_coop/coop_net")
local squad = require("includes/mods/mnb_coop/coop_squad")
mnbCoop = { campaign = { active = true }, battle = { viewing = false }, squad = squad }

local function soldier(id, seat, x)
  return { id = id, coopSquad = 1, coopSeat = seat, faction = "allied", playerControlled = 1, dead = 0, health = 100,
           retreating = 0, onFire = 0, x = x, y = 100, targetx = x, targety = 100 }
end
local function build()
  player = { gameState = 0, gameType = 0, screenx = 1000, screeny = 0, deployedTroops = {
    soldier(1, 1, 10), soldier(2, 1, 20), soldier(3, 2, 30), soldier(4, 2, 40), soldier(5, 3, 50), soldier(6, 3, 60),
    { id = 7, faction = "axis", playerControlled = 0, dead = 0, health = 100, x = 500, y = 100 } }, deployedVehicles = {} }
end
build()
function convertedId(id) for i, t in ipairs(player.deployedTroops) do if t.id == id then return i end end return -1 end
pause = 0
buttons = { "hostButtons" } mousePrompt = 5 mousePromptLock = 0 iconOn = 0 altMove = 0 selectionX = 7 selectionY = 8
selecting = true mouseOverIconId = 0 mouseDropIconId = 0 dragingIcon = 0 buttoned = 0

-- a stand-in for the game's release handler: moves selected troops like the game does
local seenGlobals
local function fakeRelease(x, y, button)
  seenGlobals = { buttons = buttons, mousePrompt = mousePrompt, selX = selectionX, selY = selectionY }
  for _, t in ipairs(player.deployedTroops) do
    if t.selected then t.targetx, t.targety = x + player.screenx, y + player.screeny t.selected = false end
  end
  mouseOverIconId = 0
end
squad.setGameRelease(fakeRelease)

net.role, net.mySeat = "host", 1
net.seats = { { name = "Host" }, { name = "Ann" }, { name = "Bob" } }
check(squad.active(), "active in co-op campaign with 3 players")

-- host rules: shortcuts follow the host's own soldiers, foreign selections dropped
for _, t in ipairs(player.deployedTroops) do t.selected = true end
squad.hostAfterButtonEngine()
local T = player.deployedTroops
check(T[1].shortcut == 1 and T[2].shortcut == 2 and T[3].shortcut == 0 and T[5].shortcut == 0, "host keys 1,2 = host's soldiers")
check(T[1].selected and not T[3].selected and not T[6].selected, "host can't keep teammates' soldiers selected")
-- Bob leaves: his soldiers become the host's
net.seats[3] = nil
squad.hostAfterButtonEngine()
check(T[5].shortcut == 3 and T[6].shortcut == 4, "a missing player's soldiers go to the host (keys 3,4)")
net.seats[3] = { name = "Bob" }
squad.hostAfterButtonEngine()

-- drag: host may not drop onto Ann's face
mouseOverIconId, mouseDropIconId = 1, 3
squad.hostBeforeRelease(2)
check(mouseDropIconId == 0, "drop onto a teammate's face refused")
mouseOverIconId, mouseDropIconId = 1, 2
squad.hostBeforeRelease(2)
check(mouseDropIconId == 2, "drop inside own group allowed")
mouseOverIconId, mouseDropIconId = 0, 0

-- Ann's order: her two soldiers, plus one of the host's and an enemy she tries to sneak in
for _, t in ipairs(T) do t.selected = false end
T[1].selected = true -- the host has his own selection going
check(squad.onClientMessage(2, { t = "move", ids = { 3, 4, 1, 7 }, x = 1500, y = 300 }), "move understood")
check(squad.onClientMessage(2, { t = "fly" }) == false, "unknown order not understood (guard strikes it)")
squad.hostRunOrders()
check(T[3].targetx == 1500 and T[4].targetx == 1500 and T[3].targety == 300, "Ann's soldiers move to her point")
check(T[1].targetx == 10 and T[2].targetx == 20 and T[7].targetx == nil, "host's soldiers and the enemy don't move")
check(T[1].selected == true, "host's own selection survives a teammate's order")
check(seenGlobals and #seenGlobals.buttons == 0 and seenGlobals.mousePrompt == 0, "replay runs with no HUD buttons or prompts")
check(seenGlobals.selX == 500 and seenGlobals.selY == 300, "replay clicks at the right screen point")
check(buttons[1] == "hostButtons" and mousePrompt == 5 and selectionX == 7 and selecting == true, "host's globals restored")
-- paused: orders dropped
pause = 1
squad.onClientMessage(2, { t = "move", ids = { 3 }, x = 1, y = 1 })
squad.hostRunOrders()
check(T[3].targetx == 1500, "no orders while the host has paused")
pause = 0
-- garbage
check(squad.onClientMessage(2, { t = "move", ids = "x", x = "a" }) == true, "bad move swallowed without error")
squad.hostRunOrders()

-- ---- client side (watching, seat 2)
local sent = {}
net.sendToHost = function(msg) sent[#sent + 1] = msg end
mnbCoop.battle.viewing = true
net.role, net.mySeat = "client", 2
mousePrompt = 0 -- the teammate's own machine: nothing armed
for _, t in ipairs(T) do t.selected = nil end
squad.clientKeypressed("1")
check(T[3].selected and not T[4].selected and not T[1].selected, "client key 1 = Ann's first soldier")
squad.clientKeypressed("2")
check(T[4].selected and not T[3].selected, "client key 2 = Ann's second")
squad.clientKeypressed("7")
check(T[3].selected and T[4].selected and not T[1].selected and not T[5].selected, "client key 7 = all of Ann's")
squad.clientKeypressed("3")
check(not T[3].selected and not T[4].selected, "client key 3: Ann has no third soldier")
-- box over everyone selects only hers
squad.clientMousepressed(0, 0, 1)
squad.clientMousereleased(-900, 200, 1) -- screen box covering world x 100..1000? (screenx 1000 -> 100..1000) none
squad.clientMousepressed(-1000, 0, 1)
squad.clientMousereleased(-900, 200, 1) -- world x 0..100, y 0..200: everyone
check(T[3].selected and T[4].selected and not T[1].selected and not T[5].selected, "box selects only your own")
-- click the ground: order sent with her ids, selection dropped
squad.clientMousepressed(500, 300, 1)
squad.clientMousereleased(500, 300, 1)
check(#sent == 1 and sent[1].t == "move" and #sent[1].ids == 2 and sent[1].x == 1500 and sent[1].y == 300, "move order sent in world coords")
check(not T[3].selected, "selection dropped after the order")
-- click one of hers
squad.clientMousepressed(-970, 100, 1)
squad.clientMousereleased(-970, 100, 1) -- world x 30
check(T[3].selected and #sent == 1, "click on own soldier selects, sends nothing")
-- click a host soldier: not selectable, counts as a ground click -> moves Ann's selected
squad.clientMousepressed(-990, 100, 1)
squad.clientMousereleased(-990, 100, 1)
check(#sent == 2 and sent[2].ids[1] == 3, "clicking someone else's soldier doesn't select him")

-- hover card: mouseOverId follows the mouse like the game's troop buttons
player.screenx, player.screeny = 1000, 0
for _, t in ipairs(T) do t.deadTimer = 0 end
love.mouse.getPosition = function() return 30 - 1000 + 5, 100 - 4 end -- near soldier 3 (world x 30)
squad.clientHover()
check(mouseOverId == 3, "hovering a soldier shows his card (id " .. tostring(mouseOverId) .. ")")
love.mouse.getPosition = function() return 500 - 1000, 100 end -- the enemy at x 500
squad.clientHover()
check(mouseOverId == -99, "no card for enemies")
love.mouse.getPosition = function() return 0, 400 end
squad.clientHover()
check(mouseOverId == -99, "no card over empty ground")

-- vehicle card and loot tooltip
player.deployedVehicles = { { id = 77, faction = "allied", x = 300, y = 300 } }
player.lootables = { { name = "loot_beer", flagged = 1, x = 600, y = 300 } }
lootText_beer = "Beer!"
love.mouse.getPosition = function() return 300 + 20 - 1000, 300 + 20 end
squad.clientHover()
check(mouseOverId2 == 77 and mouseOverId == -99, "hovering a vehicle shows its card")
love.mouse.getPosition = function() return 600 - 1000, 300 end
squad.clientHover()
check(mouseOverText == "Beer!" and mouseOverId2 == -99, "hovering loot shows what it is")
-- a tip bubble: its text shows on hover, even with its click area in the HUD list
tipCueText = { [14] = "Tip fourteen" }
function displayContextualTip(n) contextualText = tipCueText[n] end
player.tipCue = { { msg = 14, x = 800, y = 300, alpha = 255, fading = 0 } }
squad.hudButtons = { { X = 775, Y = 275, width = 30, height = 30, label = "tipCuez", mouseOverText = "" } }
love.mouse.getPosition = function() return 790 - 1000, 290 end
squad.clientHover()
check(contextualText == "Tip fourteen", "hovering a tip shows its text (" .. tostring(contextualText) .. ")")
squad.hudButtons, player.tipCue = {}, {}
-- the mission report: names and new awards show their text on hover
local savedTroops, savedState = player.deployedTroops, player.gameState
player.deployedTroops = {}
for i = 1, 6 do player.deployedTroops[i] = { name = "Pvt " .. i, awards = {} } end
player.deployedTroops[4].awards = { { name = "Purple Heart", icon = 3, called = 1 }, { name = "Bronze Star", icon = 7, called = 0 } }
awardDesc7 = "for valour"
player.gameState, menuPage = 1, 4
love.mouse.getPosition = function() return 930 + 10 + 5, 245 + 20 end -- slot 4's first new award
squad.clientHover()
check(mouseOverText == "Bronze Star, for valour", "report: hovering a medal shows it (" .. tostring(mouseOverText) .. ")")
love.mouse.getPosition = function() return 667 + 5, 321 + 5 end
squad.clientHover()
check(mouseOverText == "Pvt 2", "report: hovering a soldier shows his name")
player.deployedTroops, player.gameState, menuPage = savedTroops, savedState, 0
-- face bar name
showFaces = 1
love.mouse.getPosition = function() return 60 * 3 + 10, 680 end -- third face
squad.clientHover()
check(iconOn == 1 and iconPosition == 3, "hovering a face shows its name")
-- minimap click moves only this camera
player.endLine, player.landed = 9000, 1
local miniCalled = false
function miniMapButton() miniCalled = true end
local before = #sent
squad.clientMousepressed(640, 15, 1)
squad.clientMousereleased(640, 15, 1)
check(miniCalled and #sent == before, "minimap click moves the camera, sends no order")
showFaces = nil

-- ---- promotions, client side (Ann = seat 2, soldiers 3 and 4 at faces 3 and 4)
showFaces = 1
player.landed = 1
player.lootables = {}
player.deployedVehicles = {}
T[3].promo, T[3].spec = 1, ""
T[4].promo, T[4].spec, T[4].rank, T[4].skillUpgrade, T[4].weaponUpgrade, T[4].nextPerk = 1, "medic", 0, 0, 3, nil
T[1].promo, T[1].spec = 1, ""
specID, specDisplay, skillDisplay, abilityDisplay = -99, 0, 0, 0
before = #sent
squad.clientMousepressed(60 * 3 + 10, 680, 1)
squad.clientMousereleased(60 * 3 + 10, 680, 1)
check(specDisplay == 1 and specID == 3 and T[3].selected and #sent == before, "own face: spec panel opens, soldier selected, no move")
mouseOverLightSpec, mouseOverMedicSpec = "Light tip", "Medic tip"
local medic -- the medic button of that panel
for _, b in ipairs(squad.panelButtons()) do if b[1] == "specking_medic" then medic = b end end
check(medic and medic[2] == 3 * 60 - 3 + 25 - 1 - 15 and medic[3] == 482 - 15, "medic button where the game puts it")
love.mouse.getPosition = function() return medic[2] + 5, medic[3] + 5 end
squad.clientHover()
check(mouseOverText == "Medic tip", "hovering a spec button shows its tip")
squad.clientMousepressed(medic[2] + 5, medic[3] + 5, 1)
squad.clientMousereleased(medic[2] + 5, medic[3] + 5, 1)
check(#sent == before + 1 and sent[#sent].t == "promo" and sent[#sent].id == 3 and sent[#sent].label == "specking_medic",
  "spec choice sent to the host")
check(specDisplay == 0 and specID == -99, "panel closes after the choice")
-- a host soldier's face: nothing opens, nothing sent
before = #sent
squad.clientMousepressed(60 * 1 + 10, 680, 1)
squad.clientMousereleased(60 * 1 + 10, 680, 1)
check(specDisplay == 0 and skillDisplay == 0 and #sent == before and not T[1].selected, "someone else's face: nothing")
-- specialised soldier: the upgrade panel (no weapon, rank and skill buttons)
squad.clientMousepressed(60 * 4 + 10, 680, 1)
squad.clientMousereleased(60 * 4 + 10, 680, 1)
check(skillDisplay == 1 and specID == 4, "specialised: upgrade panel")
local labels = {}
for _, b in ipairs(squad.panelButtons()) do labels[b[1]] = b end
check(labels.promoSelect and labels.skillSelect and not labels.weaponSelect and not labels.perkSelect, "upgrade panel buttons follow the soldier")
squad.clientMousepressed(4 * 60 + 5, 415, 1)
squad.clientMousereleased(4 * 60 + 5, 415, 1)
check(sent[#sent].label == "promoSelect" and sent[#sent].id == 4, "rank choice sent")
-- the panel closes by itself once the host has spent the promotion
squad.clientMousepressed(60 * 4 + 10, 680, 1)
squad.clientMousereleased(60 * 4 + 10, 680, 1)
T[4].promo = 0
squad.clientHover()
check(skillDisplay == 0, "panel closes when the promotion is gone")
T[4].promo = 1

-- ---- promotions, host side
mnbCoop.battle.viewing = false
net.role, net.mySeat = "host", 1
local specced = {}
function specClick(s) specced[#specced + 1] = { id = specID, spec = s } specDisplay = 0 specID = -99 end
local promoted = {}
function promoSelectButton() promoted[#promoted + 1] = specID skillDisplay = 0 specID = -99 end
specID, specDisplay = 1, 1 -- the host has his own panel open
squad.onClientMessage(2, { t = "promo", id = 3, label = "specking_medic" })
squad.onClientMessage(2, { t = "promo", id = 1, label = "specking_rifle" })  -- the host's soldier
squad.onClientMessage(2, { t = "promo", id = 4, label = "specking_rifle" })  -- already specialised
squad.onClientMessage(2, { t = "promo", id = 3, label = "specking_wizard" }) -- no such speciality
squad.onClientMessage(2, { t = "promo", id = 4, label = "promoSelect" })
squad.onClientMessage(2, { t = "promo", id = 4, label = "weaponSelect" })    -- weapon maxed
squad.onClientMessage(2, { t = "promo", id = 4, label = "evilSelect" })      -- not a panel button
squad.hostRunOrders()
check(#specced == 1 and specced[1].id == 3 and specced[1].spec == "medic", "teammate's spec choice runs the game's specClick for her soldier")
check(#promoted == 1 and promoted[1] == 4, "teammate's rank choice runs promoSelectButton")
check(specID == 1 and specDisplay == 1, "host's own panel left as it was")
-- host face clicks: own soldier opens, a teammate's soldier doesn't
local opened = {}
local wrapped = squad.wrapIconClick(function(id) opened[#opened + 1] = id end)
wrapped(1) wrapped(3)
check(#opened == 1 and opened[1] == 1, "host can't open a teammate's soldier's panel")

-- ---- loot: the teammate's click replays the game's loot buttons
Button = { new = function(x, y, w, h, label)
  local self = { X = x, Y = y, width = w, height = h, label = label, status = "active" }
  self.click = function(l)
    local mx, my = love.mouse.getPosition()
    if mx + player.screenx > self.X and mx + player.screenx < self.X + self.width and my + player.screeny > self.Y
      and my + player.screeny < self.Y + self.height then _G[l .. "Button"]() end
  end
  return self
end }
local looted = {}
function lootClickButton()
  for _, t in ipairs(player.deployedTroops) do if t.selected then looted[#looted + 1] = t.id end end
  buttoned = 1
end
squad.setGameRelease(function(x, y, b)
  buttoned = 0
  for i = 1, #buttons do if buttons[i].status == "active" then buttons[i].click(buttons[i].label) end end
  if buttoned == 0 then fakeRelease(x, y, b) end
end)
player.lootables = { { name = "loot_beer", flagged = 1, x = 1200, y = 300 }, { name = "loot_ammo", flagged = 0, x = 1400, y = 300 } }
love.mouse.getPosition = function() return 3, 4 end -- the host's own mouse is elsewhere
T[3].targetx = 0
squad.onClientMessage(2, { t = "move", ids = { 3 }, x = 1205, y = 302 })
squad.hostRunOrders()
check(#looted == 1 and looted[1] == 3 and T[3].targetx == 0, "click on loot: the game's loot button runs with her soldier, no move")
check(love.mouse.getPosition() == 3, "host's mouse restored")
squad.onClientMessage(2, { t = "move", ids = { 3 }, x = 1400, y = 300 }) -- unflagged (not found yet): a plain move
squad.hostRunOrders()
check(#looted == 1 and T[3].targetx == 1400, "unfound loot is just ground")

-- ---- right click, armed prompts, skills, H, Alt (host side, Ann = seat 2)
player.lootables = {}
local toSeat = {}
net.sendTo = function(seat, msg) toSeat[#toSeat + 1] = { seat = seat, msg = msg } end
local fired, used = {}, {}
squad.setGameRelease(function(x, y, b)
  buttoned = 0
  if b == 1 then
    if mousePrompt > 0 and mousePromptLock == 0 then
      fired[#fired + 1] = { p = mousePrompt, who = mousePrompter, x = x + player.screenx }
      mousePrompt, buttoned = 0, 1
    end
    if buttoned == 0 then
      for _, t in ipairs(player.deployedTroops) do
        if t.selected then
          if altMove == 1 then t.altx, t.alty = x + player.screenx, y else t.targetx = x + player.screenx end
        end
      end
    end
  else
    for _, t in ipairs(player.deployedTroops) do
      if t.selected then
        used[#used + 1] = t.id
        if (t.medicBag or 0) > 0 then mousePrompt, mousePrompter, mousePromptLock = 80, t.id, 1 end
      end
    end
  end
  mousePromptLock = 0
end)
for _, t in ipairs(T) do t.selected = false end
mousePrompt, mousePrompter, mousePromptLock = 0, 0, 0
T[3].medicBag = 1
squad.onClientMessage(2, { t = "move", b = 2, ids = { 3 }, x = 1100, y = 100 })
squad.hostRunOrders()
check(#used == 1 and used[1] == 3, "right click: her selected soldier uses his item")
check(mousePrompt == 0, "host's own prompt untouched by her medic bag")
check(#toSeat == 1 and toSeat[1].seat == 2 and toSeat[1].msg.p == 80 and toSeat[1].msg.who == 3, "she's told her medic bag is armed")
squad.onClientMessage(2, { t = "move", ids = {}, x = 1300, y = 100 })
squad.hostRunOrders()
check(#fired == 1 and fired[1].p == 80 and fired[1].who == 3 and fired[1].x == 1300, "her next left click fires it, no selection needed")
check(toSeat[#toSeat].msg.p == 0, "she's told it's used")
squad.onClientMessage(2, { t = "move", ids = {}, x = 1300, y = 100 })
squad.hostRunOrders()
check(#fired == 1, "used once only")
-- skills
local skilled = {}
function skillClick(n)
  if n == 2 then mousePrompt, mousePrompter, mousePromptLock = 2, specID, 1
  else skilled[#skilled + 1] = { id = specID, n = n } end
end
T[4].skillUpgrade, T[4].spec = 2, "medic"
T[1].skillUpgrade = 3
specID = 1
squad.onClientMessage(2, { t = "skill", id = 4, n = 1 })
squad.onClientMessage(2, { t = "skill", id = 4, n = 3 }) -- not learnt
squad.onClientMessage(2, { t = "skill", id = 1, n = 1 }) -- the host's soldier
squad.onClientMessage(2, { t = "skill", id = 4, n = 9 }) -- junk
squad.hostRunOrders()
check(#skilled == 1 and skilled[1].id == 4 and skilled[1].n == 1, "her instant skill runs for her soldier only")
check(specID == 1, "host's specID restored")
squad.onClientMessage(2, { t = "skill", id = 4, n = 2 })
squad.hostRunOrders()
check(toSeat[#toSeat].msg.p == 2 and toSeat[#toSeat].msg.who == 4 and mousePrompt == 0, "aimed skill armed for her, not the host")
squad.onClientMessage(2, { t = "cancel" })
squad.hostRunOrders()
check(toSeat[#toSeat].msg.p == 0, "Backspace cancels her armed skill")
squad.onClientMessage(2, { t = "move", ids = {}, x = 1300, y = 100 })
squad.hostRunOrders()
check(#fired == 1, "cancelled skill doesn't fire")
-- H and Alt
local function gameKeys(key)
  if key == "h" then
    for _, t in ipairs(player.deployedTroops) do
      if t.faction == "allied" and t.playerControlled == 1 then t.targetx = t.x end
    end
  end
end
local function gameKeyUp(key)
  altMove = 0
  for _, t in ipairs(player.deployedTroops) do
    if (t.altx or 0) ~= 0 and t.faction == "allied" then t.targetx, t.altx, t.alty = t.altx, 0, 0 end
  end
end
squad.setGameKeys(gameKeys, gameKeyUp)
for _, t in ipairs(T) do t.targetx = 5000 end
squad.onClientMessage(2, { t = "halt" })
squad.hostRunOrders()
check(T[3].targetx == T[3].x and T[4].targetx == T[4].x and T[1].targetx == 5000 and T[5].targetx == 5000, "her H halts only her soldiers")
check(T[1].playerControlled == 1 and T[5].playerControlled == 1, "everyone player-controlled again after")
squad.withOnly(1, gameKeys, "h")
check(T[1].targetx == T[1].x and T[2].targetx == T[2].x and T[5].targetx == 5000, "host's H halts only the host's")
for _, t in ipairs(T) do t.targetx, t.altx = 5000, 0 end
squad.onClientMessage(2, { t = "move", ids = { 3 }, x = 2000, y = 100, alt = true })
squad.hostRunOrders()
check(T[3].altx == 2000 and T[3].targetx == 5000, "Alt click: a waypoint, not a move")
T[1].altx, T[1].alty = 3000, 100 -- the host's own waypoint
altMove = 1 -- the host is holding Alt
squad.onClientMessage(2, { t = "altgo" })
squad.hostRunOrders()
check(T[3].targetx == 2000 and T[1].targetx == 5000 and T[1].altx == 3000, "her Alt release sends hers only")
check(altMove == 1, "host's own Alt state kept")
squad.withOwnWaypoints(1, gameKeyUp, "lalt")
check(T[1].targetx == 3000, "host's Alt release sends the host's")

-- ---- client side of all that (Ann watching)
mnbCoop.battle.viewing = true
net.role, net.mySeat = "client", 2
sent = {}
for _, t in ipairs(T) do t.selected = nil end
T[3].selected = true
squad.clientMousereleased(700, 300, 2)
check(sent[1] and sent[1].t == "move" and sent[1].b == 2 and sent[1].ids[1] == 3 and sent[1].x == 1700, "right click sent with her selection")
squad.onPrompt({ p = 80, who = 3 })
check(mousePrompt == 80 and mousePrompter == 3, "armed prompt shown on her mirror (aiming cursor)")
squad.clientMousepressed(-970, 100, 1)
squad.clientMousereleased(-970, 100, 1) -- right on her own soldier 3 (world x 30)
check(#sent == 2 and sent[2].t == "move" and sent[2].x == 30, "with a prompt armed, a click on a soldier is a target, not a selection")
squad.clientKeypressed("backspace")
check(sent[3] and sent[3].t == "cancel" and mousePrompt == 0, "Backspace cancels")
squad.clientKeypressed("h")
check(sent[4] and sent[4].t == "halt", "H sent")
check(squad.clientKeyreleased("lalt") and sent[5].t == "altgo", "Alt release sent")
-- skills panel
T[4].promo = 0
specID, specDisplay, skillDisplay, abilityDisplay = -99, 0, 0, 0
squad.clientMousepressed(60 * 4 + 10, 680, 1)
squad.clientMousereleased(60 * 4 + 10, 680, 1)
check(abilityDisplay == 1 and specID == 4, "own face with skills: skill panel")
local sk = {}
for _, b in ipairs(squad.panelButtons()) do sk[b[1]] = b end
check(sk.skill_1 and sk.skill_2 and not sk.skill_3, "skill buttons follow what he has learnt")
squad.clientMousepressed(sk.skill_2[2] + 5, sk.skill_2[3] + 5, 1)
squad.clientMousereleased(sk.skill_2[2] + 5, sk.skill_2[3] + 5, 1)
check(sent[#sent].t == "skill" and sent[#sent].id == 4 and sent[#sent].n == 2 and abilityDisplay == 0, "skill sent, panel closed")

-- ---- face drag (client): only between her own faces
before = #sent
squad.clientMousepressed(60 * 3 + 10, 680, 2)
squad.clientMousereleased(60 * 4 + 10, 680, 2)
check(#sent == before + 1 and sent[#sent].t == "swap" and sent[#sent].a == 3 and sent[#sent].b == 4, "drag her face onto her other face: swap sent")
squad.clientMousepressed(60 * 3 + 10, 680, 2)
squad.clientMousereleased(60 * 1 + 10, 680, 2)
check(#sent == before + 1, "drop onto the host's face: nothing sent")
squad.clientMousepressed(60 * 1 + 10, 680, 2)
squad.clientMousereleased(60 * 3 + 10, 680, 2)
check(#sent == before + 1, "dragging someone else's face does nothing")

-- ---- HUD buttons (client)
function mnb2ReinfButton() mnb2MenuDisplay = 1 end
function mnb2CallRiflezButton() end
function mnb2SmokeButton() end
mnb2MenuDisplay = 0
local hudFake = function()
  buttons = { Button.new(1160 + player.screenx - 23, 690 + player.screeny - 23, 40, 40, "mnb2Reinf"),
              Button.new(1110 + player.screenx - 23, 690 + player.screeny - 23, 40, 40, "mnb2CallRiflez"),
              Button.new(player.screenx, 0, 10, 10, "troop_3") }
  buttons[1].mouseOverText, buttons[2].mouseOverText = "Reinforcements", "Riflemen"
  -- buttons of a menu page show only on that page, like the game's
  if mnb2MenuDisplay == 3 then buttons[#buttons + 1] = Button.new(0, 0, 40, 40, "mnb2Smoke") end
  if mnb2MenuDisplay == 5 then buttons[#buttons + 1] = Button.new(0, 0, 40, 40, "mnb2GearscopedGarand") end
end
squad.setGameButtonEngine(hudFake)
soundCpt, butCpt = 0.05, 0
squad.clientHud()
check(#squad.hudButtons == 2 and soundCpt == 0.05, "HUD pass keeps the HUD buttons, game timers restored")
before = #sent
squad.clientMousepressed(1160, 690, 1)
squad.clientMousereleased(1160, 690, 1)
check(mnb2MenuDisplay == 1 and #sent == before, "a menu page opens in her own window, nothing sent")
for _, t in ipairs(T) do t.selected = nil end
T[3].selected = true
squad.clientMousepressed(1110, 690, 1)
squad.clientMousereleased(1110, 690, 1)
local h = sent[#sent]
check(h.t == "hud" and h.label == "mnb2CallRiflez" and h.menu == 1 and h.cx == player.screenx and h.ids[1] == 3 and h.x == 1110,
  "a real button goes to the host with her camera, menu page and selection")
squad.onUi({ m = 0 })
check(mnb2MenuDisplay == 0, "host's answer sets her menu page")

-- ---- HUD buttons (host)
mnbCoop.battle.viewing = false
net.role, net.mySeat = "host", 1
check(squad.hudLabelOk("mnb2CallRiflez") and squad.hudLabelOk("playerSkill_2"), "known HUD buttons allowed")
check(not squad.hudLabelOk("mnb2Reinf") and not squad.hudLabelOk("pause_option") and not squad.hudLabelOk("mnb2Nope")
  and not squad.hudLabelOk("playerSkill_x"), "menu pages, pause buttons and unknown names refused")
function mnb2RetreatButton() end
function trenchRetreatzButton() end
check(not squad.hudLabelOk("mnb2Retreat") and not squad.hudLabelOk("trenchRetreatz"), "battle-ending buttons are the host's call")
-- a teammate's move doesn't close the host's own promotion panel
specID, specDisplay = 1, 1
squad.setGameRelease(function() specDisplay, skillDisplay, abilityDisplay = 0, 0, 0 end)
squad.onClientMessage(2, { t = "move", ids = { 3 }, x = 1500, y = 300 })
squad.hostRunOrders()
check(specDisplay == 1 and specID == 1, "host's open panel survives a teammate's move")
specID, specDisplay = -99, 0
player.tp = 10
local seenCam, seenMouse, seenSel
function mnb2CallRiflezButton()
  seenCam, seenMouse = player.screenx, love.mouse.getX()
  seenSel = T[3].selected
  player.tp = player.tp - 2
  local n = #player.deployedTroops + 1
  player.deployedTroops[n] = { id = 90 + n, faction = "allied", playerControlled = 1, dead = 0, health = 100,
    retreating = 0, onFire = 0, x = 0, y = 0 }
  mnb2MenuDisplay = 0
end
function mnb2SmokeButton() mousePrompt, mousePrompter, mousePromptLock = 28, 3, 1 end
player.screenx = 1000
mnb2MenuDisplay = 5 -- the host's own menu page
toSeat = {}
squad.onClientMessage(2, { t = "hud", label = "mnb2CallRiflez", x = 1110, y = 690, cx = 4000, cy = 0, ids = { 3 }, menu = 1 })
squad.hostRunOrders()
local recruit = player.deployedTroops[#player.deployedTroops]
check(seenCam == 4000 and seenMouse == 1110 and seenSel == true, "button ran with her camera, mouse point and selection")
check(player.screenx == 1000 and mnb2MenuDisplay == 5, "host's camera and menu page restored")
check(player.tp == 8, "TP is the shared pool")
check(recruit.coopOwner == 2 and squad.ownerOf(recruit) == 2, "her reinforcement is hers")
check(toSeat[#toSeat].msg.t == "ui" and toSeat[#toSeat].msg.m == 0, "she's told her menu closed")
squad.onClientMessage(2, { t = "hud", label = "mnb2Smoke", x = 1, y = 1, cx = 0, cy = 0, ids = {}, menu = 3 })
squad.hostRunOrders()
local pm
for _, m in ipairs(toSeat) do if m.msg.t == "prompt" then pm = m.msg end end
check(pm and pm.p == 28 and mousePrompt ~= 28, "a radio strike arms her prompt, not the host's")
-- a button that isn't on her screen (wrong menu page: a crafted message) is refused
squad.onClientMessage(2, { t = "cancel" })
squad.hostRunOrders()
toSeat = {}
squad.onClientMessage(2, { t = "hud", label = "mnb2Smoke", x = 1, y = 1, cx = 0, cy = 0, ids = {}, menu = 0 })
squad.hostRunOrders()
pm = nil
for _, m in ipairs(toSeat) do if m.msg.t == "prompt" and m.msg.p == 28 then pm = m.msg end end
check(pm == nil, "a button not on her screen is refused")
check(squad.coord("inf") == 20000 and squad.coord(0 / 0) == nil and squad.coord(1e30) == 20000 and squad.coord(512) == 512,
  "coordinates from teammates: finite and on the map")
squad.onClientMessage(2, { t = "cancel" })
squad.hostRunOrders()
table.remove(player.deployedTroops) -- the recruit leaves the test

-- a bought gun: the Gear button arms "Select a soldier" with no soldier behind it
-- (mnb2.lua:1868), then her click on a soldier fires it through his troop button
function mnb2GearscopedGarandButton() mousePrompt, mousePromptLock, mnb2MenuDisplay = 57, 1, 0 end
local armedGun, gunFor
-- (the stub Button calls label.."Button"; the game's troopClick fires for the first soldier
-- under the click and clears the prompt, so a neighbour 10 px away gets nothing)
for id = 1, 7 do
  _G["troop_" .. id .. "Button"] = function()
    if mousePrompt == 57 and not gunFor then armedGun, gunFor = mousePrompt, id mousePrompt = 0 end
  end
end
check(squad.hudLabelOk("mnb2GearscopedGarand"), "Gear buttons allowed")
toSeat, mousePrompter = {}, 0
squad.onClientMessage(2, { t = "hud", label = "mnb2GearscopedGarand", x = 560, y = 690, cx = 1000, cy = 0, ids = {}, menu = 5 })
squad.hostRunOrders()
pm = nil
for _, m in ipairs(toSeat) do if m.msg.t == "prompt" then pm = m.msg end end
check(pm and pm.p == 57, "the gun's prompt stays armed for her (no soldier behind it)")
local gameRelease0 = function(x, y, b)
  for _, bt in ipairs(buttons) do if bt.click then bt.click(bt.label) end end
end
squad.setGameRelease(gameRelease0)
local target = player.deployedTroops[convertedId(4)]
squad.onClientMessage(2, { t = "move", ids = {}, x = target.x, y = target.y })
squad.hostRunOrders()
check(armedGun == 57 and (gunFor == 3 or gunFor == 4), "her click on a soldier hands him the gun (troop button)")
squad.setGameRelease(fakeRelease)
-- tips on the map: a teammate may click one away
-- tips on the map: each window has its own, so a teammate's click fades theirs, not the host's
check(squad.isHudLabel("tipCuez") and squad.HUD_LOCAL.tipCuez and not squad.hudLabelOk("tipCuez"),
  "a tip click is the teammate's own (not sent to the host)")

-- ---- face swap (host)
local a3, a4 = T[3], T[4]
squad.onClientMessage(2, { t = "swap", a = 3, b = 4 })
squad.hostRunOrders()
check(T[3] == a4 and T[4] == a3, "her faces swapped")
squad.onClientMessage(2, { t = "swap", a = 3, b = 1 })
squad.hostRunOrders()
check(T[1].id == 1 and T[3] == a4, "she can't swap with the host's soldier")
T[3], T[4] = a3, a4

-- ---- Classic: the starting soldiers are dealt out
mnbCoop.campaign.active = false
player = { gameState = 0, gameType = 1, screenx = 0, screeny = 0, deployedVehicles = {}, deployedTroops = {} }
for i = 1, 7 do
  player.deployedTroops[i] = { id = 100 + i, faction = "allied", playerControlled = 1, dead = 0, health = 100,
    retreating = 0, onFire = 0, x = i, y = 0, shortcut = 2 }
end
player.deployedTroops[8] = { id = 200, faction = "allied", playerControlled = 0, x = 0, y = 0 } -- an AI ally
check(squad.active(), "ownership on in a Classic battle with teammates")
squad.hostAfterButtonEngine()
local P = player.deployedTroops
check(P[1].coopOwner == 1 and P[2].coopOwner == 2 and P[3].coopOwner == 3 and P[4].coopOwner == 1 and P[7].coopOwner == 1,
  "dealt in turn, host first")
check(P[8].coopOwner == nil and squad.ownerOf(P[8]) == nil, "AI allies aren't dealt")
check(P[1].shortcut == 2 and P[2].shortcut == 0, "host keeps its Ctrl groups; teammates' soldiers off the host's keys")
P[9] = { id = 300, faction = "allied", playerControlled = 1, dead = 0, x = 0, y = 0 }
squad.hostAfterButtonEngine()
check(P[9].coopOwner == nil and squad.ownerOf(P[9]) == 1, "later arrivals aren't re-dealt (host's unless recruited)")

-- ---- wallets: each player's own TP in a Classic battle with teammates (coop_wallet.lua)
local wallet = require("includes/mods/mnb_coop/coop_wallet")
local clock = 100
love.timer = love.timer or {}
love.timer.getTime = function() return clock end
-- stand-ins for the game: giveTp (mnb2.lua:894) and a purchase button that costs `testCost`
function giveTp(n) tpMax = 20 player.tp = player.tp + n if player.tp > tpMax then player.tp = tpMax end end
local income = function(n) return wallet.giveTp(giveTp, n) end
testCost, testBoom = 2, false
function mnb2CallRiflezButton()
  player.tp = player.tp - testCost
  if testBoom then error("boom") end
end
squad.setGameButtonEngine(function() buttons = { Button.new(0, 0, 40, 40, "mnb2CallRiflez") } end)
local function buy(seat, cost)
  testCost = cost
  squad.onClientMessage(seat, { t = "hud", label = "mnb2CallRiflez", x = 1, y = 1, cx = 0, cy = 0, ids = {}, menu = 1 })
  squad.hostRunOrders()
end
net.sendTo = function(seat, msg) toSeat[#toSeat + 1] = { seat = seat, msg = msg } end
toSeat = {}
net.role, net.mySeat = "host", 1
net.seats = { { name = "Host" }, { name = "Ann" }, { name = "Bob" } }
mnbCoop.battle.viewing = false
player = { gameState = 0, gameType = 1, mnb2SubGame = 0, tp = 7, screenx = 0, screeny = 0, deployedVehicles = {},
  deployedTroops = { { id = 1, faction = "allied", playerControlled = 1, dead = 0, health = 100, x = 0, y = 0 } } }
check(wallet.active(), "wallets rule in a Classic battle with teammates")
wallet.hostUpdate()
check(wallet.get(1) == 7 and wallet.get(2) == 7 and wallet.get(3) == 7, "everyone starts the battle with the host's TP")
local told = {}
for _, m in ipairs(toSeat) do if m.msg.t == "wallet" then told[m.seat] = m.msg.v end end
check(told[2] == 7 and told[3] == 7 and told[1] == nil, "each teammate is told their wallet")
toSeat = {}
wallet.hostUpdate()
check(#toSeat == 0, "nothing re-sent while nothing changed")

-- income: the full amount into every wallet, not doubled, each capped
income(1)
check(wallet.get(1) == 8 and wallet.get(2) == 8 and wallet.get(3) == 8 and player.tp == 8, "income 1x to every wallet")
income(30)
check(wallet.get(1) == 20 and wallet.get(2) == 20 and wallet.get(3) == 20, "every wallet capped at tpMax (20)")
check(wallet.cap() == 20, "cap read from the game's tpMax")
rawset(_G, "tpMax", 22) -- a ribbon raised it: the next giveTp says so
function giveTp(n) tpMax = 22 player.tp = math.min(22, player.tp + n) end
income(1)
check(wallet.get(1) == 21 and wallet.get(2) == 21 and wallet.get(3) == 21, "the host's ribbons raise everyone's cap")
function giveTp(n) tpMax = 20 player.tp = player.tp + n if player.tp > tpMax then player.tp = tpMax end end
income(0) -- (the ribbon is gone again: the game clamps the host, and so does every wallet)
check(player.tp == 20 and wallet.get(2) == 20 and wallet.get(3) == 20, "a lower cap clamps every wallet at the next income")

-- a teammate's purchase spends only their wallet
buy(2, 2)
check(wallet.get(2) == 18 and wallet.get(1) == 20 and wallet.get(3) == 20 and player.tp == 20, "Ann's purchase spends only Ann's TP")
buy(3, 10)
check(wallet.get(3) == 10 and wallet.get(2) == 18 and player.tp == 20, "Bob's purchase spends only Bob's TP")
-- income while a teammate's order runs still reaches all three exactly once
wallet.with(2, function() income(1) end)
check(wallet.get(2) == 19 and wallet.get(3) == 11 and wallet.get(1) == 20 and player.tp == 20, "income inside a teammate's call: once each, host's TP safe")
-- an error inside the game's code: the host's wallet comes back
testBoom = true
buy(2, 4)
testBoom = false
check(player.tp == 20 and wallet.get(2) == 15, "an error in the game's button: swapped back, the spend stands")
local okw, errw = wallet.with(3, function() player.tp = 4 error("crash") end)
check(okw == false and tostring(errw):find("crash") and player.tp == 20 and wallet.get(3) == 4, "wallet.with swaps back after an error and reports it")
-- the host's own purchase is plain player.tp
check(select(1, wallet.with(1, function() player.tp = player.tp - 5 end)) and player.tp == 15 and wallet.get(2) == 15, "host's own spend touches only his wallet")
player.tp = 20
wallet.with(3, function() player.tp = 10 end)

-- giving TP
check(wallet.onClientMessage(2, { t = "givetp", n = 1000, to = 1 }) == true, "givetp understood (extra fields ignored)")
check(wallet.get(2) == 10 and wallet.get(3) == 15 and wallet.get(1) == 20, "Ann gives 5 to the next player (Bob), not what the message asked")
check(wallet.onClientMessage(2, { t = "fly" }) == false, "other messages aren't the wallet's")
wallet.onClientMessage(2, { t = "givetp" })
check(wallet.get(2) == 10 and wallet.get(3) == 15, "two gives within half a second: the second is ignored")
clock = clock + 1
check(wallet.keypressed("g") and wallet.get(1) == 15 and wallet.get(2) == 15, "the host's G gives 5 to the next player (Ann)")
check(not wallet.keypressed("x"), "other keys aren't wallet keys")
clock = clock + 1
wallet.onClientMessage(3, { t = "givetp" }) -- the last seat gives round to the host
check(wallet.get(3) == 10 and wallet.get(1) == 20, "the turn goes round: Bob gives to the host")
clock = clock + 1
wallet.with(2, function() player.tp = 3 end)
wallet.onClientMessage(2, { t = "givetp" })
check(wallet.get(2) == 0 and wallet.get(3) == 13, "a give is never more than the giver has")
clock = clock + 1
local before3 = wallet.get(3)
wallet.onClientMessage(2, { t = "givetp" })
check(wallet.get(2) == 0 and wallet.get(3) == before3, "nothing to give: nothing moves, never below 0")
local noted
for _, m in ipairs(toSeat) do if m.seat == 2 and m.msg.note and m.msg.note:find("no TP") then noted = true end end
check(noted, "the giver is told they have none")
clock = clock + 1
wallet.with(3, function() player.tp = 18 end)
wallet.with(2, function() player.tp = 9 end)
wallet.onClientMessage(2, { t = "givetp" })
check(wallet.get(3) == 20 and wallet.get(2) == 7, "the receiver is capped: only what fits moves")
check(wallet.onClientMessage(3, { t = "givetp" }) and wallet.onClientMessage(2, { t = "givetp" }) == true, "a give to a full wallet is a no-op, not an error")

-- a seat that leaves, a seat that joins later
wallet.forgetSeat(3)
net.seats[3] = nil
wallet.hostUpdate()
check(wallet.get(3) == nil, "a player who left has no wallet")
clock = clock + 1
wallet.onClientMessage(2, { t = "givetp" })
check(wallet.get(2) == 7 and wallet.get(1) == 20, "alone with the host the give still goes to the host, who is capped (nothing moves)")
net.seats[3] = { name = "Bob" }
wallet.hostUpdate()
check(wallet.get(3) == 7, "a player who joins mid-battle starts with the battle's starting TP")

-- a new battle starts everything over
player = { gameState = 0, gameType = 1, mnb2SubGame = 0, tp = 12, screenx = 0, screeny = 0, deployedVehicles = {},
  deployedTroops = { { id = 1, faction = "allied", playerControlled = 1, dead = 0, health = 100, x = 0, y = 0 } } }
wallet.hostUpdate()
check(wallet.get(2) == 12 and wallet.get(3) == 12, "wallets reset when a battle starts")

-- not active: solo, or not Classic
net.seats[2], net.seats[3] = nil, nil
check(not wallet.active(), "solo: no wallets")
player.tp = 5
check(wallet.with(2, function() player.tp = player.tp + 1 end) and player.tp == 6, "solo: a call is just a call on player.tp")
check(not wallet.keypressed("g"), "solo: G does nothing")
net.seats[2], net.seats[3] = { name = "Ann" }, { name = "Bob" }
player.gameType = 0
check(not wallet.active() and not wallet.keypressed("g"), "campaign battles keep the shared game rules")
player.gameType = 1

-- the teammate's side: their own TP over the mirror's
net.role, net.mySeat = "client", 2
mnbCoop.battle.viewing = true
player = { gameState = 0, gameType = 1, tp = 99 }
wallet.clientApply()
check(player.tp == 99, "no wallet message yet: the mirror's TP is left alone")
wallet.onHostMessage({ t = "wallet", v = 13 })
wallet.clientApply()
check(player.tp == 13, "the teammate sees their own TP, not the host's")
wallet.onHostMessage({ t = "wallet", v = "evil" })
wallet.onHostMessage({ t = "wallet", v = 0 / 0 })
wallet.onHostMessage({ t = "wallet", v = 1e12 })
wallet.clientApply()
check(player.tp == 13, "junk values from the host's channel are ignored")
local noteShown
mnbCoop.notice = function(t) noteShown = t end
wallet.onHostMessage({ t = "wallet", note = "Bob gave you 5 TP\n" .. string.rep("x", 200) })
check(noteShown and #noteShown <= 80 and not noteShown:find("\n"), "the note is cut short and cleaned")
sent = {}
net.sendToHost = function(msg) sent[#sent + 1] = msg end
check(wallet.keypressed("g") and #sent == 1 and sent[1].t == "givetp", "the teammate's G asks the host (nothing else sent)")
wallet.clientReset()
player.tp = 99
wallet.clientApply()
check(player.tp == 99, "after watching ends the wallet is forgotten")
mnbCoop.battle.viewing = false
net.role, net.mySeat = "host", 1

print(("%d passed, %d failed"):format(passes, fails))
love.event.quit(fails == 0 and 0 or 1)
