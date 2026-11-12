-- =============================================================================
-- CO-OP RIBBONS
-- Ribbons of our own, numbered from 201 (the game's go to 111, plus 998/999). They are
-- ordinary game ribbons: a number in player.ribs, a picture _G["rib<id>"], a name
-- _G["ribName_<id>"] and a text _G["ribDesc_<id>"]. So the game's own ribbon screen
-- (drawFiles.lua:2937, draws every owned ribbon in the order earned, 72 slots), the tooltip
-- (urb_engine.lua:8170), hasRib and announceRibbon work with them without changes.
--
-- They can only be earned inside co-op play: the co-op campaign, or a co-op Classic defense
-- battle (owner: nothing co-op lands on a solo run). The pictures are drawn by
-- tools/ribbons/main.lua into sprites/coop_rib<id>.png and read here from the mod's folder
-- with io.open (love.graphics.newImage only reaches the game's own files).
-- =============================================================================
local ribbons = {}

ribbons.W, ribbons.H = 75, 28 -- the game's ribbon size
ribbons.list = {}
ribbons.byId = {}

-- the mod's folder: <game>/Mods/mnb_coop (tests set ribbons.dir)
function ribbons.modDir()
    if ribbons.dir then return ribbons.dir end
    local base = love and love.filesystem and love.filesystem.getSourceBaseDirectory and love.filesystem.getSourceBaseDirectory()
    if not base then return nil end
    return base .. "/Mods/mnb_coop"
end

-- Where co-op counts: the co-op campaign, or a co-op Classic defense battle.
function ribbons.inCoop()
    local c = rawget(_G, "mnbCoop")
    if type(c) ~= "table" then return false end
    if type(c.campaign) == "table" and c.campaign.active then return true end
    if type(c.defense) == "table" and c.defense.on then return true end
    return false
end

-- the profile's own counters for co-op ribbons: player.coopStats (a plain table of numbers)
function ribbons.stats()
    if type(player) ~= "table" then return {} end
    if type(player.coopStats) ~= "table" then player.coopStats = {} end
    return player.coopStats
end

function ribbons.addStat(name, n)
    local s = ribbons.stats()
    s[name] = (tonumber(s[name]) or 0) + (n or 1)
    return s[name]
end

function ribbons.stat(name)
    return tonumber(ribbons.stats()[name]) or 0
end

local function hasIt(id)
    if type(hasRib) == "function" then return hasRib(id) end
    for _, n in ipairs(player.ribs or {}) do if n == id then return true end end
    return false
end

-- The wave counters only count in a defense battle (the campaign has no waves).
local function inDefense()
    local c = rawget(_G, "mnbCoop")
    return type(c) == "table" and type(c.defense) == "table" and c.defense.on == true
        and type(player) == "table" and player.gameType == 1
end

-- ---------------------------------------------------------------- the registry
-- def: { id, name, desc, image, check = function() -> true when earned }
function ribbons.register(def)
    ribbons.list[#ribbons.list + 1] = def
    ribbons.byId[def.id] = def
    _G["ribName_" .. def.id] = def.name
    _G["ribDesc_" .. def.id] = def.desc
end

ribbons.register({
    id = 201, name = "Two-Front War", image = "coop_rib201.png",
    desc = "Survive 100 waves in a co-op Classic defense, \n +2 to the TP cap",
    check = function() return inDefense() and (tonumber(player.currentWave) or 0) >= 100 end,
})

ribbons.register({
    id = 202, name = "Hold the Line", image = "coop_rib202.png",
    -- TODO: the effect (two free riflemen guarding the radar at the start of a defense) is not built yet
    desc = "Reach wave 50 in a co-op defense with no German \n reaching the radar. Two free riflemen guard the radar at the start",
    check = function()
        return inDefense() and (tonumber(player.currentWave) or 0) >= 50 and (tonumber(player.mnb2Miss) or 0) == 0
    end,
})

ribbons.register({
    id = 203, name = "Brothers in Arms", image = "coop_rib203.png",
    -- TODO: nothing counts "revives" yet; when the revive hook exists it calls ribbons.addStat("revives")
    desc = "Revive 25 of a friend's soldiers",
    check = function() return ribbons.stat("revives") >= 25 end,
})

-- ---------------------------------------------------------------- pictures
local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

-- the ribbon's Image: the mod's png, or a plain flat colour when the file is missing
-- (the game draws _G["rib<id>"] without checking, so it must never be nil)
function ribbons.loadImage(def)
    local dir = ribbons.modDir()
    local bytes = dir and readFile(dir .. "/sprites/" .. def.image)
    if bytes then
        local ok, img = pcall(function()
            return love.graphics.newImage(love.filesystem.newFileData(bytes, def.image))
        end)
        if ok and img then return img end
    end
    local d = love.image.newImageData(ribbons.W, ribbons.H)
    d:mapPixel(function() return 0.35, 0.4, 0.3, 1 end)
    return love.graphics.newImage(d)
end

function ribbons.loadImages()
    for _, def in ipairs(ribbons.list) do
        if rawget(_G, "rib" .. def.id) == nil then
            local ok, img = pcall(ribbons.loadImage, def)
            if ok then _G["rib" .. def.id] = img else print("[mnb_coop] ribbon " .. def.id .. " picture: " .. tostring(img)) end
        end
    end
end

-- ---------------------------------------------------------------- awarding
function ribbons.award(id)
    if type(player) ~= "table" then return false end
    if type(player.ribs) ~= "table" then player.ribs = {} end
    if hasIt(id) then return false end
    player.ribs[#player.ribs + 1] = id
    if type(announceRibbon) == "function" then
        local ok, err = pcall(announceRibbon, id)
        if not ok then print("[mnb_coop] announceRibbon: " .. tostring(err)) end
    end
    return true
end

-- one co-op ribbon: only in co-op play, only once
function ribbons.check(id)
    local def = ribbons.byId[id]
    if not def or not ribbons.inCoop() or type(player) ~= "table" then return false end
    if type(player.ribs) ~= "table" or hasIt(id) then return false end
    local ok, earned = pcall(def.check)
    if ok and earned then return ribbons.award(id) end
    return false
end

function ribbons.checkAll()
    for _, def in ipairs(ribbons.list) do ribbons.check(def.id) end
end

-- checkRibCondition(n): our ids go to the registry, the game's ids to the game. The game
-- calls it for the wave ribbons after every wave (mnb2.lua:853-866), so ribbon 65 (100 waves)
-- doubles as our "a wave just ended" moment.
function ribbons.wrapCheck(orig)
    return function(ribNbr, ...)
        if type(ribNbr) == "number" and ribbons.byId[ribNbr] then
            return ribbons.check(ribNbr)
        end
        local r = { orig(ribNbr, ...) }
        if ribNbr == 65 then
            local ok, err = pcall(ribbons.checkAll)
            if not ok then print("[mnb_coop] ribbons: " .. tostring(err)) end
        end
        return unpack(r)
    end
end

-- Two-Front War: +2 to the TP cap. The game clamps inside giveTp to its global tpMax
-- (mnb2.lua:894-952), so we let it run and, if it cut the pool short, put back what the
-- clamp took, up to tpMax + 2. before = player.tp before the call, nbr = what was given.
function ribbons.afterGiveTp(before, nbr)
    if type(player) ~= "table" or type(before) ~= "number" or type(nbr) ~= "number" then return end
    if player.mnb2SubGame == 6 or player.mnb2SubGame == 8 then return end -- the game doesn't clamp there
    if not ribbons.inCoop() or not hasIt(201) then return end
    local cap = tonumber(rawget(_G, "tpMax"))
    if not cap then return end
    local want = before + nbr
    if player.tp < want then player.tp = math.min(want, cap + 2) end
end

-- ---------------------------------------------------------------- start up
function ribbons.install()
    ribbons.loadImages()
    if type(checkRibCondition) == "function" and not ribbons.wrapped then
        checkRibCondition = ribbons.wrapCheck(checkRibCondition)
        ribbons.wrapped = true
    end
end

return ribbons
