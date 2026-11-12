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
--   coop_squad   who owns which soldier: keys, rings, face frames, teammates' move orders
-- =============================================================================
local net = require("includes/mods/mnb_coop/coop_net")
local profile = require("includes/mods/mnb_coop/coop_profile")
local lobby = require("includes/mods/mnb_coop/coop_lobby")
local hud = require("includes/mods/mnb_coop/coop_hud")
local campaign = require("includes/mods/mnb_coop/coop_campaign")
local battle = require("includes/mods/mnb_coop/coop_battle")
local squad = require("includes/mods/mnb_coop/coop_squad")
local defense = require("includes/mods/mnb_coop/coop_defense")
local wallet = require("includes/mods/mnb_coop/coop_wallet")
local qmInput = require("includes/mods/mnb_coop/coop_qminput")
local ribbons = require("includes/mods/mnb_coop/coop_ribbons")

mnbCoop = { net = net, profile = profile, lobby = lobby, hud = hud, campaign = campaign, battle = battle,
    squad = squad, defense = defense, ribbons = ribbons, wallet = wallet, version = net.VERSION }

-- Co-op ribbons (coop_ribbons.lua, ids 201+): pictures, names and texts become game globals,
-- and checkRibCondition hands our ids to the registry
ribbons.install()

-- Wave pace (qm.toml patch on the wave timer, urb_engine.lua:6084): the next wave comes at
-- 60 + the living Germans / this. The defense twins every wave, so twice as many Germans
-- stand around and waves (and their TP) would come slower than in the original; 1 elsewhere.
coopWavePace = defense.wavePace

-- Co-op Classic, defense layout (coop_defense.lua): the game's Classic set-up, wave
-- maker and German direction helpers, each wrapped; they only differ in a defense battle.
spawnMNB2Wave = defense.wrapWave(spawnMNB2Wave)
-- special waves (mnb2.lua:738-793): one side per wave, never doubled
for _, name in ipairs({ "mnb2CreateJagers", "mnb2CreateFJ", "mnb2CreateSS", "mnb2CreateWerBossWave", "mnb2CreateSpecialWeaponBossWave",
    "mnb2CreateGoliathBossWave", "mnb2CreatePanzerBossWave", "mnb2CreateSniperBossWave", "mnb2CreateAirDropBossWave",
    "mnb2CreateVolksBossWave", "mnb2CreateGrenadierBossWave", "mnb2CreateLuftBossWave", "mnb2CreateV1BossWave",
    "mnb2CreateFeldBossWave", "spawnCombinedForce" }) do -- (crowd control's Combined Force too, mnb2.lua:643)
    if type(rawget(_G, name)) == "function" then _G[name] = defense.wrapSpecial(_G[name]) end
end
moveForward = defense.wrapMoveForward(moveForward)
axisRetreat = defense.wrapRetreat(axisRetreat)
axisInFront = defense.wrapInFront(axisInFront)
axisAdvance = defense.wrapAdvance(axisAdvance)
alliedRetreat = defense.wrapAlliedRetreat(alliedRetreat) -- our shaken soldiers fall back to the radar, not left
-- German vehicles from both sides: each side's own German front, a left one's AI mirrored
-- (the vehicle AIs vehicleUpdate calls one vehicle at a time, ai.lua:4150-4182)
for _, name in ipairs({ "tankAI", "truckAI", "benzAI", "pumaAI", "bikeAI", "sdkfz2AI", "horseCartAI",
    "pak36AI", "stationaryAI" }) do
    if type(rawget(_G, name)) == "function" then _G[name] = defense.wrapVehicleAI(_G[name]) end
end
-- ...and their driving rules (qm.toml patches in vehicleUpdate ask these)
coopVehicleBacks, coopVehicleBackSign, coopVehicleBackRot = defense.vehicleBacks, defense.vehicleBackSign, defense.vehicleBackRot
fjDrop = defense.wrapFjDrop(fjDrop)                         -- German paratroopers: both fronts
germanArtyPrefire = defense.wrapFrontStrike(germanArtyPrefire) -- front-line artillery: alternate fronts
preAirBurst = defense.wrapFrontStrike(preAirBurst)
local coopPreMNB2 = preMNB2Admin
function preMNB2Admin(...)
    -- a new field, or a battle under way being loaded (mnb2.lua:7, 262)
    local fresh = not (type(player) == "table" and player.ui_gameStarted ~= 0 and player.ui_gameStarted ~= nil)
    -- a Classic battle, new (the deploy buttons, urb_engine.lua:8824-8914) or carried on
    -- (urb_engine.lua:40033), waits for every teammate's READY: the ready room opens and replays
    -- this call on START (the buttons set mnb2SubGame first, so the replay starts the same mode)
    local args = { n = select("#", ...), ... }
    if not lobby.gate("CO-OP CLASSIC", function() preMNB2Admin(unpack(args, 1, args.n)) end) then return end
    local result = coopPreMNB2(...)
    local ok, err = pcall(defense.afterSetup, fresh)
    if not ok then print("[mnb_coop] defense setup: " .. tostring(err)) end
    if type(player) == "table" and player.gameState == 0 then net.resetReady() end
    return result
end

-- a client that stops watching lands back in the lobby
battle.onStopView = function(why)
    wallet.clientReset()
    menuPage = lobby.page
    net.status = "Back in the lobby: " .. tostring(why)
end

-- ---------------------------------------------------------------- network hooks
-- host: teammates' orders (coop_squad) and rosters (coop_campaign)
net.onClientMessage = function(seat, msg)
    return squad.onClientMessage(seat, msg) or wallet.onClientMessage(seat, msg) or campaign.onClientMessage(seat, msg)
end
-- client: mission results go to the co-op save, the rest is the battle view
local battleHostMessage = net.onHostMessage
net.onHostMessage = function(msg)
    if msg.t == "results" then return campaign.queueResults(msg) end
    if msg.t == "prompt" then return squad.onPrompt(msg) end -- my armed skill/item (aiming cursor)
    if msg.t == "ui" then return squad.onUi(msg) end         -- my HUD menu page after a button
    if msg.t == "wallet" then return wallet.onHostMessage(msg) end -- my own TP (Classic wallets)
    return battleHostMessage(msg)
end
net.onWelcome = function() campaign.sendRoster() end -- my top soldiers to the host
net.onSeatLeft = function(seat)
    squad.forgetSeat(seat)
    wallet.forgetSeat(seat)
    campaign.onSeatLeft(seat)
end
local battleReset = net.onReset
net.onReset = function()
    battleReset()
    campaign.friendRosters = {}
end

-- ---------------------------------------------------------------- pop-ups
-- Owner (2026-11-12): errors should show on screen, not only in the log. Two kinds:
--   notice: a co-op message (a refusal, "New war: ...") - 4 s
--   error:  something of ours failed (a Lua error caught by a pcall) - 10 s, with a count
-- Errors are caught where they're printed: every caught error of ours is printed as
-- "[mnb_coop] <what>: <file>:<line>: <message>", so the print hook below picks those
-- up (and nothing else), without touching each of the ~30 places.
local toasts = {}
mnbCoop.toasts = toasts
local TOAST_TIME = { notice = 4, error = 10 }

-- refresh = true: still happening (every frame): keep it up without counting
function mnbCoop.toast(kind, text, refresh)
    text = tostring(text):gsub("%s+", " ")
    if #text > 150 then text = text:sub(1, 147) .. "..." end
    local now = love.timer.getTime()
    for _, t in ipairs(toasts) do
        if t.text == text and t.kind == kind then
            t.at = now
            if not refresh then t.count = t.count + 1 end -- the same one again: a count
            return
        end
    end
    table.insert(toasts, 1, { kind = kind, text = text, at = now, count = 1 })
    while #toasts > 4 do table.remove(toasts) end
end

do
    local realPrint = print
    print = function(...)
        realPrint(...)
        local first = select(1, ...)
        if type(first) == "string" then
            local what, msg = first:match("^%[mnb_coop%] ([^:]+): (.-%.lua:%d+:.*)$")
            if what then pcall(mnbCoop.toast, "error", what .. ": " .. (msg:match("^[^\n]*") or msg)) end
        end
    end
end

function mnbCoop.drawToasts()
    local now = love.timer.getTime()
    for i = #toasts, 1, -1 do
        if now - toasts[i].at > TOAST_TIME[toasts[i].kind] then table.remove(toasts, i) end
    end
    if #toasts == 0 then return end
    local g = love.graphics
    g.push("all")
    g.origin()
    local font = nonoFont or g.getFont()
    g.setFont(font)
    local w, x, y = 460, g.getWidth() - 470, 60
    for _, t in ipairs(toasts) do
        local head = t.kind == "error" and ("CO-OP ERROR" .. (t.count > 1 and (" (x" .. t.count .. ")") or "")) or "CO-OP"
        local body = t.text .. (t.kind == "error" and "\nDetails: Mods/qm/log/latest.log" or "")
        local _, lines = font:getWrap(body, w - 20)
        local h = font:getHeight() * (#lines + 1) + 16
        local fade = math.min(1, (TOAST_TIME[t.kind] - (now - t.at)) / 0.5)
        g.setColor(0.08, 0.05, 0.05, 0.85 * fade)
        g.rectangle("fill", x, y, w, h, 4)
        if t.kind == "error" then g.setColor(0.85, 0.25, 0.2, fade) else g.setColor(0.85, 0.7, 0.3, fade) end
        g.rectangle("line", x, y, w, h, 4)
        g.print(head, x + 10, y + 6)
        g.setColor(0.92, 0.9, 0.86, fade)
        g.printf(body, x + 10, y + 6 + font:getHeight(), w - 20, "left")
        y = y + h + 8
    end
    g.pop()
end

-- a short message on the co-op banner (lobby.draw), and as a pop-up
function mnbCoop.notice(text)
    mnbCoop.noticeText, mnbCoop.noticeAt = text, love.timer.getTime()
    pcall(mnbCoop.toast, "notice", text)
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
    pcall(lobby.updateRoom) -- teammates follow the host into and out of the ready room
    pcall(lobby.updatePresence) -- where I am, for the others' lobby cards
    local okw, errw = pcall(window.update)
    if not okw then print("[mnb_coop] window: " .. tostring(errw)) end
    if battle.viewing then
        pcall(defense.aliasSprites) -- the defense radar's pictures
        -- watching: the host runs the battle, this machine only animates the mirror
        local ok, err = pcall(battle.clientUpdate, dt)
        if not ok then print("[mnb_coop] watching: " .. tostring(err)) end
        pcall(wallet.clientApply) -- my own TP in the mirror, not the host's
        if not battle.inDebrief() then
            pcall(squad.clientHud)   -- the game's HUD buttons, from this window's camera and menu page
        end
        pcall(squad.clientHover) -- the game's soldier card and tooltips on mouse-over (and the mission report's)
        return
    end
    if campaign.active then
        campaign.track() -- the game may have reloaded `player` from the (co-op) save
        pcall(campaign.retag)
    end
    if net.role == "host" then
        local oko, erro = pcall(squad.hostRunOrders) -- teammates' orders, before the game's frame
        if not oko then print("[mnb_coop] orders: " .. tostring(erro)) end
    end
    local okd, errd = pcall(defense.update) -- co-op defense: sides, and the radar
    if not okd then print("[mnb_coop] defense: " .. tostring(errd)) end
    local okw2, errw2 = pcall(wallet.hostUpdate) -- (first frame of a battle: the wallets start here)
    if not okw2 then print("[mnb_coop] wallets: " .. tostring(errw2)) end
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
    -- a teammate connected to a host doesn't start battles of their own
    if net.role == "client" then
        mnbCoop.notice("Only the host starts missions")
        return
    end
    -- the host waits for every teammate's READY (the ready room, replaying GO on START);
    -- a mission that starts uses it up
    local args = { n = select("#", ...), ... }
    if not lobby.gate("CO-OP CAMPAIGN", function() menu_goButton(unpack(args, 1, args.n)) end) then return end
    if campaign.active then
        local ok, err = pcall(campaign.arrangeSquad)
        if not ok then print("[mnb_coop] squad: " .. tostring(err)) end
    end
    local r = { coopGo(...) }
    if type(player) == "table" and player.gameState == 0 then net.resetReady() end
    return unpack(r)
end

local coopClassic = menu_classicButton
function menu_classicButton(...)
    if net.role == "client" then
        mnbCoop.notice("Only the host starts battles")
        return
    end
    -- (no READY here: picking a mode is free; the start itself waits in the ready room)
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
squad.setGameButtonEngine(coopButtonEngine) -- teammates build their HUD buttons with it
function buttonEngine(...)
    local result = coopButtonEngine(...)
    local ok, err = pcall(squad.hostAfterButtonEngine)
    if not ok then print("[mnb_coop] squad keys: " .. tostring(err)) end
    return result
end

-- Co-op Classic rules (12-soldier size control, double TP): every co-op defense battle,
-- solo too (owner, 2026-11-12: "the 6-man rule becomes 12 even if I'm solo"), and any
-- Classic battle the host plays with teammates connected.
local function coopClassicRules()
    if type(player) ~= "table" or player.gameType ~= 1 then return false end
    return defense.on or (net.role == "host" and net.playerCount() > 1)
end
mnbCoop.coopClassicRules = coopClassicRules

-- Classic's big-squad punishment (size control, urb_engine.lua:6022) starts above this
-- many soldiers (qm.toml patch). The game's 6 is one player's; co-op Classic allows 12
-- for the whole team (owner, 2026-11-11). Campaign: its squad size.
function coopSizeLimit()
    if coopClassicRules() then return 12 end
    return coopSquadMax and coopSquadMax() or 6
end

-- TP income in co-op Classic. With teammates connected, every player has their own wallet and
-- giveTp's full amount goes into each one (coop_wallet.lua), not doubled. Alone (a solo
-- defense) it is the old rule: one pool, double (owner, 2026-11-11). The cap (20 + ribbons,
-- giveTp at mnb2.lua:894) is not raised. giveTp is the game's one income path (waves, taunts,
-- loot, special waves); the sitrep bonus (ai.lua:6157), directive TP Surge and withdrawal
-- refunds add to player.tp directly: whichever wallet sits in it then (see coop_wallet.lua).
local coopGiveTp = giveTp
function giveTp(nbr, ...)
    if type(nbr) == "number" then
        if wallet.active() then
            local before = type(player) == "table" and player.tp or nil
            local r = { wallet.giveTp(coopGiveTp, nbr, ...) }
            pcall(ribbons.afterGiveTp, before, nbr) -- the wallet in player.tp gets the ribbon's +2 too
            return unpack(r)
        elseif coopClassicRules() then
            nbr = nbr * 2
        end
    end
    local before = type(player) == "table" and player.tp or nil
    local result = coopGiveTp(nbr, ...)
    -- Two-Front War ribbon: +2 to the cap, put back after the game's own clamp
    pcall(ribbons.afterGiveTp, before, nbr)
    return result
end

-- A face click on the host doesn't open a teammate's soldier's promotion panel: they choose.
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

-- Key and mouse handlers go in through qmInput.wrap (coop_qminput.lua): QuarterMaster 1.8 has its own in
-- front and installs them twice, and a plain love.* swap made a click loop forever (stack overflow).
local coopKeypressed -- the handler ours passes on to (the game's)
-- keys a teammate may use while watching: they only change that machine's view
-- (main.lua: f9 tactical view 7861, tab faces 8493, f3/f4 window 7886-7894)
local VIEW_KEYS = { f9 = true, tab = true, f3 = true, f4 = true }
local function onKeypressed(key, ...)
    if lobby.wantsKeyboard() then return lobby.keypressed(key) end
    if hud.keypressed(key) then return end
    -- G: give TP to the next player (Classic wallets, coop_wallet.lua)
    if key == wallet.GIVE_KEY and wallet.keypressed(key) then return end
    if battle.viewing then
        -- teammate in the host's battle: own selection keys, own view keys, Esc twice to leave
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
coopKeypressed = qmInput.wrap("keypressed", function() return onKeypressed end)

local coopKeyreleased
local function onKeyreleased(key, ...)
    if battle.viewing then
        pcall(squad.clientKeyreleased, key)
        return
    end
    if not coopKeyreleased then return end
    if (key == "lalt" or key == "ralt") and net.role == "host" and squad.active() then
        return squad.withOwnWaypoints(squad.mySeat(), coopKeyreleased, key, ...) -- teammates' waypoints wait for them
    end
    return coopKeyreleased(key, ...)
end
coopKeyreleased = qmInput.wrap("keyreleased", function() return onKeyreleased end)
-- teammates' H and Alt release are run through the game's own key handlers
squad.setGameKeys(coopKeypressed, coopKeyreleased)

-- Pause > Options saves and leaves the battle (urb_engine.lua:45012): not while teammates are in it.
local coopPauseOption = pause_optionButton
function pause_optionButton(...)
    if net.role == "host" and net.playerCount() > 1 and type(player) == "table" and player.gameState == 0 then
        -- the game's own battle announcement, and its "can't" sound
        if not pcall(anounceStuff, "Options are closed while teammates are in the battle") then
            mnbCoop.notice("Options are closed while teammates are in the battle")
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
        -- crash the teammate's game, it shows as a message and goes in the log once
        local okb, restore = pcall(battle.beforeDraw)
        love.graphics.push("all")
        local args = { ... }
        local ok, err = xpcall(function() return coopDraw(unpack(args)) end, debug.traceback)
        love.graphics.pop()
        if okb and restore then restore() end
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
    pcall(mnbCoop.drawToasts) -- error and notice pop-ups, on top of everything
end

local coopMousepressed
local function onMousepressed(x, y, button, ...)
    if battle.viewing then
        pcall(squad.clientMousepressed, x, y, button)
        return
    end
    local okd, used = pcall(campaign.squadPress, x, y, button) -- right-drag a Squad card
    if okd and used then return end
    if coopMousepressed then return coopMousepressed(x, y, button, ...) end
end
coopMousepressed = qmInput.wrap("mousepressed", function() return onMousepressed end)

local coopTextinput = love.textinput
function love.textinput(t, ...)
    if lobby.wantsKeyboard() then return lobby.textinput(t) end
    if coopTextinput then return coopTextinput(t, ...) end
end

local coopMousereleased
local function onMousereleased(x, y, button, ...)
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
coopMousereleased = qmInput.wrap("mousereleased", function() return onMousereleased end)
-- teammates' move orders are replayed through the game's own release handler
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
