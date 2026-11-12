-- =============================================================================
-- TWO COPIES ON ONE PC: the windows share the screen.
-- For testing with two game windows on one PC (the friend joins 127.0.0.1): the host's
-- window goes to the top of the screen, the friend's to the bottom. The game's window is
-- a fixed 1280x720 that draws with no scaling (main.lua:46; its own scaling is commented
-- out at main.lua:4378), so on a screen too small for two of them each copy shrinks:
--   * the game draws a whole frame onto a 1280x720 canvas, shown scaled down;
--   * mouse positions (love.mouse.get*, the mouse callbacks) are scaled back up, so the
--     game's buttons and clicks land where they should;
--   * love.graphics.getWidth/getHeight/getDimensions report 1280x720, the size everything
--     draws for (our overlays, the game's moonshine effects).
-- Option `stackWindows` (default on) turns it off.
-- =============================================================================
local net = require("includes/mods/mnb_coop/coop_net")

local win = {}

win.GAME_W, win.GAME_H = 1280, 720
win.TASKBAR = 48 -- Windows' taskbar at the bottom (LOVE can't ask for the work area)
win.scale = 1
win.placedAs = nil

-- the layout for this screen: how much to shrink, and where each window goes
function win.layout(dw, dh, which)
    local W, H, room = win.GAME_W, win.GAME_H, dh - win.TASKBAR
    if room >= 2 * H then
        -- room for both at full size: one above the other
        return 1, math.floor((dw - W) / 2), which == "top" and 0 or room - H
    end
    if dw >= 2 * W then
        -- wide and short: side by side at full size
        return 1, which == "top" and 0 or dw - W, math.max(0, math.floor((room - H) / 2))
    end
    -- shrink both to half the height each, one above the other
    local s = math.min(room / 2 / H, dw / W)
    local w, h = math.floor(W * s), math.floor(H * s)
    return s, math.floor((dw - w) / 2), which == "top" and 0 or room - h
end

-- shrink this window to `s` of the game's size, drawing and reading the mouse to match
function win.shrink(s)
    if s >= 1 or win.scale ~= 1 then return end
    win.scale = s
    local W, H = win.GAME_W, win.GAME_H
    local _, _, flags = love.window.getMode()
    flags = flags or {}
    love.window.setMode(math.floor(W * s), math.floor(H * s),
        { resizable = false, vsync = flags.vsync or 1, borderless = true, display = flags.display })
    win.canvas = love.graphics.newCanvas(W, H)

    -- sizes: what the game draws for, not the shrunk window
    local g = love.graphics
    g.getWidth = function() return W end
    g.getHeight = function() return H end
    g.getDimensions = function() return W, H end

    -- drawing: the whole frame onto the canvas, then the canvas scaled into the window
    local draw = love.draw
    love.draw = function(...)
        g.push("all")
        g.setCanvas(win.canvas)
        g.clear(0, 0, 0, 1)
        local ok, err = pcall(draw, ...)
        g.pop()
        g.push("all")
        g.origin()
        g.setColor(1, 1, 1, 1)
        g.draw(win.canvas, 0, 0, 0, s, s)
        g.pop()
        if not ok then error(err, 0) end
    end

    -- the mouse: window pixels back to game pixels
    local m = love.mouse
    local gp, gx, gy = m.getPosition, m.getX, m.getY
    m.getPosition = function() local x, y = gp() return x / s, y / s end
    m.getX = function() return gx() / s end
    m.getY = function() return gy() / s end
    for _, name in ipairs({ "mousepressed", "mousereleased" }) do
        local f = love[name]
        if f then love[name] = function(x, y, ...) return f(x / s, y / s, ...) end end
    end
    local moved = love.mousemoved
    if moved then love.mousemoved = function(x, y, dx, dy, ...) return moved(x / s, y / s, dx / s, dy / s, ...) end end
end

-- Two copies on this PC: they run under the same Steam account, so the host's seat and a
-- friend's seat carry the same Steam id (a real friend always has another). Joining
-- 127.0.0.1 counts too, whatever the ids.
local function sameAccount(a, b)
    return type(a) == "table" and type(b) == "table" and a.steamId ~= nil and a.steamId ~= "" and a.steamId == b.steamId
end

function win.bothOnThisPC()
    local seats = net.seats or {}
    if net.role == "client" then
        return net.samePC == true or sameAccount(seats[1], seats[net.mySeat or 0])
    elseif net.role == "host" then
        if net.friendOnSamePC then return true end
        for i = 2, net.MAX_SEATS or 3 do
            if sameAccount(seats[1], seats[i]) then return true end
        end
    end
    return false
end

-- every frame: once both copies are known to be on this PC, lay the windows out
function win.update()
    local which
    if win.bothOnThisPC() then which = net.role == "host" and "top" or "bottom" end
    if not which or win.placedAs == which or not net.isOn("stackWindows", true) then return end
    win.placedAs = which
    local _, _, flags = love.window.getMode()
    local display = flags and flags.display or 1
    local dw, dh = love.window.getDesktopDimensions(display)
    local s, x, y = win.layout(dw, dh, which)
    if s < 1 then win.shrink(s) end
    love.window.setPosition(x, y, display)
end

return win
