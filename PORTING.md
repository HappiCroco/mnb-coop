# mnb_coop: not ported yet

Moved here from urb-modding-tool on 2026-11-10. It is still written for the old URB loader:
it uses `modLib.after(...)` hooks and `modLib.mobLog`, and `coop_helper.py` must sit next to `mnb.exe`
(`mnb_coop_main.lua` finds it with `love.filesystem.getSource()`).

It has no `qm.toml`, so `tools/qm.py` and the Mod Manager ignore it. To port: add a `qm.toml` with a
`module` patch, replace the `modLib` hooks with plain function wrappers (as the other mods do), and
replace `mobLog` with `modLibrary.debugLog`.
