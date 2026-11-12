-- Every mod file must compile (LuaJIT, same as the game).
local MOD = os.getenv("COOP_DIR")
local bad = 0
local files = { "coop_codec.lua", "coop_profile.lua", "coop_net.lua", "coop_campaign.lua", "coop_battle.lua",
  "coop_lobby.lua", "coop_hud.lua", "coop_squad.lua", "coop_wallet.lua", "coop_defense.lua", "coop_window.lua",
  "coop_qminput.lua", "coop_mods.lua", "coop_ribbons.lua", "mnb_coop_main.lua", "config.lua" }
local n = 0
for _, f in ipairs(files) do
  n = n + 1
  local fn, err = loadfile(MOD .. "/" .. f)
  if not fn then bad = bad + 1 print("COMPILE ERROR " .. err) else print("ok " .. f) end
end
print(("%d passed, %d failed"):format(n - bad, bad))
love.event.quit(bad)
