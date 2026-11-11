-- =============================================================================
-- MUD AND BLOOD CO-OP (step 1: lobby)
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
-- =============================================================================
local net = require("includes/mods/mnb_coop/coop_net")
local profile = require("includes/mods/mnb_coop/coop_profile")
local lobby = require("includes/mods/mnb_coop/coop_lobby")
local hud = require("includes/mods/mnb_coop/coop_hud")
local campaign = require("includes/mods/mnb_coop/coop_campaign")

mnbCoop = { net = net, profile = profile, lobby = lobby, hud = hud, campaign = campaign, version = net.VERSION }

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
    love.graphics.setColor(1, 1, 1, 1)
end

-- ---------------------------------------------------------------- love hooks
local coopUpdate = love.update
function love.update(dt, ...)
    net.update()
    if campaign.active then pcall(campaign.retag) end
    return coopUpdate(dt, ...)
end

-- Co-op campaign squad: arrange 3 soldiers per player before a mission starts, and
-- place soldiers 7+ once the game has set the mission up.
local coopGo = menu_goButton
function menu_goButton(...)
    if campaign.active then
        local ok, err = pcall(campaign.arrangeSquad)
        if not ok then print("[mnb_coop] squad: " .. tostring(err)) end
    end
    return coopGo(...)
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
function love.keypressed(key, ...)
    if lobby.wantsKeyboard() then return lobby.keypressed(key) end
    if hud.keypressed(key) then return end
    return coopKeypressed(key, ...)
end

local coopDraw = love.draw
function love.draw(...)
    coopDraw(...)
    local ok, err = pcall(hud.draw)
    if not ok then print("[mnb_coop] stats panel: " .. tostring(err)) end
end

local coopTextinput = love.textinput
function love.textinput(t, ...)
    if lobby.wantsKeyboard() then return lobby.textinput(t) end
    if coopTextinput then return coopTextinput(t, ...) end
end

local coopMousereleased = love.mousereleased
function love.mousereleased(x, y, button, ...)
    if menuPage == lobby.page then lobby.mousereleased(x, y) end
    return coopMousereleased(x, y, button, ...)
end

local coopQuit = love.quit
function love.quit(...)
    net.shutdown()
    local result
    if coopQuit then result = coopQuit(...) end -- the game saves here (co-op files if co-op campaign is on)
    pcall(campaign.onQuitAfterGameSaved)
    return result
end

print("[mnb_coop] co-op " .. net.VERSION .. " loaded")
return mnbCoop
