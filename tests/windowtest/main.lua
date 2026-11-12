-- Headless test of coop_window.lua's layout: two 1280x720 game windows on one screen.
local MOD = os.getenv("COOP_DIR")
for _, n in ipairs({ "coop_codec", "coop_profile", "coop_mods", "coop_net", "coop_window" }) do
  package.preload["includes/mods/mnb_coop/" .. n] = function() return assert(loadfile(MOD .. "/" .. n .. ".lua"))() end
end
local fails, passes = 0, 0
local function check(c, w) if c then passes = passes + 1 else fails = fails + 1 print("FAIL: " .. w) end end
currentVersion = "x"
modLibrary = { option = function() return nil end }
local win = require("includes/mods/mnb_coop/coop_window")

-- the owner's screen: 1920x1080, too small for two at full size: both shrink, one above the other
local s, x, y = win.layout(1920, 1080, "top")
local s2, x2, y2 = win.layout(1920, 1080, "bottom")
local h = math.floor(720 * s)
check(s < 1 and s == s2, "1920x1080: both shrink by the same amount (" .. s .. ")")
check(y == 0 and y2 + h <= 1080 - win.TASKBAR and y2 >= h, "1920x1080: host on top, teammate below, no overlap, above the taskbar")
check(x == x2 and x >= 0, "1920x1080: both centred")
-- 2560x1440: still not 1440 + taskbar tall, but wide enough side by side at full size
s, x, y = win.layout(2560, 1440, "top")
s2, x2, y2 = win.layout(2560, 1440, "bottom")
check(s == 1 and x == 0 and x2 == 1280 and y == y2, "2560x1440: side by side at full size")
-- 4K: both at full size, one above the other
s, x, y = win.layout(3840, 2160, "top")
s2, x2, y2 = win.layout(3840, 2160, "bottom")
check(s == 1 and y == 0 and y2 >= 720 and x == x2, "3840x2160: stacked at full size")

-- who counts as "both copies on this PC"
local net = require("includes/mods/mnb_coop/coop_net")
net.role, net.mySeat = "client", 2
net.seats = { { name = "Me", steamId = "765" }, { name = "Me", steamId = "765" } }
check(win.bothOnThisPC(), "teammate copy: same Steam id as the host, any address")
net.seats[2].steamId = "999"
net.samePC = false
check(not win.bothOnThisPC(), "a real teammate (other Steam id) is never moved")
net.samePC = true
check(win.bothOnThisPC(), "joining 127.0.0.1 counts too")
net.role, net.samePC = "host", false
net.seats = { { name = "Me", steamId = "765" }, nil, { name = "Me", steamId = "765" } }
check(win.bothOnThisPC(), "host: a seat with its own Steam id")
net.seats = { { name = "Me", steamId = "765" }, { name = "Ann", steamId = "999" } }
check(not win.bothOnThisPC(), "host with a real teammate: not moved")
net.seats = { { name = "Me" }, { name = "Me" } }
check(not win.bothOnThisPC(), "no Steam ids (offline Steam): not guessed")

print(("%d passed, %d failed"):format(passes, fails))
love.event.quit(fails == 0 and 0 or 1)
