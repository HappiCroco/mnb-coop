-- =============================================================================
-- CO-OP TEST CHEATS (F6, option "Test cheats")
-- owner, 2026-11-12: "co-op specific cheats... applied anywhere: on the main menu it adds the
-- experience, on the co-op screen it adds to the co-op". The panel shows what fits where you are:
--   * main menu (your own profile): career XP, Classic XP, skill credits, your squad's XP;
--     saved at once (the real save, and the real Classic save for Classic XP);
--   * co-op lobby and co-op pages (your co-op profile): the same, on the co-op save;
--   * a battle on this machine (solo, or the host's): TP for everyone, heal, squad XP,
--     abilities ready, skill credits, items placed at the next click, next wave (Classic);
--   * watching the host's battle: nothing (it's the host's battle; the host can cheat).
-- Off by default, so nobody opens it by accident.
-- =============================================================================
local net = require("includes/mods/mnb_coop/coop_net")
local campaign = require("includes/mods/mnb_coop/coop_campaign")

local cheats = {}

cheats.KEY = "f6"          -- free in the game (it uses F1, F3, F4, F5, F7, F8, F9)
cheats.open = false
cheats.armed = nil         -- { loot, label }: the next click in the world places it
local swallowRelease = false

local X, Y, W, ROW, GAP = 30, 150, 260, 26, 4

local function notice(text)
    if mnbCoop and mnbCoop.notice then pcall(mnbCoop.notice, text) end
end

local function viewing() return mnbCoop and mnbCoop.battle and mnbCoop.battle.viewing end

local function lobbyPages()
    local lobby = mnbCoop and mnbCoop.lobby
    if not lobby then return false end
    return menuPage == lobby.page or menuPage == lobby.hubPage or menuPage == lobby.roomPage
end

-- where we are: "watching", "battle", "coop", "menu", or nil (nothing loaded yet)
function cheats.context()
    if viewing() then return "watching" end
    if type(player) ~= "table" then return nil end
    if player.gameState == 0 then
        if net.role == "client" then return "watching" end
        return "battle"
    end
    if campaign.active or lobbyPages() then return "coop" end
    return "menu"
end

local TITLES = {
    battle = "THIS BATTLE",
    coop = "YOUR CO-OP PROFILE",
    menu = "YOUR OWN PROFILE",
    watching = "THE HOST'S BATTLE",
}

-- ---------------------------------------------------------------- profile cheats
-- run fn(p) on the profile this screen is about, and save it
local function onProfile(ctx, fn)
    if ctx == "coop" then
        campaign.withProfile(fn)
    else
        fn(player)
        if player.gameType == 0 and not campaign.active and not (campaign.classic and campaign.classic.active) then
            campaign.saveRealProfile(player)
        end
    end
end

local function careerXp(ctx, kind, xp)
    local promos = 0
    onProfile(ctx, function(p) promos = campaign.addCareerXp(p, kind, xp) end)
    if kind == "classic" then
        -- the Classic save too, or leaving Classic would copy the older rank back
        local path = ctx == "coop" and (campaign.classic.DIR .. "/saveMNB2.lua") or "saveMNB2.lua"
        pcall(campaign.addClassicSaveXp, path, xp)
    end
    notice(string.format("%s +%d XP%s", kind == "classic" and "Classic" or "Career", xp,
        promos > 0 and (", promoted " .. promos .. "x") or ""))
end

local function squadXp(ctx, xp)
    local n = 0
    onProfile(ctx, function(p)
        for i = 1, 6 do
            local s = type(p.deployedTroops) == "table" and p.deployedTroops[i]
            if type(s) == "table" and (s.dead or 0) == 0 then
                if pcall(giveXp, s, xp) then n = n + 1 end
            end
        end
    end)
    notice(string.format("%d soldiers +%d XP", n, xp))
end

local function credits(ctx, n)
    onProfile(ctx, function(p) p.skillCredit = (tonumber(p.skillCredit) or 0) + n end)
    notice("Skill credits +" .. n)
end

-- ---------------------------------------------------------------- battle cheats
local function mySoldiers()
    local out = {}
    for _, t in ipairs(player.deployedTroops or {}) do
        if type(t) == "table" and t.faction == "allied" and t.playerControlled == 1 and (t.health or 0) > 0 then
            out[#out + 1] = t
        end
    end
    return out
end

local function addTp(n)
    local w = mnbCoop and mnbCoop.wallet
    if w and w.addAll then w.addAll(n) else player.tp = (tonumber(player.tp) or 0) + n end
    notice("TP +" .. n .. (net.playerCount() > 1 and " for everyone" or ""))
end

local function heal()
    local n = 0
    for _, t in ipairs(mySoldiers()) do
        t.health = t.maxHealth or 100
        if t.maxMorale then t.morale = t.maxMorale end
        n = n + 1
    end
    notice("Healed " .. n .. " soldiers")
end

local function battleXp(xp)
    local n = 0
    for _, t in ipairs(mySoldiers()) do if pcall(giveXp, t, xp) then n = n + 1 end end
    notice(string.format("%d soldiers +%d XP", n, xp))
end

local function recharge()
    for i = 1, 12 do
        local s = player.skill and player.skill[i]
        if type(s) == "table" and (s.id or 0) > 0 then s.timer, s.use = 0, 0 end
    end
    notice("Commander abilities ready")
end

local function nextWave()
    player.deployTimer = 1e6 -- (the wave comes once deployTimer > 60 + totalAxis(), urb_engine.lua:6084)
    notice("Next wave coming")
end

local function arm(loot, label)
    cheats.armed = { loot = loot, label = label }
    notice("Click where the " .. label .. " goes")
end

-- ---------------------------------------------------------------- the lists
function cheats.items(ctx)
    if ctx == "watching" then
        return { { text = "Cheats here are the host's (or play solo)" } }
    end
    if ctx == "battle" then
        local list = {
            { text = "+20 TP", fn = function() addTp(20) end },
            { text = "Heal the squad", fn = heal },
            { text = "Squad +200 XP", fn = function() battleXp(200) end },
            { text = "Abilities ready again", fn = recharge },
            { text = "+3 skill credits", fn = function() credits("battle", 3) end },
            { text = "Place: frag grenade", fn = function() arm("loot_frag", "frag grenade") end },
            { text = "Place: AT grenade", fn = function() arm("loot_atGrenade", "AT grenade") end },
            { text = "Place: smoke grenade", fn = function() arm("loot_smoke", "smoke grenade") end },
            { text = "Place: molotov", fn = function() arm("loot_molotov", "molotov") end },
            { text = "Place: bangalore", fn = function() arm("loot_bangalore", "bangalore") end },
            { text = "Place: ammo", fn = function() arm("loot_ammo", "ammo box") end },
            { text = "Place: medal", fn = function() arm("loot_medal", "medal") end },
        }
        if player.gameType == 1 then list[#list + 1] = { text = "Next wave now", fn = nextWave } end
        return list
    end
    if ctx == "coop" or ctx == "menu" then
        return {
            { text = "Career +1000 XP", fn = function() careerXp(ctx, "campaign", 1000) end },
            { text = "Classic +1000 XP", fn = function() careerXp(ctx, "classic", 1000) end },
            { text = "+3 skill credits", fn = function() credits(ctx, 3) end },
            { text = "Squad +200 XP each", fn = function() squadXp(ctx, 200) end },
        }
    end
    return {}
end

local function rows()
    local ctx = cheats.context()
    local list = cheats.items(ctx)
    local out = {}
    for i, it in ipairs(list) do
        out[i] = { it = it, x = X, y = Y + 26 + (i - 1) * (ROW + GAP), w = W, h = ROW }
    end
    return out, ctx
end

local function inside(r, x, y) return x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h end

-- ---------------------------------------------------------------- input and drawing
-- the toggle key; true if used
function cheats.keypressed(key)
    if key ~= cheats.KEY then return false end
    if not net.isOn("testCheats", false) then
        notice("Test cheats are off (co-op options)")
        return true
    end
    cheats.open = not cheats.open
    if not cheats.open then cheats.armed = nil end
    return true
end

-- mouse press; true if it is ours (then its release is ours too)
function cheats.mousepressed(x, y, button)
    if button ~= 1 or not net.isOn("testCheats", false) then return false end
    if cheats.open then
        for _, r in ipairs((rows())) do
            if inside(r, x, y) then
                if r.it.fn then
                    local ok, err = pcall(r.it.fn)
                    if not ok then notice("Cheat failed: " .. tostring(err)) end
                end
                swallowRelease = true
                return true
            end
        end
    end
    if cheats.armed and cheats.context() == "battle" then
        local a = cheats.armed
        cheats.armed = nil
        local ok = pcall(createLootByName, a.loot, x + (player.screenx or 0), y + (player.screeny or 0))
        notice(ok and (a.label .. " placed") or "Couldn't place it")
        swallowRelease = true
        return true
    end
    return false
end

function cheats.mousereleased(_, _, button)
    if button == 1 and swallowRelease then
        swallowRelease = false
        return true
    end
    return false
end

function cheats.draw()
    if not net.isOn("testCheats", false) then return end
    if cheats.armed and not cheats.open then
        local mx, my = love.mouse.getPosition()
        love.graphics.push("all")
        love.graphics.origin()
        love.graphics.setFont(nonoFont or love.graphics.getFont())
        love.graphics.setColor(1, 0.85, 0.4, 1)
        love.graphics.print("Click to place: " .. cheats.armed.label, mx + 14, my + 10)
        love.graphics.pop()
    end
    if not cheats.open then return end
    local list, ctx = rows()
    love.graphics.push("all")
    love.graphics.origin()
    local font = nonoFont or love.graphics.getFont()
    love.graphics.setFont(font)
    local h = 26 + #list * (ROW + GAP) + 8
    love.graphics.setColor(0, 0, 0, 0.78)
    love.graphics.rectangle("fill", X - 8, Y - 8, W + 16, h + 8, 4)
    love.graphics.setColor(0.45, 0.1, 0.1, 1)
    love.graphics.rectangle("line", X - 8, Y - 8, W + 16, h + 8, 4)
    love.graphics.setColor(1, 0.85, 0.4, 1)
    love.graphics.print("TEST CHEATS: " .. (TITLES[ctx] or "..."), X, Y)
    local mx, my = love.mouse.getPosition()
    for _, r in ipairs(list) do
        local hot = r.it.fn and inside(r, mx, my)
        love.graphics.setColor(hot and 0.35 or 0.2, hot and 0.12 or 0.2, hot and 0.12 or 0.2, 0.95)
        love.graphics.rectangle("fill", r.x, r.y, r.w, r.h)
        love.graphics.setColor(r.it.fn and 1 or 0.7, r.it.fn and 1 or 0.7, r.it.fn and 1 or 0.7, 1)
        love.graphics.print(r.it.text, r.x + 8, r.y + (r.h - font:getHeight()) / 2)
    end
    if cheats.armed then
        love.graphics.setColor(1, 0.85, 0.4, 1)
        love.graphics.print("Click to place: " .. cheats.armed.label, mx + 14, my + 10)
    end
    love.graphics.pop()
end

return cheats
