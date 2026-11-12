-- =============================================================================
-- CO-OP CAMPAIGN
-- Every player has their own co-op save on their own PC: the game's campaign on
-- a SEPARATE profile (own XP, ranks, career, squad). The player's real campaign is
-- never read or written while it runs.
--
-- How: while co-op is active, every love.filesystem call that names one of the
-- game's save files is redirected into coop/campaign/. The game's own code then
-- loads and saves the co-op profile without knowing it.
--   enter(): keep the real `player` in memory, switch the redirect on, load the
--            co-op profile (or make a new one with fresh rookies), and show the
--            game's main menu on it (Career, Squad, Campaign...).
--   exit():  save the co-op profile, switch the redirect off, put the real
--            `player` back. Happens on Back from the Multiplayer lobby, and on quit.
-- Settings (volume, fullscreen, particles...) live in the profile too, so they're
-- copied into the co-op profile on enter and back to the real one on exit.
--
-- ROSTERS (owner's design, 2026-11-11; DESIGN.md "Own rosters"):
-- squad slots 1..6 of a player's co-op profile ARE that player's roster. On the
-- Squad screen it can be sorted (right-drag a card onto another). The soldiers a
-- player brings to a mission are the top of that order: PRIORITY below, top row
-- first, as many as their share of the 6 (solo 6, duo 3, trio 2).
--   clients send their top soldiers to the host ("roster"), kept up to date;
--   the host builds the mission squad from everyone's (arrangeSquad);
--   after the mission the host sends each player their soldiers back ("results"),
--   and soldiers who stayed home get half the average XP the fielded ones gained.
-- A player who leaves mid-mission: their soldiers become NPCs holding position and
-- nothing that happens to them counts (no results are sent back).
-- =============================================================================
local campaign = {}

campaign.active = false
campaign.DIR = "coop/campaign"
campaign.profile = nil -- the co-op profile table while active (even while `player` is a battle mirror)
-- co-op Classic's own profile (section further down); its redirect shares the machinery below
campaign.classic = { active = false, DIR = "coop/classic" }

local REDIRECT = {
    ["saveMNB3.lua"] = campaign.DIR .. "/saveMNB3.lua",
    ["backUp.lua"] = campaign.DIR .. "/backUp.lua",
    ["saveMNB2.lua"] = campaign.DIR .. "/saveMNB2.lua",
}

local fs = love.filesystem
local realFs = {}
for _, name in ipairs({ "write", "load", "getInfo", "read", "remove", "exists", "append", "newFile", "lines", "newFileData" }) do
    if type(fs[name]) == "function" then realFs[name] = fs[name] end
end

-- The folder the game's save files go to right now (never both at once), or nil.
local function redirectDir()
    if campaign.active then return campaign.DIR end
    if campaign.classic.active then return campaign.classic.DIR end
    return nil
end

local function mapPath(path)
    local dir = redirectDir()
    if dir and type(path) == "string" and REDIRECT[path] then return dir .. "/" .. path end
    return path
end

for name, fn in pairs(realFs) do
    fs[name] = function(path, ...) return fn(mapPath(path), ...) end
end

local realPlayer = nil

-- profile fields that are really settings, kept the same in both profiles
local function isSetting(k)
    return type(k) == "string" and (k:match("^option_") or k == "fullScreen" or k == "borderLess" or k == "brutalityWarn")
end

local function copySettings(from, to)
    if type(from) ~= "table" or type(to) ~= "table" then return end
    for k, v in pairs(from) do
        if isSetting(k) and type(v) ~= "table" then to[k] = v end
    end
end

local function serialize(t)
    local ok, ser = pcall(require, "includes/ser")
    if ok and type(ser) == "function" then return ser(t) end
    return nil
end

local net = require("includes/mods/mnb_coop/coop_net")
local profile = require("includes/mods/mnb_coop/coop_profile")

local function log(fmt, ...)
    if net.isOn("debug", false) then print("[mnb_coop] " .. string.format(fmt, ...)) end
end

-- Runs fn with the global `player` set to p (the game's helpers, like
-- createAlliedSoldier and giveXp, read the global).
local function asPlayer(p, fn, ...)
    local saved = player
    player = p
    local ok, a, b = pcall(fn, ...)
    player = saved
    if not ok then print("[mnb_coop] " .. tostring(a)) end
    return a, b
end

function campaign.hasSave()
    return realFs.getInfo(REDIRECT["saveMNB3.lua"]) ~= nil
end

local function readSaveFile()
    if not realFs.getInfo(REDIRECT["saveMNB3.lua"]) then return nil end
    local ok, chunk = pcall(realFs.load, REDIRECT["saveMNB3.lua"])
    if not (ok and type(chunk) == "function") then return nil end
    local ok2, data = pcall(chunk)
    if ok2 and type(data) == "table" then return data end
    return nil
end

local function writeSaveFile(p)
    pcall(fs.createDirectory, campaign.DIR)
    local data = serialize(p)
    if data then pcall(realFs.write, REDIRECT["saveMNB3.lua"], data) end
end

-- The co-op profile from disk, or a brand-new one with fresh rookies (the game's
-- newProfile, which works on the global `player`). `base` gives the startup flags.
function campaign.loadProfile(base)
    local p = readSaveFile()
    local fresh = false
    if not p then
        p = asPlayer({}, function()
            newProfile()
            return player
        end)
        if type(p) ~= "table" then return nil, "could not make a co-op profile" end
        fresh = true
    end
    -- same order as the game's own startup: bloop is set before updateProfile, or
    -- updateProfile takes the profile for an old one and resets it
    p.bloop = (type(base) == "table" and base.bloop) or p.bloop or 0
    local updated = asPlayer(p, function()
        updateProfile(player)
        return player -- updateProfile may swap the table
    end)
    if type(updated) == "table" then p = updated end
    p.coopCampaign = 1
    campaign.normalize(p)
    return p, fresh
end

-- Open the co-op profile (any player). Returns false (and a reason) if it can't.
function campaign.enter()
    if campaign.active then return true end
    if campaign.classic.active then campaign.classic.exit() end -- the real profile back first
    if type(player) ~= "table" then return false, "no profile loaded" end
    pcall(fs.createDirectory, campaign.DIR)
    local p, fresh = campaign.loadProfile(player)
    if not p then return false, fresh end
    realPlayer = player
    campaign.active = true
    player = p
    campaign.profile = p
    copySettings(realPlayer, p)
    p.gameState = 1
    campaign.page = 1
    campaign.save()
    print("[mnb_coop] co-op profile " .. (fresh and "started" or "opened") .. ", day " .. tostring(p.dayz))
    return true
end

-- The game sometimes replaces `player` with a fresh load of the save (the pause
-- menu's Options does, urb_engine.lua:45029). While co-op is open and this
-- machine isn't showing a host's battle, the co-op profile IS whatever `player` is.
function campaign.track()
    if not campaign.active or type(player) ~= "table" then return end
    if mnbCoop and mnbCoop.battle and mnbCoop.battle.viewing then return end
    campaign.profile = player
end

function campaign.save()
    campaign.track()
    if not campaign.active or type(campaign.profile) ~= "table" then return end
    writeSaveFile(campaign.profile)
end

-- Runs fn(profile) on this player's co-op profile, open or not, and saves it.
function campaign.withProfile(fn)
    campaign.track()
    local p = campaign.active and campaign.profile or campaign.loadProfile(player)
    if type(p) ~= "table" then return end
    asPlayer(p, fn, p)
    if campaign.active then campaign.save() else writeSaveFile(p) end
end

-- Leave co-op: save it and give the real profile back.
function campaign.exit()
    if not campaign.active then return end
    campaign.track()
    campaign.setPage(1)
    campaign.save()
    local coopPlayer = campaign.profile or player
    campaign.active = false
    campaign.profile = nil
    player = realPlayer or player
    copySettings(coopPlayer, player) -- settings changed during co-op carry over
    player.gameState = 1
    realPlayer = nil
    print("[mnb_coop] back to your own campaign profile")
end

-- Throw the co-op campaign away (keeps a .old copy, just in case).
function campaign.reset()
    if campaign.active then return false end
    for _, path in pairs(REDIRECT) do
        if realFs.getInfo(path) then
            local data = realFs.read(path)
            if data then realFs.write(path .. ".old", data) end
            realFs.remove(path)
        end
    end
    return true
end

-- Called every frame (menu button pass). The co-op profile stays loaded on the
-- game's main menu (that menu is the co-op hub: Career, Squad, Campaign...); it
-- ends when the player goes Back from the Multiplayer lobby, or quits.
function campaign.update()
    campaign.classic.update()
    campaign.track()
    -- results that arrived while watching the battle: apply once back in the menus
    if campaign.pendingResults and not (mnbCoop and mnbCoop.battle and mnbCoop.battle.viewing) then
        campaign.applyPendingResults()
    end
    if not campaign.active then return end
    if not campaign.onSquadPage() then campaign.setPage(1) end
    -- no main menu while co-op is open: every "back to the main menu" lands on the co-op page
    if menuPage == 1 and mnbCoop and mnbCoop.lobby then menuPage = mnbCoop.lobby.getHubPage() end
end

-- The game saves on quit; with the redirect on, that save lands in the co-op files.
-- Afterwards put the real profile back and save it the way the game would have.
function campaign.onQuitAfterGameSaved()
    if campaign.classic.active then
        campaign.classic.exit()
    elseif campaign.active then
        campaign.exit()
    else
        return
    end
    local data = serialize(player)
    if data then pcall(realFs.write, player.gameType == 0 and "saveMNB3.lua" or "saveMNB2.lua", data) end
end

-- =============================================================================
-- CO-OP CLASSIC PROFILE (v0.9.11)
-- A co-op Classic game never touches the player's real Classic profile (rank,
-- ribbons, the ribbon counters). Same trick as the campaign: while it is open,
-- the game's save files go to coop/classic/, so menu_classicButton loads and
-- saves "saveMNB2.lua" there (a first game starts a fresh Classic profile by
-- the game's own newProfile path).
-- The Classic code also reads and writes "saveMNB3.lua" (leaving Classic loads
-- the campaign profile and copies the Classic rank and ribbons into it,
-- mnb2.lua:1142-1192), so that file is redirected too: a stand-in campaign
-- profile of its own sits in coop/classic/, the real campaign save is never read.
--   enter(): keep the real `player`, redirect on, put the stand-in in its place.
--   exit():  save what is loaded, redirect off, real `player` back. Happens when
--            the menus come back to the lobby or the main menu, on Back from the
--            lobby, on opening the co-op campaign, and on quit.
-- =============================================================================
local classic = campaign.classic
local classicReal = nil -- the real `player`, kept aside while co-op Classic is open
local classicMaxWave = nil -- the game's mnb3Tomnb2_maxWave of the real session (kept aside too)
-- settings that menu_classicButton carries into the Classic profile besides isSetting's
local CLASSIC_SETTINGS = { "scrollSpeed", "fadeTimer" }

local function copyClassicSettings(from, to)
    copySettings(from, to)
    if type(from) ~= "table" or type(to) ~= "table" then return end
    for _, k in ipairs(CLASSIC_SETTINGS) do
        if from[k] ~= nil and type(from[k]) ~= "table" then to[k] = from[k] end
    end
end

local function readLua(path)
    if not realFs.getInfo(path) then return nil end
    local ok, chunk = pcall(realFs.load, path)
    if not (ok and type(chunk) == "function") then return nil end
    local ok2, data = pcall(chunk)
    if ok2 and type(data) == "table" then return data end
    return nil
end

function classic.hasSave()
    return realFs.getInfo(classic.DIR .. "/saveMNB2.lua") ~= nil
end

-- Open the co-op Classic profile. Returns false (and a reason) if it can't.
function classic.enter()
    if classic.active then return true end
    if campaign.active then return false, "leave the co-op campaign first" end
    if type(player) ~= "table" then return false, "no profile loaded" end
    pcall(fs.createDirectory, classic.DIR)
    local base = player
    classic.active = true -- before anything below can make the game write a file
    local p = readLua(classic.DIR .. "/saveMNB3.lua")
    if not p then
        p = asPlayer({}, function()
            newProfile()
            return player
        end)
    end
    if type(p) ~= "table" then
        classic.active = false
        return false, "could not make a co-op Classic profile"
    end
    -- bloop first, as in loadProfile: updateProfile takes a profile without it for an old one
    p.bloop = base.bloop or p.bloop or 0
    local updated = asPlayer(p, function()
        updateProfile(player)
        return player
    end)
    if type(updated) == "table" then p = updated end
    p.gameType, p.gameState = 0, 1
    copyClassicSettings(base, p)
    classicReal = base
    -- the game hands this on to the next Classic profile it loads: not the real session's
    classicMaxWave = rawget(_G, "mnb3Tomnb2_maxWave")
    rawset(_G, "mnb3Tomnb2_maxWave", nil)
    player = p
    local data = serialize(p)
    if data then pcall(realFs.write, classic.DIR .. "/saveMNB3.lua", data) end
    print("[mnb_coop] co-op Classic profile " .. (classic.hasSave() and "opened" or "started") .. ", real Classic untouched")
    return true
end

-- Leave co-op Classic: save what is loaded and give the real profile back.
function classic.exit()
    if not classic.active then return end
    local cur = player
    local viewing = mnbCoop and mnbCoop.battle and mnbCoop.battle.viewing
    if type(cur) == "table" and not viewing then
        local data = serialize(cur)
        local name = cur.gameType == 1 and "saveMNB2.lua" or "saveMNB3.lua"
        if data then pcall(realFs.write, classic.DIR .. "/" .. name, data) end
    end
    classic.active = false
    rawset(_G, "mnb3Tomnb2_maxWave", classicMaxWave)
    classicMaxWave = nil
    if type(classicReal) == "table" then
        player = classicReal
        if type(cur) == "table" then copyClassicSettings(cur, player) end -- settings changed meanwhile carry over
        player.gameState = 1
    end
    classicReal = nil
    print("[mnb_coop] back to your own Classic profile")
end

-- Every menu frame: once the menus are back on the lobby or the main menu, the game
-- is done with the Classic files, and the real profile returns.
function classic.update()
    if not classic.active or type(player) ~= "table" or player.gameState == 0 then return end
    if mnbCoop and mnbCoop.battle and mnbCoop.battle.viewing then return end
    local lobby = mnbCoop and mnbCoop.lobby
    local lobbyPage = lobby and lobby.getPage and lobby.getPage()
    if menuPage == 1 or (lobbyPage and menuPage == lobbyPage) then classic.exit() end
end

-- =============================================================================
-- ROSTER
-- =============================================================================
-- The order soldiers are brought in: the top row of the Squad screen first
-- (cards 1, 3, 5), then the bottom row (2, 4, 6).
campaign.PRIORITY = { 1, 3, 5, 2, 4, 6 }
local PRIORITY = campaign.PRIORITY

-- The squad size the game should use right now (6 outside co-op; more only in a
-- later 4-player mode). qm.toml patches the game's "6" checks to ask this.
function coopSquadMax()
    local p = campaign.profile
    if campaign.active and type(p) == "table" and tonumber(p.coopSquadTarget) then
        return p.coopSquadTarget
    end
    return 6
end

-- players in the session right now (1 when not connected)
function campaign.playersNow()
    if net.role == "host" or net.role == "client" then return math.max(1, net.playerCount()) end
    return 1
end

-- how many of the 6 each player brings
function campaign.share(players)
    return math.max(1, math.floor(6 / math.max(1, players or campaign.playersNow())))
end

function campaign.isGoing(slot, players)
    local share = campaign.share(players)
    for k = 1, share do if PRIORITY[k] == slot then return true end end
    return false
end

-- Who plays this session (host side): { {id, name, seat}, ... } in seat order.
function campaign.owners()
    local list = {}
    if net.role == "host" then
        for seat = 1, net.MAX_SEATS do
            local s = net.seats[seat]
            if s then list[#list + 1] = { id = s.steamId or ("seat" .. seat), name = s.name, seat = seat } end
        end
    end
    if #list == 0 then list[1] = { id = profile.steamId() or "host", name = profile.name(), seat = 1 } end
    return list
end

local function newUid()
    return (profile.steamId() or "local") .. ":" .. os.time() .. ":" .. love.math.random(1, 999999)
end

-- a fresh rookie, the way the game makes one (needs `player` = the profile)
local function newSoldier()
    local s = {}
    createAlliedSoldier(s)
    s.perks = { randNbr(21) }
    pcall(assignNextPerk, s)
    s.coopUid = newUid()
    return s
end

local function isAlive(t)
    return type(t) == "table" and (tonumber(t.health) or 0) > 0 and (tonumber(t.dead) or 0) == 0
end

-- fields only a mission uses; a soldier going home or abroad loses them
local BATTLE_TAGS = { "coopSeat", "coopOwner", "coopXpBefore", "coopNew", "coopNpc", "coopCapNoted", "selected" }
local function untag(s)
    for _, k in ipairs(BATTLE_TAGS) do s[k] = nil end
    s.coopSquad = 1
    return s
end

-- Deep copy of plain data (soldiers are plain tables), depth-limited.
local function copyData(v, depth)
    if type(v) ~= "table" then
        local tv = type(v)
        if tv == "number" or tv == "string" or tv == "boolean" then return v end
        return nil
    end
    if (depth or 0) > 6 then return nil end
    local out = {}
    for k, x in pairs(v) do
        local tk = type(k)
        if tk == "string" or tk == "number" then out[k] = copyData(x, (depth or 0) + 1) end
    end
    return out
end
campaign.copyData = copyData

-- A soldier received over the network becomes a normal squad soldier: plain data
-- only, and the fields the game relies on forced to sane values.
local function sanitize(s)
    local t = copyData(s, 0) or {}
    t.faction, t.tag, t.playerControlled, t.npc = "allied", "allied", 1, 0
    t.health = tonumber(t.health) or 100
    t.maxHealth = tonumber(t.maxHealth) or 100
    t.dead = tonumber(t.dead) or 0
    t.xp = tonumber(t.xp) or 0
    t.id = tonumber(t.id) or randNbr(9999999999)
    -- an edited save can't bring values the game never makes: level tops out at 11
    -- (giveXp, urb_engine.lua:14694-14730), combat skill starts at 30 and grows slowly
    local function clamp(k, lo, hi, default)
        local v = tonumber(t[k]) or default
        if v < lo then v = lo elseif v > hi then v = hi end
        t[k] = v
    end
    clamp("xp", 0, 10000, 0)
    clamp("level", 1, 11, 1)
    clamp("rank", 0, 8, 0)
    clamp("skill", 0, 150, 30)
    clamp("maxHealth", 1, 400, 100)
    clamp("health", -1000, t.maxHealth, t.maxHealth)
    clamp("maxMorale", 1, 400, 100)
    clamp("promo", 0, 11, 0)
    if type(t.weapon) ~= "table" then t.weapon = {} end
    if type(t.perks) ~= "table" then t.perks = {} end
    if type(t.awards) ~= "table" then t.awards = {} end
    if type(t.coopUid) ~= "string" or #t.coopUid > 40 then t.coopUid = nil end
    for _, k in ipairs(BATTLE_TAGS) do t[k] = nil end

    -- Fields the game turns into sprite or text names (security pass 2026-11-12): a value
    -- it never makes would make its drawing code fail on every machine that shows him.
    -- Each must name something the game has loaded; otherwise a safe default.
    local function loaded(name) return rawget(_G, name) ~= nil end
    -- every number finite and sane, every string short
    for k, v in pairs(t) do
        if type(v) == "number" and (v ~= v or v > 1e9 or v < -1e9) then t[k] = 0
        elseif type(v) == "string" and #v > 64 then t[k] = v:sub(1, 64) end
    end
    if type(t.name) == "string" then t.name = t.name:sub(1, 40) end
    if type(t.spec) ~= "string" or not loaded("spec_" .. t.spec) then t.spec = "" end -- drawFiles.lua:1273
    if type(t.state) ~= "string" or not loaded("allied_" .. t.state) then t.state = "idle" end -- drawFiles.lua:513
    for _, part in ipairs({ "eyes", "nose", "mouth", "hair" }) do -- urb_engine.lua:7969-7972
        local n = tonumber(t[part])
        if not n or not loaded("face_" .. part .. n) then t[part] = 1 end
    end
    -- perks: ids with a perk picture (1..21, main.lua:528), no more than there are
    local perks = {}
    for _, n in ipairs(t.perks) do
        n = tonumber(n)
        if n and n == math.floor(n) and loaded("perk_" .. n) and #perks < 21 then perks[#perks + 1] = n end
    end
    t.perks = perks
    local np = tonumber(t.nextPerk)
    local names = rawget(_G, "perks")
    if t.nextPerk ~= nil and not (np and type(names) == "table" and names[np] and loaded("perkText" .. np)) then
        t.nextPerk = nil
        if type(assignNextPerk) == "function" then pcall(assignNextPerk, t) end
    end
    -- awards: { name, called, icon } with an award picture (urb_engine.lua:41243, drawFiles.lua:3457)
    local awards = {}
    for _, a in ipairs(t.awards) do
        local icon = type(a) == "table" and tonumber(a.icon)
        if icon and loaded("award" .. icon) and #awards < 100 then
            awards[#awards + 1] = { name = tostring(a.name or ""):sub(1, 60), called = tonumber(a.called) == 0 and 0 or 1, icon = icon }
        end
    end
    t.awards = awards
    -- the weapon, rebuilt from its tag by the game (weaponCreator, urb_engine.lua:12876: an
    -- unknown tag becomes a k98), so no crafted damage, range or rate of fire comes along.
    -- Nothing else changes a weapon's stats for good (only a battle condition, bcChecks.lua:558).
    if type(weaponCreator) == "function" then
        local old = t.weapon
        local w = {}
        if pcall(weaponCreator, w, type(old.tag) == "string" and old.tag or "m1") then
            local ammo = tonumber(old.ammo)
            if ammo and tonumber(w.maxAmmo) then w.ammo = math.max(0, math.min(ammo, w.maxAmmo)) end
            t.weapon = w
        end
    end
    return t
end
campaign.sanitize = sanitize

-- Makes squad slots 1..6 of a profile its six roster soldiers, each with a stable
-- coopUid. Also turns an older co-op save (v0.4: up to 12 soldiers + coopBench)
-- into a roster: the first six stay, any others are kept aside in coopExtra.
function campaign.normalize(p)
    if type(p) ~= "table" then return end
    local troops = p.deployedTroops
    if type(troops) ~= "table" then
        troops = {}
        p.deployedTroops = troops
    end
    local squad = {}
    for i = #troops, 1, -1 do
        local t = troops[i]
        if type(t) == "table" and t.faction == "allied" and t.playerControlled == 1 and t.npc ~= 1 and t.coopNpc ~= 1 then
            table.insert(squad, 1, table.remove(troops, i))
        end
    end
    for _, s in ipairs(p.coopBench or {}) do squad[#squad + 1] = s end
    p.coopBench = nil
    if #squad > 6 then
        p.coopExtra = p.coopExtra or {}
        for k = 7, #squad do p.coopExtra[#p.coopExtra + 1] = squad[k] end
    end
    for i = 1, 6 do
        local s = squad[i]
        if type(s) ~= "table" then s = asPlayer(p, newSoldier) end
        untag(s)
        if type(s.coopUid) ~= "string" then s.coopUid = newUid() end
        table.insert(troops, i, s)
    end
    p.coopSquadTarget = 6
    p.coopSlotSeats = { 1, 1, 1, 1, 1, 1 }
    p.coopSlotPos = { 1, 2, 3, 4, 5, 6 }
    p.coopSlotOwners = {}
end

-- ---------------------------------------------------------------- host: missions
campaign.friendRosters = {} -- seat -> { steamId, soldiers = { {pos, soldier}, ... } }

-- "roster" from a client: the soldiers they would bring, in their order
function campaign.onClientMessage(seat, msg)
    if msg.t ~= "roster" then return false end
    if type(msg.soldiers) ~= "table" then return true end
    local list = {}
    for i = 1, math.min(6, #msg.soldiers) do
        local e = msg.soldiers[i]
        local pos = type(e) == "table" and tonumber(e.pos)
        if pos and pos >= 1 and pos <= 6 and type(e.soldier) == "table" then
            list[#list + 1] = { pos = math.floor(pos), soldier = sanitize(e.soldier) }
        end
    end
    campaign.friendRosters[seat] = { steamId = net.seats[seat] and net.seats[seat].steamId, soldiers = list }
    log("seat %d sent %d soldiers", seat, #list)
    pcall(campaign.fillFreeSlots) -- joined during a mission: in as reinforcements, if a slot is free
    return true
end

local function priorityIndex(pos)
    for k, p in ipairs(PRIORITY) do if p == pos then return k end end
    return 99
end

-- Before a mission (host, or alone): the mission squad from everyone's rosters.
function campaign.arrangeSquad()
    if not campaign.active then return end
    campaign.track()
    local p = campaign.profile
    campaign.settleMission() -- a mission the host quit before settling
    campaign.setPage(1)
    campaign.normalize(p)
    local troops = p.deployedTroops
    -- a soldier who died stays on the roster until replaced: a recruit takes his
    -- place now (the game does the same for the squad at mission start)
    for i = 1, 6 do
        if not isAlive(troops[i]) then troops[i] = asPlayer(p, newSoldier) end
    end
    local roster = {}
    for i = 1, 6 do roster[i] = table.remove(troops, 1) end

    local seats = {}
    if net.role == "host" then
        for seat = 1, net.MAX_SEATS do if net.seats[seat] then seats[#seats + 1] = seat end end
    end
    if #seats == 0 then seats = { 1 } end
    local share = campaign.share(#seats)

    local usedIds = {}
    for _, t in ipairs(troops) do if type(t) == "table" and t.id then usedIds[t.id] = true end end
    local slots, slotSeats, slotPos, slotOwners = {}, {}, {}, {}
    local function add(s, seat, pos)
        s.coopSquad, s.coopSeat, s.coopPos = 1, seat, pos
        s.coopXpBefore = tonumber(s.xp) or 0
        if not s.id or usedIds[s.id] then s.id = randNbr(9999999999) end
        usedIds[s.id] = true
        slots[#slots + 1] = s
        slotSeats[#slotSeats + 1] = seat
        slotPos[#slotPos + 1] = pos
        local sitting = net.seats[seat]
        slotOwners[#slotOwners + 1] = sitting and (sitting.steamId or sitting.name) or nil
    end

    -- the host's: the top of its roster; the rest stay home
    local going = {}
    for k = 1, share do
        local pos = PRIORITY[k]
        going[pos] = true
        add(roster[pos], 1, pos)
    end
    local home = {}
    for pos = 1, 6 do if not going[pos] then home[pos] = roster[pos] end end

    -- each friend's: the top of the roster they sent
    local missionSeats = {}
    for _, seat in ipairs(seats) do
        missionSeats[seat] = net.seats[seat] and (net.seats[seat].steamId or net.seats[seat].name) or true
        if seat ~= 1 then
            local fr = campaign.friendRosters[seat]
            local list = {}
            if fr and fr.steamId == (net.seats[seat] and net.seats[seat].steamId) then
                for _, e in ipairs(fr.soldiers) do
                    if isAlive(e.soldier) then list[#list + 1] = e end
                end
            end
            table.sort(list, function(a, b) return priorityIndex(a.pos) < priorityIndex(b.pos) end)
            local n = 0
            for _, e in ipairs(list) do
                if n < share then
                    add(copyData(e.soldier, 0), seat, e.pos)
                    n = n + 1
                end
            end
            -- a friend whose roster never arrived still gets soldiers for this mission
            while n < share do
                local s = asPlayer(p, newSoldier)
                s.coopNew = 1
                add(s, seat, nil)
                n = n + 1
            end
        end
    end

    for i = #slots, 1, -1 do table.insert(troops, 1, slots[i]) end
    p.coopHome = home
    p.coopSlotSeats, p.coopSlotPos, p.coopSlotOwners = slotSeats, slotPos, slotOwners
    p.coopSquadTarget = #slots
    -- the share stays fixed for the whole mission; gainz is the mission's own day for the
    -- XP cap (postMissionAdmin moves gainz on before it gives the journal XP)
    p.coopMission = { seats = missionSeats, share = share, gainz = tonumber(p.gainz) or 1 }
    print(string.format("[mnb_coop] mission squad: %d soldiers, %d each for %d player(s)", #slots, share, #seats))
end

-- After a mission (host): own soldiers back on the roster, friends' soldiers sent
-- back to them. Runs when the host leaves the mission-end page (and, if the game
-- was closed there, before the next mission). Safe to call twice.
function campaign.settleMission()
    campaign.track()
    local p = campaign.profile
    if not campaign.active or type(p) ~= "table" or type(p.coopMission) ~= "table" then return end
    local troops = p.deployedTroops
    local k = math.min(tonumber(p.coopSquadTarget) or 6, #troops)
    local seats, poss = p.coopSlotSeats or {}, p.coopSlotPos or {}
    local results, back, gains = {}, {}, {}
    for i = 1, k do
        local t = troops[i]
        if type(t) == "table" and t.coopNpc ~= 1 and t.faction == "allied" then
            local seat, pos = seats[i] or 1, poss[i]
            if seat == 1 then
                if pos then
                    back[pos] = t
                    if t.coopXpBefore and isAlive(t) then gains[#gains + 1] = (tonumber(t.xp) or 0) - t.coopXpBefore end
                end
            else
                results[seat] = results[seat] or {}
                results[seat][#results[seat] + 1] = { pos = pos, soldier = t }
            end
        end
    end
    for i = k, 1, -1 do table.remove(troops, i) end
    -- soldiers who pulled out with a player who left are gone for good
    for i = #troops, 1, -1 do
        if type(troops[i]) == "table" and troops[i].coopNpc == 1 then table.remove(troops, i) end
    end

    -- the host's roster back in its order; home soldiers get half the average gain
    local home = p.coopHome or {}
    local sum = 0
    for _, g in ipairs(gains) do sum = sum + g end
    local half = #gains > 0 and math.floor(sum / #gains / 2) or 0
    for pos = 1, 6 do
        local s = back[pos] or home[pos]
        if type(s) ~= "table" then s = asPlayer(p, newSoldier) end
        if not back[pos] and half >= 1 and isAlive(s) then asPlayer(p, giveXp, s, half) end
        untag(s)
        if type(s.coopUid) ~= "string" then s.coopUid = newUid() end
        table.insert(troops, pos, s)
    end

    -- friends who are still here (the same person in that seat) get theirs back
    for seat, list in pairs(results) do
        local want = p.coopMission.seats and p.coopMission.seats[seat]
        local s = net.seats[seat]
        if net.role == "host" and s and (want == true or want == nil or (s.steamId or s.name) == want) then
            local out = {}
            for _, e in ipairs(list) do
                local c = copyData(e.soldier, 0)
                for _, tag in ipairs(BATTLE_TAGS) do c[tag] = nil end
                out[#out + 1] = { pos = e.pos, soldier = c }
            end
            net.sendTo(seat, { t = "results", soldiers = out, day = p.dayz, gainz = p.coopMission.gainz })
            log("results to seat %d: %d soldiers", seat, #out)
        end
    end
    p.coopMission, p.coopHome = nil, nil
    p.coopSquadTarget = 6
    p.coopSlotSeats = { 1, 1, 1, 1, 1, 1 }
    p.coopSlotPos = { 1, 2, 3, 4, 5, 6 }
    p.coopSlotOwners = {}
    campaign.save()
    print("[mnb_coop] mission settled: squad back on the rosters")
end

-- Host: a player left mid-mission (owner's rule, 2026-11-11). Their soldiers go with
-- them: they walk off the nearest edge (top or bottom) and are gone. Nothing that
-- happens to them counts (no results go back; their roster stays as it was). Their
-- slots are free: a player who joins during the mission brings soldiers in there.
local LEAVE_TIMEOUT = 30 -- seconds; a soldier who can't reach the edge is taken off anyway

function campaign.onSeatLeft(seat)
    campaign.friendRosters[seat] = nil
    local p = campaign.profile
    if not campaign.active or type(p) ~= "table" or type(p.coopMission) ~= "table" then return end
    if type(player) ~= "table" or player.gameState ~= 0 then return end
    local now = love.timer.getTime()
    for _, t in ipairs(p.deployedTroops or {}) do
        if type(t) == "table" and t.coopSquad == 1 and t.coopSeat == seat then
            t.coopNpc, t.coopLeaving, t.coopLeftAt, t.coopSquad = 1, 1, now, nil
            t.selected = false
            t.coopExitY = ((tonumber(t.y) or 360) < 360) and -200 or 920
        end
    end
    print("[mnb_coop] seat " .. seat .. " left: their soldiers are pulling out")
end

-- Host, every battle frame: soldiers pulling out keep walking to their edge; once
-- off the map (or after the timeout) they are taken off: parked far away, out of
-- the squad, removed by the game with the other NPCs after the mission.
function campaign.updateLeavers()
    local p = campaign.profile
    if not campaign.active or type(p) ~= "table" or type(p.coopMission) ~= "table" then return end
    if type(player) ~= "table" or player.gameState ~= 0 then return end
    local now = love.timer.getTime()
    for _, t in ipairs(p.deployedTroops or {}) do
        if type(t) == "table" and t.coopLeaving == 1 then
            local gone = (tonumber(t.y) or 0) < -80 or (tonumber(t.y) or 0) > 800
                or now - (t.coopLeftAt or now) > LEAVE_TIMEOUT or not isAlive(t)
            if gone then
                t.coopLeaving, t.coopGone = nil, 1
                t.playerControlled, t.npc = 0, 1
                t.x, t.y, t.targetx, t.targety = -9999, -9999, -9999, -9999
            else
                t.targetx, t.targety = t.x, t.coopExitY
                t.selected = false
            end
        end
    end
    campaign.fillFreeSlots()
end

-- Host: a player who joined during the mission brings their soldiers into the
-- slots a leaver freed: in from the left edge, like the game's reinforcements
-- (bcChecks.lua:1348-1379: x 50, y 350 +-50, heading for the front).
function campaign.fillFreeSlots()
    local p = campaign.profile
    if not campaign.active or type(p) ~= "table" or type(p.coopMission) ~= "table" then return end
    if type(player) ~= "table" or player.gameState ~= 0 or net.role ~= "host" then return end
    local troops, seats, poss = p.deployedTroops, p.coopSlotSeats or {}, p.coopSlotPos or {}
    p.coopSlotOwners = p.coopSlotOwners or {}
    local owners = p.coopSlotOwners
    -- a seat number is reused by whoever joins next: slots belong to a PERSON
    -- (Steam id, else name), so compare who sits in the seat now
    local function who(seat)
        local s = net.seats[seat]
        return s and (s.steamId or s.name) or nil
    end
    local free, inMission = {}, {}
    for i = 1, tonumber(p.coopSquadTarget) or 6 do
        local t, s = troops[i], seats[i]
        if s and s ~= 1 then
            local here = who(s) ~= nil and who(s) == owners[i]
            if here then
                inMission[s] = (inMission[s] or 0) + 1 -- soldiers this person already has out there
            elseif not (type(t) == "table" and t.coopLeaving == 1) then
                free[#free + 1] = i
            end
        end
    end
    if #free == 0 then return end
    for seat = 2, net.MAX_SEATS do
        local fr = campaign.friendRosters[seat]
        local share = tonumber(p.coopMission.share) or campaign.share() -- as at mission start, at most the free slots
        local already = inMission[seat] or 0
        if #free > 0 and net.seats[seat] and already < share and fr then
            -- their roster in order, minus the soldiers already out there
            local out = {}
            for i2 = 1, tonumber(p.coopSquadTarget) or 6 do
                local t2 = troops[i2]
                if type(t2) == "table" and seats[i2] == seat and owners[i2] == who(seat) and t2.coopPos then out[t2.coopPos] = true end
            end
            local list = {}
            for _, e in ipairs(fr.soldiers) do
                if isAlive(e.soldier) and not out[e.pos] then list[#list + 1] = e end
            end
            table.sort(list, function(a, b) return priorityIndex(a.pos) < priorityIndex(b.pos) end)
            local usedIds = {}
            for _, t in ipairs(troops) do if type(t) == "table" and t.id then usedIds[t.id] = true end end
            local n = already
            for _, e in ipairs(list) do
                if n < share and #free > 0 then
                    local i = table.remove(free, 1)
                    local old = troops[i]
                    local s = copyData(e.soldier, 0)
                    s.coopSquad, s.coopSeat, s.coopPos = 1, seat, e.pos
                    s.coopXpBefore = tonumber(s.xp) or 0
                    if not s.id or usedIds[s.id] then s.id = randNbr(9999999999) end
                    s.x, s.y = 50, 350 + randNbr(100) - 50
                    s.targetx = type(alliedFrontLine) == "function" and alliedFrontLine() or 300
                    s.targety = s.y
                    s.state, s.morale = "idle", math.max(tonumber(s.morale) or 100, 30)
                    troops[i] = s
                    if type(old) == "table" then troops[#troops + 1] = old end -- the parked leaver, out of the squad
                    seats[i], poss[i] = seat, e.pos
                    owners[i] = who(seat)
                    n = n + 1
                end
            end
            if n > already then
                p.coopMission.seats[seat] = who(seat) or true
                inMission[seat] = n
                print(string.format("[mnb_coop] seat %d's soldiers come in as reinforcements (%d)", seat, n - already))
            end
        end
    end
end

-- =============================================================================
-- XP DAY CAP (owner's rule, 2026-11-11): no farming the easy days. On the war's
-- first day (D-Day) soldiers can't get past level 2, on the second past level 4;
-- from the third day on there is no cap. "Day" = missions won (player.gainz,
-- which also picks the map). A soldier reaches level L at 10*(L-1) XP (giveXp,
-- urb_engine.lua:14694-14730), so a cap of L keeps XP below 10*L.
-- =============================================================================
campaign.CAPS = { [1] = 2, [2] = 4 }

function campaign.levelCap(gainz)
    return campaign.CAPS[math.floor(tonumber(gainz) or 1)] or 11
end

-- the day whose cap applies right now (host / alone): the open mission's, else the save's
function campaign.currentGainz()
    local p = campaign.profile
    if type(p) ~= "table" then return 99 end
    if type(p.coopMission) == "table" and p.coopMission.gainz then return p.coopMission.gainz end
    return tonumber(p.gainz) or 1
end

-- How much of `xp` a soldier may still earn under a cap (0 when he's at it).
function campaign.cappedXp(dude, xp, cap)
    if cap >= 11 then return xp end
    local top = 10 * cap - 0.01
    local have = tonumber(dude.xp) or 0
    if have >= top then return 0 end
    return math.min(xp, top - have)
end

-- Wraps the game's giveXp (installed from mnb_coop_main). Only in the co-op
-- campaign; Classic and the single-player campaign are untouched.
function campaign.wrapGiveXp(realGiveXp)
    return function(dude, xp, ...)
        if campaign.active and type(dude) == "table" and dude.faction == "allied" and type(xp) == "number"
            and type(player) == "table" and player.gameType ~= 1 then
            local cap = campaign.levelCap(campaign.applyingGainz or campaign.currentGainz())
            local allowed = campaign.cappedXp(dude, xp, cap)
            if allowed < xp and dude.coopCapNoted ~= 1 and player.gameState == 0 then
                dude.coopCapNoted = 1 -- once per soldier per mission
                pcall(floatyText, dude, "XP capped: level " .. cap .. " on this day")
            end
            if allowed <= 0 then return end
            return realGiveXp(dude, allowed, ...)
        end
        return realGiveXp(dude, xp, ...)
    end
end

-- =============================================================================
-- D-DAY KEEPS VETERANS AS THEY ARE
-- On D-Day the game gives squad slots 1..6 new perks and, on the easier
-- difficulty, a fresh M1 (preGameAdmin, urb_engine.lua:40220-40283). Fine for
-- rookies; a veteran joining a friend's D-Day, or landing again in a New war,
-- would lose his for good. Soldiers who already earned XP keep theirs.
-- =============================================================================
function campaign.stashVeterans()
    if not campaign.active or type(player) ~= "table" then return nil end
    local stash = {}
    for i = 1, coopSquadMax() do
        local t = player.deployedTroops and player.deployedTroops[i]
        if type(t) == "table" and (tonumber(t.xp) or 0) > 0 then
            stash[t] = { perks = copyData(t.perks, 0), weapon = copyData(t.weapon, 0) }
        end
    end
    return stash
end

function campaign.restoreVeterans(stash)
    if type(stash) ~= "table" then return end
    for t, kept in pairs(stash) do
        if type(kept.perks) == "table" then t.perks = kept.perks end
        if type(kept.weapon) == "table" and next(kept.weapon) then t.weapon = kept.weapon end
    end
end

-- =============================================================================
-- NEW WAR (owner's rule): day, sector, career and ribbons start over; the six
-- soldiers stay with their levels. The old save is kept as a backup file. Safe
-- because the new war starts under the day 1 cap again.
-- freshStart = true: a full reset, the six soldiers are new rookies too.
-- =============================================================================
function campaign.newWar(freshStart)
    if not campaign.active then return false, "open your co-op save first" end
    campaign.track()
    local p = campaign.profile
    if type(p) ~= "table" then return false, "no co-op save" end
    if type(p.coopMission) == "table" then
        -- a mission still under way in this save (the game was left mid-battle): it's
        -- abandoned, everyone's soldiers go home first as after any mission. (This used to
        -- refuse with "finish the mission first", which read as New war doing nothing.)
        campaign.settleMission()
        p = campaign.profile
        if type(p) ~= "table" or type(p.coopMission) == "table" then return false, "could not close the mission under way" end
    end
    campaign.normalize(p)
    local keep = {}
    if not freshStart then
        for i = 1, 6 do keep[i] = p.deployedTroops[i] end
    end
    -- the war that ends is kept as a backup
    local data = serialize(p)
    if data then pcall(realFs.write, REDIRECT["saveMNB3.lua"] .. ".war" .. os.time(), data) end
    local fresh = asPlayer({}, function()
        newProfile()
        return player
    end)
    if type(fresh) ~= "table" then return false, "could not start a new war" end
    fresh.bloop = p.bloop or 0
    local updated = asPlayer(fresh, function()
        updateProfile(player)
        return player
    end)
    if type(updated) == "table" then fresh = updated end
    fresh.coopCampaign = 1
    copySettings(p, fresh)
    campaign.normalize(fresh)
    for i = 1, 6 do
        if type(keep[i]) == "table" then
            untag(keep[i])
            fresh.deployedTroops[i] = keep[i]
        end
    end
    fresh.gameState = 1
    player = fresh
    campaign.profile = fresh
    campaign.save()
    print(freshStart and "[mnb_coop] fresh start: day 1 with six new rookies"
        or "[mnb_coop] new war: back to day 1, the six soldiers come along")
    return true
end

-- Control follows the slot (owner's rule): whoever stands in squad slot i belongs to
-- that slot's player, including a replacement the game puts in a dead soldier's
-- slot (a new table without our tags). Stamped every frame; cheap. A slot whose
-- player isn't connected is commanded by the host (coop_squad.ownerOf).
function campaign.retag()
    local p = campaign.profile
    if not campaign.active or type(p) ~= "table" or type(p.coopMission) ~= "table" then return end
    local troops, owners, seats = p.deployedTroops, p.coopSlotOwners or {}, p.coopSlotSeats
    if type(troops) ~= "table" or type(seats) ~= "table" then return end
    if campaign.page ~= 1 then return end
    for i = 1, coopSquadMax() do
        local t = troops[i]
        if type(t) == "table" and t.faction == "allied" and t.playerControlled == 1 and t.npc ~= 1 and t.coopNpc ~= 1 then
            t.coopSquad, t.coopOwner = 1, owners[i]
            if seats[i] then t.coopSeat = seats[i] end
        end
    end
end

-- After the game set up the mission: soldiers 7+ (later 4-player mode) stand next
-- to soldiers 1..6 and, on D-Day, get the same perks and rifles the game gives 1..6.
function campaign.placeExtras(dday)
    if not campaign.active then return end
    local troops = player.deployedTroops
    for i = 7, coopSquadMax() do
        local t, buddy = troops[i], troops[((i - 1) % 6) + 1]
        if type(t) == "table" and type(buddy) == "table" then
            t.x = (buddy.x or 300) + randNbr(40) - 20
            t.y = (buddy.y or 500) + 30 + randNbr(20)
            t.targetx, t.targety = t.x, t.y
            t.morale = 100
            if dday then
                t.og = 1
                t.perks = { randNbr(21) }
                pcall(assignNextPerk, t)
                if player.diff == 0 and t.weapon then pcall(weaponCreator, t.weapon, "m1") end
            end
        end
    end
end

-- ---------------------------------------------------------------- client: rosters
-- The top of this player's roster goes to the host (as many as the biggest share a
-- friend can have: 3). Sent on joining, after sorting, and after results.
function campaign.sendRoster()
    if net.role ~= "client" then return end
    campaign.withProfile(function(p)
        local list = {}
        for k = 1, 3 do
            local pos = PRIORITY[k]
            local s = p.deployedTroops[pos]
            if type(s) == "table" then list[#list + 1] = { pos = pos, soldier = copyData(s, 0) } end
        end
        net.sendToHost({ t = "roster", soldiers = list })
        log("sent my top %d soldiers to the host", #list)
    end)
end

-- "results" from the host: kept until this machine is back from the battle view.
function campaign.queueResults(msg)
    if type(msg.soldiers) ~= "table" then return end
    campaign.pendingResults = msg
    if not (mnbCoop and mnbCoop.battle and mnbCoop.battle.viewing) then campaign.applyPendingResults() end
end

function campaign.applyPendingResults()
    local msg = campaign.pendingResults
    campaign.pendingResults = nil
    if type(msg) ~= "table" then return end
    campaign.withProfile(function(p)
        local troops = p.deployedTroops
        p.cimetery = p.cimetery or {}
        local fielded, gains = {}, {}
        for _, e in ipairs(msg.soldiers) do
            local pos = type(e) == "table" and tonumber(e.pos)
            if pos and pos >= 1 and pos <= 6 and type(e.soldier) == "table" then
                pos = math.floor(pos)
                fielded[pos] = true
                local old, s = troops[pos], sanitize(e.soldier)
                -- the soldier who went out was replaced on the field: he fell
                if isAlive(old) and old.coopUid ~= s.coopUid then
                    old.dead, old.health = 1, 0
                    old.dateOfDeath = old.dateOfDeath or msg.day or p.dayz
                    p.cimetery[#p.cimetery + 1] = old
                end
                if isAlive(s) then
                    if type(old) == "table" and old.coopUid == s.coopUid then
                        gains[#gains + 1] = (tonumber(s.xp) or 0) - (tonumber(old.xp) or 0)
                    end
                    if type(s.coopUid) ~= "string" then s.coopUid = newUid() end
                    troops[pos] = untag(s)
                else
                    -- killed in action: on the memorial; a recruit takes the place
                    s.dateOfDeath = s.dateOfDeath or msg.day or p.dayz
                    p.cimetery[#p.cimetery + 1] = s
                    troops[pos] = newSoldier()
                end
            end
        end
        local sum = 0
        for _, g in ipairs(gains) do sum = sum + g end
        local half = #gains > 0 and math.floor(sum / #gains / 2) or 0
        if half >= 1 then
            -- home soldiers' half follows the day cap of the host's mission, not this save's day
            local cap = campaign.levelCap(msg.gainz or 99)
            campaign.applyingGainz = msg.gainz or 99
            for pos = 1, 6 do
                local s = troops[pos]
                if not fielded[pos] and isAlive(s) then
                    local amount = campaign.cappedXp(s, half, cap)
                    if amount > 0 then pcall(giveXp, s, amount) end
                end
            end
            campaign.applyingGainz = nil
        end
        print(string.format("[mnb_coop] mission results: %d soldiers back, home soldiers +%d XP", #msg.soldiers, half))
    end)
    campaign.sendRoster()
end

-- ---------------------------------------------------------------- squad screen
-- The game's Squad screen (menuPage 3) shows slots 1..6 as cards: columns at x 50,
-- 275, 500; rows at y 185 (1, 3, 5) and 430 (2, 4, 6); 200x220 each
-- (drawFiles.lua:3020-3025). Right-drag a card onto another to swap them (the same
-- gesture as the battle's face drag). Each card says GOING or HOME.
campaign.page = 1
local SQUAD_PAGES = { [3] = true, [4] = true, [5] = true }
local CARD_X, CARD_Y, CARD_W, CARD_H = { 50, 275, 500 }, { 185, 430 }, 200, 220

local function cardAt(x, y)
    for c = 1, 3 do
        for r = 1, 2 do
            if x >= CARD_X[c] and x <= CARD_X[c] + CARD_W and y >= CARD_Y[r] and y <= CARD_Y[r] + CARD_H then
                return (c - 1) * 2 + r
            end
        end
    end
    return nil
end

local drag = nil

function campaign.squadPress(x, y, button)
    if not campaign.active or menuPage ~= 3 or button ~= 2 then return false end
    local slot = cardAt(x, y)
    if not slot then return false end
    drag = slot
    pcall(function() iconSlide:clone():play() end)
    return true
end

function campaign.squadRelease(x, y, button)
    if button ~= 2 or not drag then return false end
    local from = drag
    drag = nil
    if not campaign.active or menuPage ~= 3 then return true end
    local to = cardAt(x, y)
    local troops = campaign.profile and campaign.profile.deployedTroops
    if not to or to == from or type(troops) ~= "table" then
        pcall(function() iconBad:clone():play() end)
        return true
    end
    troops[from], troops[to] = troops[to], troops[from]
    if soldierHighLight == from then soldierHighLight = to elseif soldierHighLight == to then soldierHighLight = from end
    pcall(function() iconGood:clone():play() end)
    campaign.save()
    if net.role == "client" then campaign.sendRoster() end
    return true
end

function campaign.drawSquadTags()
    if not campaign.active or menuPage ~= 3 then return end
    local font = nonoFont or love.graphics.getFont()
    love.graphics.setFont(font)
    local players = campaign.playersNow()
    for c = 1, 3 do
        for r = 1, 2 do
            local slot = (c - 1) * 2 + r
            local going = campaign.isGoing(slot, players)
            local x, y = CARD_X[c] + 6, CARD_Y[r] + 4
            love.graphics.setColor(0, 0, 0, 1)
            love.graphics.print(going and "GOING" or "HOME", x + 1, y + 1)
            if going then love.graphics.setColor(0.45, 0.8, 0.35, 1) else love.graphics.setColor(0.75, 0.75, 0.75, 1) end
            love.graphics.print(going and "GOING" or "HOME", x, y)
        end
    end
    local share = campaign.share(players)
    local hint = "Right-drag a card onto another to swap. You bring " .. share .. (share == 1 and " soldier" or " soldiers") ..
        " (" .. players .. (players == 1 and " player" or " players") .. "); the rest stay home and get half the XP."
    love.graphics.setColor(0, 0, 0, 1)
    love.graphics.print(hint, 51, 656)
    love.graphics.setColor(0.85, 0.85, 0.85, 1)
    love.graphics.print(hint, 50, 655)
    if drag then
        local s = campaign.profile and campaign.profile.deployedTroops[drag]
        local mx, my = love.mouse.getPosition()
        love.graphics.setColor(1, 1, 1, 0.9)
        love.graphics.print(type(s) == "table" and tostring(s.name) or "?", mx + 12, my)
    end
    love.graphics.setColor(1, 1, 1, 1)
end

-- ---------------------------------------------------------------- squad screens, 7..12
-- (later 4-player mode) The game's squad screens draw slots 1..6. A page switch
-- swaps soldiers 1..6 with 7..N in the list, so the second group gets the same screens.
function campaign.setPage(page)
    local p = campaign.profile
    if page == campaign.page or type(p) ~= "table" or type(p.deployedTroops) ~= "table" then return end
    local troops = p.deployedTroops
    local owners, seats, poss = p.coopSlotOwners or {}, p.coopSlotSeats or {}, p.coopSlotPos or {}
    local extra = math.min(6, coopSquadMax() - 6)
    for k = 1, extra do
        troops[k], troops[6 + k] = troops[6 + k], troops[k]
        owners[k], owners[6 + k] = owners[6 + k], owners[k]
        seats[k], seats[6 + k] = seats[6 + k], seats[k]
        poss[k], poss[6 + k] = poss[6 + k], poss[k]
    end
    campaign.page = page
end

function campaign.onSquadPage()
    return SQUAD_PAGES[menuPage] == true
end

function campaign.registerButtons()
    if not campaign.active or not SQUAD_PAGES[menuPage] or coopSquadMax() <= 6 then return end
    buttons[#buttons + 1] = Button.new(150, 686, 230, 30, "coopSquadPage", "active", true,
        "Show the other soldiers of the co-op squad on this screen")
end

function coopSquadPageButton()
    pcall(function() _G["weaponInspect" .. randNbr(5)]:clone():play() end)
    campaign.setPage(campaign.page == 1 and 2 or 1)
    soldierHighLight = 1
end

function campaign.squadPageLabel()
    if not campaign.active or not SQUAD_PAGES[menuPage] or coopSquadMax() <= 6 then return nil end
    local n = coopSquadMax()
    if campaign.page == 1 then return "SOLDIERS 7-" .. n .. " >" end
    return "< SOLDIERS 1-6"
end

-- name of the player who owns the soldier in slot i (for the squad screens)
function campaign.slotOwnerName(i)
    local t = type(player) == "table" and player.deployedTroops and player.deployedTroops[i]
    local seat = type(t) == "table" and t.coopSeat
    return seat and net.seats[seat] and net.seats[seat].name or nil
end

return campaign
