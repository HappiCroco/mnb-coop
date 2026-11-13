# Sync audit: what a teammate's screen gets wrong

A teammate doesn't run the game's battle update. Their screen shows the host's `player` table, which arrives
about 30 times a second. Some of the game's own animation runs locally (`battle.clientUpdate` in
`coop_battle.lua`). Anything else that the game changes every frame, outside what we send, is frozen, stepped
or wrong on their screen. This file records what was searched, what was found and what was done about it.

Line numbers refer to the vanilla source (`vanilla-src/`, the game as shipped) unless a mod file is named.

## 2026-11-13, first pass

Four Haiku search agents, one per area. Each finding was checked against the code before any fix.

### Sounds

| Finding | Where | Status |
|---|---|---|
| Vehicle engine and track loops start before their first `setVolume`, so teammates heard them at full volume everywhere | `urb_engine.lua:21463-21700` | **Fixed**: `updateLoopVolumes` sets each loop's volume from the teammate's own camera, every frame |
| `tensionLoop` (music as the front nears the end) changes volume after it starts | `urb_engine.lua:6414-6450` | **Fixed**: the host sends volume changes of tracked loops (`hostNoteVolume`, event `u`) |
| `introTune` fades out every frame | `main.lua:4352-4354` | **Fixed**: it's tracked like a loop (`LONG_SOUNDS`) so the fade is sent |
| `ddayExploLoop` (distant beach explosions) gets quieter as the camera moves right | `urb_engine.lua:6466` | **Fixed**: worked out from the teammate's own camera |
| The game stops all sounds at a battle's end; teammates still on the report kept their loops | `urb_engine.lua:5684, 5711` | **Fixed**: `love.audio.stop()` on the host sends a stop-all (event `sa`) |
| A loop played again while still tracked would leave the teammate's old copy playing | mod | **Fixed**: the old copy gets a stop first |
| The battle's background sounds (background loop, night, rain, river, beach explosions, landing boat, intro tune) start while the game sets the battle up, before the sync starts: teammates never got them (only Classic's background loop had a fix) | `urb_engine.lua:40350-40393`, `mnb2.lua:369-382` | **Fixed**: the first full state, and a joiner's, carries every loop and long sound playing on the host (`playingSounds`) |
| `bgSound`, `rainSound`, `riverSound`: fixed volume | `main.lua:62-90` | Fine |
| No `love.audio.play`, `:pause`, `:seek` in battle code; every sound goes through `Source:play` | | Fine |

### Globals the battle draw reads

| Finding | Where | Status |
|---|---|---|
| Lightning flash (and the sky lighting up) | set `urb_engine.lua:5819-5821`, drawn `drawFiles.lua:1212` | **Fixed**: host notes it every frame, sends it (`msg.fx.lf`) |
| Night gunfire / explosions lighting the sky (`ambientLightFlash`) | `urb_engine.lua:9691, 10465`; `drawFiles.lua:1065` | **Fixed** (`msg.fx.af`) |
| "Critical engagement" banner (`majorTimer`, `majorEvent`) | `urb_engine.lua:5761, 5870`; `drawFiles.lua:1135` | **Fixed** (`msg.fx.mt/me`, sent when it shows or goes) |
| Red ring on a retreating soldier never pulsed (`panicCircle`) | `drawFiles.lua:1906-1915` | **Fixed**: pulsed locally like `selectCircle` |
| Hover highlight on the pre-battle deploy screens (`diff1MouseOver`, `diff2MouseOver`) | `urb_engine.lua:44876-44913` | Open, minor (only while the host is on those screens) |
| `pause` overlay | | By design: teammates get a PAUSED banner |
| `showTerrain`, `showLOS`, `showFaces` | key toggles | Each player's own, fine |
| Screen shake | | Arrives through the camera, fine |

### Animated fields in lists

Lists in `INTERP` (troops, vehicles, neutrals, planes) are smoothed between updates. Only `x`, `y` and
rotation fields used to be smoothed.

| Finding | Where | Status |
|---|---|---|
| Turret angle (`turretCurrentAngle`) stepped at the update rate | `ai.lua:3577-3650` | **Fixed**: smoothed (`SMOOTH_FIELDS`) |
| Plane fade and growth (`alpha`, `scale`) | `urb_engine.lua:10329-10340` | **Fixed**: smoothed |
| Promotion and highlight rings (`promotionCircle`, `highlightCircle`) | `ai.lua:34-43` | **Fixed**: smoothed |
| Christmas lights (`xmasLights.*`) | `urb_engine.lua:5960-5990` | Open, minor (only on maps with them; they step at 30 Hz) |
| Walk/aim/fire sprites come from `state`, no frame counters | `drawFiles.lua:288-306` | Fine |
| Explosion frames, fire flicker, building roofs, selection ring | drawn or run locally | Fine |

### Particles

On a teammate's screen, particles are moved by our own mover (`moveParticles`, `steerLobbed`), not the game's
`particleUpdate`.

| Finding | Where | Status |
|---|---|---|
| Grenades flew straight past their spot | `particlesSystem.lua:6566-6733` | **Fixed** (1.2.3): steer, lob swell, bounce |
| Rifle, flare, contact, rocket and stick grenades, molotovs and blendkörper go off and vanish where they land; ours rolled on and lay there | `particlesSystem.lua:6785, 6808, 6858-6872` | **Fixed**: removed on arrival |
| Grenades hitting a wall bounce back (`walled`) | `particlesSystem.lua:6876-6930` | Open: our copy flies through walls. Needs the game's wall checks on the teammate's side |
| Pamphlets tumble (`topParticleUpdate` turns `rotationz` toward random targets) | `particlesSystem.lua:5-29` | Open, minor |
| Live rounds and props become ground items (`replaceTicle`) when they stop | `particlesSystem.lua:6553-6560` | Open: check that the host's new `deco` entries reach teammates |
| Flares leave a ground mark (`groundBlast` deco) | `particlesSystem.lua:6817-6854` | Open: same check |
| Bounce roll heading has a small random offset (`bounceAngle`) | `particlesSystem.lua:6934` | Ignored (up to 3°) |
| Trails (smoke behind rifle grenades) | | Fine: they're new particles, sent by the host |
| Shells, tracers, bombs: no target, they stop by drag | | Fine: the mover has drag |

### Weather

| Finding | Where | Status |
|---|---|---|
| Rain, floating fluff and dark clouds are made when a mission starts and moved in the battle update; each machine keeps its own (they follow the camera), so teammates had a clear sky | made `bcChecks.lua:856-898`, moved `drawFiles.lua:1947-2027` | **Fixed**: `weatherUpdate` makes and moves them on the teammate's camera |

## Not covered yet (ideas for the next pass)

- Projectiles passing through walls (above).
- `player.deco` is a synced list, so props and flare marks should arrive; not checked in a game.
- Responsiveness: instant local feedback for a teammate's clicks; unreliable battle updates (the planned network rework).
