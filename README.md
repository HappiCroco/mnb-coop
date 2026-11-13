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

Everyone playing together needs the same version. The co-op's options (port, join code, updates per second...) are on
QuarterMaster's Mod Options screen (QuarterMaster 1.8 or newer); without it the defaults are used.

## Play
Main menu → **Multiplayer**. The host clicks HOST A LOBBY. The game connects through Steam: teammates accept the host's
**INVITE (STEAM)**, click **Join Game** on the host in their Steam friends list, or paste the `steam:...#CODE` address the
host copied and click JOIN. No port forwarding or tunnel needed. (A local address like `192.168.0.10:47913`, or a
[playit.gg](https://playit.gg) UDP tunnel, still works too.) When the host picks a mode, everyone
lands on the ready room: teammates press **READY**, then the host presses **START**. Each card shows where that player
is (lobby, campaign, battle report...).

## Other mods: do we all need the same ones?
Not always. The host's game runs the battle; everyone else sees it and sends orders. That decides what matters:

- **Pictures and sounds** (art packs, new uniforms, sound packs): fine either way. Each player sees their own.
- **A mod only a teammate has** runs on their screen only. It can't change the host's battle: the host checks every order
  a teammate sends. A teammate with a spawn menu can open it, but nothing they spawn reaches the host's battle.
- **A mod only the host has** changes the battle for everyone. That's often fine (a host's F7 spawn menu, a balance
  tweak). But if it **adds new things** (new soldiers, weapons, vehicles, pictures), a teammate without it may see missing
  pictures or errors. Then everyone should install it.
- **Different versions** of the same mod: update so everyone has the same one, to be safe.

The lobby checks this for you when someone joins. A pop-up says if something needs a look, and a **!** appears on the
player's card (orange: check it, red: serious). Hover the card to see which mod, on which side:

| Says | Means |
|---|---|
| FINE | pictures or sounds only, a mod only a teammate has, or a mod that says only the host needs it |
| CHECK | a mod with code only the host has: if it adds new things, teammates need it too |
| SERIOUS | a mod that says everyone needs it, missing on one side or in a different version |

**Mod makers:** you can tell the co-op what your mod needs by adding `"coop"` to its `mod.json`:
`"coop": "host"` (only the host needs it), `"both"` (everyone needs the same version) or `"any"` (doesn't matter).

## For developers
`main` holds only what players get. Work happens on the
[`dev` branch](https://github.com/HappiCroco/mnb-coop/tree/dev), which also has the design notes (DESIGN.md), the
headless tests (`tests/run_tests.bat`, needs LÖVE's `lovec.exe`) and `Launch Two Games.bat` for testing on one PC.

## Special Thanks To
- [URB](https://x.com/urban_prophet), creator of Mud and Blood and its series, and helping with questions of balancing.
- [Gamiseus](https://github.com/Gamiseus), developer of QuarterMaster, for making this powerful harness.

## AI Disclosure
The code was written by Claude, but the code was checked and tested, design choices were also made by me, overall Claude is the main contributor to the project.

## Licence
MIT with the Commons Clause ([LICENSE](LICENSE)): use it, change it, share it, build on it, put it in your own
mods, all free. You can't sell it, or sell something whose value is mostly this mod. Keep the licence with copies.
It covers this mod's own code only. Mud and Blood and its files belong to their owners; nothing here includes or
grants rights to the game.
