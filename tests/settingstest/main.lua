-- Two game copies sharing coop/settings.txt must not overwrite each other's addresses.
local MOD = os.getenv("COOP_DIR")
local fails, passes = 0, 0
local function check(c, w) if c then passes = passes + 1 else fails = fails + 1 print("FAIL: " .. w) end end
love.filesystem.setIdentity("coopsettingstest")
love.filesystem.remove("coop/settings.txt")

local hostCopy = assert(loadfile(MOD .. "/coop_profile.lua"))()
local joinCopy = assert(loadfile(MOD .. "/coop_profile.lua"))()
hostCopy.loadSettings()
joinCopy.loadSettings()

-- host pastes the playit address
hostCopy.settings.shareAddress = "name.playit.gg:12345"
hostCopy.saveSettings()
-- the other copy joins by that address
joinCopy.settings.lastAddress = "name.playit.gg:12345#ABCDE"
joinCopy.saveSettings()
-- host clicks its card (showcase) and saves again: must not wipe lastAddress
hostCopy.settings.showKind = "classic"
hostCopy.saveSettings()
-- the joining copy changes its showcase too
joinCopy.settings.showKind = "none"
joinCopy.saveSettings()

local fresh = assert(loadfile(MOD .. "/coop_profile.lua"))()
fresh.loadSettings()
check(fresh.settings.shareAddress == "name.playit.gg:12345", "host's share address kept: " .. tostring(fresh.settings.shareAddress))
check(fresh.settings.lastAddress == "name.playit.gg:12345#ABCDE", "joined address kept: " .. tostring(fresh.settings.lastAddress))
check(fresh.settings.showKind == "none", "latest showcase wins")
check(hostCopy.settings.lastAddress == "name.playit.gg:12345#ABCDE", "host copy picked up the other copy's change")
love.filesystem.remove("coop/settings.txt")
print(("%d passed, %d failed"):format(passes, fails))
love.event.quit(fails == 0 and 0 or 1)
