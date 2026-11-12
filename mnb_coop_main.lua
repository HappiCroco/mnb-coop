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
local defense = require("includes/mods/mnb_coop/coop_defense")

mnbCoop = { net = net, profile = profile, lobby = lobby, hud = hud, campaign = campaign, battle = battle,
    squad = squad, defense = defense, version = net.VERSION }

-- Co-op Classic, defense layout (coop_defense.lua): the game's Classic set-up, wave
-- maker and German direction helpers, each wrapped; they only differ in a defense battle.
spawnMNB2Wave = defense.wrapWave(spawnMNB2Wave)
moveForward = defense.wrapMoveForward(moveForward)
axisRetreat = defense.wrapRetreat(axisRetreat)
axisInFront = defense.wrapInFront(axisInFront)
axisAdvance = defense.wrapAdvance(axisAdvance)
fjDrop = defense.wrapFjDrop(fjDrop)                         -- German paratroopers: both fronts
germanArtyPrefire = defense.wrapFrontStrike(germanArtyPrefire) -- front-line artillery: alternate fronts
preAirBurst = defense.wrapFrontStrike(preAirBurst)
local coopPreMNB2 = preMNB2Admin
function preMNB2Admin(...)
    -- a new field, or a battle under way being loaded (mnb2.lua:7, 262)
    local fresh = not (type(player) == "table" and player.ui_gameStarted ~= 0 and player.ui_gameStarted ~= nil)
    local result = coopPreMNB2(...)
    local ok, err = pcall(defense.afterSetup, fresh)
    if not ok then print("[mnb_coop] defense setup: " .. tostring(err)) end
    return result
end

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
    if msg.t == "prompt" then return squad.onPrompt(msg) end -- my armed skill/item (aiming cursor)
    if msg.t == "ui" then return squad.onUi(msg) end         -- my HUD menu page after a button
    return battleHostMessage(msg)
end
net.onWelcome = function() campaign.sendRoster() end -- my top soldiers to the host
net.onSeatLeft = function(seat)
    squad.forgetSeat(seat)
    campaign.onSeatLeft(seat)
end
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

-- two copies on one PC: the windows share the screen (coop_window.lua)
local window = require("includes/mods/mnb_coop/coop_window")

-- ---------------------------------------------------------------- love hooks
local coopUpdate = love.update
function love.update(dt, ...)
    net.update()
    local okw, errw = pcall(window.update)
    if not okw then print("[mnb_coop] window: " .. tostring(errw)) end
    if battle.viewing then
        pcall(defense.aliasSprites) -- the defense radar's pictures
        -- watching: the host runs the battle, this machine only animates the mirror
        local ok, err = pcall(battle.clientUpdate, dt)
        if not ok then print("[mnb_coop] watching: " .. tostring(err)) end
        if not battle.inDebrief() then
            pcall(squad.clientHud)   -- the game's HUD buttons, from this window's camera and menu page
            pcall(squad.clientHover) -- the game's soldier card and tooltips on mouse-over
        end
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
    local okd, errd = pcall(defense.update) -- co-op defense: sides, and the radar
    if not okd then print("[mnb_coop] defense: " .. tostring(errd)) end
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
    -- the co-op Classic tile arms this; the game's own Classic button doesn't
    defense.wanted, defense.armed = defense.armed, false
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
    elseif defense.wanted and battle.DEBRIEF_PAGES[fromPage] then
        -- a co-op Classic battle is over: back to the Multiplayer screen
        defense.wanted, defense.on = false, false
        if menuPage ~= lobby.getPage() then
            menuPage = lobby.getPage()
            mouseOverText = ""
        end
    end
    return result
end

-- Battle HUD pass: number keys follow your own soldiers in co-op (coop_squad.lua).
local coopButtonEngine = buttonEngine
squad.setGameButtonEngine(coopButtonEngine) -- friends build their HUD buttons with it
function buttonEngine(...)
    local result = coopButtonEngine(...)
    local ok, err = pcall(squad.hostAfterButtonEngine)
    if not ok then print("[mnb_coop] squad keys: " .. tostring(err)) end
    return result
end

-- Classic's big-squad punishment (size control, urb_engine.lua:6022) starts above this
-- many soldiers (qm.toml patch). The game's 6 is one player's; a co-op Classic battle
-- with friends allows 12 for the whole team (owner, 2026-11-11). Campaign: its squad size.
function coopSizeLimit()
    if net.role == "host" and net.playerCount() > 1 and type(player) == "table" and player.gameType == 1 then
        return 12
    end
    return coopSquadMax and coopSquadMax() or 6
end

-- A face click on the host doesn't open a friend's soldier's promotion panel: they choose.
iconClick = squad.wrapIconClick(iconClick)

-- XP day cap in the co-op campaign (coop_campaign.lua): no farming the easy days.
giveXp = campaign.wrapGiveXp(giveXp)

local coopPreGame = preGameAdmin
function preGameAdmin(...)
    local dday = campaign.active and player.gainz == 1 and player.landed == 0
    -- D-Day hands out new perks and rifles; veterans keep their own
    local okv, veterans = pcall(function() return dday and campaign.stashVeterans() or nil end)
    local result = coopPreGame(...)
    if okv and veterans then pcall(campaign.restoreVeterans, veterans) end
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
    if key == "h" and net.role == "host" and squad.active() and type(player) == "table" and player.gameState == 0 then
        return squad.withOnly(squad.mySeat(), coopKeypressed, key, ...) -- H halts your own soldiers only
    end
    return coopKeypressed(key, ...)
end

local coopKeyreleased = love.keyreleased
function love.keyreleased(key, ...)
    if battle.viewing then
        pcall(squad.clientKeyreleased, key)
        return
    end
    if not coopKeyreleased then return end
    if (key == "lalt" or key == "ralt") and net.role == "host" and squad.active() then
        return squad.withOwnWaypoints(squad.mySeat(), coopKeyreleased, key, ...) -- friends' waypoints wait for them
    end
    return coopKeyreleased(key, ...)
end
-- friends' H and Alt release are run through the game's own key handlers
squad.setGameKeys(coopKeypressed, coopKeyreleased)

-- Pause > Options saves and leaves the battle (urb_engine.lua:45012): not while friends are in it.
local coopPauseOption = pause_optionButton
function pause_optionButton(...)
    if net.role == "host" and net.playerCount() > 1 and type(player) == "table" and player.gameState == 0 then
        -- the game's own battle announcement, and its "can't" sound
        if not pcall(anounceStuff, "Options are closed while friends are in the battle") then
            mnbCoop.notice("Options are closed while friends are in the battle")
        end
        pcall(function() poop:clone():play() end)
        return
    end
    if coopPauseOption then return coopPauseOption(...) end
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
