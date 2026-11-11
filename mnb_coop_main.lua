-- =============================================================================
-- MUD AND BLOOD CO-OP (step 2: watching the host's battle)
-- Up to 4 players. The host runs the real battle; the others see it live and
-- command their own soldiers (steps 2-3). Design: DESIGN.md in this folder.
--
-- This file wires the parts into the game:
--   coop_codec   safe data encoding (never runs received data as code)
--   coop_net     enet connection + lobby session
--   coop_profile Steam name/avatar, face, showcase, co-op settings file
--   coop_lobby   the Multiplayer page on the main menu
--   coop_hud     network stats panel (ping, up/down rates), option or Ctrl+F8
--   coop_campaign the co-op campaign: the game's campaign on its own save files
--   coop_battle  battle sync: the host's battle mirrored to clients (they watch)
--   coop_squad   who owns which soldier: keys, rings, face frames, friends' move orders
-- =============================================================================
local net = require("includes/mods/mnb_coop/coop_net")
local profile = require("includes/mods/mnb_coop/coop_profile")
local lobby = require("includes/mods/mnb_coop/coop_lobby")
local hud = require("includes/mods/mnb_coop/coop_hud")
local campaign = require("includes/mods/mnb_coop/coop_campaign")
local battle = require("includes/mods/mnb_coop/coop_battle")
local squad = require("includes/mods/mnb_coop/coop_squad")

mnbCoop = { net = net, profile = profile, lobby = lobby, hud = hud, campaign = campaign, battle = battle,
    squad = squad, version = net.VERSION }

-- a client that stops watching lands back in the lobby
battle.onStopView = function(why)
    menuPage = lobby.page
    net.status = "Back in the lobby: " .. tostring(why)
end

-- ---------------------------------------------------------------- network hooks
-- host: friends' orders (coop_squad) and rosters (coop_campaign)
net.onClientMessage = function(seat, msg)
    return squad.onClientMessage(seat, msg) or campaign.onClientMessage(seat, msg)
end
-- client: mission results go to the co-op save, the rest is the battle view
local battleHostMessage = net.onHostMessage
net.onHostMessage = function(msg)
    if msg.t == "results" then return campaign.queueResults(msg) end
    return battleHostMessage(msg)
end
net.onWelcome = function() campaign.sendRoster() end -- my top soldiers to the host
net.onSeatLeft = function(seat) campaign.onSeatLeft(seat) end
local battleReset = net.onReset
net.onReset = function()
    battleReset()
    campaign.friendRosters = {}
end

-- a short message on the co-op banner (lobby.draw)
function mnbCoop.notice(text)
    mnbCoop.noticeText, mnbCoop.noticeAt = text, love.timer.getTime()
    pcall(function() poop:clone():play() end)
end

-- called from the patched buttonUpdateMenu / drawState1 (see qm.toml)
function mnbCoop.registerMenuButtons()
    local okc, errc = pcall(campaign.update) -- back on the main menu = leave the co-op campaign
    if not okc then print("[mnb_coop] campaign: " .. tostring(errc)) end
    pcall(campaign.registerButtons) -- squad page switch
    local ok, err = pcall(lobby.registerButtons)
    if not ok then print("[mnb_coop] menu buttons: " .. tostring(err)) end
end

function mnbCoop.drawMenu()
    local ok, err = pcall(lobby.draw)
    if not ok then print("[mnb_coop] menu draw: " .. tostring(err)) end
    local okt, errt = pcall(campaign.drawSquadTags) -- GOING / HOME on the co-op Squad screen
    if not okt then print("[mnb_coop] squad tags: " .. tostring(errt)) end
    love.graphics.setColor(1, 1, 1, 1)
end

-- ---------------------------------------------------------------- love hooks
local coopUpdate = love.update
function love.update(dt, ...)
    net.update()
    if battle.viewing then
        -- watching: the host runs the battle, this machine only animates the mirror
        local ok, err = pcall(battle.clientUpdate, dt)
        if not ok then print("[mnb_coop] watching: " .. tostring(err)) end
        if not battle.inDebrief() then pcall(squad.clientHover) end -- the game's soldier card on mouse-over
        return
    end
    if campaign.active then
        campaign.track() -- the game may have reloaded `player` from the (co-op) save
        pcall(campaign.retag)
    end
    if net.role == "host" then
        local oko, erro = pcall(squad.hostRunOrders) -- friends' orders, before the game's frame
        if not oko then print("[mnb_coop] orders: " .. tostring(erro)) end
    end
    local result = coopUpdate(dt, ...)
    if campaign.active then
        local okl, errl = pcall(campaign.updateLeavers) -- a leaver's soldiers walk off; newcomers come in
        if not okl then print("[mnb_coop] leavers: " .. tostring(errl)) end
    end
    if net.role == "host" then
        local ok, err = pcall(battle.hostUpdate, dt)
        if not ok then print("[mnb_coop] battle sync: " .. tostring(err)) end
    end
    return result
end

-- Co-op campaign squad: share the 6 soldiers out between the players before a mission starts, and
-- place soldiers 7+ once the game has set the mission up.
local coopGo = menu_goButton
function menu_goButton(...)
    -- a friend connected to a host doesn't start battles of their own
    if net.role == "client" then
        mnbCoop.notice("Only the host starts missions")
        return
    end
    if campaign.active then
        local ok, err = pcall(campaign.arrangeSquad)
        if not ok then print("[mnb_coop] squad: " .. tostring(err)) end
    end
    return coopGo(...)
end

local coopClassic = menu_classicButton
function menu_classicButton(...)
    if net.role == "client" then
        mnbCoop.notice("Only the host starts battles")
        return
    end
    return coopClassic(...)
end

-- BACK on a mission-end page: the mission is settled (soldiers back on everyone's
-- roster, results sent) and, in co-op, the host lands in the Multiplayer lobby.
local coopBack = menu_backButton
function menu_backButton(...)
    local fromPage = menuPage
    local result = coopBack(...)
    if campaign.active and battle.DEBRIEF_PAGES[fromPage] then
        local ok, err = pcall(campaign.settleMission)
        if not ok then print("[mnb_coop] settle: " .. tostring(err)) end
        if menuPage == 1 then
            menuPage = lobby.getPage()
            mouseOverText = ""
        end
    end
    return result
end

-- Battle HUD pass: number keys follow your own soldiers in co-op (coop_squad.lua).
local coopButtonEngine = buttonEngine
function buttonEngine(...)
    local result = coopButtonEngine(...)
    local ok, err = pcall(squad.hostAfterButtonEngine)
    if not ok then print("[mnb_coop] squad keys: " .. tostring(err)) end
    return result
end

local coopPreGame = preGameAdmin
function preGameAdmin(...)
    local dday = campaign.active and player.gainz == 1 and player.landed == 0
    local result = coopPreGame(...)
    if campaign.active then
        local ok, err = pcall(campaign.placeExtras, dday)
        if not ok then print("[mnb_coop] squad placement: " .. tostring(err)) end
    end
    return result
end

local coopKeypressed = love.keypressed
-- keys a friend may use while watching: they only change that machine's view
-- (main.lua: f9 tactical view 7861, tab faces 8493, f3/f4 window 7886-7894)
local VIEW_KEYS = { f9 = true, tab = true, f3 = true, f4 = true }
function love.keypressed(key, ...)
    if lobby.wantsKeyboard() then return lobby.keypressed(key) end
    if hud.keypressed(key) then return end
    if battle.viewing then
        -- friend in the host's battle: own selection keys, own view keys, Esc twice to leave
        local ok, used = pcall(squad.clientKeypressed, key)
        if ok and used then return end
        if VIEW_KEYS[key] then
            -- the game's own handler: these keys only change this machine's view
            battle.localSound = true
            local okv, errv = pcall(coopKeypressed, key, ...)
            battle.localSound = false
            if not okv then print("[mnb_coop] view key: " .. tostring(errv)) end
            return
        end
        if key == "r" then pcall(fadeAllRoofs) return end -- the game's R, without its menu reset
        return battle.keypressed(key)
    end
    return coopKeypressed(key, ...)
end

local coopDraw = love.draw
function love.draw(...)
    if battle.viewing then
        -- the host's battle drawn with the game's code: a missing piece must not
        -- crash the friend's game, it shows as a message and goes in the log once
        love.graphics.push("all")
        local args = { ... }
        local ok, err = xpcall(function() return coopDraw(unpack(args)) end, debug.traceback)
        love.graphics.pop()
        battle.noteDrawError(not ok and err or nil)
    else
        coopDraw(...)
    end
    local okf, errf = pcall(squad.drawFaceFrames)
    if not okf then print("[mnb_coop] face frames: " .. tostring(errf)) end
    if battle.viewing then
        pcall(squad.drawClientBox)
        local okv, errv = pcall(battle.drawOverlay)
        if not okv then print("[mnb_coop] watching overlay: " .. tostring(errv)) end
    end
    local ok, err = pcall(hud.draw)
    if not ok then print("[mnb_coop] stats panel: " .. tostring(err)) end
end

local coopMousepressed = love.mousepressed
function love.mousepressed(x, y, button, ...)
    if battle.viewing then
        pcall(squad.clientMousepressed, x, y, button)
        return
    end
    local okd, used = pcall(campaign.squadPress, x, y, button) -- right-drag a Squad card
    if okd and used then return end
    if coopMousepressed then return coopMousepressed(x, y, button, ...) end
end

local coopTextinput = love.textinput
function love.textinput(t, ...)
    if lobby.wantsKeyboard() then return lobby.textinput(t) end
    if coopTextinput then return coopTextinput(t, ...) end
end

local coopMousereleased = love.mousereleased
function love.mousereleased(x, y, button, ...)
    if battle.viewing then
        local ok, err = pcall(squad.clientMousereleased, x, y, button)
        if not ok then print("[mnb_coop] order: " .. tostring(err)) end
        return
    end
    local okd, used = pcall(campaign.squadRelease, x, y, button) -- drop of a Squad card (swap)
    if okd and used then return end
    if menuPage == lobby.page then lobby.mousereleased(x, y) end
    pcall(squad.hostBeforeRelease, button) -- faces only reorder inside your own group
    return coopMousereleased(x, y, button, ...)
end
-- friends' move orders are replayed through the game's own release handler
squad.setGameRelease(coopMousereleased)

local coopQuit = love.quit
function love.quit(...)
    battle.stopView("quit") -- the real `player` must be back before the game saves it
    net.shutdown()
    local result
    if coopQuit then result = coopQuit(...) end -- the game saves here (co-op files if co-op campaign is on)
    pcall(campaign.onQuitAfterGameSaved)
    return result
end

print("[mnb_coop] co-op " .. net.VERSION .. " loaded")
return mnbCoop
