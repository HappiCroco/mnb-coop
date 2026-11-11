# Mud and Blood Co-op: design (2026-11-10)

Rewrite of the old sketch (file IPC + Python helper, never worked). Based on a read of `vanilla-src/`.
Game code facts are cited as `file:line` so they can be re-checked after game updates.

## What the game allows (findings)
- **No lockstep.** The game never seeds its RNG (`randNbr` = `love.math.random`, urb_engine.lua:78; ~8,100 call sites, also
  called from draw code), and many timers count frames, not time. Two machines cannot simulate the same battle.
  → **Host-authoritative:** only the host runs the battle. Clients are a live *view* of it plus a remote control.
- **Networking:** LÖVE ships `enet` and LuaSocket (checked with lovec: both load). No Python helper, no extra files.
  The game's `luasteam.dll` is a cut-down build: `getSteamID`, `getFriendPersonaName`, `setRichPresence`, overlay, stats.
  **No** Steam lobbies, invites, avatars or Steam networking → players connect by IP. Host reachability, in order:
  UPnP port mapping from HOST (pure Lua: SSDP + SOAP over LuaSocket; send SSDP on the LAN interface, VPN adapters such as
  Radmin 26.x / Tailscale 100.x otherwise swallow it; delete the mapping on stop) → playit.gg tunnel (free, carries UDP)
  → LAN / VPN. UPnP is useless behind carrier-grade or double NAT: the owner's router (OpenWrt, miniupnpd, UPnP on) had a
  private WAN address on 2026-11-10, so for them playit.gg is the real path. Keep the transport swappable in case the
  game's dev ever ships a full Steam networking build (Steam relays would remove all of this).
- Squads: campaign caps the squad at 6 (`squadSize() < 6`, urb_engine.lua:4391). Co-op campaign plan: 3 soldiers per
  player (duo = vanilla 6, trio 9, four 12) with enemy waves scaled up to match; owner wants it harder, not easier.
  "6" is not one rule but several spots that all assume one player; co-op must scale each to `3 * players`:
  - campaign: dead squad members are only replaced while `squadSize() < 6` (urb_engine.lua:4391);
  - campaign debrief: "full squad" doubles squad XP at `squadSize() >= 6` (39202), full-honour check (39359),
    `bcModTeamCap = 6` (bcChecks.lua:240, checked at urb_engine.lua:39322); 5+ alive gives a Steam stat (39215, blocked by QM);
  - classic: above 6 (`squadSizer()`, counts vehicle crews too) the game randomly calls `sizeControl()` (urb_engine.lua:6022,
    mnb2.lua:5438): artillery, WP, airbursts and strafes that grow with squad size. Already toggleable via
    modifiedFunctions' `disableSizeControl`; co-op raises the threshold instead of removing it.
- **One `player` table holds everything** (troops of both factions in `player.deployedTroops`, vehicles, map, TP, camera).
  It is sometimes replaced wholesale (urb_engine.lua:1554, 45029; mnb2.lua:1143): never cache `player`, read the global.
- **Entities have random `id`s** (`randNbr(9999999999)`, ai.lua:2609) and indexes shift on `table.remove`; sync by `id`.
- **No projectile table.** Shots resolve instantly; what you see is particles (`player.particles/topParticles`),
  explosions (`player.explosions`, advanced and removed *in draw*, drawFiles.lua:919), deco (blood, corpses, craters).
- **Sounds** are fired inline from sim code (~1,300 `:play()` sites, none in battle draw). Clients need sound events.
- **Input** is mostly two-step: a button sets global `mousePrompt = N`, the next mouse release resolves it
  (main.lua:4435 onward). Move orders are inline in `love.mousereleased` (~main.lua:6671) and apply to every troop with
  `selected == true`. Buttons hit-test with `love.mouse.getPosition()` and call `_G[label.."Button"]()` with no args
  (urb_engine.lua:124-190). There is one `mousePrompt`, one selection, one TP pool.

## Architecture
```
 HOST (real game)                         CLIENT (view + remote control)
 runTime0 simulates  ──snapshots 20 Hz──▶ mirror `player` tables, interpolated
 hooks record events ──events (reliable)─▶ explosions, cues, deco, sounds replayed
 executes orders     ◀──orders (reliable)── local selection + clicks turned into orders
```
- enet channels: 0 reliable (lobby, map, events, orders), 1 unsequenced (snapshots).
- Wire format: our own small encoder for numbers/strings/flat tables. **Never `load()` network data** (the old sketch did:
  that is remote code execution). Big payloads (map) go through `love.data.compress("string", "zlib", ...)`.
- Version handshake: mod version + game build; mismatch is refused with a message.
- **Host guard (our free firewall, v0.3.0):** join code (5 chars, rides in the copied address as `addr:port#CODE`,
  GMenu option `joinCode`, NEW CODE re-rolls it); 5 s to send a valid hello or the connection is dropped;
  per-connection limits of 60 msgs/s and 400 KB/s (flooders are cut off); packets over 200 KB and junk earn strikes,
  5 strikes = dropped; host can remove a player (two clicks on their card) and they can't rejoin that lobby; 16 enet
  slots so strangers being turned away never block the 4 real seats. Behind playit every connection comes from the
  local playit agent, so IP bans are useless there; the join code is the real gate. The guard only makes junk cheap
  to ignore: the packets still reach the PC, only playit's paid firewall (or switching the tunnel off) stops that.

## Structure: a co-op layer with its own chapter (owner's decision, 2026-11-11)
- CO-OP tile on the main menu → lobby (party of up to 4 cards) → the host picks a **mode card**. Each mode is an adapter
  over an existing mode plus co-op overrides that are active only while co-op runs:
  - **Co-op Classic**: the vanilla Classic battle with the 3-per-player scaling. No persistent squad. Ships first.
  - **Co-op Campaign**: its own chapter with its **own save** (`saveCOOP*.lua`), own XP/rank track and its own thumbnail.
    Uses campaign logic, but never touches the single-player campaign or its soldiers. Each player keeps their own
    3-man co-op roster on their own PC and brings it to whoever hosts; KIA is permanent in that roster, as in vanilla.
    Campaign progress (day/sector) belongs to the host's co-op save.
  - Later: the upcoming Christmas-patch mode, as one more card.
- Co-op overrides replace single-player assumptions only when co-op is on: squad caps, reinforcements, debrief XP,
  size control (see Squads above).
- **Save safety (hard rule):** a client's `player` table is replaced by the host's mirror during co-op, and the game
  writes saves from many places (love.quit, debriefs, menus). Clients must stash their real `player` on joining, block
  every vanilla save write while co-op is active, and restore it on leaving. Never let a mirror reach `saveMNB2/3.lua`.
- Menu space: the main menu has no free column (Career/Squad stacked at x=50, Campaign 275, Classic 500, Options 725,
  Community 950). Plan: stack Options as a half-height tile and give CO-OP its own full column with a thumbnail
  (150x360 like `campaingIcon1`; owner may draw it, placeholder until then).

## Online play: playit.gg (owner has CGNAT)
- Only the host installs playit (normal install, Program Files, not in the mod folder). One-time: log in from the browser
  prompt to claim the agent, then create one **UDP** tunnel to the co-op port on localhost. Friends type the playit
  address (`name.playit.gg:port`) into JOIN; the lobby has a field where the host pastes it to show/copy it.
- Not needed for LAN tests. Set it up with the owner when step 2 is tested with a friend outside the house.

## Lobby (main menu)
- Patches add a **CO-OP** tile to the main menu (`buttonUpdateMenu` menuPage 1 block, urb_engine.lua:8127; drawn in the
  `menuPage == 0 or 1` block of drawFiles.lua ~2564). The click goes to `menu_coopButton()` → our lobby page
  (`GMenu.allocatePage("mnb_coop", "lobby", draw, registerButtons)` when GMenu is installed, else our own page number).
  Lobby buttons use the game's own `Button.new`, so they look and click like vanilla.
- **Four player cards.** Empty = dashed slot "OPEN". Taken = the player's card:
  - **Picture:** the Steam avatar from the Steam client's own cache, `<Steam>/config/avatarcache/<steamid64>.png`
    (Steam root = three folders up from the game folder, `D:/Games/Steam` here; verified the file exists). Each player
    reads *their own* and sends the PNG (~a few KB) once. Fallback: the player's in-game face (faceBase + their
    eyes/nose/mouth/hair, already loaded by the game).
  - **Name:** Steam persona name (`Steam.friends.getFriendPersonaName(Steam.user.getSteamID())`), else profile name.
  - **Showcase (player's choice, GMenu option):** campaign rank insignia (`playerRank1..13`), classic rank
    (`command_1..13`), or a ribbon (`rib1..111`, name/desc in `ribName_N`/`ribDesc_N`). All are game sprites everyone
    already has, so only numbers are sent.
  - Ready tick, ping, seat colour (seat colour also tints that player's selection rings in battle).
- Host: HOST button (port shown, plus LAN IP), picks the mode, START when everyone is ready. Join: IP field (last one
  remembered), JOIN. Leave/Kick.

## Co-op campaign: what 9-12 soldiers need (audit 2026-11-11)
Built so far (v0.3.x): `coop_campaign.lua` runs the game's campaign on its own profile by redirecting the save file
names (`saveMNB3.lua`, `backUp.lua`, `saveMNB2.lua`) into `coop/campaign/` while active; leaves on main menu or quit.
The squad is slots 1..6 of `player.deployedTroops` (created first by `newProfile`, urb_engine.lua:4955, never removed;
NPCs, enemies and crews are appended after). Nothing crashes with squad soldiers at 7..12, but they are silently
second-class unless these are patched (~16-20 sites, mostly urb_engine.lua):
- P1, needed: newProfile squad loop (4955); preGameAdmin placement/perks/weapons for 1..6 (40220-40290); dead-member
  replacement scans `for i=1,6` (bcChecks.lua 1352 bcReplacement, 1384 ribReplacement, 1421 alarmReplacement;
  urb_engine 251 skill, 4391 `squadSize() < 6`); squad/roster/awards menus hard-code 6 cards (drawFiles 3008-3160,
  3296-3560; urb_engine 8199-8301 menuPage 3/4/5); existing co-op saves need a top-up to 3 per player.
- P2, balance: `>= 6` full-squad bonuses (39202, 39215, 39322, 39359), size control (6022), voice lines (6342-6348),
  soldierHit `6 - squadSize()` damage scale (21959), makeBrandies (bcChecks 1108).
- P3, polish: battle face bar spacing (drawFiles 1227, getIconCoord 14975), icon drag-swap (main.lua 6911).
- Fine already: skills/perks/specs, XP (giveXp, groupXp), number-key groups, rings and bars (all loop the whole list).
Built 2026-11-11 (v0.4.0): arrangeSquad/retag/placeExtras/page switch in coop_campaign.lua + qm.toml patches
for the P1 replacement scans and all P2 thresholds via `coopSquadMax()`. P3 (face bar spacing, drag-swap) not done.
Menu idea (built): keep the vanilla 6-card squad screens and add a "page" switch that swaps soldiers 1-6 with 7-12 in the
list while in menus (all vanilla menu code reads slots 1..6), swapped back before a mission starts.

## Own rosters (owner's design, 2026-11-11; built in v0.6.0, headless test 36 checks, not yet tried in-game)
Code: coop_campaign.lua (normalize, arrangeSquad, settleMission at BACK from the mission-end page, onSeatLeft,
sendRoster on welcome/sort/results, applyPendingResults once back from the battle view, Squad-screen right-drag).
`campaign.track()` follows `player` because the game reloads it from the save (pause Options, urb_engine.lua:45029).
Replaces "every friend's soldiers live in the host's save" (that made replacements and changing players janky).
- **Every player has their own co-op save** on their own PC (`coop/campaign/saveMNB3.lua`, the co-op profile). Its
  squad slots 1..6 ARE that player's roster. The CO-OP CAMPAIGN tile opens the game's main menu on it for anyone
  (Career, Squad...); only the host (or offline) can start a mission, and missions use the host's day/sector.
- **Sorting** on the co-op Squad screen (the game has none). The top slots are the soldiers you bring: your share of
  the 6 (solo 6, duo 3, trio 2). The rest stay home.
- **Mission start:** clients send their top soldiers to the host (kept up to date: on join, after sorting, after
  results). Each roster soldier carries a stable `coopUid` so results find their way back.
- **Mission end:** the host sends each player their soldiers back (results: XP, ranks, awards, wounds; KIA removed;
  a soldier the game put in that player's slot as a replacement joins their roster). **Soldiers at home get half the
  average XP the fielded ones gained.** The host does the same for its own roster.
- **A player leaves mid-mission** (owner changed this the same day): their soldiers pull out with them, walking to
  the nearest edge (top or bottom); off the map, or after 30 s, they are taken off (parked at -9999, removed at the
  settle). Nothing counts for that player. **A player who joins mid-mission** brings their top soldiers in as
  reinforcements into the freed slots, from the left edge like the game's own (x 50, y 350 +-50, to the front line).
  Slots belong to a PERSON (Steam id, else name), not a seat number, since a newcomer reuses the leaver's seat; the
  per-player share stays as it was at mission start.
- **New player** (no co-op save yet): their own game makes fresh rookies (a new co-op profile).

## Battle sync (host → clients)
**Built 2026-11-11 (v0.5.0, `coop_battle.lua`, watching only; headless test 42 checks, not yet tried in-game).**
What was built differs from the plan below in one way: no hand-kept field list. The whole `player` is mirrored generically:
- Plain fields and nested tables are diffed against what was last sent (floats rounded to 0.01). Lists of tables are
  diffed per element, keyed by the element's table identity on the host, so a list that shifts (deco trimmed from the
  front, urb_engine.lua:6171; a dead troop removed) sends `rm`/`add` keys, not everything. A reorder sends the key order.
- Never sent: camera, `option_*` settings, weather lists (rain/fluff/clouds stay empty on clients), `delayedAction`,
  `troopBin`, troops' `selected`. Effect lists (particles, topParticles, explosions, text/damage/ui/icon/tip cues,
  water/mine circles) send new entries once, flat (scalars only; an explosion's `dad` is the whole shooter).
- One message per tick (20/s, option `syncRate` 10), reliable on channel 1, zlib when over 400 bytes. Full state on
  battle start and for mid-battle joiners (sent right after a tick so the shared baseline matches).
- Client: the game's update is replaced while watching. It smooths x/y/`*rotation` of troops, vehicles, neutrals and
  planes over the measured snap interval, runs the cue updates, buildingsUpdate, updateLight and screenControl
  (own camera). particleUpdate/topParticleUpdate are NOT run on clients: they also land grenades, drop paratroopers
  and hurt troops (particlesSystem.lua:6514, 1). A first try ran them in a setfenv sandbox with gameplay functions
  stubbed; a stub returning nil made the game's code error every frame and froze every flash and tracer (owner's
  screenshot, 2026-11-11). Now clients move effects with our own looks-only mover (lifetime, drift, spin, drag, fade,
  grow/shrink, flight along rotationz); what an effect does on landing arrives from the host as its own event.
  planeUpdate/delayUpdate are never run on clients either. Lesson: never run game code half-disabled on a client.
- Sounds: `play`/`stop`/`clone` wrapped on the Source methods. The host names Sources by their global (clones inherit),
  loops get an instance id so `stop` reaches clients. Clients hear only the host's sounds.
- Each player's own view (2026-11-11, from the owner's tests): roof fading (`fading/roofAlpha/targetRoofAlpha` sent once
  per building, then local), F9/Tab/F3/F4/R, and a client copy of the game's mouse-over pass in its order: tip
  bubbles, soldier card (`mouseOverId`), face names, minimap tooltip + click (camera), vehicle card (`mouseOverId2`),
  roofs, loot tooltips. Not yet: skill/perk tooltips and buttons (need the HUD buttons; with skills), pause overlay.
  Never run buttonEngine on a client: its top spawns gameplay (boat explosion, air support, urb_engine.lua:44363-44372).
- Mission-end pages (4, 5, 10, 14, 15) stay synced after the battle with `view {gs, page}` and the page's animation
  globals (box1..9Timer, play*once, uiFade/dateFade/bgFade/tipText, temp*, mnb2Wave*; clients accept only those
  name patterns). Friends can't click there: BACK can reset progress or make a new profile (urb_engine.lua:1536-1630).
  Page 4 has 6 hard-coded soldier slots (drawFiles.lua:3441-3574) with the four grades below (3575-3674): the
  4x3 mode needs that page redrawn (owner: grades moved right to make room for 12).
- Client input in battle is blocked except these, own-soldier orders, Esc twice (leave) and Ctrl+F8. All file writes outside `coop/` are dropped
  while watching; the real `player` comes back on bend, disconnect, leave or quit (before the game's quit-save).
- **Battle start:** host sends mode/subgame and the static map once (bgPatch, forest, rocks, deco, buildings, road,
  groundType, placeables, lootables, mineField, trench, endLine). Clients install it into their `player` and enter
  `gameState = 0` with the simulation switched off (`runTime0` skipped; their own camera/scroll still runs).
- **Snapshots (20 Hz):** troops, vehicles, neutrals: only the fields draw code reads (x, y, rotation, state, tag,
  weapon.tag, faction, health, dead, flags packed in a bitmask, gear counters). Client interpolates between the last two.
  Dead troops are sent once.
- **Events (hooks on the host):** `createExplosion`, `floatyText`/`anounceStuff`/`damageCueText` (cues), deco appends
  (blood, corpses, craters), `addParticle` for the visible kinds (muzzle flashes, tracers), planes, and **sounds** via one
  wrapper on the LÖVE Source metatable `play` (reverse map Source → global name built at load), so no 1,300 patches.
- HUD on clients: TP, wave, squad faces from the snapshot.

## Control (clients → host)
**Owner's rules (2026-11-11), built in v0.5.0 (`coop_squad.lua`, headless test 25 checks):** up to **3 players**, the squad
stays the vanilla **6, shared out** (solo 6, duo 3+3, trio 2+2+2; 4 players x 3 = 12 later). Soldiers belong to players:
- Number keys 1..n select *your* soldiers in face-bar order (the game picks by `shortcut`, which buttonEngine rewrites
  every frame from face order, urb_engine.lua:44396-44424; our buttonEngine wrapper renumbers yours 1..n, others 0).
  7 and box/click selection can't keep someone else's soldier selected on the host.
- Owner colour: ring under each squad soldier (qm.toml patch before the white selection ring, drawFiles.lua:261)
  and a frame on each face in the face bar.
- Face drag (right mouse, swap at main.lua:6908-6912) only between two faces of your own group.
- A soldier whose player isn't connected counts as the host's.
- Friends: select on the mirror (selection is never synced), click ground → `move {ids, x, y}` in world coords.
  The host validates ownership and **replays the click through the game's own love.mousereleased** with only those
  soldiers selected, `buttons` emptied and prompts off, then restores its own selection and globals. No copy of the
  game's move rules. Not yet: friends' skills/grenades (same replay with `mousePrompt`), their face bar clicks and drags.
- Each troop gets `coopSeat` (1 = host). Units a player recruits are theirs; the host's starting squad can be split.
- Clients select locally on their mirror (selection never touches the host's flags) and send **orders**:
  `move(ids, wx, wy)`, `recruit(type)`, `skill(id, slot)`, `prompt(N, ids, wx, wy)` in **world** coordinates.
- Host runs an order by swapping state for one call: save the host's `selected` flags / `mousePrompt` / `mousePrompter`,
  set them to the client's, run the action (our own `coopMove` for moves, the game's function or prompt resolver for the
  rest), restore. Orders are queued and run at the start of the host frame, never mid-update.
- TP: shared pool by default (true co-op); option to split TP income per seat.
- A client that leaves gives its troops back to the host.

## Scope and phases
1. **Lobby + connection** (built 2026-11-11, v0.2.0; headless tests pass, not yet tried in-game). Main-menu entry is
   "Multiplayer" on the bottom bar (owner's choice), placed right of whatever buttons are there: CO-OP tile, lobby page, 4 cards (avatar, name, showcase), host/join/leave, ready, handshake.
   Testable on one PC with two game windows or on LAN.
2. **Spectate:** Classic mode only. Clients see the host's battle live with their own camera, explosions, cues, sounds.
3. **Command:** seats, ownership, move/recruit/skills/prompts from clients.
4. **Polish:** seat colours in battle, map pings, chat, split-TP option, campaign mode, reconnect.

## Testing
- Net core and codec: headless with `lovec` (two processes on localhost).
- Game behaviour: two machines, or two copies of the game on one PC (Steam may refuse a second instance; then a friend).
