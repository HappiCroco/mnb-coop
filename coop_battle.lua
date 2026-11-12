-- =============================================================================
-- CO-OP BATTLE SYNC (step 2: watching)
-- The host runs the real battle. Clients get a MIRROR of the host's `player`
-- table and draw it with the game's own draw code; their own simulation is off.
--
--   Host, every frame : notes new effect entries (particles, explosions, cues)
--                       and every sound the game plays.
--   Host, 20 (or 10)/s: one "snap" message with only what changed since the last
--                       one, plus the new effects and sounds. zlib-compressed.
--   Client            : applies it to the mirror, smooths positions between
--                       snaps, and runs the effect lists itself (cue fading,
--                       particle motion in a sandbox where gameplay is switched off).
--
-- How "what changed" works (no list of fields to maintain):
--   * Plain fields of `player` (numbers, strings, nested tables) are diffed
--     against what was last sent. Floats are rounded to 0.01.
--   * Lists of tables (troops, vehicles, deco, buildings...) are diffed per
--     element. Elements are keyed by their table identity on the host, so a list
--     that shifts (blood decals trimmed from the front, a dead troop removed)
--     sends "removed k, added m" instead of resending everything.
--   * Effect lists (SPAWN) are never diffed: new entries go out once, whole.
--
-- Save safety: while watching, the client's real `player` is kept aside and
-- every file write outside coop/ is dropped, so the mirror can never reach the
-- game's save files. Leaving (Esc twice, host ends the battle, disconnect, quit)
-- puts the real `player` back first.
-- =============================================================================
local codec = require("includes/mods/mnb_coop/coop_codec")
local net = require("includes/mods/mnb_coop/coop_net")

local battle = {}

battle.viewing = false    -- client: watching the host's battle
battle.hostActive = false -- host: sending a battle
battle.stats = { snapBytes = 0, snapRaw = 0, fullBytes = 0, snaps = 0, sounds = 0 }

local DEL = "\1del" -- "this field is gone" in a delta
local MAXD = 6      -- nested table depth that is synced
local floor, abs, pi = math.floor, math.abs, math.pi

-- keys of `player` each machine keeps for itself (camera, settings, local weather)
local LOCAL = {
    showDirective = true, -- each player's own Classic directive panel (directiveMenuButton)
    screenx = true,
    screeny = true,
    masterScreenx = true,
    masterScreeny = true,
    memorialx = true,
    memorialy = true,
    gameState = true,
    rainParticles = true,
    fluffBalls = true,
    clouds = true,
    fullScreen = true,
    borderLess = true,
    brutalityWarn = true,
}
-- host-only simulation state, never sent (delayed actions run gameplay functions)
local HOSTONLY = { delayedAction = true, troopBin = true }
-- effect lists: new entries are sent once and each client runs them itself
local SPAWN = {
    particles = true,
    topParticles = true,
    explosions = true,
    textCue = true,
    damageCue = true,
    uiCue = true,
    iconCue = true,
    tipCue = true,
    waterCircles = true,
    mineCircles = true,
}
local SPAWN_CAP = 2000 -- client: oldest effects are dropped above this
-- lists that are lists of tables even while empty
local KNOWN_LISTS = {
    deployedTroops = true,
    deployedVehicles = true,
    neutrals = true,
    planes = true,
    buildings = true,
    placeables = true,
    lootables = true,
    mineField = true,
    deco = true,
    bgPatch = true,
    forest = true,
    rocks = true,
    road = true,
    leaves = true,
    groundType = true,
    losBlockers = true,
    fire = true,
    xmasLights = true,
}
-- moving things: positions and angles are smoothed between snaps
local INTERP = { deployedTroops = true, deployedVehicles = true, neutrals = true, planes = true }
-- element fields each machine keeps for itself (selection is per player)
local ELEM_LOCAL = { selected = true }
-- element fields sent once when the element first arrives, then each machine's
-- own: roof fading follows each player's own mouse (fadeClosestRoof/buildingsUpdate)
local ELEM_INIT = { fading = true, targetRoofAlpha = true, roofAlpha = true }

local function log(fmt, ...)
    if net.isOn("debug", false) then print("[mnb_coop] " .. string.format(fmt, ...)) end
end

local function isLocalKey(k)
    return LOCAL[k] or (type(k) == "string" and k:sub(1, 7) == "option_")
end

local function skipTop(k)
    return type(k) ~= "string" or isLocalKey(k) or HOSTONLY[k] or SPAWN[k]
end

local function skipNewElem(k) return ELEM_LOCAL[k] end
local function skipElem(k) return ELEM_LOCAL[k] or ELEM_INIT[k] end

-- ---------------------------------------------------------------- diff engine
local function q(v)
    if v ~= v then return 0 end
    if v == floor(v) or v == math.huge or v == -math.huge then return v end
    return floor(v * 100 + 0.5) / 100
end

local function syncable(v)
    local t = type(v)
    return t == "number" or t == "string" or t == "boolean" or t == "table"
end

-- Compares `cur` with `base` (our copy of what was last sent), brings `base` up
-- to date and returns the changes, or nil if nothing changed. `skip(k)` leaves
-- keys out (first level only).
local function diffTable(base, cur, depth, skip)
    local d
    for k, v in pairs(cur) do
        local tk = type(k)
        if (tk == "string" or tk == "number") and not (skip and skip(k)) then
            local tv = type(v)
            if tv == "number" then
                v = q(v)
                if base[k] ~= v then
                    base[k] = v
                    d = d or {}
                    d[k] = v
                end
            elseif tv == "string" or tv == "boolean" then
                if base[k] ~= v then
                    base[k] = v
                    d = d or {}
                    d[k] = v
                end
            elseif tv == "table" and depth < MAXD then
                local b = base[k]
                if type(b) ~= "table" then
                    b = {}
                    base[k] = b
                    d = d or {}
                    d[k] = diffTable(b, v, depth + 1) or {}
                else
                    local sub = diffTable(b, v, depth + 1)
                    if sub then
                        d = d or {}
                        d[k] = sub
                    end
                end
            end
        end
    end
    for k in pairs(base) do
        local v = cur[k]
        if v == nil or not syncable(v) or (skip and skip(k)) or (type(v) == "table" and depth >= MAXD) then
            base[k] = nil
            d = d or {}
            d[k] = DEL
        end
    end
    return d
end

local function applyDelta(target, d)
    for k, v in pairs(d) do
        if v == DEL then
            target[k] = nil
        elseif type(v) == "table" then
            local t = target[k]
            if type(t) ~= "table" then
                t = {}
                target[k] = t
            end
            applyDelta(t, v)
        else
            target[k] = v
        end
    end
end

-- effect entries are copied flat: their scalar fields only (an explosion's
-- `dad` is the whole shooter, not needed to draw it)
local function flatCopy(t)
    local c = {}
    for k, v in pairs(t) do
        local tv = type(v)
        if tv == "number" or tv == "string" or tv == "boolean" then c[k] = v end
    end
    return c
end

-- ---------------------------------------------------------------- host capture
local keyOf = setmetatable({}, { __mode = "k" }) -- element table -> network key
local nextKey = 0

local function newCaptureState()
    return { top = {}, lists = {}, mode = {} }
end

local function captureList(lb, cur, fresh)
    local keys, n = {}, 0
    local d = nil
    local elems = lb.elems
    for i = 1, #cur do
        local el = cur[i]
        if type(el) == "table" then
            local k = keyOf[el]
            if not k then
                nextKey = nextKey + 1
                k = nextKey
                keyOf[el] = k
            end
            n = n + 1
            keys[n] = k
            local be = elems[k]
            local ed
            if not be then
                be = {}
                elems[k] = be
                ed = diffTable(be, el, 1, skipNewElem) or {}
                for f in pairs(ELEM_INIT) do be[f] = nil end -- sent once, never diffed again
            else
                ed = diffTable(be, el, 1, skipElem)
            end
            if ed then
                d = d or {}
                d.e = d.e or {}
                d.e[k] = ed
            end
        end
    end
    local old = lb.order
    local same = not fresh and #old == n
    if same then
        for i = 1, n do if old[i] ~= keys[i] then
                same = false
                break
            end end
    end
    if not same then
        d = d or {}
        local inNew = {}
        for i = 1, n do inNew[keys[i]] = true end
        local rm, kept = {}, {}
        for i = 1, #old do
            local k = old[i]
            if inNew[k] then kept[#kept + 1] = k else
                rm[#rm + 1] = k
                elems[k] = nil
            end
        end
        local appendOnly = not fresh and #kept <= n
        if appendOnly then
            for i = 1, #kept do if kept[i] ~= keys[i] then
                    appendOnly = false
                    break
                end end
        end
        if appendOnly then
            if #rm > 0 then d.rm = rm end
            if n > #kept then
                local add = {}
                for i = #kept + 1, n do add[#add + 1] = keys[i] end
                d.add = add
            end
        else
            d.o = keys
        end
        lb.order = keys
    end
    return d
end

-- Everything that changed in `player` since `st` was last captured.
-- A fresh `st` gives the full state.
local function capture(st)
    local p = player
    local msg = {}
    for k, v in pairs(p) do
        if not skipTop(k) and type(v) == "table" and st.mode[k] ~= "list"
            and (KNOWN_LISTS[k] or type(v[1]) == "table") then
            st.mode[k] = "list"
        end
    end
    local lr
    for k in pairs(st.mode) do
        local v = p[k]
        -- stops being a list: gone, not a table, or a table of plain fields now
        if type(v) ~= "table" or (not KNOWN_LISTS[k] and next(v) ~= nil and type(v[1]) ~= "table") then
            st.mode[k] = nil
            if st.lists[k] then
                st.lists[k] = nil
                lr = lr or {}
                lr[#lr + 1] = k
            end
        end
    end
    msg.lr = lr
    msg.s = diffTable(st.top, p, 0, function(k) return skipTop(k) or st.mode[k] == "list" end)
    local l
    for k in pairs(st.mode) do
        local lb = st.lists[k]
        local fresh = false
        if not lb then
            lb = { order = {}, elems = {} }
            st.lists[k] = lb
            fresh = true
        end
        local ld = captureList(lb, p[k], fresh)
        if ld then
            l = l or {}
            l[k] = ld
        end
    end
    msg.l = l
    return msg
end

-- current contents of every effect list, for a full state
local function spawnContents()
    local sp = {}
    for name in pairs(SPAWN) do
        local list = player[name]
        local items = {}
        if type(list) == "table" then
            for i = 1, #list do
                if type(list[i]) == "table" then items[#items + 1] = flatCopy(list[i]) end
            end
        end
        sp[name] = items
    end
    return sp
end

-- ---------------------------------------------------------------- sounds
-- One wrapper on the Source methods catches every sound the game plays (it plays
-- clones of global Sources: `_G["huh"..n]:clone():play()`). The host names each
-- Source by its global, clones inherit the name; clients play the same global.
local nameOf = setmetatable({}, { __mode = "k" })
local instId = setmetatable({}, { __mode = "k" }) -- host: looping instance -> id
local nextInst = 0
local lastNameScan = -100
local rawPlay, rawStop, rawClone

local function scanSourceNames()
    lastNameScan = love.timer.getTime()
    for k, v in pairs(_G) do
        if type(k) == "string" and type(v) == "userdata" and not nameOf[v] then
            local ok, isSource = pcall(function() return v:typeOf("Source") end)
            if ok and isSource then nameOf[v] = k end
        end
    end
end

local H = nil -- host battle state
local C = nil -- client view state

-- Sound distance. The game sets a sound's loudness from how far its source is from
-- the camera (volumeScale gfx.lua:13, gunScale/stepScale/ambiantScale/exploScale
-- urb_engine.lua:17285-17364), as in `clone:setVolume(stepScale(dude)/2.3)`. The host
-- notes the scale call just before a setVolume: where the sound is and the factor on
-- top; each teammate works the loudness out again from their own camera.
local SCALE_CODE = { volumeScale = "v", gunScale = "g", stepScale = "s", exploScale = "e", ambiantScale = "a" }
local SCALE_NAME = {}
for name, code in pairs(SCALE_CODE) do SCALE_NAME[code] = name end
local lastScale = nil -- the scale call waiting for its setVolume
local soundPlace = setmetatable({}, { __mode = "k" })
local DEFAULT_FACTOR = 1 / 2.3 -- the game's usual factor, for a sound silent on the host's camera

for name, code in pairs(SCALE_CODE) do
    local orig = rawget(_G, name)
    if type(orig) == "function" then
        _G[name] = function(a, b, ...)
            local v = orig(a, b, ...)
            if H then
                local x, y
                if code == "a" then x, y = a, b elseif type(a) == "table" then x, y = a.x, a.y end
                if type(x) == "number" and type(y) == "number" and type(v) == "number" then
                    lastScale = { k = code, x = x, y = y, v = v }
                end
            end
            return v
        end
    end
end

-- host: the setVolume right after a scale call belongs to that place
local function noteVolume(src, vol)
    local s = lastScale
    lastScale = nil
    if not s or type(vol) ~= "number" then
        soundPlace[src] = nil
        return
    end
    local factor = s.v > 0 and vol / s.v or DEFAULT_FACTOR
    if factor < 0 or factor > 2 then
        soundPlace[src] = nil
        return
    end
    soundPlace[src] = { k = s.k, x = s.x, y = s.y, f = factor }
end

-- client: this machine's loudness for a placed sound, or nil
local function placedVolume(ev)
    local fn = SCALE_NAME[ev.k]
    local x, y, f = tonumber(ev.x), tonumber(ev.y), tonumber(ev.f)
    if not fn or not x or not y or not f or type(_G[fn]) ~= "function" then return nil end
    local ok, v
    if ev.k == "a" then ok, v = pcall(_G[fn], x, y) else ok, v = pcall(_G[fn], { x = x, y = y }) end
    if not ok or type(v) ~= "number" then return nil end
    return math.max(0, math.min(1, v * f))
end
battle.placedVolume = placedVolume

local function hostNoteSound(src)
    local name = nameOf[src]
    if not name and love.timer.getTime() - lastNameScan > 2 then
        scanSourceNames()
        name = nameOf[src]
    end
    if not name or #H.snd >= 48 then return end
    local okv, vol = pcall(src.getVolume, src)
    local okp, pitch = pcall(src.getPitch, src)
    local ev = { n = name, v = okv and q(vol) or 1, p = okp and q(pitch) or 1 }
    local place = soundPlace[src]
    if place then
        ev.k, ev.x, ev.y, ev.f = place.k, math.floor(place.x + 0.5), math.floor(place.y + 0.5), q(place.f)
    end
    local okl, looping = pcall(src.isLooping, src)
    if okl and looping then
        nextInst = nextInst + 1
        instId[src] = nextInst
        ev.i = nextInst
    end
    H.snd[#H.snd + 1] = ev
end

local function hookSources()
    local okd, sd = pcall(love.sound.newSoundData, 16)
    if not okd then return false end
    local oks, src = pcall(love.audio.newSource, sd)
    if not oks or not src then return false end
    local mt = getmetatable(src)
    local methods = type(mt.__index) == "table" and mt.__index or mt
    rawPlay, rawStop, rawClone = methods.play, methods.stop, methods.clone
    if not (rawPlay and rawStop and rawClone) then return false end
    local rawSetVolume = methods.setVolume
    methods.play = function(s, ...)
        -- clients only hear the host's sounds, plus their own view keys' clicks
        if battle.viewing and not battle.localSound then return false end
        if H then pcall(hostNoteSound, s) end
        lastScale = nil
        return rawPlay(s, ...)
    end
    if rawSetVolume then
        methods.setVolume = function(s, v, ...)
            if H then pcall(noteVolume, s, v) end
            return rawSetVolume(s, v, ...)
        end
    end
    methods.stop = function(s, ...)
        if H and instId[s] then
            H.snd[#H.snd + 1] = { s = instId[s] }
            instId[s] = nil
        end
        return rawStop(s, ...)
    end
    methods.clone = function(s, ...)
        local c = rawClone(s, ...)
        local name = nameOf[s]
        if name and c then nameOf[c] = name end
        return c
    end
    return true
end
battle.soundHooked = hookSources()

local function clientPlaySounds(list)
    for _, ev in ipairs(list) do
        if ev.s then
            local c = C.inst[ev.s]
            if c then
                pcall(rawStop, c)
                C.inst[ev.s] = nil
            end
        elseif type(ev.n) == "string" then
            local base = rawget(_G, ev.n)
            if type(base) == "userdata" then
                local ok, c = pcall(rawClone, base)
                if ok and c then
                    -- a placed sound: as loud as it is from this player's own camera
                    pcall(c.setVolume, c, placedVolume(ev) or tonumber(ev.v) or 1)
                    pcall(c.setPitch, c, math.max(0.01, tonumber(ev.p) or 1))
                    if ev.i then
                        pcall(c.setLooping, c, true)
                        C.inst[ev.i] = c
                    end
                    pcall(rawPlay, c)
                end
            end
        end
    end
end

-- ---------------------------------------------------------------- image globals
-- Some things the battle draw uses are globals the host sets while building the
-- map, not `player` fields: the background `bg` is `love.graphics.newImage(
-- "sprites/mudBg.png")` in preGameAdmin. The host remembers which file every
-- image came from and sends the file names of these globals; clients load the
-- same files (and get their own back when they stop watching).
local IMAGE_GLOBALS = { "bg" }
local imagePath = setmetatable({}, { __mode = "k" })

do
    local realNewImage = love.graphics.newImage
    love.graphics.newImage = function(src, ...)
        local img = realNewImage(src, ...)
        if type(src) == "string" and img then imagePath[img] = src end
        return img
    end
end

-- host: { name = path } for the image globals (only changed ones unless `all`)
local function imageGlobals(sent, all)
    local out
    for _, name in ipairs(IMAGE_GLOBALS) do
        local path = imagePath[rawget(_G, name)]
        if path and (all or sent[name] ~= path) then
            sent[name] = path
            out = out or {}
            out[name] = path
        end
    end
    return out
end

local imageCache = {}
local function safeImagePath(path)
    return type(path) == "string" and #path < 200 and not path:find("%.%.") and path:match("^[%w_/%-%.]+%.png$") ~= nil
end

-- client
local function applyImageGlobals(list)
    for name, path in pairs(list) do
        local known = false
        for _, n in ipairs(IMAGE_GLOBALS) do if n == name then known = true end end
        if known and safeImagePath(path) then
            local img = imageCache[path]
            if not img then
                local ok, loaded = pcall(love.graphics.newImage, path)
                if ok then
                    img = loaded
                    imageCache[path] = img
                end
            end
            if img then
                if C.savedGlobals[name] == nil then C.savedGlobals[name] = { v = rawget(_G, name) } end
                _G[name] = img
            end
        end
    end
end

-- ---------------------------------------------------------------- debrief
-- After a battle the host's game shows a mission-end page (drawState1): 4 mission
-- successful, 5 retreat/squad lost, 10 classic debrief, 14 war won, 15 war lost.
-- The sync keeps running there so teammates see the same page. Those pages animate
-- with globals (box1..9Timer, play*once, fades, the classic temp* stats), which the
-- host sends as plain values. Clients accept only names matching these patterns.
battle.DEBRIEF_PAGES = { [4] = true, [5] = true, [10] = true, [14] = true, [15] = true }
local GLOBAL_PATTERNS = { "^box%dTimer$", "^play%d+once$", "^temp[%w_]+$", "^mnb2Wave%w*$" }
local GLOBAL_NAMES = { uiFade = true, dateFade = true, bgFade = true, tipText = true }

local function isSyncedGlobal(name)
    if type(name) ~= "string" or #name > 40 then return false end
    if GLOBAL_NAMES[name] then return true end
    for _, p in ipairs(GLOBAL_PATTERNS) do if name:match(p) then return true end end
    return false
end

-- host: changed debrief globals since `sent` (all of them if `all`)
local function debriefGlobals(sent, all)
    local out
    for k, v in pairs(_G) do
        local tv = type(v)
        if (tv == "number" or tv == "string" or tv == "boolean") and isSyncedGlobal(k) then
            if tv == "number" then v = q(v) end
            if all or sent[k] ~= v then
                sent[k] = v
                out = out or {}
                out[k] = v
            end
        end
    end
    return out
end

-- client
local function applyDebriefGlobals(list)
    for name, v in pairs(list) do
        local tv = type(v)
        if isSyncedGlobal(name) and (tv == "number" or tv == "string" or tv == "boolean") then
            if C.savedGlobals[name] == nil then C.savedGlobals[name] = { v = rawget(_G, name) } end
            _G[name] = v
        end
    end
end

-- host: what the host's screen shows (battle, or which mission-end page)
local function viewState()
    -- pz: the host has the game paused (the global `pause`, Esc): teammates see a PAUSED banner
    -- instead of everyone just freezing (owner, 2026-11-12)
    return { gs = player.gameState == 0 and 0 or 1, page = tonumber(menuPage) or 0,
        pz = (tonumber(rawget(_G, "pause")) or 0) ~= 0 and 1 or 0 }
end

-- client: show the same thing
local function applyView(v)
    if type(v) ~= "table" then return end
    -- only a banner: the teammate's own `pause` stays 0 (their window must keep drawing and
    -- taking their keys; the host's updates simply stop moving things)
    if C then C.hostPaused = v.pz == 1 and v.gs == 0 end
    if v.gs == 0 then
        player.gameState = 0
    elseif battle.DEBRIEF_PAGES[v.page] then
        player.gameState = 1
        menuPage = v.page
        player.screenx, player.screeny = 0, 0 -- menus draw unscrolled (runTime1 does the same)
        mouseOverId = -99
    end
end

-- ---------------------------------------------------------------- packing
local function pack(msg)
    local raw = codec.encode(msg)
    battle.stats.lastRaw = #raw
    if #raw < 400 then return raw end
    local ok, z = pcall(love.data.compress, "string", "zlib", raw, 3)
    if ok and type(z) == "string" and #z < #raw then return codec.encode({ t = "z", z = z }) end
    return raw
end

-- ---------------------------------------------------------------- host side
local seen = setmetatable({}, { __mode = "k" }) -- effect entries already sent

local function markSpawnsSeen()
    for name in pairs(SPAWN) do
        local list = player[name]
        if type(list) == "table" then
            for i = 1, #list do if type(list[i]) == "table" then seen[list[i]] = true end end
        end
    end
end

local function hostScanSpawns()
    for name in pairs(SPAWN) do
        local list = player[name]
        if type(list) == "table" then
            for i = 1, #list do
                local el = list[i]
                if type(el) == "table" and not seen[el] then
                    seen[el] = true
                    local pend = H.pend[name]
                    if not pend then
                        pend = {}
                        H.pend[name] = pend
                    end
                    if #pend < 400 then pend[#pend + 1] = flatCopy(el) end
                end
            end
        end
    end
end

local function fullMessage(st)
    local msg = capture(st)
    msg.t = "bfull"
    msg.sp = spawnContents()
    msg.cam = { player.masterScreenx or player.screenx or 0, player.masterScreeny or player.screeny or 0 }
    msg.img = imageGlobals({}, true)
    msg.view = viewState()
    msg.g = debriefGlobals({}, true)
    msg.host = net.seats[1] and net.seats[1].name or "Host"
    return msg
end

local function hostStart()
    H = { st = newCaptureState(), pend = {}, snd = {}, acc = 0, seq = 0, joiners = {}, imgSent = {}, gSent = {} }
    battle.hostActive = true
    if battle.soundHooked then scanSourceNames() end
    markSpawnsSeen()
    local full = fullMessage(H.st)
    imageGlobals(H.imgSent, true)
    debriefGlobals(H.gSent, true)
    local data = pack(full)
    battle.stats.fullBytes = #data
    net.broadcastRaw(data, 1)
    log("battle sync started, full state %d bytes", #data)
end

local function hostStop()
    if not H then return end
    H = nil
    battle.hostActive = false
    net.broadcastRaw(codec.encode({ t = "bend" }), 1)
    log("battle sync stopped")
end

local function hostTick()
    H.seq = H.seq + 1
    local msg = capture(H.st)
    msg.t, msg.n = "snap", H.seq
    msg.img = imageGlobals(H.imgSent, false)
    msg.view = viewState()
    if player.gameState ~= 0 then msg.g = debriefGlobals(H.gSent, false) end -- only the mission-end pages need them
    if next(H.pend) then
        msg.sp = H.pend
        H.pend = {}
    end
    if #H.snd > 0 then
        msg.snd = H.snd
        battle.stats.sounds = battle.stats.sounds + #H.snd
        H.snd = {}
    end
    local data = pack(msg)
    battle.stats.snapBytes = #data
    battle.stats.snaps = battle.stats.snaps + 1
    net.broadcastRaw(data, 1, H.joiners)
    -- players who joined mid-battle get the whole state right after a tick, when
    -- the shared baseline matches what everyone else has
    if next(H.joiners) then
        local full = pack(fullMessage(newCaptureState()))
        battle.stats.fullBytes = #full
        for seat in pairs(H.joiners) do net.sendRawTo(seat, full, 1) end
        H.joiners = {}
    end
end

function battle.onSeatJoined(seat)
    if H then H.joiners[seat] = true end
end

-- Called after the game's own update, every frame.
function battle.hostUpdate(dt)
    if net.role ~= "host" or net.playerCount() < 2 then
        if H then hostStop() end
        return
    end
    local inBattle = player and player.gameState == 0
    -- after a battle, keep going while the host is on a mission-end page
    local inDebrief = H and player and player.gameState ~= 0 and battle.DEBRIEF_PAGES[menuPage]
    if inBattle and not H then
        hostStart()
    elseif not inBattle and not inDebrief and H then
        hostStop()
    end
    if not H then return end
    hostScanSpawns()
    H.acc = H.acc + dt
    local rate = tonumber(net.option("syncRate", 30)) or 30 -- (config.lua; at most one per frame)
    local interval = 1 / math.max(1, math.min(60, rate))
    if H.acc >= interval then
        H.acc = math.min(H.acc - interval, interval)
        local t0 = love.timer.getTime()
        hostTick()
        local now = love.timer.getTime()
        -- for the stats panel: the cost of one update (smoothed) and updates per second
        local s = battle.stats
        s.tickMs = (s.tickMs or 0) * 0.9 + (now - t0) * 1000 * 0.1
        if s.lastTickAt then s.rate = (s.rate or 0) * 0.9 + (1 / math.max(0.001, now - s.lastTickAt)) * 0.1 end
        s.lastTickAt = now
        -- out now: enet would otherwise send it at the next frame's service call, one
        -- frame later (the update is made after this frame's service, in hostUpdate)
        net.flush()
    end
end

-- ---------------------------------------------------------------- client side
local function isInterpField(f)
    return f == "x" or f == "y" or (type(f) == "string" and f:find("[Rr]otation") ~= nil)
end

local function lerpAngle(a, b, t)
    local d = b - a
    -- radians that wrapped around: take the short way
    if abs(d) > pi and abs(a) <= 2 * pi + 0.1 and abs(b) <= 2 * pi + 0.1 then
        d = (d + pi) % (2 * pi) - pi
    end
    return a + d * t
end

local function applyList(k, ld)
    local st = C.lists[k]
    local arr = player[k]
    local reorder = false
    if not st or type(arr) ~= "table" then
        st = { order = {}, byKey = {} }
        C.lists[k] = st
        arr = {}
        player[k] = arr
        reorder = true
    end
    local smooth = INTERP[k]
    local now = love.timer.getTime()
    if ld.e then
        for key, ed in pairs(ld.e) do
            local el = st.byKey[key]
            if not el then
                el = {}
                st.byKey[key] = el
                applyDelta(el, ed)
            elseif smooth then
                local it = C.interp[el]
                -- fields still moving that this snap doesn't touch: finish them
                if it then
                    for f, p in pairs(it) do
                        if f ~= "t0" and ed[f] == nil then
                            el[f] = p[2]
                            it[f] = nil
                        end
                    end
                end
                local from
                for f, v in pairs(ed) do
                    if type(v) == "number" and isInterpField(f) and type(el[f]) == "number" then
                        from = from or {}
                        from[f] = el[f]
                    end
                end
                applyDelta(el, ed)
                if from then
                    it = it or {}
                    C.interp[el] = it
                    it.t0 = now
                    for f, a in pairs(from) do
                        local b = el[f]
                        if f:find("[Rr]otation") or abs(b - a) < 400 then
                            it[f] = { a, b }
                            el[f] = a
                        else
                            it[f] = nil -- teleport: jump
                        end
                    end
                end
            else
                applyDelta(el, ed)
            end
        end
    end
    if ld.o then
        local keep = {}
        for _, key in ipairs(ld.o) do keep[key] = true end
        for key in pairs(st.byKey) do if not keep[key] then st.byKey[key] = nil end end
        st.order = ld.o
        reorder = true
    end
    if ld.rm then
        local gone = {}
        for _, key in ipairs(ld.rm) do
            gone[key] = true
            st.byKey[key] = nil
        end
        local o = {}
        for _, key in ipairs(st.order) do if not gone[key] then o[#o + 1] = key end end
        st.order = o
        reorder = true
    end
    if ld.add then
        for _, key in ipairs(ld.add) do st.order[#st.order + 1] = key end
        reorder = true
    end
    if reorder then
        for i = #arr, 1, -1 do arr[i] = nil end
        local o, used = {}, {}
        for _, key in ipairs(st.order) do
            local el = st.byKey[key]
            if el and not used[key] then
                used[key] = true
                o[#o + 1] = key
                arr[#arr + 1] = el
            end
        end
        st.order = o
    end
end

local function applySnap(msg)
    if type(msg.lr) == "table" then
        for _, k in ipairs(msg.lr) do
            C.lists[k] = nil
            player[k] = nil
        end
    end
    if type(msg.s) == "table" then applyDelta(player, msg.s) end
    if type(msg.l) == "table" then
        for k, ld in pairs(msg.l) do
            if type(k) == "string" and type(ld) == "table" then applyList(k, ld) end
        end
    end
    if type(msg.sp) == "table" then
        for name, items in pairs(msg.sp) do
            if SPAWN[name] and type(items) == "table" then
                local list = player[name]
                if type(list) ~= "table" then
                    list = {}
                    player[name] = list
                end
                for _, it in ipairs(items) do list[#list + 1] = it end
                local extra = #list - SPAWN_CAP
                if extra > 0 then for _ = 1, extra do table.remove(list, 1) end end
            end
        end
    end
    if type(msg.snd) == "table" then clientPlaySounds(msg.snd) end
    if type(msg.img) == "table" then applyImageGlobals(msg.img) end
    if type(msg.g) == "table" then applyDebriefGlobals(msg.g) end
    if msg.view then applyView(msg.view) end
end

local function startView(msg)
    if not C then
        C = { real = player, inst = {}, savedGlobals = {} }
        pcall(love.audio.stop)
        mousePrompt, mousePrompter, mousePromptLock = 0, 0, 0 -- armed skills come from the host (squad.onPrompt)
        specID, specDisplay, skillDisplay, abilityDisplay = -99, 0, 0, 0
        mnb2MenuDisplay = 0 -- this player's own Classic menu page
    end
    -- the mirror starts from nothing but this machine's own settings and camera,
    -- so nothing of the client's own profile can mix into the host's battle
    local m = {}
    for k, v in pairs(C.real) do
        if isLocalKey(k) and type(v) ~= "table" then m[k] = v end
    end
    m.rainParticles, m.fluffBalls, m.clouds = {}, {}, {}
    m.gameState = 0
    player = m
    C.lists, C.interp = {}, setmetatable({}, { __mode = "k" })
    C.lastAt, C.interval = love.timer.getTime(), 0.05
    C.hostName = type(msg.host) == "string" and msg.host or "Host"
    applySnap(msg)
    if type(msg.cam) == "table" then
        local x, y = tonumber(msg.cam[1]) or 0, tonumber(msg.cam[2]) or 0
        player.screenx, player.masterScreenx, player.screeny, player.masterScreeny = x, x, y, y
    end
    battle.viewing = true
    battle.leaveAskedAt = nil
    buttons = {}
    mouseOverText = ""
    pause = 0
    log("watching the host's battle")
end

-- Puts the client's own `player` back. Safe to call when not watching.
function battle.stopView(why)
    if not C then return end
    for _, c in pairs(C.inst) do pcall(rawStop, c) end
    pcall(love.audio.stop)
    for name, saved in pairs(C.savedGlobals) do _G[name] = saved.v end
    player = C.real
    player.gameState = 1
    pcall(love.graphics.setBackgroundColor, 0, 0, 0) -- (the game's own, main.lua:4248)
    C = nil
    battle.viewing = false
    buttons = {}
    mouseOverText = ""
    mouseOverId = -99 -- no soldier card left over from the host's battle
    specID, specDisplay, skillDisplay, abilityDisplay = -99, 0, 0, 0 -- nor a promotion panel
    mousePrompt, mousePrompter, mousePromptLock = 0, 0, 0             -- nor an armed skill
    mnb2MenuDisplay = 0                                               -- nor an open Classic menu
    if battle.onStopView then pcall(battle.onStopView, why) end
    log("stopped watching (%s)", tostring(why))
end

-- Client: Back on the mission report. This teammate is done with it: back to the lobby
-- now, still in the session; the host's next battle brings them in again (its "bfull").
-- Their soldiers' results come from the host when it leaves the report, as before.
function battle.leaveReport()
    if not battle.inDebrief() then return end
    pcall(function() clickSound:clone():play() end)
    battle.stopView("you left the mission report; you'll join the host's next battle")
end

-- Messages from the host (net.onHostMessage).
function battle.onHostMessage(msg)
    if msg.t == "z" then
        if type(msg.z) ~= "string" then return end
        local ok, raw = pcall(love.data.decompress, "string", "zlib", msg.z)
        if not ok or type(raw) ~= "string" then return end
        msg = codec.decode(raw, codec.HOST_LIMITS)
        if type(msg) ~= "table" then return end
    end
    if msg.t == "bfull" then
        startView(msg)
    elseif msg.t == "snap" then
        if not C then return end
        local now = love.timer.getTime()
        local gap = now - C.lastAt
        C.lastAt = now
        C.interval = math.max(0.03, math.min(0.25, C.interval * 0.8 + gap * 0.2))
        applySnap(msg)
    elseif msg.t == "bend" then
        battle.stopView("the host's battle ended")
    end
end

-- ---- client: effects animated locally, looks only
-- The game's particleUpdate/topParticleUpdate also land grenades, drop
-- paratroopers and hurt troops, so clients don't run them (a first try ran them
-- in a sandbox with gameplay switched off: a switched-off helper returning nil
-- made the game's code error every frame and every flash and tracer froze).
-- Instead this small mover does only what you see, with the same motion rules
-- (particlesSystem.lua:6531-6942 and 1-33): lifetime, drift, spin, drag, fade,
-- grow/shrink, flight along rotationz. What a particle DOES when it lands
-- (explosion, blood, loot) comes from the host as its own event.
local function moveParticles(list, dt)
    if type(list) ~= "table" then return end
    local step = dt * 60
    for i = #list, 1, -1 do
        local p = list[i]
        if type(p) ~= "table" or type(p.x) ~= "number" or type(p.y) ~= "number" then
            table.remove(list, i)
        else
            local life = (tonumber(p.lifeSpan) or 0) - dt
            p.lifeSpan = life
            p.innerRotation = (tonumber(p.innerRotation) or 0) + (tonumber(p.spin) or 0) * step
            p.x = p.x + (tonumber(p.drift) or 0)
            local vel, drag = tonumber(p.velocity) or 0, tonumber(p.drag) or 0
            if drag > 0 and vel > 0 then
                vel = vel - drag * step
                if vel < 0 then
                    vel = 0
                    p.spin = 0
                end
                p.velocity = vel
            end
            local fade = tonumber(p.fade) or 0
            if fade > 0 then p.alpha = (tonumber(p.alpha) or 0) - fade * step end
            local expand, shrink = tonumber(p.expand) or 0, tonumber(p.shrink) or 0
            if expand ~= 0 then p.scale = math.min(4, (tonumber(p.scale) or 1) + expand * dt) end
            if shrink > 0 and (tonumber(p.scale) or 0) > 0.0001 then p.scale = p.scale - shrink * dt end
            local rot = tonumber(p.rotationz)
            if vel ~= 0 and rot then
                p.x = p.x + math.sin(rot + pi) * vel * dt
                p.y = p.y - math.cos(rot + pi) * vel * dt
            end
            if life < 0 then table.remove(list, i) end
        end
    end
end

-- water and mine ripples: grow, then go (particlesSystem.lua:6516-6528)
local function moveCircles(list, dt)
    if type(list) ~= "table" then return end
    for i = #list, 1, -1 do
        local c = list[i]
        if type(c) ~= "table" then
            table.remove(list, i)
        else
            c.timer = (tonumber(c.timer) or 0) + dt * 50
            if c.timer > 300 then table.remove(list, i) end
        end
    end
end

local function safeCall(fn, dt)
    if type(fn) == "function" then
        local ok, err = pcall(fn, dt)
        if not ok then log("view update: %s", tostring(err)) end
    end
end

-- Client: replaces the game's update while watching.
-- client: on the host's mission-end page rather than in the battle
function battle.inDebrief()
    return C ~= nil and type(player) == "table" and player.gameState ~= 0
end

-- The Classic battle's background loop (gunfire in the distance) starts while the host
-- sets the battle up (mnb2.lua:369-377), before the sync runs, so it never reaches a
-- teammate. Their window starts the game's own loop once, as the game would have.
function battle.startBackground()
    if not C or C.bgStarted or type(player) ~= "table" or player.gameType ~= 1 or player.gameState ~= 0 then return end
    C.bgStarted = true
    local src = rawget(_G, "bgSound")
    if player.mnb2SubGame == 99 then
        if specialEvent == "Cologne" then src = rawget(_G, "cologneBGSound")
        elseif specialEvent == "Halloween" then src = rawget(_G, "nightBgSound") end
    end
    if type(src) ~= "userdata" or not rawPlay then return end
    pcall(src.setLooping, src, true)
    pcall(rawPlay, src)
end

function battle.clientUpdate(dt)
    if not C then return end
    if battle.inDebrief() then
        player.screenx, player.screeny = 0, 0 -- its timers and fades come from the host
        return
    end
    battle.startBackground()
    local now = love.timer.getTime()
    for el, it in pairs(C.interp) do
        local a = math.min(1, (now - it.t0) / C.interval)
        for f, p in pairs(it) do
            if f ~= "t0" then
                if type(f) == "string" and f:find("[Rr]otation") then
                    el[f] = lerpAngle(p[1], p[2], a)
                else
                    el[f] = p[1] + (p[2] - p[1]) * a
                end
            end
        end
        if a >= 1 then C.interp[el] = nil end
    end
    safeCall(textCueUpdate, dt)
    safeCall(uiCueUpdate, dt)
    safeCall(iconCueUpdate, dt)
    safeCall(tipCueUpdate, dt)
    safeCall(buildingsUpdate, dt)
    safeCall(updateLight, dt)
    moveParticles(player.particles, dt)
    moveParticles(player.topParticles, dt)
    moveCircles(player.waterCircles, dt)
    moveCircles(player.mineCircles, dt)
    -- selection ring pulse (the game animates it in its battle update)
    if type(selectCircle) == "number" then
        if selectCircleUp == 1 then
            selectCircle = selectCircle + dt * 10
            if selectCircle >= 10 then selectCircleUp = 0 end
        else
            selectCircle = selectCircle - dt * 10
            if selectCircle <= 0 then selectCircleUp = 1 end
        end
    end
    safeCall(screenControl, dt)
end

-- Client: Esc twice within 3 s leaves the session.
function battle.keypressed(key)
    if key ~= "escape" then return end
    local now = love.timer.getTime()
    if battle.leaveAskedAt and now - battle.leaveAskedAt < 3 then
        battle.leaveAskedAt = nil
        battle.stopView("you left")
        net.leave()
    else
        battle.leaveAskedAt = now
    end
end

-- Client: the game's draw failed on the mirror (nil = this frame drew fine).
-- Each different error is logged once.
function battle.noteDrawError(err)
    if not C then return end
    if err == nil then
        C.drawError = nil
        return
    end
    local first = tostring(err):match("^[^\n]*") or "?"
    C.drawError = first
    -- shown as an error pop-up (mnb_coop_main), kept up while it keeps happening
    if mnbCoop and mnbCoop.toast then pcall(mnbCoop.toast, "error", "part of the battle could not be drawn: " .. first, true) end
    C.loggedErrors = C.loggedErrors or {}
    if not C.loggedErrors[first] then
        C.loggedErrors[first] = true
        print("[mnb_coop] drawing the host's battle failed: " .. tostring(err))
    end
end

-- ---- client: the D-Day landing intro (campaign day 1, drawFiles.lua:1450-1563)
-- The sea there is the window's background colour, set by the host's game when the boat
-- ride starts (urb_engine.lua:40176) and back to black on landing (drawFiles.lua:2174):
-- a teammate's window never ran that, so their sea was black. Their colour follows the
-- mirrored state instead. The start choices (difficulty, map cycle, read the brief) are
-- the host's to click (diffSelect1..6, urb_engine.lua:44452): a teammate sees the step's
-- empty frame instead of buttons they can't press, and a note that the host is choosing.
local SEA = { 28 / 255, 39 / 255, 49 / 255 }
local HOST_CHOICE = { [-3] = "difficulty", [-5] = "map cycle", [-7] = "whether to read the brief" }

function battle.beforeDraw()
    if not C or type(player) ~= "table" then return end
    local boatRide = player.gainz == 1 and player.landed == 0 and player.gameState == 0
    if boatRide then
        love.graphics.setBackgroundColor(SEA[1], SEA[2], SEA[3])
    else
        love.graphics.setBackgroundColor(0, 0, 0)
    end
    C.hostChoosing = nil
    local step = tonumber(player.beachFade)
    if boatRide and step and HOST_CHOICE[step] then
        C.hostChoosing = HOST_CHOICE[step]
        player.beachFade = step + 1 -- the step before it draws nothing
        return function() player.beachFade = step end
    end
end

function battle.drawOverlay()
    if not C then return end
    if C.hostChoosing then
        love.graphics.push("all")
        love.graphics.origin()
        love.graphics.setFont(largeFont or love.graphics.getFont())
        local msg = C.hostName .. " is choosing the " .. C.hostChoosing .. "..."
        if C.hostChoosing:sub(1, 7) == "whether" then msg = C.hostName .. " is choosing " .. C.hostChoosing .. "..." end
        love.graphics.setColor(0, 0, 0, 1)
        for _, d in ipairs({ { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 } }) do
            love.graphics.printf(msg, d[1], 85 + d[2], love.graphics.getWidth(), "center")
        end
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.printf(msg, 0, 85, love.graphics.getWidth(), "center")
        love.graphics.pop()
    end
    if C.hostPaused then
        -- the host paused (Esc): say so in the middle of the screen, the game's big font,
        -- over a dimmed battle (the game's own pause screen isn't drawn on a teammate's window)
        love.graphics.push("all")
        love.graphics.origin()
        local sw, sh = love.graphics.getWidth(), love.graphics.getHeight()
        love.graphics.setColor(0, 0, 0, 0.35)
        love.graphics.rectangle("fill", 0, 0, sw, sh)
        local big = largeFont or love.graphics.getFont()
        local small = nonoFont or love.graphics.getFont()
        local y = sh / 2 - big:getHeight()
        love.graphics.setFont(big)
        love.graphics.setColor(0, 0, 0, 1)
        for _, d in ipairs({ { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 } }) do
            love.graphics.printf("PAUSED", d[1], y + d[2], sw, "center")
        end
        love.graphics.setColor(1, 0.85, 0.4, 1)
        love.graphics.printf("PAUSED", 0, y, sw, "center")
        love.graphics.setFont(small)
        love.graphics.setColor(0.9, 0.9, 0.9, 1)
        love.graphics.printf(C.hostName .. " paused the game", 0, y + big:getHeight() + 6, sw, "center")
        love.graphics.pop()
    end
    -- (a draw error shows as an error pop-up, battle.noteDrawError)
    local font = nonoFont or love.graphics.getFont()
    local text = "WATCHING " .. C.hostName:upper() .. "'S BATTLE"
    local sub = "Esc twice to leave"
    if battle.inDebrief() then
        text = C.hostName:upper() .. "'S MISSION REPORT"
        sub = "Back: return to the lobby whenever you like"
    end
    if battle.leaveAskedAt and love.timer.getTime() - battle.leaveAskedAt < 3 then
        sub = "Press Esc again to leave the co-op session"
    end
    love.graphics.push("all")
    love.graphics.origin()
    love.graphics.setFont(font)
    local w = math.max(font:getWidth(text), font:getWidth(sub)) + 24
    local x = (love.graphics.getWidth() - w) / 2
    love.graphics.setColor(0, 0, 0, 0.6)
    love.graphics.rectangle("fill", x, 6, w, font:getHeight() * 2 + 14, 4)
    love.graphics.setColor(1, 0.85, 0.4, 1)
    love.graphics.printf(text, x, 11, w, "center")
    love.graphics.setColor(0.85, 0.85, 0.85, 1)
    love.graphics.printf(sub, x, 13 + font:getHeight(), w, "center")
    love.graphics.pop()
end

-- ---------------------------------------------------------------- save safety
-- While watching, no file outside coop/ may be written: the game saves from
-- many places and `player` is the host's mirror then.
local fs = love.filesystem
for _, name in ipairs({ "write", "append", "remove" }) do
    local real = fs[name]
    if type(real) == "function" then
        fs[name] = function(path, ...)
            if battle.viewing and not (type(path) == "string" and path:sub(1, 5) == "coop/") then
                log("blocked a %s to %s while watching", name, tostring(path))
                return true
            end
            return real(path, ...)
        end
    end
end

-- ---------------------------------------------------------------- wiring
net.onHostMessage = function(msg) return battle.onHostMessage(msg) end
net.onSeatJoined = function(seat) return battle.onSeatJoined(seat) end
net.onReset = function()
    if C then battle.stopView("disconnected") end
    if H then
        H = nil
        battle.hostActive = false
    end
end

-- for tests
battle._test = {
    capture = capture,
    newCaptureState = newCaptureState,
    fullMessage = fullMessage,
    pack = pack,
    applySnap = applySnap,
    startView = startView,
    viewState = viewState,
    DEL = DEL,
    setClient = function(c) C = c end,
    getClient = function() return C end,
    setHost = function(h) H = h end,
    scanSourceNames = scanSourceNames,
}

return battle
