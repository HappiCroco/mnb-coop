-- Headless test of coop_mods.lua: reading a Mods folder, and how much each difference matters.
-- Mods/ here is a fake game Mods folder: a pictures-only pack, a host's F7 spawn menu
-- ("coop": "host"), a mod everyone needs ("coop": "both", code in a .lua file), one switched
-- off and a stray folder.
local MOD = os.getenv("COOP_DIR")
package.preload["includes/mods/mnb_coop/coop_mods"] = function() return assert(loadfile(MOD .. "/coop_mods.lua"))() end
local mods = require("includes/mods/mnb_coop/coop_mods")

local fails, passes = 0, 0
local function check(c, w) if c then passes = passes + 1 else fails = fails + 1 print("FAIL: " .. w) end end

-- 1. reading the folder (the real Windows listing, no console window)
mods.modsDir = function() return MOD .. "/tests/modtest/Mods" end
local mine = mods.mine(true)
check(type(mine) == "table" and #mine == 3, "three mods found (switched-off and stray skipped): " .. tostring(mine and #mine))
local byId = {}
for _, m in ipairs(mine or {}) do byId[m.id] = m end
check(byId.art_pack and byId.art_pack.c == false and byId.art_pack.n == "Art Pack", "a pictures-only pack: no code")
check(byId.spawn_menu and byId.spawn_menu.c == true and byId.spawn_menu.co == "host", "a patching mod: code, host-only by its mod.json")
check(byId.big_guns and byId.big_guns.c == true and byId.big_guns.co == "both" and byId.big_guns.v == "1.2.0",
  "a mod with a .lua file: code, needed by both")
check(mine and mine[1].id == "art_pack", "sorted by id")

-- 2. how much a difference matters
local function find(diffs, id) for _, d in ipairs(diffs) do if d.id == id then return d end end end
local host = mine
local friend = { { id = "big_guns", n = "Big Guns", v = "1.1.0", c = true, co = "both" } } -- old Big Guns only
local d = mods.compare(host, friend, "Ann")
check(find(d, "big_guns").sev == 3, "a 'both' mod in different versions: SERIOUS")
check(find(d, "spawn_menu").sev == 1, "the host's F7 spawn menu missing on the teammate: fine (only the host needs it)")
check(find(d, "art_pack").sev == 1, "a pictures-only pack on one side: fine")
check(d[1].id == "big_guns", "worst first")
local unknown = { { id = "new_units", n = "New Units", v = "1.0", c = true } }
d = mods.compare(unknown, {}, "Ann")
check(d[1].sev == 2 and d[1].text:find("Ann needs it too", 1, true), "an unmarked code mod only on the host: CHECK")
d = mods.compare({}, unknown, "Ann")
check(d[1].sev == 1 and d[1].text:find("their screen only", 1, true), "a code mod only on the teammate: fine, it can't change the host's battle")
d = mods.compare({}, { { id = "big_guns", n = "Big Guns", v = "1.2.0", c = true, co = "both" } }, "Ann")
check(d[1].sev == 3, "a 'both' mod only on the teammate: SERIOUS")
d = mods.compare(host, host, "Ann")
check(#d == 0 and mods.summary(d) == "Mods match", "same mods: match")
d = mods.compare(host, friend, "Ann")
check(mods.summary(d) == "Mods differ: 1 serious, 2 fine", "summary: " .. mods.summary(d))
check(mods.worst(d) == 3 and #mods.lines(d) == 3 and mods.lines(d)[1]:find("^SERIOUS  Big Guns"), "tooltip lines")

-- 3. a list from the network is cleaned
local dirty = mods.clean({ { id = ("x"):rep(500), v = 5, c = "yes", co = "everyone" }, "junk", { n = "no id" } })
check(#dirty == 1 and #dirty[1].id == 40 and dirty[1].v == "?" and dirty[1].c == false and dirty[1].co == nil,
  "a received list: long ids cut, wrong types dropped")
local many = {}
for i = 1, 500 do many[i] = { id = "m" .. i } end
check(#mods.clean(many) == mods.MAX, "a received list is cut at " .. mods.MAX)
check(mods.clean("nope") == nil, "not a list: no check")

-- 4. the real game folder (just that it reads; what's installed is the player's business)
mods.modsDir = function() return "D:/Games/Steam/steamapps/common/MudandBlood/Mods" end
local real = mods.mine(true)
print("game Mods folder: " .. (real and (#real .. " mods besides the co-op") or "not readable here"))

print(("%d passed, %d failed"):format(passes, fails))
love.event.quit(fails == 0 and 0 or 1)
