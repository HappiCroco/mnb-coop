-- =============================================================================
-- CO-OP DEFENSE (owner's design, 2026-11-11): Classic, but the squad starts in the
-- MIDDLE of the map around a radar, and the waves come from BOTH sides. A German
-- who gets near the radar scores against the players (the game's "miss": an iron
-- cross on the HUD, ten of them end the battle).
--
-- Built on the game's own Classic code, nothing copied:
--   * preMNB2Admin (mnb2.lua:2) sets the battle up; afterwards the squad, the camera
--     and the radar are moved to the middle (afterSetup);
--   * spawnMNB2Wave (mnb2.lua:408) makes each wave to the right of the players;
--     every other German of it is mirrored to the left flank (wrapWave);
--   * the Classic German AI (axisAI2's Classic branch, urb_engine.lua:17793) only
--     uses moveForward / axisAdvance / axisInFront / axisRetreat for direction
--     (urb_engine.lua:19049-19314). For Germans of the left side ("L") these run
--     mirrored: forward is to the right. Everything else (cover, shooting) is
--     direction-free and stays the game's;
--   * the game counts a miss when a German passes x < 300 (urb_engine.lua:6569);
--     here a miss is a German near the radar (RADIUS) or through its line to the
--     other side, and he is sent back to his own side.
-- Vehicles all keep coming from the right (their AI has hard left-facing rules,
-- ai.lua:3403); infantry, paratroopers and the rest come from both sides.
-- Active only for a Classic battle started from the CO-OP CLASSIC tile.
-- =============================================================================
local net = require("includes/mods/mnb_coop/coop_net")

local defense = {}

defense.RADIUS = 130     -- how close to the radar counts as reaching it (radar itself: 30)
defense.LEFT_EDGE = 400  -- left Germans stay right of this (the game's own miss line is 300)
defense.armed = false    -- the co-op Classic tile was just clicked
defense.wanted = false   -- this Classic session came from the co-op tile
defense.on = false       -- this battle is laid out as a defense
defense.radarX, defense.radarY = 6300, 360
defense.flip = 0

-- Classic sub-modes that get the middle layout: the plain ones, not para (7),
-- trench (8, 10) or the special events (99)
local ALLOWED = { [0] = true, [1] = true, [2] = true, [3] = true, [4] = true, [5] = true, [6] = true, [9] = true }

local function log(fmt, ...)
    if net.isOn("debug", false) then print("[mnb_coop] " .. string.format(fmt, ...)) end
end

function defense.active()
    return defense.on and type(player) == "table" and player.gameType == 1 and player.gameState == 0
end

-- The radar uses its own placeable names (pictures borrowed from the game's radar,
-- main.lua:1495-1497) so the game's radar rules (alliedEw, wave-end reveal,
-- capture, destruction) don't apply to the objective. Every machine needs the
-- names to draw it (drawFiles.lua:195 draws _G[placeable.name]).
function defense.aliasSprites()
    if rawget(_G, "coopRadar") == nil and rawget(_G, "radarBase") ~= nil then coopRadar = radarBase end
    if rawget(_G, "coopRadarTop") == nil and rawget(_G, "radarTop") ~= nil then coopRadarTop = radarTop end
end

local function isGerman(t)
    return type(t) == "table" and t.faction == "axis" and type(t.x) == "number"
end

local function counts(t)
    return isGerman(t) and t.tag ~= "jager" and t.tag ~= "zombie"
end

local function isLeft(t)
    return defense.active() and type(t) == "table" and t.coopSide == "L"
end

-- the players' soldiers' span (west-most and east-most x), or the radar
local function alliedSpan()
    local lo, hi
    for _, t in ipairs(player.deployedTroops or {}) do
        if t.faction == "allied" and t.playerControlled == 1 and (t.dead or 0) == 0 and type(t.x) == "number" then
            lo = math.min(lo or t.x, t.x)
            hi = math.max(hi or t.x, t.x)
        end
    end
    return lo or defense.radarX, hi or defense.radarX
end

local function sendLeft(t, x)
    t.coopSide = "L"
    t.x, t.targetx = x, x
    if type(t.trenchHome) == "number" then t.trenchHome = x end
end

-- ---------------------------------------------------------------- the clearing
-- Owner's rule: the ground around the radar is cleared, so the defenders have an
-- open position. Map lists from createMNB2Map (mapBuild.lua:1362): trees (forest),
-- rocks, placeables (bushes, wire, crates, sandbags...), leaves, mines (mineField),
-- ground patches (groundType: mud, water, floors) and deco. A building that reaches
-- into the clearing goes whole, with its walls, floor and roof pieces around it
-- (they sit in placeables/groundType/deco within its radius). Roads, the ground
-- texture (bgPatch) and loot stay.
defense.CLEAR_RADIUS = 260
local CLEAR_LISTS = { "forest", "rocks", "placeables", "leaves", "mineField", "groundType", "deco" }

local function within(e, x, y, r)
    return type(e) == "table" and type(e.x) == "number" and type(e.y) == "number"
        and (e.x - x) ^ 2 + (e.y - y) ^ 2 < r * r
end

local function removeWhere(list, keep)
    if type(list) ~= "table" then return 0 end
    local n = 0
    for i = #list, 1, -1 do
        if not keep(list[i]) then
            table.remove(list, i)
            n = n + 1
        end
    end
    return n
end

function defense.clearAround(cx, cy, r)
    local spots = { { cx, cy, r } } -- areas to empty: the clearing, plus each building that reaches into it
    local nb = removeWhere(player.buildings, function(b)
        if type(b) ~= "table" or type(b.x) ~= "number" then return true end
        local br = tonumber(b.radius) or 200
        if within(b, cx, cy, r + br) then
            spots[#spots + 1] = { b.x, b.y, br }
            return false
        end
        return true
    end)
    local n = 0
    for _, name in ipairs(CLEAR_LISTS) do
        local gone = removeWhere(player[name], function(e)
            if type(e) == "table" and (e.name == "coopRadar" or e.name == "coopRadarTop") then return true end
            for _, s in ipairs(spots) do
                if within(e, s[1], s[2], s[3]) then return false end
            end
            return true
        end)
        -- the map's deco is counted in decoStart (mnb2.lua:257); the game trims only
        -- what comes after it (battle mess, urb_engine.lua:6171), so keep the count true
        if name == "deco" and tonumber(player.decoStart) then
            player.decoStart = math.max(0, player.decoStart - gone)
        end
        n = n + gone
    end
    log("defense: cleared %d things and %d buildings around the radar", n, nb)
    return n, nb
end

-- ---------------------------------------------------------------- setup
-- After the game's preMNB2Admin: squad in a ring around the radar in the middle,
-- camera there, the ground around it cleared, radar placed, Germans already on the
-- map sorted by side.
-- `fresh` = the game set up a new field (preMNB2Admin with ui_gameStarted == 0);
-- otherwise it only loaded a battle under way (mnb2.lua:262), which keeps its layout.
function defense.afterSetup(fresh)
    if fresh == false then return defense.resume() end
    defense.on = false
    if not defense.wanted or type(player) ~= "table" or player.gameType ~= 1 then return end
    if not ALLOWED[tonumber(player.mnb2SubGame) or 0] then return end
    if not net.isOn("classicDefense", true) then return end
    defense.on = true
    defense.flip = 0
    defense.aliasSprites()
    local cx, cy = math.floor((tonumber(player.endLine) or 12600) / 2), 360
    defense.radarX, defense.radarY = cx, cy
    local squad = {}
    for _, t in ipairs(player.deployedTroops or {}) do
        if t.faction == "allied" and t.playerControlled == 1 then squad[#squad + 1] = t end
    end
    for k, t in ipairs(squad) do
        local a = (k - 1) / math.max(1, #squad) * 2 * math.pi
        t.x, t.y = cx + math.floor(math.cos(a) * 90), cy + math.floor(math.sin(a) * 90)
        t.targetx, t.targety = t.x, t.y
    end
    defense.clearAround(cx, cy, defense.CLEAR_RADIUS)
    player.placeables = player.placeables or {}
    local p = player.placeables
    p[#p + 1] = { name = "coopRadar", x = cx, y = cy, size = 10, rotation = 0, losBlocker = 0, cover = 0, radius = 30, save = 0 }
    p[#p + 1] = { name = "coopRadarTop", x = cx, y = cy, size = 10, rotation = 0, losBlocker = 0, cover = 0, radius = 30, save = 0 }
    player.masterScreenx, player.screenx = cx - 640, cx - 640
    for _, t in ipairs(player.deployedTroops or {}) do
        if isGerman(t) then t.coopSide = t.x < cx and "L" or "R" end
    end
    defense.markAllSeen() -- what's on the map now stays put; later friendly arrivals come in at the radar
    log("defense: squad of %d around the radar at x %d", #squad, cx)
end

-- A Classic battle under way was loaded: it is a defense if its radar is there.
-- Nothing is moved or cleared again.
function defense.resume()
    defense.on = false
    if type(player) ~= "table" or player.gameType ~= 1 then return end
    for _, p in ipairs(player.placeables or {}) do
        if type(p) == "table" and p.name == "coopRadar" and type(p.x) == "number" then
            defense.on = true
            defense.radarX, defense.radarY = p.x, tonumber(p.y) or 360
            break
        end
    end
    if defense.on then
        defense.aliasSprites()
        defense.markAllSeen()
        log("defense: battle under way resumed, radar at x %d", defense.radarX)
    end
end

-- ---------------------------------------------------------------- waves
-- Every other German a wave brings is mirrored to the left flank: as far left of
-- the westmost player as the game put him right of the eastmost one.
function defense.wrapWave(orig)
    return function(...)
        if not defense.active() then return orig(...) end
        local troops = player.deployedTroops
        local n0 = #troops
        local r = { orig(...) }
        local lo, hi = alliedSpan()
        for i = n0 + 1, #troops do
            local t = troops[i]
            if isGerman(t) and t.coopSide == nil then
                defense.flip = defense.flip + 1
                if defense.flip % 2 == 0 then
                    sendLeft(t, math.max(defense.LEFT_EDGE + 200, math.floor(lo - (t.x - hi))))
                else
                    t.coopSide = "R"
                end
            end
        end
        return unpack(r)
    end
end

-- ---------------------------------------------------------------- the German AI, mirrored for the left side
-- moveForward (urb_engine.lua:19206): forward is x + 100..600 for the left side
function defense.wrapMoveForward(orig)
    return function(dude, ...)
        if not isLeft(dude) then return orig(dude, ...) end
        if enemyCqc(dude) > 0 then return end
        if type(fireInFront) == "function" and fireInFront(dude) > 0 then
            -- a fire nearby: sidestep instead, as the game's own does
            dude.targetx, dude.targety = dude.x, randNbr(720)
            return
        end
        dude.targetx = math.min(dude.x + randNbr(500) + 100, (tonumber(player.endLine) or 12600))
        dude.targety = dude.y + randNbr(100) - 50
        dude.patrolTimer = 7
    end
end

-- axisRetreat (urb_engine.lua:19292): back is to the left for the left side
function defense.wrapRetreat(orig)
    return function(dude, ...)
        if not isLeft(dude) then return orig(dude, ...) end
        if enemyCqc(dude) > 0 then return end
        dude.targetx = math.max(defense.LEFT_EDGE, dude.x - 1000)
        dude.targety = dude.y + (randNbr(100) - 50)
        dude.temporaryStop, dude.actionTimer, dude.patrolTimer = 0, 5, 10
        dude.state, dude.aim, dude.pinned, dude.retreating = "idle", 0, 0, 10
    end
end

-- axisInFront (urb_engine.lua:19049): Germans of the same side further forward
function defense.wrapInFront(orig)
    return function(dude, ...)
        if not defense.active() or type(dude) ~= "table" then return orig(dude, ...) end
        local left, n = dude.coopSide == "L", 0
        for _, t in ipairs(player.deployedTroops) do
            if t.faction == "axis" and (t.health or 0) > 10 and t.id ~= dude.id and (t.coopSide == "L") == left then
                local ahead = left and (t.x - dude.x) or (dude.x - t.x)
                if ahead > 200 then n = n + 1 end
            end
        end
        return n
    end
end

-- axisAdvance (urb_engine.lua:19174): Germans of the same side behind him come along
function defense.wrapAdvance(orig)
    return function(dude, ...)
        if not defense.active() or type(dude) ~= "table" then return orig(dude, ...) end
        local left = dude.coopSide == "L"
        for _, t in ipairs(player.deployedTroops) do
            if t.faction == "axis" and (t.health or 0) > 10 and t.id ~= dude.id and (t.coopSide == "L") == left
                and distanceCheck2(dude, t) < 400 then
                local behind -- (not `left and a or b`: that falls through to b whenever a is false)
                if left then behind = t.x < dude.x else behind = t.x > dude.x end
                if behind and (underCover(t) == false or randNbr(100) < (t.momentum or 0) * 2) then
                    moveForward(t)
                end
            end
        end
    end
end

-- ---------------------------------------------------------------- friendly arrivals
-- The game brings reinforcements in at the far left (mnb2CallReinfButton, mnb2.lua:4972:
-- x = 10, walking to the front) and bought vehicles at the left edge too. In the
-- defense they come in like the horse cart does (germanSideCart, mnb2.lua:6761):
-- from the top or bottom edge of the map, at the radar, alternating sides.
defense.ARRIVAL_EDGE = 600 -- arrivals left of this were placed by the game at the left edge
local seen = setmetatable({}, { __mode = "k" })
defense.arrivalSide = 0

function defense.markAllSeen()
    for _, t in ipairs(player.deployedTroops or {}) do seen[t] = true end
    for _, v in ipairs(player.deployedVehicles or {}) do seen[v] = true end
end

-- a new friendly soldier or vehicle at the left edge: in at the radar, from above or below
function defense.bringIn(u, isVehicle)
    defense.arrivalSide = defense.arrivalSide + 1
    local fromTop = defense.arrivalSide % 2 == 1
    local spread = isVehicle and 250 or 150
    local x = defense.radarX + randNbr(spread * 2) - spread
    u.x = x
    u.y = fromTop and (isVehicle and -150 or -30) or (isVehicle and 870 or 750)
    u.targetx = x
    u.targety = defense.radarY + (fromTop and -1 or 1) * (100 + randNbr(80))
end

local function newArrivals()
    for _, t in ipairs(player.deployedTroops or {}) do
        if not seen[t] then
            seen[t] = true
            if t.faction == "allied" and type(t.x) == "number" and t.x < defense.ARRIVAL_EDGE and (t.dead or 0) == 0 then
                defense.bringIn(t, false)
            end
        end
    end
    for _, v in ipairs(player.deployedVehicles or {}) do
        if not seen[v] then
            seen[v] = true
            if v.faction == "allied" and type(v.x) == "number" and v.x < defense.ARRIVAL_EDGE then
                defense.bringIn(v, true)
            end
        end
    end
end

-- Tactical withdrawal (the Command menu's TacDraw, a player skill): the game walks the
-- soldier to x -500 and takes him off at x < 100 (ai.lua:1690, urb_engine.lua:6822,
-- with a chance of a TP refund in Classic). From the middle that's half the map, so in
-- the defense he leaves by the nearest top/bottom edge (called from the patched line).
-- The game keeps targets inside y 10..710 (sanityCheck), hence the 40 px margins.
function defense.withdraw(t)
    if not defense.active() or type(t) ~= "table" or type(t.y) ~= "number" then return end
    t.targetx = t.x
    t.targety = t.y < defense.radarY and 0 or 720
end

-- at the edge: handed to the game's own take-off (x < 100, urb_engine.lua:6822)
local function withdrawn()
    for _, t in ipairs(player.deployedTroops or {}) do
        if t.faction == "allied" and (tonumber(t.tacDraw) or 0) > 0 and (t.dead or 0) == 0 and type(t.y) == "number"
            and (t.y <= 40 or t.y >= 680) then
            t.x = 50
        end
    end
end

-- ---------------------------------------------------------------- every frame (host or solo)
-- Before the game's frame: new Germans get a side by where they are, the left ones
-- are kept off the game's own miss line, and a German at the radar scores.
function defense.update()
    defense.aliasSprites()
    if not defense.active() then return end
    newArrivals()
    withdrawn()
    local rx, ry, r2 = defense.radarX, defense.radarY, defense.RADIUS * defense.RADIUS
    for _, t in ipairs(player.deployedTroops or {}) do
        if isGerman(t) then
            if t.coopSide == nil then t.coopSide = t.x < rx and "L" or "R" end
            if t.coopSide == "L" and t.x < defense.LEFT_EDGE - 70 then t.x = defense.LEFT_EDGE - 70 end
            if counts(t) and (t.dead or 0) == 0 and (t.health or 0) > 10 then
                -- near the radar, or past its line to the other side (owner: either counts)
                local near = (t.x - rx) ^ 2 + (t.y - ry) ^ 2 < r2
                local through = (t.coopSide == "L" and t.x > rx + defense.RADIUS)
                    or (t.coopSide ~= "L" and t.x < rx - defense.RADIUS)
                if near or through then defense.reached(t) end
            end
        end
    end
end

-- a German got to the radar: one iron cross, and back he goes to his side
function defense.reached(t)
    if (tonumber(player.mnb2Miss) or 0) < 10 then player.mnb2Miss = (tonumber(player.mnb2Miss) or 0) + 1 end
    if t.coopSide == "L" then
        t.x = defense.LEFT_EDGE + 200
    else
        t.x = 12000 -- where the game sends its own misses (urb_engine.lua:6577)
    end
    t.targetx = t.x
    pcall(function() backLine:clone():play() end)
    pcall(anounceStuff, "The Germans reached the radar!")
    pcall(function() -- a note at the radar itself, for whoever is looking there
        local cue = { name = "Radar reached!", x = defense.radarX - 60, y = defense.radarY - 60, alpha = 255 }
        player.textCue[#player.textCue + 1] = cue
        if type(floatyClean) == "function" then floatyClean(cue) end
    end)
    log("defense: radar reached (%d)", player.mnb2Miss)
end

return defense
