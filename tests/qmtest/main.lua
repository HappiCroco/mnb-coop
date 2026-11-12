-- Headless test of coop_qminput.lua: our key/mouse handlers next to QuarterMaster 1.8's input layer.
-- QM 1.8 installs its handlers when its module loads and again later (a patch in main.lua), each time
-- keeping whatever love.* holds as the function it calls next. A plain love.* swap in between looped
-- forever on the first click (main.lua:3492 'origMousePressed' ... stack overflow).
local MOD = os.getenv("COOP_DIR")
package.preload["includes/mods/mnb_coop/coop_qminput"] = function()
  return assert(loadfile(MOD .. "/coop_qminput.lua"))()
end
local qmInput = require("includes/mods/mnb_coop/coop_qminput")

local fails, passes = 0, 0
local function check(c, w) if c then passes = passes + 1 else fails = fails + 1 print("FAIL: " .. w) end end

local EVENTS = { mousepressed = { "handleMousePressed", "origMousePressed" },
  mousereleased = { "handleMouseReleased", "origMouseReleased" },
  keypressed = { "handleKeyPressed", "origKeyPressed" }, keyreleased = { "handleKeyReleased", "origKeyReleased" } }

local log, depth, maxDepth
local function reset() log, depth, maxDepth = {}, 0, 0 end

-- a stand-in for QM 1.8's QM.Input: same install rule (take love.* as "next" unless it is already ours)
local function makeQm()
  local input = {}
  for ev, n in pairs(EVENTS) do
    input[n[1]] = function(...)
      depth = depth + 1
      maxDepth = math.max(maxDepth, depth)
      log[#log + 1] = "qm"
      if depth < 50 and input[n[2]] then input[n[2]](...) end
      depth = depth - 1
    end
  end
  function input.installHooks()
    for ev, n in pairs(EVENTS) do
      if love[ev] ~= input[n[1]] then
        input[n[2]] = love[ev]
        love[ev] = input[n[1]]
      end
    end
  end
  return input
end

local function gameHandlers()
  for ev in pairs(EVENTS) do love[ev] = function() log[#log + 1] = "game" end end
end

-- ours: logs, then passes on to whatever wrap returned
local function installCoop()
  local nexts = {}
  for ev in pairs(EVENTS) do
    nexts[ev] = qmInput.wrap(ev, function()
      return function(...)
        log[#log + 1] = "coop"
        if nexts[ev] then return nexts[ev](...) end
      end
    end)
  end
end

local function same(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do if a[i] ~= b[i] then return false end end
  return true
end

-- 1. QM 1.8's order: game handlers, QM installs, our mod loads, QM installs again
gameHandlers()
QM = { Input = makeQm() }
QM.Input.installHooks()
installCoop()
QM.Input.installHooks()
for ev in pairs(EVENTS) do
  reset()
  love[ev](10, 20, 1)
  check(maxDepth == 1, ev .. ": QM's handler runs once, no loop (depth " .. maxDepth .. ")")
  check(same(log, { "qm", "coop", "game" }), ev .. ": QM, then ours, then the game's (" .. table.concat(log, ",") .. ")")
  check(love[ev] == QM.Input[EVENTS[ev][1]], ev .. ": love." .. ev .. " is still QM's handler")
end
-- a third install (if QM ever does one) changes nothing either
QM.Input.installHooks()
reset()
love.mousepressed(1, 1, 1)
check(same(log, { "qm", "coop", "game" }), "third QM install: same chain")

-- 2. no QuarterMaster input layer (QM 1.4): a plain wrap
QM = nil
gameHandlers()
installCoop()
reset()
love.mousepressed(1, 1, 1)
check(same(log, { "coop", "game" }), "no QM.Input: ours, then the game's (" .. table.concat(log, ",") .. ")")

-- 3. QM loads after us: it takes ours as next, both installs
gameHandlers()
installCoop()
QM = { Input = makeQm() }
QM.Input.installHooks()
QM.Input.installHooks()
reset()
love.mousepressed(1, 1, 1)
check(maxDepth == 1 and same(log, { "qm", "coop", "game" }), "QM after us: QM, ours, the game's (" .. table.concat(log, ",") .. ")")

-- 4. QM table without input handlers in love.* (another mod's QM global, or 1.8 before it installs)
QM = { Input = {} }
gameHandlers()
installCoop()
reset()
love.keypressed("a")
check(same(log, { "coop", "game" }), "QM.Input not in front: a plain wrap")

print(string.format("%d passed, %d failed", passes, fails))
love.event.quit(fails == 0 and 0 or 1)
