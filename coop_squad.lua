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

local MAX_ORDER_IDS = 40 -- a Classic army can be big
local replaying = false -- the host is running a friend's click through the game's code right now

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

-- true when ownership rules apply right now: watching, or hosting friends in the
-- co-op campaign or in a Classic battle
function squad.active()
    if viewing() then return true end
    if net.role ~= "host" or net.playerCount() <= 1 then return false end
    if mnbCoop and mnbCoop.campaign and mnbCoop.campaign.active then return true end
    return type(player) == "table" and player.gameType == 1
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
    if t.playerControlled == 1 then
        -- Classic: dealt out at the start, or recruited by that player (coopOwner)
        local o = tonumber(t.coopOwner)
        if o and net.seats[o] then return o end
        return 1
    end
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
    if not squad.active() or type(soldier) ~= "table" or soldier.dead ~= 0 then return end
    -- every soldier the players command, hired ones too (they have no coopOwner when the
    -- host hired them or they arrived later: they're the host's, like ownerOf says)
    local seat = squad.ownerOf(soldier)
    if not seat then return end
    local r, g, b = squad.seatColor(seat)
    love.graphics.push("all")
    love.graphics.setLineStyle("smooth")
    love.graphics.setLineWidth(1) -- thin but bright (owner, 2026-11-11: the old one was too faded)
    love.graphics.setColor(r, g, b, seat == squad.mySeat() and 1 or 0.85)
    love.graphics.circle("line", soldier.x, soldier.y, 17, 32)
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
-- (Classic keeps the game's own Ctrl+number groups for the host's soldiers.)
function squad.hostAfterButtonEngine()
    if replaying or not squad.active() or viewing() or type(player) ~= "table" then return end
    local classic = player.gameType == 1
    if classic then squad.dealClassic() end
    local n, me = 0, squad.mySeat()
    for _, t in ipairs(player.deployedTroops or {}) do
        if t.playerControlled == 1 and t.faction == "allied" then
            if squad.ownerOf(t) == me then
                n = n + 1
                if not classic then t.shortcut = n end
            else
                t.shortcut = 0
                if t.selected then t.selected = false end
            end
        end
    end
end

-- Classic: the soldiers a battle starts with are dealt out between the players in
-- turn (host first), once per battle. Later soldiers belong to whoever recruited them.
local dealtList = setmetatable({}, { __mode = "k" })
function squad.dealClassic()
    local troops = player.deployedTroops
    if type(troops) ~= "table" or dealtList[troops] then return end
    dealtList[troops] = true
    local seats = {}
    for s = 1, net.MAX_SEATS or 3 do
        if net.seats[s] then seats[#seats + 1] = s end
    end
    if #seats == 0 then return end
    local k = 0
    for _, t in ipairs(troops) do
        if t.playerControlled == 1 and t.faction == "allied" and t.coopOwner == nil and t.coopSquad ~= 1 then
            k = k + 1
            t.coopOwner = seats[(k - 1) % #seats + 1]
        end
    end
    log("Classic: %d soldiers dealt to %d players", k, #seats)
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

-- the promotion panel's choices (urb_engine.lua:44772-44804)
local SPECS = { "light", "rifle", "gunner", "medic", "comms", "officer", "engy", "scout", "sniper", "commando",
    "sapper", "intel" }
local SPEC_ROW_Y = { 632, 582, 532, 482, 432, 382, 332, 282, 232, 182, 132, 82 }
local IS_SPEC = {}
for _, s in ipairs(SPECS) do IS_SPEC[s] = true end
local UPGRADES = { perkSelect = true, promoSelect = true, weaponSelect = true, skillSelect = true }

-- index in player.deployedTroops of the troop with this id, or nil
local function indexOfId(id)
    local troops = type(player) == "table" and player.deployedTroops
    if type(troops) ~= "table" or id == nil then return nil end
    for i, t in ipairs(troops) do
        if t.id == id then return i end
    end
    return nil
end

-- can soldier t take this promotion choice right now (the panel's own conditions)
local function promoAllowed(t, label)
    if type(t) ~= "table" or t.dead ~= 0 or (tonumber(t.health) or 0) <= 10 then return false end
    if (tonumber(t.promo) or 0) <= 0 or (tonumber(player.landed) or 0) <= 0 then return false end
    local spec = label:match("^specking_(%a+)$")
    if spec then return IS_SPEC[spec] == true and t.spec == "" end
    if not UPGRADES[label] or t.spec == "" or type(t.spec) ~= "string" then return false end
    if label == "perkSelect" then return t.nextPerk ~= nil and t.nextPerk ~= false end
    if label == "promoSelect" then return (tonumber(t.rank) or 3) < 3 end
    if label == "skillSelect" then return (tonumber(t.skillUpgrade) or 3) < 3 end
    -- weaponSelect: the next weapon of that speciality must exist
    local wu = tonumber(t.weaponUpgrade) or 3
    local unlock = type(player.unlock) == "table" and player.unlock[t.spec]
    return wu < 3 and type(unlock) == "table" and unlock[wu + 1] ~= nil
end
squad.promoAllowed = promoAllowed

-- an order from a seated player; returns true if it is a kind we know
function squad.onClientMessage(seat, msg)
    local t = msg.t
    if t ~= "move" and t ~= "promo" and t ~= "skill" and t ~= "halt" and t ~= "altgo" and t ~= "cancel"
        and t ~= "hud" and t ~= "swap" then
        return false
    end
    if type(player) ~= "table" or player.gameState ~= 0 or #queue >= 32 then return true end -- late or flooding
    if t == "hud" then
        local x, y, cx, cy = tonumber(msg.x), tonumber(msg.y), tonumber(msg.cx), tonumber(msg.cy)
        if squad.hudLabelOk(msg.label) and x and y and cx and cy then
            local ids = {}
            if type(msg.ids) == "table" then
                for i = 1, math.min(#msg.ids, MAX_ORDER_IDS) do ids[#ids + 1] = tonumber(msg.ids[i]) end
            end
            local menu = tonumber(msg.menu) or 0
            queue[#queue + 1] = { kind = "hud", seat = seat, label = msg.label, x = x, y = y, cx = cx, cy = cy,
                ids = ids, menu = (menu >= 0 and menu <= 8) and math.floor(menu) or 0 }
        end
    elseif t == "swap" then
        if tonumber(msg.a) and tonumber(msg.b) then
            queue[#queue + 1] = { kind = "swap", seat = seat, a = tonumber(msg.a), b = tonumber(msg.b) }
        end
    elseif t == "promo" then
        if type(msg.label) == "string" and #msg.label < 40 and tonumber(msg.id) then
            queue[#queue + 1] = { kind = "promo", seat = seat, id = tonumber(msg.id), label = msg.label }
        end
    elseif t == "skill" then
        local n = tonumber(msg.n)
        if tonumber(msg.id) and (n == 1 or n == 2 or n == 3) then
            queue[#queue + 1] = { kind = "skill", seat = seat, id = tonumber(msg.id), n = n }
        end
    elseif t == "halt" or t == "altgo" or t == "cancel" then
        queue[#queue + 1] = { kind = t, seat = seat }
    else
        local x, y = tonumber(msg.x), tonumber(msg.y)
        if not x or not y or type(msg.ids) ~= "table" then return true end
        local ids = {}
        for i = 1, math.min(#msg.ids, MAX_ORDER_IDS) do
            local id = tonumber(msg.ids[i])
            if id then ids[#ids + 1] = id end
        end
        queue[#queue + 1] = { seat = seat, ids = ids, x = x, y = y, button = msg.b == 2 and 2 or 1, alt = msg.alt == true }
    end
    return true
end

-- ---------------------------------------------------------------- prompts (host)
-- A skill or an item that wants a map click (smoke, frag, medic bag...) arms the
-- game's mousePrompt/mousePrompter. The host keeps one armed prompt per friend
-- here, never in the globals between frames, so its own prompt is untouched; the
-- friend's next left click fires it (main.lua:4471). The friend is told, so their
-- window shows the game's aiming cursor.
local seatPrompt = {}

local function sendPrompt(seat)
    local p = seatPrompt[seat]
    pcall(net.sendTo, seat, { t = "prompt", p = p and p.p or 0, who = p and p.who or 0 })
end

-- after a replay for `seat`: keep what it armed (or note that it was used)
local function keepPrompt(seat, before)
    local p = tonumber(mousePrompt) or 0
    if p > 0 then
        seatPrompt[seat] = { p = p, who = mousePrompter }
    else
        seatPrompt[seat] = nil
    end
    local now = seatPrompt[seat]
    if (before and before.p) ~= (now and now.p) or (before and before.who) ~= (now and now.who) then sendPrompt(seat) end
end

-- the armed prompt of `seat`, if its soldier is still theirs and standing
local function armedPrompt(seat)
    local p = seatPrompt[seat]
    if not p then return nil end
    local i = indexOfId(p.who)
    local t = i and player.deployedTroops[i]
    if not t or squad.ownerOf(t) ~= seat or t.dead ~= 0 then
        seatPrompt[seat] = nil
        sendPrompt(seat)
        return nil
    end
    return p
end

-- a player left or the battle ended
function squad.forgetSeat(seat)
    if seat then seatPrompt[seat] = nil else seatPrompt = {} end
end

-- Runs a friend's move: their soldiers selected, everything else as if nothing
-- was on screen but the found loot and crates, then the game's own left-click
-- release at that point (with the mouse there too: the loot buttons and the
-- crate handlers read love.mouse, Button.new urb_engine.lua:134-137, 7595).
-- (the panel globals too: the game's move closes the open promotion/skill panel,
-- main.lua:6850-6852, and that must not close the host's own)
local SAVED_GLOBALS = { "buttons", "mousePrompt", "mousePrompter", "mousePromptLock", "iconOn", "altMove",
    "selectionX", "selectionY", "selecting", "mouseOverIconId", "mouseDropIconId", "dragingIcon", "buttoned",
    "justClicked", "specID", "specDisplay", "skillDisplay", "abilityDisplay" }

-- the game's loot and crate buttons (urb_engine.lua:44743-44757), world space
local function lootButtons()
    local out = {}
    if type(Button) ~= "table" or type(Button.new) ~= "function" then return out end
    for _, l in ipairs(player.lootables or {}) do
        local n = l.name
        if (tonumber(l.flagged) or 0) >= 1 and type(n) == "string" and type(l.x) == "number" then
            local label
            if n == "gunCrate" then
                label = "gunCratez"
            elseif n == "supplyCrate" then
                label = "supplyCratez"
            elseif n == "cargoCrate" then
                label = "cargoCratez"
            elseif n:match("^loot_") then
                label = "lootClick"
            elseif n:match("^side_") then
                label = "lootCratez"
            end
            if label then out[#out + 1] = Button.new(l.x - 25, l.y - 25, 50, 50, label, "active", true, "") end
        end
    end
    return out
end
squad.lootButtons = lootButtons

-- runs fn with love.mouse reporting (sx, sy)
local function withMouseAt(sx, sy, fn, ...)
    local m = love.mouse
    local gp, gx, gy = m.getPosition, m.getX, m.getY
    m.getPosition = function() return sx, sy end
    m.getX = function() return sx end
    m.getY = function() return sy end
    local ok, err = pcall(fn, ...)
    m.getPosition, m.getX, m.getY = gp, gx, gy
    return ok, err
end

local function runMove(o)
    local troops = player.deployedTroops
    local mine = {}
    for _, id in ipairs(o.ids) do
        local i = convertedId(id)
        local t = i and i > 0 and troops[i]
        if t and squad.ownerOf(t) == o.seat and canSelect(t) then mine[t] = true end
    end
    -- left click: an armed prompt fires (no selection needed); right click: items,
    -- or a howitzer/M20 under the mouse (no selection needed either)
    -- (a right click leaves an armed prompt armed, as in the game)
    local armed = armedPrompt(o.seat)
    if not next(mine) and not (armed and o.button == 1) and o.button ~= 2 then return end
    local savedSel, savedVeh = {}, {}
    for _, t in ipairs(troops) do
        savedSel[t] = t.selected
        t.selected = mine[t] and true or false
    end
    for _, v in ipairs(player.deployedVehicles or {}) do
        savedVeh[v] = v.selected
        v.selected = false
    end
    local g = {}
    for _, name in ipairs(SAVED_GLOBALS) do g[name] = _G[name] end
    buttons, mousePromptLock, iconOn = lootButtons(), 0, 0
    mousePrompt, mousePrompter = armed and armed.p or 0, armed and armed.who or 0
    altMove = o.alt and 1 or 0 -- Alt held: a waypoint, sent on the friend's Alt release
    mouseOverIconId, mouseDropIconId, dragingIcon = 0, 0, 0
    local sx, sy = o.x - (player.screenx or 0), o.y - (player.screeny or 0)
    selectionX, selectionY = sx, sy
    local before = seatPrompt[o.seat]
    local ok, err = withMouseAt(sx, sy, gameRelease, sx, sy, o.button or 1)
    keepPrompt(o.seat, before)
    for _, name in ipairs(SAVED_GLOBALS) do _G[name] = g[name] end
    for t, s in pairs(savedSel) do if not mine[t] then t.selected = s end end
    for v, s in pairs(savedVeh) do v.selected = s end
    if not ok then print("[mnb_coop] friend's move: " .. tostring(err)) end
    log("seat %d moved %d soldier(s)", o.seat, #o.ids)
end

-- A friend's promotion choice for one of their soldiers: the game's own panel
-- button (specClick / perkSelectButton...), with specID pointing at him. The
-- host's own panel, if open, is left as it was.
local PANEL_GLOBALS = { "specID", "specDisplay", "skillDisplay", "abilityDisplay", "buttoned" }

local function runPromo(o)
    local i = indexOfId(o.id)
    local t = i and player.deployedTroops[i]
    if not t or squad.ownerOf(t) ~= o.seat or not promoAllowed(t, o.label) then
        log("seat %d promotion %s refused", o.seat, tostring(o.label))
        return
    end
    local g = {}
    for _, name in ipairs(PANEL_GLOBALS) do g[name] = _G[name] end
    specID = o.id
    local spec = o.label:match("^specking_(%a+)$")
    local ok, err
    if spec then
        ok, err = pcall(specClick, spec)
    else
        ok, err = pcall(_G[o.label .. "Button"])
    end
    for _, name in ipairs(PANEL_GLOBALS) do _G[name] = g[name] end
    if not ok then print("[mnb_coop] friend's promotion: " .. tostring(err)) end
    log("seat %d promoted %s: %s", o.seat, tostring(t.name), o.label)
end

-- A friend's soldier skill (the face panel's skill_1..3): the game's skillClick
-- with specID pointing at him. Skills that act at once are done; skills that want
-- a map click arm that friend's prompt.
local SKILL_GLOBALS = { "specID", "specDisplay", "skillDisplay", "abilityDisplay", "buttoned", "mousePrompt",
    "mousePrompter", "mousePromptLock" }

local function runSkill(o)
    local i = indexOfId(o.id)
    local t = i and player.deployedTroops[i]
    if not t or squad.ownerOf(t) ~= o.seat or t.dead ~= 0 or (tonumber(t.health) or 0) <= 10
        or (tonumber(t.skillUpgrade) or 0) < o.n or (tonumber(player.landed) or 0) <= 0
        or type(skillClick) ~= "function" then
        log("seat %d skill %d refused", o.seat, o.n)
        return
    end
    local g = {}
    for _, name in ipairs(SKILL_GLOBALS) do g[name] = _G[name] end
    specID, mousePrompt, mousePrompter = o.id, 0, 0
    local before = seatPrompt[o.seat]
    local ok, err = pcall(skillClick, o.n)
    if (tonumber(mousePrompt) or 0) > 0 then
        keepPrompt(o.seat, before) -- a new prompt replaces the one they had armed
    end
    for _, name in ipairs(SKILL_GLOBALS) do _G[name] = g[name] end
    if not ok then print("[mnb_coop] friend's skill: " .. tostring(err)) end
    log("seat %d used skill %d of %s", o.seat, o.n, tostring(t.name))
end

-- Runs fn with only `seat`'s soldiers counted as player-controlled: the game's
-- H (halt every soldier, main.lua:8516) then halts just that player's.
function squad.withOnly(seat, fn, ...)
    local hidden = {}
    for _, t in ipairs(player.deployedTroops or {}) do
        if t.playerControlled == 1 and squad.ownerOf(t) ~= seat then hidden[#hidden + 1] = t end
    end
    for _, t in ipairs(hidden) do t.playerControlled = 0 end
    local ok, err = pcall(fn, ...)
    for _, t in ipairs(hidden) do t.playerControlled = 1 end
    if not ok then print("[mnb_coop] " .. tostring(err)) end
end

-- Runs the game's Alt release (main.lua:8535: every allied soldier with a waypoint
-- sets off) for `seat`'s waypoints only; the others keep theirs for their own release.
function squad.withOwnWaypoints(seat, fn, ...)
    local held = {}
    for _, t in ipairs(player.deployedTroops or {}) do
        local owner = squad.ownerOf(t)
        if owner and owner ~= seat and (tonumber(t.altx) or 0) ~= 0 then
            held[#held + 1] = { t = t, x = t.altx, y = t.alty }
            t.altx, t.alty = 0, 0
        end
    end
    local ok, err = pcall(fn, ...)
    for _, h in ipairs(held) do h.t.altx, h.t.alty = h.x, h.y end
    if not ok then print("[mnb_coop] " .. tostring(err)) end
end

local gamePressed, gameReleased = nil, nil -- the game's love.keypressed / keyreleased (set by mnb_coop_main)
function squad.setGameKeys(pressed, released) gamePressed, gameReleased = pressed, released end

local function runKey(o)
    if o.kind == "halt" and gamePressed then
        squad.withOnly(o.seat, gamePressed, "h")
    elseif o.kind == "altgo" and gameReleased then
        local keep = altMove -- the host may be holding its own Alt
        squad.withOwnWaypoints(o.seat, gameReleased, "lalt")
        altMove = keep
    elseif o.kind == "cancel" then
        if seatPrompt[o.seat] then
            seatPrompt[o.seat] = nil
            sendPrompt(o.seat)
        end
    end
end

-- ---------------------------------------------------------------- HUD buttons
-- The bottom-right battle buttons: command abilities (playerSkill_), and in Classic
-- the reinforcement/command/radio/build/gear/item/vehicle/upgrade menus, trench
-- buttons, directives and the broom. Opening and closing a menu is the friend's own
-- business (their window); a button that does something comes to the host as
-- `hud {label, x, y, cx, cy, ids, menu}` and runs there as the game's own click.

-- buttons that only change what the clicking player's own HUD shows
local HUD_LOCAL = { mnb2Reinf = true, mnb2Command = true, mnb2Radio = true, mnb2Build = true, mnb2Gear = true,
    mnb2Item = true, mnb2Vehicles = true, mnb2Upgrades = true, mnb2Back = true, directiveMenu = true }
squad.HUD_LOCAL = HUD_LOCAL

-- buttons that end the battle or order the WHOLE team around: the host's call only.
-- mnb2Retreat ends the battle (ui_squadLostFade, mnb2.lua:2163), trenchRetreatz sets
-- mnb2Miss = 10 (trench.lua:581), trenchUp/trenchRetreat move every allied soldier
-- (trench.lua:560, 603) with no owner check.
local HUD_HOST_ONLY = { mnb2Retreat = true, trenchRetreatz = true, trenchUp = true, trenchRetreat = true }
squad.HUD_HOST_ONLY = HUD_HOST_ONLY

function squad.isHudLabel(label)
    if type(label) ~= "string" then return false end
    return label:match("^mnb2") ~= nil or label:match("^trench") ~= nil or label:match("^playerSkill_%d+$") ~= nil
        or label:match("^directive") ~= nil or label:match("^myDirectives_%d+$") ~= nil
        or label == "broomer" or label == "noSkillTrench"
end

-- a HUD button a friend may have the host run
function squad.hudLabelOk(label)
    if type(label) ~= "string" or #label > 40 or not label:match("^[%w_]+$") or HUD_LOCAL[label] then return false end
    if HUD_HOST_ONLY[label] then return false end
    if not squad.isHudLabel(label) then return false end
    for _, prefix in ipairs({ "playerSkill_", "trenchAbility_", "directiveOffer_", "myDirectives_" }) do
        if label:sub(1, #prefix) == prefix then return label:sub(#prefix + 1):match("^%d+$") ~= nil end
    end
    return type(rawget(_G, label .. "Button")) == "function"
end

local HUD_GLOBALS = { "mnb2MenuDisplay", "mnb2MouseOver", "trenchMouseOver", "buttonFade", "mouseOverText",
    "contextualText", "redText" }

-- Runs a friend's HUD click: their selection, their menu page, their camera and
-- their mouse point for one call of the game's own button dispatch (Button.new's
-- click, urb_engine.lua:134), then everything back as the host had it. Soldiers
-- the click brings in (reinforcements) are theirs.
local function runHud(o)
    if type(Button) ~= "table" or type(Button.new) ~= "function" then return end
    local troops = player.deployedTroops
    local mine = {}
    for _, id in ipairs(o.ids) do
        local i = indexOfId(id)
        local t = i and troops[i]
        if t and squad.ownerOf(t) == o.seat and canSelect(t) then mine[t] = true end
    end
    local savedSel, savedVeh = {}, {}
    for _, t in ipairs(troops) do
        savedSel[t] = t.selected
        t.selected = mine[t] and true or false
    end
    for _, v in ipairs(player.deployedVehicles or {}) do
        savedVeh[v] = v.selected
        v.selected = false
    end
    local g = {}
    for _, name in ipairs(SAVED_GLOBALS) do g[name] = _G[name] end
    for _, name in ipairs(HUD_GLOBALS) do g[name] = _G[name] end
    local cam = { player.screenx, player.screeny, player.masterScreenx, player.masterScreeny }
    local armed = armedPrompt(o.seat)
    local before = seatPrompt[o.seat]
    mousePrompt, mousePrompter, mousePromptLock = armed and armed.p or 0, armed and armed.who or 0, 0
    mnb2MenuDisplay, buttoned, iconOn = o.menu, 0, 0
    player.screenx, player.screeny = o.cx, o.cy
    local count = #troops
    replaying = true
    local ok, err = withMouseAt(o.x, o.y, function()
        local b = Button.new(-1e9, -1e9, 2e9, 2e9, o.label, "active", true, "")
        b.click(o.label)
    end)
    replaying = false
    player.screenx, player.screeny, player.masterScreenx, player.masterScreeny = cam[1], cam[2], cam[3], cam[4]
    -- soldiers that arrived with this click are the friend's
    for i = count + 1, #troops do
        local t = troops[i]
        if t.playerControlled == 1 and t.faction == "allied" and t.coopOwner == nil and t.coopSquad ~= 1 then
            t.coopOwner = o.seat
        end
    end
    keepPrompt(o.seat, before)
    pcall(net.sendTo, o.seat, { t = "ui", m = tonumber(mnb2MenuDisplay) or 0 })
    for _, name in ipairs(SAVED_GLOBALS) do _G[name] = g[name] end
    for _, name in ipairs(HUD_GLOBALS) do _G[name] = g[name] end
    for t, s in pairs(savedSel) do if not mine[t] then t.selected = s end end
    for t in pairs(mine) do t.selected = false end
    for v, s in pairs(savedVeh) do v.selected = s end
    if not ok then print("[mnb_coop] friend's button: " .. tostring(err)) end
    log("seat %d pressed %s", o.seat, o.label)
end

-- A friend drags one of their faces onto another of theirs: the two swap places
-- in the face bar, like the game's drop (main.lua:6908-6912).
local function runSwap(o)
    local troops = player.deployedTroops
    local i, j = indexOfId(o.a), indexOfId(o.b)
    if not i or not j or i == j then return end
    local a, b = troops[i], troops[j]
    if a.playerControlled ~= 1 or b.playerControlled ~= 1 then return end
    if squad.ownerOf(a) ~= o.seat or squad.ownerOf(b) ~= o.seat then return end
    troops[i], troops[j] = b, a
    pcall(function()
        local c = iconGood:clone()
        c:setPitch((90 + randNbr(10)) / 100)
        c:play()
    end)
    log("seat %d swapped faces %d and %d", o.seat, i, j)
end

-- Host, at the start of its frame (before the game's update).
function squad.hostRunOrders()
    if type(player) ~= "table" or player.gameState ~= 0 then
        if next(seatPrompt) then seatPrompt = {} end -- prompts end with the battle
    end
    if #queue == 0 then return end
    local list = queue
    queue = {}
    if not gameRelease or type(player) ~= "table" or player.gameState ~= 0 or pause ~= 0 then return end
    for _, o in ipairs(list) do
        if o.kind == "promo" then
            runPromo(o)
        elseif o.kind == "skill" then
            runSkill(o)
        elseif o.kind == "hud" then
            runHud(o)
        elseif o.kind == "swap" then
            runSwap(o)
        elseif o.kind then
            runKey(o)
        else
            runMove(o)
        end
    end
end

-- Host: a face click opens the promotion panel and selects the soldier
-- (iconClick, urb_engine.lua:2606). Not for a friend's soldier: they choose.
function squad.wrapIconClick(orig)
    return function(idz, ...)
        if squad.active() and not viewing() then
            local i = indexOfId(idz)
            local t = i and player.deployedTroops[i]
            if t and not isMine(t) then return end
        end
        return orig(idz, ...)
    end
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
    if key == "h" then -- halt: your own soldiers stop (main.lua:8516)
        net.sendToHost({ t = "halt" })
        return true
    end
    if key == "backspace" then -- the game's cancel: armed skill off, panel shut, selection dropped (main.lua:7813)
        if (tonumber(mousePrompt) or 0) > 0 then net.sendToHost({ t = "cancel" }) end
        mousePrompt = 0
        squad.closePanel()
        clearSelection()
        return true
    end
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

-- the troop whose face is under a screen point, or nil
local function faceAt(x, y)
    if showFaces ~= 1 or type(player) ~= "table" or player.gameType == 1 then return nil end
    local peeps = 0
    for _, t in ipairs(player.deployedTroops or {}) do
        if t.playerControlled == 1 then
            peeps = peeps + 1
            if x > 60 * peeps and x < 60 * peeps + 40 and y > 670 and y < 710 then return t end -- the face's button
        end
    end
    return nil
end

local drag = nil -- the face a friend is dragging (right mouse), like the game's dragingIcon

function squad.clientMousepressed(x, y, button)
    if button == 1 then press = { x = x, y = y } end
    if button == 2 then
        local t = faceAt(x, y)
        drag = t and isMine(t) and t.id or nil
    end
end

-- right mouse released over a face: swap the dragged face with it if both are yours
local function clientDrop(x, y)
    local from = drag
    drag = nil
    local t = faceAt(x, y)
    if t and isMine(t) and t.id ~= from then
        net.sendToHost({ t = "swap", a = from, b = t.id })
    else
        pcall(function() iconBad:clone():play() end) -- the game's "can't"
    end
end

local function selectedIds()
    local ids = {}
    for _, t in ipairs(mineSelectable()) do
        if t.selected and t.id then ids[#ids + 1] = t.id end
    end
    return ids
end

local function altHeld()
    return love.keyboard.isDown("lalt") or love.keyboard.isDown("ralt")
end

-- Right click (main.lua:6901-7763): your selected soldiers use what they carry at
-- that point (molotov, faust, mines, medic bag...), or a howitzer/M20 there is used.
local function clientRightClick(x, y)
    if showFaces == 1 and y >= 670 and y <= 710 then return end -- the face bar: drags are your own business
    local ox, oy = player.screenx or 0, player.screeny or 0
    net.sendToHost({ t = "move", b = 2, ids = selectedIds(), x = x + ox, y = y + oy })
end

function squad.clientMousereleased(x, y, button)
    if button == 2 and type(player) == "table" and player.gameState == 0 then
        if drag then
            clientDrop(x, y)
        else
            clientRightClick(x, y)
        end
        return
    end
    if button ~= 1 or not press then return end
    if type(player) ~= "table" or player.gameState ~= 0 then
        press = nil
        return
    end                                                                             -- mission-end page: nothing to order
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
    if squad.clientHudClick(x, y) then return end
    if squad.clientPanelClick(x, y) then return end
    if squad.clientFaceClick(x, y) then return end
    local wx, wy = x + ox, y + oy
    -- a skill or item is armed: this click is its target (the host fires it)
    if (tonumber(mousePrompt) or 0) > 0 then
        net.sendToHost({ t = "move", ids = selectedIds(), x = wx, y = wy })
        return
    end
    -- a click on one of your soldiers selects him
    for _, t in ipairs(mineSelectable()) do
        if (t.x - wx) ^ 2 + (t.y - wy) ^ 2 <= 15 * 15 then
            if not shift() then clearSelection() end
            t.selected = true
            return
        end
    end
    -- otherwise: move the selected ones there (Alt held: a waypoint, they go on Alt release)
    local ids = selectedIds()
    if #ids == 0 then return end
    net.sendToHost({ t = "move", ids = ids, x = wx, y = wy, alt = altHeld() or nil })
    clearSelection() -- the game also drops the selection after a move order
end

-- ---------------------------------------------------------------- HUD (client)
-- The friend's window runs the game's own HUD pass (buttonEngine) on the mirror to
-- know where its buttons are and what their tooltips say, with the game's random
-- battle chatter part skipped (soundCpt) and sounds muted as always while watching.
local gameButtonEngine = nil
function squad.setGameButtonEngine(fn) gameButtonEngine = fn end
squad.hudButtons = {}

function squad.clientHud()
    squad.hudButtons = {}
    if type(gameButtonEngine) ~= "function" or type(player) ~= "table" or player.gameState ~= 0 then return end
    local sc, bc = soundCpt, butCpt
    soundCpt, butCpt = -1e9, 1 -- build the buttons now, no chatter or ambient sounds
    local ok, err = pcall(gameButtonEngine, 0)
    soundCpt, butCpt = sc, bc
    if not ok then
        log("HUD pass: %s", tostring(err))
        return
    end
    for _, b in ipairs(type(buttons) == "table" and buttons or {}) do
        if type(b) == "table" and squad.isHudLabel(b.label) then squad.hudButtons[#squad.hudButtons + 1] = b end
    end
end

-- the HUD buttons under a screen point (the game clicks every one under the mouse)
local function hudHits(x, y)
    local out = {}
    local wx, wy = x + (player.screenx or 0), y + (player.screeny or 0)
    for _, b in ipairs(squad.hudButtons) do
        if wx > b.X and wx < b.X + b.width and wy > b.Y and wy < b.Y + b.height then out[#out + 1] = b end
    end
    return out
end
squad.hudHits = hudHits

-- Client click on the HUD: menu pages open here, everything else goes to the host.
function squad.clientHudClick(x, y)
    local hits = hudHits(x, y)
    if #hits == 0 then return false end
    for _, b in ipairs(hits) do
        if HUD_LOCAL[b.label] then
            local fn = rawget(_G, b.label .. "Button")
            local battle = mnbCoop and mnbCoop.battle
            if battle then battle.localSound = true end
            if type(fn) == "function" then pcall(fn) end
            if battle then battle.localSound = false end
        elseif HUD_HOST_ONLY[b.label] then
            -- ends the battle or orders everyone: the host's call
            local battle = mnbCoop and mnbCoop.battle
            if battle then battle.localSound = true end
            pcall(function() poop:clone():play() end)
            pcall(anounceStuff, "Only the host can order that")
            if battle then battle.localSound = false end
        else
            net.sendToHost({ t = "hud", label = b.label, x = x, y = y, cx = player.screenx or 0, cy = player.screeny or 0,
                ids = selectedIds(), menu = tonumber(mnb2MenuDisplay) or 0 })
        end
    end
    return true
end

-- Host → this friend: their HUD menu page after a button (some buttons close it)
function squad.onUi(msg)
    mnb2MenuDisplay = tonumber(msg.m) or 0
end

-- Host → this friend: their armed prompt (0 = none). The game draws its aiming
-- cursor from mousePrompt/mousePrompter (drawFiles.lua), on the mirror.
function squad.onPrompt(msg)
    mousePrompt = tonumber(msg.p) or 0
    mousePrompter = tonumber(msg.who) or 0
    mousePromptLock = 0
end

-- Client key release: Alt sends the waypoints off, like the game's (main.lua:8535)
function squad.clientKeyreleased(key)
    if key == "lalt" or key == "ralt" then
        net.sendToHost({ t = "altgo" })
        return true
    end
    return false
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
    -- 0. the promotion panel: the game's hover loop lets the last button win,
    -- and the panel's buttons come last (urb_engine.lua:44763, 44844-44851)
    squad.checkPanel()
    for _, b in ipairs(squad.panelButtons()) do
        if inBox(mx, my, b[2], b[3], b[4], b[5]) then
            mouseOverText = type(b[6]) == "string" and b[6] or ""
            return
        end
    end
    -- 0b. HUD buttons: the game's tooltip (Classic menu buttons show theirs through
    -- mnb2MouseOver, which the game's HUD pass has just set)
    local hud = squad.hudHits(mx, my)[1]
    if hud then
        if not tostring(hud.label):match("^mnb2") then mouseOverText = hud.mouseOverText or "" end
        return
    end
    mnb2MouseOver, trenchMouseOver = "", 0
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
            if n == "gunCrate" then
                text = gunCrateTxt
            elseif n == "supplyCrate" then
                text = supplyCrateTxt
            elseif n == "cargoCrate" then
                text = cargoCrateTxt
            elseif n:match("^loot_") then
                text = _G["lootText_" .. n:sub(6)]
            elseif n:match("^side_") then
                text = _G["weaponText_" .. n:sub(6)]
            end
            if type(text) == "string" then
                mouseOverText = text
                return
            end
        end
    end
end

-- ---------------------------------------------------------------- promotions (client)
-- The friend opens the game's promotion panel for their own soldier on their
-- mirror (the game draws it from specID/specDisplay/skillDisplay); a choice goes
-- to the host as a "promo" order, which runs the game's own button there.

-- face bar position (1, 2, ...) of the troop at index i
local function facePosition(i)
    local peeps = 0
    for v = 1, i do
        if player.deployedTroops[v].playerControlled == 1 then peeps = peeps + 1 end
    end
    return peeps
end

local function closePanel()
    specID, specDisplay, skillDisplay, abilityDisplay = -99, 0, 0, 0
end
squad.closePanel = closePanel

-- the open panel's buttons in screen space: { label, x, y, w, h, tip }
-- (same boxes as the game's, urb_engine.lua:44763-44804, without the camera)
function squad.panelButtons()
    local out = {}
    if specDisplay ~= 1 and skillDisplay ~= 1 and abilityDisplay ~= 1 then return out end
    local i = indexOfId(specID)
    local t = i and player.deployedTroops[i]
    if not t then return out end
    local peeps = facePosition(i)
    if abilityDisplay == 1 and specDisplay ~= 1 and skillDisplay ~= 1 then
        -- skills (urb_engine.lua:44818-44838): the skill's text, or the time left
        local up = tonumber(t.skillUpgrade) or 0
        for _, s in ipairs({ { 3, 400, 50 }, { 2, 510, 45 }, { 1, 610, 45 } }) do
            local n = s[1]
            if up >= n then
                local timer = tonumber(t["skill" .. n .. "Timer"]) or 0
                local tip
                if timer <= 0 then
                    tip = _G[tostring(t.spec) .. "_skillText_" .. n]
                else
                    local ok, txt = pcall(tellTime, timer)
                    tip = ok and txt or nil
                end
                out[#out + 1] = { "skill_" .. n, peeps * 60, s[2], 45, s[3], tip }
            end
        end
        return out
    end
    if specDisplay == 1 then
        for k, s in ipairs(SPECS) do
            local x = peeps * 60 - 3 + 25 - (s == "rifle" and 0 or 1) - 15
            local tip = _G["mouseOver" .. s:sub(1, 1):upper() .. s:sub(2) .. "Spec"]
            out[#out + 1] = { "specking_" .. s, x, SPEC_ROW_Y[k] - 15, 30, 30, tip }
        end
        return out
    end
    local function text(fn)
        local ok, name = pcall(fn)
        return ok and type(name) == "string" and _G[name] or nil
    end
    local x = peeps * 60
    if t.nextPerk then out[#out + 1] = { "perkSelect", x, 310, 45, 45, _G["perkText" .. tostring(t.nextPerk)] } end
    if (tonumber(t.skillUpgrade) or 3) < 3 then out[#out + 1] = { "skillSelect", x, 610, 45, 45, text(skillTextSelector) } end
    if (tonumber(t.weaponUpgrade) or 3) < 3 then out[#out + 1] = { "weaponSelect", x, 510, 45, 45, text(weaponTextSelector) } end
    if (tonumber(t.rank) or 3) < 3 then out[#out + 1] = { "promoSelect", x, 410, 45, 45, text(rankTextSelector) } end
    return out
end

-- Client: a click on the open panel sends that choice. True if it hit the panel.
function squad.clientPanelClick(x, y)
    for _, b in ipairs(squad.panelButtons()) do
        if inBox(x, y, b[2], b[3], b[4], b[5]) then
            local i = indexOfId(specID)
            local t = i and player.deployedTroops[i]
            local n = tonumber(b[1]:match("^skill_(%d)$"))
            if t and isMine(t) and n then
                net.sendToHost({ t = "skill", id = specID, n = n })
            elseif t and isMine(t) and promoAllowed(t, b[1]) then
                net.sendToHost({ t = "promo", id = specID, label = b[1] })
            end
            closePanel()
            return true
        end
    end
    return false
end

-- Client: a click in the face bar. Your own soldier: selected, and his
-- promotion panel opens like the game's iconClick (urb_engine.lua:2606-2645).
-- Anyone else's face: nothing. True if the click was on a face (no move order).
function squad.clientFaceClick(x, y)
    if showFaces ~= 1 or player.gameType == 1 then return false end
    local peeps = 0
    for _, t in ipairs(player.deployedTroops) do
        if t.playerControlled == 1 then
            peeps = peeps + 1
            if inBox(x, y, 60 * peeps, 670, 40, 40) then
                if isMine(t) and (tonumber(player.landed) or 0) > 0 then
                    closePanel()
                    if (tonumber(t.promo) or 0) > 0 then
                        if t.spec == "" then specDisplay = 1 else skillDisplay = 1 end
                        specID = t.id
                    elseif (tonumber(t.skillUpgrade) or 0) > 0 then
                        abilityDisplay = 1
                        specID = t.id
                    end
                    if not shift() then clearSelection() end
                    if canSelect(t) then t.selected = true end
                end
                return true
            end
        end
    end
    return false
end

-- Client, every frame: the panel closes once its soldier has nothing left to pick
function squad.checkPanel()
    local promoPanel = specDisplay == 1 or skillDisplay == 1
    if not promoPanel and abilityDisplay ~= 1 then return end
    local i = indexOfId(specID)
    local t = i and player.deployedTroops[i]
    local left = promoPanel and (tonumber(t and t.promo) or 0) or (tonumber(t and t.skillUpgrade) or 0)
    if not t or not isMine(t) or t.dead ~= 0 or left <= 0 then closePanel() end
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
    local mx, my = love.mouse.getPosition()
    if drag and love.mouse.isDown(2) then
        -- the dragged face: a frame in your colour under the mouse
        local r, g, b = squad.seatColor(squad.mySeat())
        love.graphics.push("all")
        love.graphics.origin()
        love.graphics.setLineWidth(2)
        love.graphics.setColor(r, g, b, 0.8)
        love.graphics.rectangle("line", mx - 20, my - 20, 40, 40, 2)
        love.graphics.pop()
    end
    if not press or not love.mouse.isDown(1) then return end
    love.graphics.push("all")
    love.graphics.origin()
    love.graphics.setColor(0, 150 / 255, 0, 1)
    love.graphics.rectangle("line", press.x, press.y, mx - press.x, my - press.y)
    love.graphics.pop()
end


return squad
