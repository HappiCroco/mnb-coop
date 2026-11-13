-- Headless test of coop_steam (Steam Join Game and invites): the connect string, a join that
-- comes in waits for the menus, and no Steam at all is harmless.
local MOD = os.getenv("COOP_DIR")
for _, n in ipairs({ "coop_codec", "coop_profile", "coop_mods", "coop_net", "coop_steam" }) do
  package.preload["includes/mods/mnb_coop/" .. n] = function() return assert(loadfile(MOD .. "/" .. n .. ".lua"))() end
end
local fails, passes = 0, 0
local function check(c, w) if c then passes = passes + 1 else fails = fails + 1 print("FAIL: " .. w) end end

local steam = require("includes/mods/mnb_coop/coop_steam")
check(steam.parseConnect("+mnb_coop name.playit.gg:12345#K7QXA") == "name.playit.gg:12345#K7QXA", "connect string parsed")
check(steam.parseConnect("mnb.exe -foo +mnb_coop 192.168.0.10:47913 -bar") == "192.168.0.10:47913", "found on a command line")
check(steam.parseConnect("+mnb_coop ;rm -rf") == nil and steam.parseConnect("+connect 1.2.3.4") == nil and steam.parseConnect(nil) == nil,
  "anything else is refused")

-- no Steam here (tests): init says so, nothing breaks
check(not steam.init() and not steam.ok and type(steam.why) == "string", "no Steam: off, with a reason (" .. tostring(steam.why) .. ")")
steam.update("1.2.3.4:5", true, function() return true end)
check(steam.pending == nil, "update without Steam does nothing")
check(select(1, steam.openInvite("x")) == false, "invite without Steam: false")

-- a join request waits until the menus can take it
steam.requestJoin(nil, "test")
check(steam.pending == nil, "an empty join is ignored")
steam.requestJoin("host.example:47913#ABCDE", "test")
check(steam.pending == "host.example:47913#ABCDE", "a join is kept")
steam.ok = true -- (pretend: the presence call fails quietly without the DLL)
local tries, joined = 0, nil
local function joinNow(a) tries = tries + 1 if tries < 3 then return false end joined = a return true end
steam.update(nil, false, joinNow)
steam.update(nil, false, joinNow)
check(steam.pending ~= nil and joined == nil, "kept while the menus can't take it")
steam.update(nil, false, joinNow)
check(steam.pending == nil and joined == "host.example:47913#ABCDE", "joined once they can")
steam.ok = false

print(("%d passed, %d failed"):format(passes, fails))
love.event.quit(fails == 0 and 0 or 1)
