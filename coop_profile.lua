-- =============================================================================
-- CO-OP PROFILE
-- Who this player is on a lobby card: Steam name, Steam avatar (read from the
-- Steam client's own avatar cache), the in-game face as a fallback, and the
-- "showcase" the player picked (campaign rank, classic rank or a ribbon).
-- Also keeps co-op's own small settings file (last address, showcase), which
-- is separate from the game's saves.
-- =============================================================================
local profile = {}

local SETTINGS_FILE = "coop/settings.txt"
local MAX_AVATAR = 128 * 1024

profile.settings = { lastAddress = "", shareAddress = "", showKind = "campaign", showRib = 0 }

-- ---------------------------------------------------------------- settings
-- Plain "key=value" lines. Never loaded as Lua.
-- Two copies of the game on one PC (Launch Two Games.bat) share this file, so a
-- save only writes the settings THIS copy changed, merged into what the file
-- holds now; it never puts back another copy's old values.
local fromFile = {} -- what this copy last read from / wrote to the file (defaults count as read)
for k, v in pairs(profile.settings) do fromFile[k] = v end

local function readFile()
    local vals = {}
    local ok, text = pcall(love.filesystem.read, SETTINGS_FILE)
    if not ok or not text then return vals end
    for line in text:gmatch("[^\r\n]+") do
        local k, v = line:match("^(%w+)=(.*)$")
        if k and profile.settings[k] ~= nil then
            if type(profile.settings[k]) == "number" then
                vals[k] = tonumber(v)
            else
                vals[k] = v
            end
        end
    end
    return vals
end

function profile.loadSettings()
    local vals = readFile()
    for k, v in pairs(vals) do
        profile.settings[k] = v
        fromFile[k] = v
    end
end

function profile.saveSettings()
    local vals = readFile()
    for k, v in pairs(profile.settings) do
        if v ~= fromFile[k] then vals[k] = v end -- changed here: ours wins
    end
    local lines = {}
    for k, v in pairs(vals) do
        profile.settings[k] = v -- and pick up what the other copy changed
        fromFile[k] = v
        lines[#lines + 1] = k .. "=" .. tostring(v):gsub("[\r\n]", "")
    end
    table.sort(lines)
    pcall(love.filesystem.createDirectory, "coop")
    pcall(love.filesystem.write, SETTINGS_FILE, table.concat(lines, "\n"))
end

-- ---------------------------------------------------------------- steam
local function steamCall(fn)
    local ok, v = pcall(fn)
    if ok then return v end
    return nil
end

function profile.steamId()
    local id = steamCall(function() return Steam.user.getSteamID() end)
    if id == nil then return nil end
    local s = tostring(id):gsub("ULL$", ""):gsub("LL$", "")
    if s:match("^%d+$") then return s end
    return nil
end

function profile.name()
    local id = steamCall(function() return Steam.user.getSteamID() end)
    local name = id and steamCall(function() return Steam.friends.getFriendPersonaName(id) end)
    if type(name) == "string" and name ~= "" then return name:sub(1, 32) end
    if player and type(player.name) == "string" and player.name ~= "" then return player.name:sub(1, 32) end
    return "Soldier"
end

-- Steam root: the game sits in <Steam>/steamapps/common/<game>. A game in a second
-- library folder still has its avatar cache in the main Steam folder, so a couple of
-- usual install places are tried too.
local function steamRoots()
    local roots = {}
    local base = steamCall(function() return love.filesystem.getSourceBaseDirectory() end)
    if base then
        local root = base:gsub("\\", "/"):match("^(.-)/[Ss]team[Aa]pps/common/")
        if root then roots[#roots + 1] = root end
    end
    roots[#roots + 1] = "C:/Program Files (x86)/Steam"
    roots[#roots + 1] = "C:/Program Files/Steam"
    return roots
end

local function readBinary(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

-- A PNG we'll decode: also small in pixels (the IHDR chunk's width and height, bytes
-- 17-24). A few KB of PNG can claim 30000x30000 pixels, gigabytes once decoded on the
-- host and every friend. Steam avatars are 184x184.
local MAX_AVATAR_SIDE = 512
function profile.isPng(data)
    if type(data) ~= "string" or #data < 33 or #data > MAX_AVATAR or data:sub(1, 8) ~= "\137PNG\r\n\26\n" then return false end
    if data:sub(13, 16) ~= "IHDR" then return false end
    local function u32(i)
        local a, b, c, d = data:byte(i, i + 3)
        return ((a * 256 + b) * 256 + c) * 256 + d
    end
    local w, h = u32(17), u32(21)
    return w >= 1 and h >= 1 and w <= MAX_AVATAR_SIDE and h <= MAX_AVATAR_SIDE
end

-- Bytes of our own avatar PNG, or nil.
function profile.avatarBytes()
    local id = profile.steamId()
    if not id then return nil end
    for _, root in ipairs(steamRoots()) do
        local data = readBinary(root .. "/config/avatarcache/" .. id .. ".png")
        if profile.isPng(data) then return data end
    end
    return nil
end

-- Image from PNG bytes (ours or received). nil if the bytes are not a usable PNG.
function profile.imageFromBytes(data, tag)
    if not profile.isPng(data) then return nil end
    local ok, img = pcall(function()
        local fd = love.filesystem.newFileData(data, (tag or "avatar") .. ".png")
        return love.graphics.newImage(fd)
    end)
    return ok and img or nil
end

-- ---------------------------------------------------------------- face
function profile.face()
    local p = player or {}
    return {
        eyes = tonumber(p.eyes) or 1,
        nose = tonumber(p.nose) or 1,
        mouth = tonumber(p.mouth) or 1,
        hair = tonumber(p.hair) or 1
    }
end

-- Draws a face (from profile.face(), ours or a remote one) into a size x size box.
function profile.drawFace(face, x, y, size)
    if not faceBase then return end
    local s = size / faceBase:getWidth()
    love.graphics.draw(faceBase, x, y, 0, s, s)
    for _, part in ipairs({ "eyes", "nose", "mouth", "hair" }) do
        local img = _G["face_" .. part .. tostring(face and face[part] or 1)]
        if img then love.graphics.draw(img, x, y, 0, s, s) end
    end
end

-- ---------------------------------------------------------------- showcase
-- What the player shows on their card. Sent as { kind, n }; everyone owns the game,
-- so only numbers travel and each client draws its own copy of the sprite.
local function earnedRibs()
    local list = {}
    if player and type(player.ribs) == "table" then
        for _, n in ipairs(player.ribs) do
            if type(n) == "number" and _G["rib" .. n] then list[#list + 1] = n end
        end
    end
    return list
end

local function clampRank(n)
    n = tonumber(n) or 0
    if n < 1 then return nil end
    return math.min(13, math.floor(n))
end

function profile.showcase()
    local s = profile.settings
    if s.showKind == "campaign" then
        return { kind = "campaign", n = clampRank(player and player.rank) }
    elseif s.showKind == "classic" then
        return { kind = "classic", n = clampRank(player and player.mnb2Rank) }
    elseif s.showKind == "ribbon" then
        for _, n in ipairs(earnedRibs()) do
            if n == s.showRib then return { kind = "ribbon", n = n } end
        end
    end
    return { kind = "none" }
end

-- Clicking your own card steps through: campaign rank, classic rank, each ribbon, nothing.
function profile.nextShowcase()
    local s, ribs = profile.settings, earnedRibs()
    if s.showKind == "campaign" then
        s.showKind = "classic"
    elseif s.showKind == "classic" then
        if #ribs > 0 then s.showKind, s.showRib = "ribbon", ribs[1] else s.showKind = "none" end
    elseif s.showKind == "ribbon" then
        local nextRib
        for i, n in ipairs(ribs) do
            if n == s.showRib then
                nextRib = ribs[i + 1]
                break
            end
        end
        if nextRib then s.showRib = nextRib else s.showKind = "none" end
    else
        s.showKind = "campaign"
    end
    profile.saveSettings()
end

function profile.showcaseImage(show)
    if type(show) ~= "table" or type(show.n) ~= "number" then return nil end
    local n = math.floor(show.n)
    if show.kind == "campaign" then
        return _G["playerRank" .. n]
    elseif show.kind == "classic" then
        return _G["command_" .. n]
    elseif show.kind == "ribbon" then
        return _G["rib" .. n]
    end
    return nil
end

function profile.showcaseText(show)
    if type(show) ~= "table" or type(show.n) ~= "number" then return "" end
    local n = math.floor(show.n)
    local ok, text = pcall(function()
        if show.kind == "campaign" then
            return "Campaign: " .. rankTell(n)
        elseif show.kind == "classic" then
            return "Classic: " .. mnb2RankTell(n)
        elseif show.kind == "ribbon" then
            return tostring(_G["ribName_" .. n] or ("Ribbon " .. n)) .. ": " .. tostring(_G["ribDesc_" .. n] or "")
        end
    end)
    return ok and text or ""
end

return profile
