-- =============================================================================
-- CO-OP SQUAD IN BATTLE: who owns which soldier, and orders from friends
-- Squad soldiers carry coopSeat (set by coop_campaign.arrangeSquad). In battle:
--   * each squad soldier has a ring in its owner's seat colour, and its face in
--     the face bar a frame in that colour;
--   * number keys 1..n select the n soldiers of the player pressing them, in face
--     bar order; 7 selects all of them; box and click selection only take your own;
--   * dragging a face (right mouse) only reorders inside your own group;
--   * friends select on their mirror and click to move; the order goes to the host,
--     which replays the click through the game's own mouse code with only that
--     friend's soldiers selected (no copy of the game's move rules here).
-- A soldier whose player isn't connected counts as the host's.
-- Active only in the co-op campaign with more than one player, or while watching.
-- =============================================================================
local net = require("includes/mods/mnb_coop/coop_net")

local squad = {}

local MAX_ORDER_IDS = 12

local function log(fmt, ...)
    if net.isOn("debug", false) then print("[mnb_coop] " .. string.format(fmt, ...)) end
end

-- seat number of this machine's player (1 = host)
function squad.mySeat()
    return net.mySeat or 1
end

local function viewing()
    return mnbCoop and mnbCoop.battle and mnbCoop.battle.viewing
end

-- true when ownership rules apply right now
function squad.active()
    if viewing() then return true end
    if not (mnbCoop and mnbCoop.campaign and mnbCoop.campaign.active) then return false end
    return net.role == "host" and net.playerCount() > 1
end

local function isSquadSoldier(t)
    return type(t) == "table" and t.coopSquad == 1 and t.faction == "allied"
end

-- the seat that commands this troop now, or nil if it isn't the players'
function squad.ownerOf(t)
    if type(t) ~= "table" or t.faction ~= "allied" then return nil end
    if t.coopNpc == 1 then return nil end -- pulling out with a player who left: nobody's to command
    if isSquadSoldier(t) then
        local s = t.coopSeat
        if s and net.seats[s] then return s end
        return 1 -- their player isn't here: the host commands them
    end
    if t.playerControlled == 1 then return 1 end
    return nil
end

local function isMine(t)
    return squad.ownerOf(t) == squad.mySeat()
end

local function canSelect(t)
    return t.dead == 0 and (t.health or 0) > 10 and (t.retreating or 0) <= 0 and (t.onFire or 0) <= 0
end

-- slots (indexes in player.deployedTroops) commanded by `seat`, in face bar order
function squad.slotsOf(seat)
    local out = {}
    local troops = type(player) == "table" and player.deployedTroops
    if type(troops) ~= "table" then return out end
    for i = 1, #troops do
        local t = troops[i]
        if t.playerControlled == 1 and squad.ownerOf(t) == seat then out[#out + 1] = i end
    end
    return out
end

function squad.seatColor(seat)
    local c = net.SEAT_COLORS[seat] or { 200, 200, 200 }
    return c[1] / 255, c[2] / 255, c[3] / 255
end

-- ---------------------------------------------------------------- drawing
-- In world space under each soldier, from the game's troop loop (qm.toml patch).
function squad.drawOwnerRing(soldier)
    if not squad.active() or not isSquadSoldier(soldier) or soldier.dead ~= 0 then return end
    local seat = squad.ownerOf(soldier)
    local r, g, b = squad.seatColor(seat)
    love.graphics.push("all")
    love.graphics.setLineWidth(1.5)
    love.graphics.setColor(r, g, b, seat == squad.mySeat() and 0.45 or 0.28) -- faint: a hint, not a highlight
    love.graphics.circle("line", soldier.x, soldier.y, 17)
    love.graphics.pop()
end

-- Screen space, after the game's draw: a border in the owner's colour around each
-- portrait in the face bar. Same place and size as the game draws the portrait:
-- centred on (20 + n*60, 690), faceBase at 0.6 scale (drawFiles.lua:1243).
function squad.drawFaceFrames()
    if not squad.active() or showFaces ~= 1 or type(player) ~= "table" or player.gameState ~= 0 then return end
    if player.gameType == 1 or type(player.deployedTroops) ~= "table" or not faceBase then return end
    local w, h = faceBase:getWidth() * 0.6, faceBase:getHeight() * 0.6
    local cy = 690 - (player.screeny or 0)
    love.graphics.push("all")
    love.graphics.origin()
    love.graphics.setLineWidth(2)
    local peeps = 0
    for _, t in ipairs(player.deployedTroops) do
        if t.playerControlled == 1 then
            peeps = peeps + 1
            local seat = squad.ownerOf(t)
            if isSquadSoldier(t) and seat then
                local r, g, b = squad.seatColor(seat)
                love.graphics.setColor(r, g, b, seat == squad.mySeat() and 0.6 or 0.35)
                love.graphics.rectangle("line", 20 + peeps * 60 - w / 2 - 1, cy - h / 2 - 1, w + 2, h + 2, 2)
            end
        end
    end
    love.graphics.pop()
end

-- ---------------------------------------------------------------- host rules
-- After the game's buttonEngine (every battle frame on the host): number keys
-- follow the host's own soldiers, and nobody else's soldier stays selected here.
function squad.hostAfterButtonEngine()
    if not squad.active() or viewing() or type(player) ~= "table" or player.gameType == 1 then return end
    local n, me = 0, squad.mySeat()
    for _, t in ipairs(player.deployedTroops or {}) do
        if t.playerControlled == 1 and t.faction == "allied" then
            if squad.ownerOf(t) == me then
                n = n + 1
                t.shortcut = n
            else
                t.shortcut = 0
                if t.selected then t.selected = false end
            end
        end
    end
end

-- Host, right mouse release: a face may only be dropped onto another face of yours.
function squad.hostBeforeRelease(button)
    if not squad.active() or viewing() or button ~= 2 then return end
    local troops = type(player) == "table" and player.deployedTroops
    if type(troops) ~= "table" then return end
    local from, to = tonumber(mouseOverIconId) or 0, tonumber(mouseDropIconId) or 0
    if from > 0 and to > 0 and (not isMine(troops[from]) or not isMine(troops[to])) then
        mouseDropIconId = 0 -- the game then plays its "can't" sound
    end
end

-- ---------------------------------------------------------------- orders (host)
local queue = {}
local gameRelease = nil -- the game's love.mousereleased (set by mnb_coop_main)

function squad.setGameRelease(fn) gameRelease = fn end

-- an order from a seated player; returns true if it is a kind we know
function squad.onClientMessage(seat, msg)
    if msg.t ~= "move" then return false end
    if type(player) ~= "table" or player.gameState ~= 0 then return true end -- late, ignore
    local x, y = tonumber(msg.x), tonumber(msg.y)
    if not x or not y or type(msg.ids) ~= "table" then return true end
    local ids = {}
    for i = 1, math.min(#msg.ids, MAX_ORDER_IDS) do
        local id = tonumber(msg.ids[i])
        if id then ids[#ids + 1] = id end
    end
    if #queue < 32 then queue[#queue + 1] = { seat = seat, ids = ids, x = x, y = y } end
    return true
end

-- Runs a friend's move: their soldiers selected, everything else as if nothing
-- was on screen, then the game's own left-click release at that point.
local SAVED_GLOBALS = { "buttons", "mousePrompt", "mousePromptLock", "iconOn", "altMove", "selectionX", "selectionY",
    "selecting", "mouseOverIconId", "mouseDropIconId", "dragingIcon", "buttoned" }

local function runMove(o)
    local troops = player.deployedTroops
    local mine = {}
    for _, id in ipairs(o.ids) do
        local i = convertedId(id)
        local t = i and i > 0 and troops[i]
        if t and squad.ownerOf(t) == o.seat and canSelect(t) then mine[t] = true end
    end
    if not next(mine) then return end
    local savedSel, savedVeh = {}, {}
    for _, t in ipairs(troops) do savedSel[t] = t.selected t.selected = mine[t] and true or false end
    for _, v in ipairs(player.deployedVehicles or {}) do savedVeh[v] = v.selected v.selected = false end
    local g = {}
    for _, name in ipairs(SAVED_GLOBALS) do g[name] = _G[name] end
    buttons, mousePrompt, mousePromptLock, iconOn, altMove = {}, 0, 0, 0, 0
    local sx, sy = o.x - (player.screenx or 0), o.y - (player.screeny or 0)
    selectionX, selectionY = sx, sy
    local ok, err = pcall(gameRelease, sx, sy, 1)
    for _, name in ipairs(SAVED_GLOBALS) do _G[name] = g[name] end
    for t, s in pairs(savedSel) do if not mine[t] then t.selected = s end end
    for v, s in pairs(savedVeh) do v.selected = s end
    if not ok then print("[mnb_coop] friend's move: " .. tostring(err)) end
    log("seat %d moved %d soldier(s)", o.seat, #o.ids)
end

-- Host, at the start of its frame (before the game's update).
function squad.hostRunOrders()
    if #queue == 0 then return end
    local list = queue
    queue = {}
    if not gameRelease or type(player) ~= "table" or player.gameState ~= 0 or pause ~= 0 then return end
    for _, o in ipairs(list) do runMove(o) end
end

-- ---------------------------------------------------------------- client input
-- While watching, the friend selects on the mirror (selection is never synced)
-- and clicks the ground to move. Same feel as the game: drag a box to select,
-- click a soldier, 1..n for your soldiers, 7 for all of yours, shift adds.
local press = nil

local function shift()
    return love.keyboard.isDown("lshift") or love.keyboard.isDown("rshift")
end

local function mineSelectable()
    local out = {}
    for _, i in ipairs(squad.slotsOf(squad.mySeat())) do
        local t = player.deployedTroops[i]
        if canSelect(t) then out[#out + 1] = t end
    end
    return out
end

local function clearSelection()
    for _, t in ipairs(player.deployedTroops or {}) do t.selected = nil end
end

function squad.clientKeypressed(key)
    local n = tonumber(key)
    if not n or n < 1 or n > 7 then return false end
    if not shift() then clearSelection() end
    local mine = squad.slotsOf(squad.mySeat())
    if n == 7 then
        for _, t in ipairs(mineSelectable()) do t.selected = true end
    else
        local t = mine[n] and player.deployedTroops[mine[n]]
        if t and canSelect(t) then t.selected = true end
    end
    return true
end

function squad.clientMousepressed(x, y, button)
    if button == 1 then press = { x = x, y = y } end
end

function squad.clientMousereleased(x, y, button)
    if button ~= 1 or not press then return end
    if type(player) ~= "table" or player.gameState ~= 0 then press = nil return end -- mission-end page: nothing to order
    local px, py = press.x, press.y
    press = nil
    local ox, oy = player.screenx or 0, player.screeny or 0
    if math.abs(x - px) + math.abs(y - py) >= 25 then
        -- box: your own soldiers inside it
        local x1, x2 = math.min(px, x) + ox, math.max(px, x) + ox
        local y1, y2 = math.min(py, y) + oy, math.max(py, y) + oy
        if not shift() then clearSelection() end
        for _, t in ipairs(mineSelectable()) do
            if t.x >= x1 and t.x <= x2 and t.y >= y1 and t.y <= y2 then t.selected = true end
        end
        return
    end
    if squad.clientMiniMapClick(x, y) then return end
    local wx, wy = x + ox, y + oy
    -- a click on one of your soldiers selects him
    for _, t in ipairs(mineSelectable()) do
        if (t.x - wx) ^ 2 + (t.y - wy) ^ 2 <= 15 * 15 then
            if not shift() then clearSelection() end
            t.selected = true
            return
        end
    end
    -- otherwise: move the selected ones there
    local ids = {}
    for _, t in ipairs(mineSelectable()) do
        if t.selected and t.id then ids[#ids + 1] = t.id end
    end
    if #ids == 0 then return end
    net.sendToHost({ t = "move", ids = ids, x = wx, y = wy })
    clearSelection() -- the game also drops the selection after a move order
end

-- Client, every frame: the game's soldier card (nonoSquare, drawn while the global
-- mouseOverId holds a troop id) is fed by its HUD pass, which clients don't run.
-- Same hit boxes as the game's troop buttons (urb_engine.lua:44411-44416): allied
-- troops, 25x25 around the living, 5x5 on fresh bodies.
-- The game's mouse-over pass (urb_engine.lua:44842-44917) only sets display globals:
-- the first hover area under the mouse wins, in the order the HUD pass makes them.
-- The same areas, in the same order, from the game's button code (cited per step).
local function inBox(px, py, x, y, w, h)
    return px > x and px < x + w and py > y and py < y + h
end

-- the minimap strip at the top (urb_engine.lua:44432-44437), in screen space
local function miniMapBox()
    if showFaces ~= 1 or type(player.endLine) ~= "number" then return nil end
    local mapLength = player.endLine / 30
    return 640 - mapLength / 2, 5, mapLength, 20
end

function squad.clientHover()
    mouseOverText, contextualText, iconOn = "", "", 0
    mouseOverId, mouseOverId2 = -99, -99
    if type(player) ~= "table" or type(player.deployedTroops) ~= "table" then return end
    local mx, my = love.mouse.getPosition()
    local wx, wy = mx + (player.screenx or 0), my + (player.screeny or 0)
    -- 1. tip bubbles (44385-44387): their text
    for _, c in ipairs(player.tipCue or {}) do
        if type(c.x) == "number" and inBox(wx, wy, c.x - 25, c.y - 25, 30, 30) then
            pcall(displayContextualTip, c.msg)
            return
        end
    end
    -- 2. allied soldiers (44411-44416): the soldier card
    for _, t in ipairs(player.deployedTroops) do
        if t.faction == "allied" and t.id and (tonumber(t.deadTimer) or 0) < 10 and type(t.x) == "number" then
            local size = (t.dead == 0 or player.deadSelectable == 1) and 25 or 5
            if inBox(wx, wy, t.x - 12, t.y - 12, size, size) then
                mouseOverId = t.id
                return
            end
        end
    end
    -- 3. faces in the face bar (44419-44425): the name over the face (set the way
    -- iconDisplay does, without its drag state, sound or highlight ring)
    if showFaces == 1 and player.gameType ~= 1 then
        local peeps = 0
        for _, t in ipairs(player.deployedTroops) do
            if t.playerControlled == 1 then
                peeps = peeps + 1
                if inBox(mx, my, 60 * peeps, 670, 40, 40) then
                    iconText, iconPosition, iconOn = t.name, peeps, 1
                    return
                end
            end
        end
    end
    -- 4. minimap (44437)
    local bx, by, bw, bh = miniMapBox()
    if bx and inBox(mx, my, bx, by, bw, bh) then
        mouseOverText = miniMapTxt or ""
        return
    end
    -- 5. allied vehicles (44489-44491): the vehicle card
    for _, v in ipairs(player.deployedVehicles or {}) do
        if v.faction == "allied" and v.id and type(v.x) == "number" and inBox(wx, wy, v.x - 12, v.y - 12, 75, 75) then
            mouseOverId2 = v.id
            return
        end
    end
    -- 6. buildings (44734-44740): fade the nearest roof, this player's own
    local wide = ((player.gainz or 0) < 105 and (player.gainz or 0) > 85) or player.mnb2SubGame == 99
    local reach = wide and 325 or 150
    for _, b in ipairs(player.buildings or {}) do
        if type(b.x) == "number" and inBox(wx, wy, b.x - reach, b.y - reach, reach * 2, reach * 2) then
            pcall(fadeClosestRoof)
            return
        end
    end
    -- 7. found loot and crates (44743-44757): what it is
    for _, l in ipairs(player.lootables or {}) do
        if (tonumber(l.flagged) or 0) >= 1 and type(l.x) == "number" and type(l.name) == "string"
            and inBox(wx, wy, l.x - 25, l.y - 25, 50, 50) then
            local n = l.name
            local text
            if n == "gunCrate" then text = gunCrateTxt
            elseif n == "supplyCrate" then text = supplyCrateTxt
            elseif n == "cargoCrate" then text = cargoCrateTxt
            elseif n:match("^loot_") then text = _G["lootText_" .. n:sub(6)]
            elseif n:match("^side_") then text = _G["weaponText_" .. n:sub(6)] end
            if type(text) == "string" then mouseOverText = text return end
        end
    end
end

-- Client click on the minimap: the game's own minimap button, which only moves
-- this machine's camera (urb_engine.lua:44975-45008). True if it was a minimap click.
function squad.clientMiniMapClick(x, y)
    local bx, by, bw, bh = miniMapBox()
    if not bx or not inBox(x, y, bx, by, bw, bh) or type(miniMapButton) ~= "function" then return false end
    local battle = mnbCoop and mnbCoop.battle
    if battle then battle.localSound = true end
    pcall(miniMapButton)
    if battle then battle.localSound = false end
    return true
end

-- client: a box while dragging, like the game's
function squad.drawClientBox()
    if not press or not love.mouse.isDown(1) then return end
    local mx, my = love.mouse.getPosition()
    love.graphics.push("all")
    love.graphics.origin()
    love.graphics.setColor(0, 150 / 255, 0, 1)
    love.graphics.rectangle("line", press.x, press.y, mx - press.x, my - press.y)
    love.graphics.pop()
end

net.onClientMessage = function(seat, msg) return squad.onClientMessage(seat, msg) end

return squad
