-- =============================================================================
-- CO-OP NETWORK STATS PANEL
-- A small box in the top-right corner while connected: ping to each player (or
-- to the host), how much is going up and down per second, totals, and messages
-- per second. Turned on with the "Show network stats" option or Ctrl+F8
-- (plain F8 belongs to GConsole).
-- =============================================================================
local net = require("includes/mods/mnb_coop/coop_net")

local hud = {}
hud.toggled = false -- Ctrl+F8 flips this on top of the option

local W, PAD = 230, 8

local function optionOn()
    return net.isOn("netStats", false)
end

function hud.visible()
    return net.role ~= "offline" and (optionOn() ~= hud.toggled)
end

local function kb(bytes)
    if bytes >= 1024 * 1024 then return string.format("%.1f MB", bytes / (1024 * 1024)) end
    return string.format("%.1f KB", bytes / 1024)
end

-- green under 80 ms, yellow under 160, red above
local function pingColor(ms)
    if ms < 80 then return 0.55, 0.85, 0.45 end
    if ms < 160 then return 0.95, 0.8, 0.3 end
    return 0.95, 0.35, 0.3
end

function hud.keypressed(key)
    local ctrl = love.keyboard.isDown("lctrl") or love.keyboard.isDown("rctrl")
    if key == "f8" and ctrl and net.role ~= "offline" then
        hud.toggled = not hud.toggled
        return true
    end
    return false
end

function hud.draw()
    if not hud.visible() then return end
    local font = nonoFont or love.graphics.getFont()
    local lineH = font:getHeight() + 2
    local s = net.stats
    local pings = net.pings()

    local rows = {}
    local title = net.role == "host" and "CO-OP HOST" or (net.role == "client" and "CO-OP CLIENT" or "CO-OP")
    rows[#rows + 1] = { title, 1, 1, 1 }
    for seat = 1, net.MAX_SEATS do
        local p = pings[seat]
        if p then
            local who = net.seats[seat] and net.seats[seat].name or ("Seat " .. seat)
            local r, g, b = pingColor(p.avg)
            rows[#rows + 1] = { string.format("%s: %d ms (last %d)", who, p.avg, p.last), r, g, b }
        end
    end
    if net.role == "host" and not next(pings) then rows[#rows + 1] = { "No players yet", 0.7, 0.7, 0.7 } end
    rows[#rows + 1] = { string.format("Up   %s/s   (%d msg/s)", kb(s.upRate), math.floor(s.msgsOutRate + 0.5)), 0.85, 0.85, 0.85 }
    rows[#rows + 1] = { string.format("Down %s/s   (%d msg/s)", kb(s.downRate), math.floor(s.msgsInRate + 0.5)), 0.85, 0.85, 0.85 }
    rows[#rows + 1] = { string.format("Total up %s, down %s", kb(s.totalUp), kb(s.totalDown)), 0.65, 0.65, 0.65 }
    local battle = mnbCoop and mnbCoop.battle
    if battle and (battle.hostActive or battle.viewing) then
        local b = battle.stats
        if battle.hostActive then
            rows[#rows + 1] = { string.format("Battle: snap %s (raw %s), full %s",
                kb(b.snapBytes or 0), kb(b.lastRaw or 0), kb(b.fullBytes or 0)), 0.75, 0.85, 1 }
            -- what one update costs the host's frame, and how many it actually sends
            rows[#rows + 1] = { string.format("Updates: %d/s, %.1f ms each", math.floor((b.rate or 0) + 0.5), b.tickMs or 0),
                (b.tickMs or 0) > 8 and 0.95 or 0.75, (b.tickMs or 0) > 8 and 0.6 or 0.85, (b.tickMs or 0) > 8 and 0.4 or 1 }
            -- the automatic rate: what it is now, and the teammate furthest behind
            local auto = net.isOn("autoRate", true)
            local lag, seat = b.lag or 0, b.lagSeat
            local who = seat and net.seats[seat] and net.seats[seat].name
            rows[#rows + 1] = { string.format("Rate %d/s%s, behind %.2f s%s", battle.currentRate(), auto and " (auto)" or "",
                lag, who and (" (" .. who .. ")") or ""), lag > 0.5 and 0.95 or 0.75, lag > 0.5 and 0.6 or 0.85, lag > 0.5 and 0.4 or 1 }
        else
            local buf = battle.bufferMs and battle.bufferMs()
            rows[#rows + 1] = { "Battle: watching" .. (buf and (", smoothing buffer " .. buf .. " ms") or ""), 0.75, 0.85, 1 }
        end
    end
    if net.role == "host" and (net.blocked or 0) > 0 then
        rows[#rows + 1] = { "Turned away: " .. net.blocked, 0.95, 0.5, 0.4 }
    end

    local w = W
    for _, row in ipairs(rows) do w = math.max(w, font:getWidth(row[1]) + PAD * 2) end
    local h = PAD * 2 + #rows * lineH
    local sw = love.graphics.getWidth()
    local x, y = sw - w - 10, 10
    love.graphics.push("all")
    love.graphics.origin()
    love.graphics.setColor(0, 0, 0, 0.72)
    love.graphics.rectangle("fill", x, y, w, h, 4)
    love.graphics.setColor(0.4, 0.1, 0.1, 0.9)
    love.graphics.rectangle("line", x, y, w, h, 4)
    love.graphics.setFont(font)
    for i, row in ipairs(rows) do
        love.graphics.setColor(row[2], row[3], row[4], 1)
        love.graphics.print(row[1], x + PAD, y + PAD + (i - 1) * lineH)
    end
    love.graphics.pop()
end

return hud
