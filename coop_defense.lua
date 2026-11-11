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

-- ---------------------------------------------------------------- setup
-- After the game's preMNB2Admin: squad in a ring around the radar in the middle,
-- camera there, radar placed, Germans already on the map sorted by side.
function defense.afterSetup()
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
    player.placeables = player.placeables or {}
    local p = player.placeables
    p[#p + 1] = { name = "coopRadar", x = cx, y = cy, size = 10, rotation = 0, losBlocker = 0, cover = 0, radius = 30, save = 0 }
    p[#p + 1] = { name = "coopRadarTop", x = cx, y = cy, size = 10, rotation = 0, losBlocker = 0, cover = 0, radius = 30, save = 0 }
    player.masterScreenx, player.screenx = cx - 640, cx - 640
    for _, t in ipairs(player.deployedTroops or {}) do
        if isGerman(t) then t.coopSide = t.x < cx and "L" or "R" end
    end
    log("defense: squad of %d around the radar at x %d", #squad, cx)
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
                local behind = left and (t.x < dude.x) or (t.x > dude.x)
                if behind and (underCover(t) == false or randNbr(100) < (t.momentum or 0) * 2) then
                    moveForward(t)
                end
            end
        end
    end
end

-- ---------------------------------------------------------------- every frame (host or solo)
-- Before the game's frame: new Germans get a side by where they are, the left ones
-- are kept off the game's own miss line, and a German at the radar scores.
function defense.update()
    defense.aliasSprites()
    if not defense.active() then return end
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
