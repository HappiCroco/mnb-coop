# Mud and Blood Co-op

Play Mud and Blood together: up to 3 players, one host running the battle, everyone commanding their own soldiers.

- **Co-op Campaign**: the campaign on its own co-op save. Each player brings their own six soldiers; results go back
  to each player's save. Your single-player campaign is never touched.
- **Co-op Classic (Defense)**: start in the middle around a radar, the Germans come from both sides. Ten Germans at the
  radar and it's over.

Needs the [QuarterMaster](https://github.com/Gamiseus/QuarterMaster) mod loader.

## Install
- **QuarterMaster launcher:** Mods > Browse > Mud and Blood Co-op > Install. Updates come the same way.
- **By hand:** download `mnb_coop.zip` from [Releases](https://github.com/HappiCroco/mnb-coop/releases) and extract it
  into the game's `Mods` folder, so you get `Mods/mnb_coop/qm.toml`.

Everyone playing together needs the same version. [GMenu](https://github.com/Gamiseus/MnB-Mods) is optional: it
gives the co-op an options page.

## Play
Main menu → **Multiplayer**. The host clicks HOST and shares the address (for online play behind a router, a
[playit.gg](https://playit.gg) UDP tunnel works); friends paste it and join.

## AI Disclosure
The code was written by Claude, but the code was checked and tested, design choices was also made by me, overall Claude is the main contributor to the project.

## Licence
MIT with the Commons Clause ([LICENSE](LICENSE)): use it, change it, share it, build on it, put it in your own
mods, all free. You can't sell it, or sell something whose value is mostly this mod. Keep the licence with copies.
It covers this mod's own code only. Mud and Blood and its files belong to their owners; nothing here includes or
grants rights to the game.

## For developers
`main` holds only what players get. Work happens on the
[`dev` branch](https://github.com/HappiCroco/mnb-coop/tree/dev), which also has the design notes (DESIGN.md), the
headless tests (`tests/run_tests.bat`, needs LÖVE's `lovec.exe`) and `Launch Two Games.bat` for testing on one PC.
