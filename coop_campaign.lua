-- =============================================================================
-- CO-OP CAMPAIGN (host side)
-- The co-op campaign is the game's own campaign, run on a SEPARATE profile:
-- its own save files, its own XP, ranks, squad and progress. The player's real
-- campaign is never read or written while it runs.
--
-- How: while co-op campaign is active, every love.filesystem call that names one
-- of the game's save files is redirected into coop/campaign/. The game's own
-- campaign code then loads and saves the co-op profile without knowing it.
--   enter(): keep the real `player` in memory, switch the redirect on, load the
--            co-op profile (or make a new one), open the campaign screen.
--   exit():  save the co-op profile, switch the redirect off, put the real
--            `player` back. Happens when the game returns to the main menu, and
--            on quit.
-- Settings (volume, fullscreen, particles...) live in the profile too, so they're
-- copied into the co-op profile on enter and back to the real one on exit.
-- =============================================================================
local campaign = {}

campaign.active = false
campaign.DIR = "coop/campaign"

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

local function mapPath(path)
    if campaign.active and type(path) == "string" and REDIRECT[path] then return REDIRECT[path] end
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

function campaign.hasSave()
    return realFs.getInfo(REDIRECT["saveMNB3.lua"]) ~= nil
end

-- Start or continue the co-op campaign. Returns false (and a reason) if it can't.
function campaign.enter()
    if campaign.active then return true end
    if type(player) ~= "table" then return false, "no profile loaded" end
    pcall(fs.createDirectory, campaign.DIR)
    realPlayer = player
    campaign.active = true

    local loaded = nil
    if realFs.getInfo(REDIRECT["saveMNB3.lua"]) then
        local ok, chunk = pcall(realFs.load, REDIRECT["saveMNB3.lua"])
        if ok and type(chunk) == "function" then
            local ok2, data = pcall(chunk)
            if ok2 and type(data) == "table" then loaded = data end
        end
    end
    if loaded then
        player = loaded
    else
        player = {}
        local ok, err = pcall(newProfile, player)
        if not ok then
            player, campaign.active = realPlayer, false
            return false, "could not make a co-op profile: " .. tostring(err)
        end
    end
    -- same order as the game's own startup: bloop is set before updateProfile, or
    -- updateProfile takes the profile for an old one and resets it
    player.bloop = realPlayer.bloop or 0
    pcall(updateProfile, player)
    copySettings(realPlayer, player)
    player.coopCampaign = 1
    player.gameState = 1
    campaign.page = 1
    pcall(campaign.arrangeSquad)
    campaign.save()
    print("[mnb_coop] co-op campaign " .. (loaded and "continued" or "started") .. ", day " .. tostring(player.dayz))
    return true
end

function campaign.save()
    if not campaign.active then return end
    local data = serialize(player)
    if data then pcall(realFs.write, REDIRECT["saveMNB3.lua"], data) end
end

-- Leave the co-op campaign: save it and give the real profile back.
function campaign.exit()
    if not campaign.active then return end
    campaign.setPage(1)
    campaign.save()
    local coopPlayer = player
    campaign.active = false
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

-- Called every frame (menu button pass): leaving to the main menu ends co-op campaign.
function campaign.update()
    if not campaign.active then return end
    if menuPage == 1 then campaign.exit() return end
    if not campaign.onSquadPage() then campaign.setPage(1) end
end

-- The game saves on quit; with the redirect on, that save lands in the co-op files.
-- Afterwards put the real profile back and save it the way the game would have.
function campaign.onQuitAfterGameSaved()
    if not campaign.active then return end
    campaign.exit()
    local data = serialize(player)
    if data then pcall(realFs.write, player.gameType == 0 and "saveMNB3.lua" or "saveMNB2.lua", data) end
end

-- =============================================================================
-- SQUAD: 3 SOLDIERS PER PLAYER
-- The game keeps the campaign squad in slots 1..6 of player.deployedTroops. In
-- the co-op campaign the squad is slots 1..N, N = 3 per player (a lone host keeps
-- the vanilla 6). Each squad soldier carries:
--   coopSquad = 1, coopOwner = the player's Steam id, coopSeat = lobby seat
-- Soldiers whose player isn't here this session sit out in player.coopBench.
-- qm.toml patches the game's "6" checks to call coopSquadMax() (replacement of
-- the dead, full-squad bonuses, size control, damage scale...).
-- =============================================================================
local net = require("includes/mods/mnb_coop/coop_net")
local profile = require("includes/mods/mnb_coop/coop_profile")

-- The squad size the game should use right now (6 outside the co-op campaign).
function coopSquadMax()
    if campaign.active and type(player) == "table" and tonumber(player.coopSquadTarget) then
        return player.coopSquadTarget
    end
    return 6
end

-- Who plays this session: { {id, name, seat}, ... } in seat order.
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

local function isSquad(t, i, target)
    if type(t) ~= "table" then return false end
    if t.coopSquad == 1 then return true end
    return i <= target and t.faction == "allied" and t.playerControlled == 1 and t.npc ~= 1
end

local function newSoldier()
    local s = {}
    createAlliedSoldier(s)
    s.perks = { randNbr(21) }
    pcall(assignNextPerk, s)
    return s
end

-- Put the right soldiers in slots 1..N for this session. Run in the menus, before a mission.
function campaign.arrangeSquad()
    if not campaign.active then return end
    campaign.setPage(1)
    local troops = player.deployedTroops
    local oldTarget = tonumber(player.coopSquadTarget) or 6

    -- 1. take every squad soldier out of the list (and off the bench)
    local pool = {}
    for i = #troops, 1, -1 do
        if isSquad(troops[i], i, oldTarget) then table.insert(pool, 1, table.remove(troops, i)) end
    end
    for _, s in ipairs(player.coopBench or {}) do pool[#pool + 1] = s end

    -- 2. give each player present up to `per` of their own soldiers
    local owners = campaign.owners()
    local per = (#owners <= 1) and 6 or 3
    player.coopOwnerNames = player.coopOwnerNames or {}
    local squad, bench, taken = {}, {}, {}
    for _, o in ipairs(owners) do
        player.coopOwnerNames[o.id] = o.name
        local mine = {}
        for k, s in ipairs(pool) do
            if not taken[k] and s.coopOwner == o.id and #mine < per then mine[#mine + 1] = s taken[k] = true end
        end
        o.soldiers = mine
    end
    -- 3. soldiers nobody owns yet (fresh profile, replacements) fill the gaps
    for _, o in ipairs(owners) do
        for k, s in ipairs(pool) do
            if #o.soldiers >= per then break end
            if not taken[k] and (s.coopOwner == nil) then o.soldiers[#o.soldiers + 1] = s taken[k] = true end
        end
        while #o.soldiers < per do o.soldiers[#o.soldiers + 1] = newSoldier() end
    end
    -- 4. everyone else sits out (their player isn't here, or a player had too many)
    for k, s in ipairs(pool) do if not taken[k] then bench[#bench + 1] = s end end

    local slotOwners = {}
    for _, o in ipairs(owners) do
        for _, s in ipairs(o.soldiers) do
            s.coopSquad, s.coopOwner, s.coopSeat = 1, o.id, o.seat
            squad[#squad + 1] = s
            slotOwners[#slotOwners + 1] = o.id
        end
    end
    for i, s in ipairs(squad) do table.insert(troops, i, s) end
    player.coopBench = bench
    player.coopSquadTarget = #squad
    player.coopSlotOwners = slotOwners
    print(string.format("[mnb_coop] squad: %d soldiers for %d player(s), %d sitting out", #squad, #owners, #bench))
end

-- A soldier the game re-creates in a squad slot (replacement of the dead) is a new
-- table without our tags: give it the slot's owner. Cheap; runs every frame.
function campaign.retag()
    if not campaign.active or type(player) ~= "table" then return end
    local troops, owners = player.deployedTroops, player.coopSlotOwners
    if type(troops) ~= "table" or type(owners) ~= "table" then return end
    for i = 1, coopSquadMax() do
        local t = troops[i]
        if type(t) == "table" and t.coopSquad ~= 1 and t.faction == "allied" and t.playerControlled == 1 then
            t.coopSquad, t.coopOwner = 1, owners[i]
        end
    end
end

-- After the game set up the mission: soldiers 7+ stand next to soldiers 1..6 and,
-- on D-Day, get the same perks and starting rifles the game gives 1..6.
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

-- ---------------------------------------------------------------- squad screens
-- The game's squad, roster and awards screens draw slots 1..6. A page switch swaps
-- soldiers 1..6 with 7..N in the list, so the second group gets the same screens.
campaign.page = 1
local SQUAD_PAGES = { [3] = true, [4] = true, [5] = true }

function campaign.setPage(page)
    if page == campaign.page or type(player) ~= "table" or type(player.deployedTroops) ~= "table" then return end
    local troops, owners = player.deployedTroops, player.coopSlotOwners or {}
    local extra = math.min(6, coopSquadMax() - 6)
    for k = 1, extra do
        troops[k], troops[6 + k] = troops[6 + k], troops[k]
        owners[k], owners[6 + k] = owners[6 + k], owners[k]
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
    local id = type(t) == "table" and t.coopOwner
    return id and player.coopOwnerNames and player.coopOwnerNames[id] or nil
end

return campaign
