# SimpleRacer

Arcade racing game for iPad, kept to the essentials: one race mode, a choice of car and a paint
colour. The driving is classic arcade racing: automatic acceleration, drifting, a nitro gauge with
perfect nitro and shockwave, and takedowns.

**Status:** pre-release (version 0.1.0), a playable skeleton. The app is not distributed through
the App Store or TestFlight. The in-game interface is in Polish.

## Features

- **Race**: 6 cars, 2 laps on a city circuit, the player starts from the back of the grid.
  Countdown, position, lap, race time, speed and nitro gauge on the HUD; a results screen with
  the finishing position, time and number of takedowns.
- **Garage**: three cars with different top speed, acceleration, handling and nitro power, and
  the paint colour — eight presets or any colour from the system colour picker. The choice is
  saved on the device.
- **Rivals**: five AI drivers that hold a lane, counter-steer into corners, drift through tight
  ones, use nitro on straights and hit perfect nitro depending on their skill. Mild rubber-banding
  keeps the race close.
- **Controls**: on-screen touch buttons, a hardware keyboard and game controllers
  (GameController framework), all at the same time.

Not implemented yet: ramps and jumps (barrel rolls, 360s), traffic, a takedown camera,
more tracks, tilt steering.

## Campaign

- **40 tracks in 5 regions** — City, Coast, Desert, Forest, Snow (8 each). The first track is
  hand-made; the rest come from a seeded generator and a validator (closed loop that never comes
  close to itself, corners of at least 32 m radius, at most 2 laps, wide road), and a test drives
  six AI cars around every track. Each region has its own ground, buildings and trees.
- **Stars**: a win gives 3, a podium 2, any finish 1. Stars unlock regions (0, 10, 22, 36 and 52);
  inside a region tracks open one after another.
- **Coins** for every race (more for harder tracks, better places and takedowns); races can be
  replayed.
- **Car rating** — one number from top speed, acceleration, handling and nitro. Every track
  needs a minimum rating (650 → 820). Four upgrades (engine, acceleration, handling, nitro),
  five levels each, raise it; better cars cost coins.
- **Kid-safe**: rivals can never wreck the player (a rival hit only pushes); the player can
  still take rivals down. The DRIFT button never brakes — it waits until the car is fast enough —
  and a short tap still gives a half-second drift.
- **Easy, for children**: rivals are a little weaker than the track's requirement and slow down
  when far ahead; the starter car, fully upgraded, can finish the whole campaign; one playthrough
  pays for those upgrades; and tests check that auto-steering alone reaches the podium on tracks
  1, 10, 20, 30 and 40.

## Gameplay

| Action | Touch | Keyboard | Controller |
|---|---|---|---|
| Steer | ◀ ▶ | ← / → (A / D) | left stick, d-pad |
| Drift (brake when slow) | DRIFT | ↓ (S, Shift) | B, left trigger |
| Nitro | NITRO | Space (↑, W) | A, right trigger |
| Shockwave | double-tap NITRO | double-tap Space | double-tap A |
| Pause | ⏸ | Esc | Menu |

The car accelerates by itself.

**Auto-steering** (the "Auto-prowadzenie" switch in the menu, on by default): the car keeps to the
track and takes corners by itself, drifting through tight ones. ◀ ▶ (or ← / →) move it one lane
left or right; DRIFT and NITRO work as usual. With auto-steering off, ◀ ▶ steer directly.

**Mute**: the 🔊 button next to pause mutes music and sounds at once (separate switches are in
the menu).

**Pause**: the ⏸ button at the top (Esc on a keyboard, Menu on a controller) pauses the race,
with *Graj dalej* (resume), *Od nowa* (restart) and *Menu*. The race also pauses by itself when the
app goes to the background (Home, a notification, Control Centre).

- **Nitro** fills from drifting, nitro canisters lying on the track, near misses (overtaking a
  rival with a small gap) and takedowns.
  One press fires normal nitro. Pressing again at the end of a burn (the gauge glows and reads
  "TERAZ!") fires **perfect nitro**, which is stronger. A quick double press fires a
  **shockwave**: it burns the whole gauge, gives the biggest boost, and any contact wrecks a rival.
- **Nitro canisters**: rows of three glowing canisters sit on one lane every 130 m. Driving through
  one adds nitro; it comes back after 6 seconds. Rivals collect them too.
- **Mini-turbo**: the longer a drift lasts, the longer the speed burst when it ends.
- **Slipstream**: driving right behind a rival (same lane, 5–28 m) gives faster acceleration, a
  slightly higher top speed and some nitro — a reason to get behind someone before overtaking.
- Speed bonuses (nitro, mini-turbo, slipstream) do not stack: the strongest one counts. Steering
  softens at high speed for stability; glancing a wall costs little speed, and only a steep
  high-speed hit wrecks the car.
- **Drift**: press DRIFT at speed — with or without steering. The car slides into the drift by
  itself (towards the steering direction, or towards the next corner when not steering), turns
  tighter, smokes from the rear tyres and fills the nitro gauge; steering the other way
  counter-steers. When the car is too slow to drift, the button waits (it never brakes) and the
  drift starts by itself once the car is fast enough.
- **Takedown**: hitting a rival hard from the side or from behind wrecks it and adds nitro.
- **Wreck**: hitting a wall at a steep angle. The car is back on the track after 2 seconds.

## Music and sound

- Music: "Chiptune Adventures" by Juhani Junkala (SubspaceAudio), CC0 —
  [OpenGameArt](https://opengameart.org/content/4-chiptunes-adventure). The menu plays "Stage
  Select"; races alternate "Stage 1" and "Stage 2". Files are AAC in `App/Audio` (see
  `LICENSE-MUSIC.txt`).
- Sound effects (countdown, start, nitro canister chime, nitro, crash, takedown, wall impacts) and
  the driving sounds are synthesised in code — no sound files. The engine (`App/Audio/EngineSynth.swift`)
  is a V8 with a virtual 6-speed gearbox: revs follow speed and gear, each shift cuts the throttle for
  ~80 ms, the tone comes from ignition pulses exciting exhaust resonators plus a load-dependent
  low-pass (dull on the overrun, with exhaust pops). Tyre squeal follows the slip angle, wind noise
  grows with speed², nitro adds bite and a whoosh. `tools/audition-engine.swift` renders a test drive
  to WAV without a simulator.
- The audio session is *ambient*: it respects the device mute and mixes with other audio. Music
  and sounds can be switched off separately in the menu; audio stops when the app leaves the
  foreground and resumes after interruptions (calls, Siri).
- Haptics: iPads have no haptic engine, so vibration goes to a connected game controller that has
  one (`GCController.haptics`, `App/Input/Haptics.swift`) — short pulses on wall hits, wrecks,
  takedowns and nitro.

## App icon and privacy

The icon is generated by `tools/make-icon.swift` (`swift tools/make-icon.swift
App/Assets.xcassets/AppIcon.appiconset/AppIcon.png`). `App/PrivacyInfo.xcprivacy` declares that the
game does no tracking and collects no data; the only "required reason" API is `UserDefaults`, used
to keep the chosen car, colour and steering mode on the device. The game makes no network requests.

## Requirements

- macOS with Xcode 16 or later (built and tested with Xcode 27.1). Deployment target:
  iPadOS 18.0, iPad only, landscape only. Swift language version 5 (`SWIFT_VERSION` in
  `project.yml`).
- [XcodeGen](https://github.com/yonaskolb/XcodeGen). The repository does not commit the
  `.xcodeproj`; it is generated from `project.yml`:

  ```sh
  brew install xcodegen
  ```

- The Metal toolchain, for the ground shader. Newer Xcode versions download it separately; if the
  build stops with "missing Metal Toolchain", run:

  ```sh
  xcodebuild -downloadComponent MetalToolchain
  ```

## Building

```sh
xcodegen generate
open SimpleRacer.xcodeproj
```

Run on an iPad simulator, or on a device after choosing a team in
**Signing & Capabilities** of the `SimpleRacer` target.

Build configurations:

| Configuration | Optimised | `LocalModels/PrivateOnly` | Use |
|---|---|---|---|
| Debug | no | yes | development |
| **Family** | yes | yes | **Xcode “Run”** — installs on the family's iPads |
| Release | yes | **no** | App Store archive |

From the command line, on an iPad simulator:

```sh
xcodebuild -project SimpleRacer.xcodeproj -scheme SimpleRacer \
  -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M4)' \
  -derivedDataPath .build/dd CODE_SIGNING_ALLOWED=NO build
xcrun simctl install booted .build/dd/Build/Products/Debug-iphonesimulator/SimpleRacer.app
xcrun simctl launch booted com.renacode.simpleracer
```

Debug builds accept launch arguments for testing in the simulator:

- `-autostartRace` skips the menu and starts a race straight away,
- `-holdDrift` holds DRIFT from 8 seconds after launch,
- `-finishSoon` puts the player 150 m before the finish line (to reach the results screen quickly),
- `-track <n>` picks the campaign track, `-screen campaign|garage` opens a screen,
- `-logWheels` logs the parts found as wheels in each car model, `-showCredits` opens Settings on the credits list, `-raceAfter N` presses "Ścigaj się" after N seconds in the menu,
- `-mute` turns music and sound effects off (simulator tests play through the Mac speakers),
- `-rich` gives coins and stars (to look at the shop and unlocks), `-car <id>` picks and owns a car,
- `-autoNitro` presses nitro every 4 s, `-toggleMuteAt N` toggles sound after N seconds.

These and the timing logs work in Debug and Family builds, not in Release.

```sh
xcrun simctl launch booted com.renacode.simpleracer -autostartRace -holdDrift
```

In Xcode 27 the simulator window is **Device Hub**
(`Xcode.app/Contents/Applications/DeviceHub.app`); the game runs in landscape, so rotate the
device with ⌘← / ⌘→.

## Tests and CI

The game logic is a separate Swift package with no graphics, so its tests run on macOS without
a simulator:

```sh
cd RaceCore && swift test
```

The tests cover auto-steering (a full race with no input and no wall crash, much faster than not
steering at all, one tap moves exactly one lane), the nitro rules (activation, perfect window, shockwave), drifting (the DRIFT
button alone starts a drift instead of braking, its direction follows the next corner, it never
brakes and kicks in at speed), wall hits (event without a wreck, no speed jump after a wreck),
collisions (rivals never wreck the player, wrecked cars are obstacles), standings after the finish,
nitro canisters (layout on the track, pickup and respawn), the track geometry (closed
loop, minimum corner radius, side orientation) and a full headless race of six AI cars, which
must all finish without a single wall crash.

GitHub Actions (`.github/workflows/ci.yml`) runs those tests and builds the app for a generic
iOS Simulator destination on every push to `main` and on pull requests. The workflow uses the
latest stable Xcode and needs no specific simulator or code signing.

## Architecture

- **`RaceCore`** (Swift package, Foundation only) holds the whole race: car physics, nitro,
  collisions, AI and the race simulation. Physics runs at a fixed 120 Hz step in track
  coordinates: `s` is the distance along the track centre line and `d` the sideways offset.
  This keeps walls, race positions and AI driving simple, and makes the full race testable.
  All tuning values are in `Config.swift`.
- **The app** (SwiftUI + RealityKit) renders it. `RaceGame` wraps the simulation, places the car
  entities, drives the chase camera and publishes the HUD state to SwiftUI; menus, the garage,
  the HUD and the touch controls are SwiftUI views over a `RealityView` with a virtual camera.
  Cars are the realistic models from `LocalModels` (see [Local realistic models](#local-realistic-models)).
  The scenery is built from photos: region panoramas, impostors of trees and buildings and photo
  textures for the ground and barriers (see [Scenery](#scenery-panoramas-impostors-and-photo-textures)).
  The CC0 Kenney models (see [3D models](#3d-models)), loaded from OBJ files by a small parser in
  `RaceCore`, are only a fallback when those files are missing. The road, kerbs and walls, drift
  smoke and nitro flames are generated in code.
- The selected car and colour are stored in `UserDefaults`. There is no backend.

## Local realistic models

Realistic car models can be added locally, without committing them: put `.usdz` files in
`LocalModels/` (git-ignored) and describe them in a `cars.json` next to them.

```
LocalModels/
  Commercial/    models whose licence allows a paid app (CC0, CC BY, Sketchfab/Fab Standard…)
    cars.json
    *.usdz
  PrivateOnly/   everything else (non-commercial licences, real car brands) — Debug builds only
    cars.json
    *.usdz
```

A build phase copies them into the app bundle (`Models/Realistic`). **`PrivateOnly/` is copied only
in the Debug configuration**, so a Release/App Store build never contains those files. Each entry
in `cars.json` gives the car's name, stats, the USD mesh names of its body paint (recoloured in the
garage), an optional yaw and the author, licence and source shown on the in-app credits screen.
Cars whose file is present appear in the garage and among rivals; until a model has loaded, or when
there is none, the car falls back to its Kenney model.

**Licence gate:** the Release build runs `tools/check-licenses.py` on `LocalModels/Commercial` and
fails when any car lacks `"commercial": true`, any licence is non-commercial (NC), no-derivatives (ND)
or editorial, or a `.usdz` file has no entry with a licence.

## 3D models

`App/Models` holds CC0 models (public domain, no attribution required) from three packs by
[Kenney](https://www.kenney.nl):

| Folder | Pack | Used for |
|---|---|---|
| `Cars/` | [Car Kit](https://kenney.nl/assets/car-kit) 3.1 | the three cars (`sedan-sports`, `race-future`, `hatchback-sports`) |
| `City/` | [City Kit (Commercial)](https://kenney.nl/assets/city-kit-commercial) 2.1 | buildings and skyscrapers along the track |
| `Track/` | [Racing Kit](https://kenney.nl/assets/racing-kit) 1.0 | trees (fallback only) |

To swap a model, replace its `.obj`/`.mtl` (and texture) with a file of the same name. Each car
names its model and the palette cell that holds the paint in `CarCatalog.swift` (`CarModelRef`);
the garage recolours that cell, keeping its shading. The tests check that every bundled model
loads, that its materials and textures exist, and that each car has a body, four wheels and a
paint cell its body actually uses.

## Scenery: panoramas, impostors and photo textures

Like most mobile racers, the scenery is built from photos rather than heavy 3D models:

- **Far plane:** each region has a 360° panorama on a sphere that moves with the camera, so the
  horizon stays put. The sky and ground come from a small copy (`App/Sky/sky-<region>.jpg`,
  2048 × 1024); the horizon band, where the buildings, trees and hills are, comes from the full
  8K photo (`sky-<region>-band.jpg`). The horizon stays sharp without the memory cost of a whole 8K
  texture. The small copy also lights the scene and gives the cars their reflections. The garage and
  menu use a photo of an indoor karting hall (`sky-garage*.jpg`) the same way, turned so the camera
  faces the tyre barriers. A concrete floor under the turntable covers the tyres standing right next
  to the camera in the photo and fades into the photo's floor.
- **Ground:** a tiled photo texture per region (`App/Ground/`) drawn by a small Metal shader
  (`App/Render/Ground.metal`). It fades out with distance from the camera, so the 3D ground blends
  into the ground in the panorama with no visible edge on the horizon.
- **Along the road:** trees and buildings are *impostors*, photos of a 3D model taken from the front
  and the side with a transparent background. A tree is two crossed planes. A building is a box
  wrapped in its facade photos, and buildings stand side by side with their fronts in one line, like
  a real street. All impostors that share a photo are merged into one mesh, so the whole roadside is
  a few dozen draw calls.
- **City buildings:** real-scale blocks built in code (`App/Render/Buildings.swift`): stone ground
  floor, a cornice above it, a photo PBR facade laid out in whole 3.2 m floors, and a parapet. The
  materials are lit (sun and sky reflections), so walls shade differently and windows reflect the sky.
  Street blocks stand side by side; taller office towers form a second row. Textures in `App/Buildings/`.
- **Road and walls:** photo asphalt with normal and roughness maps; the track edge is a wall with
  thickness and a coping, textured per region (brick, sandstone, stone, wooden planks).
- No Kenney props are left along the track (no lamps, grandstands or start gantry); the start is a
  line on the road.

Impostors are rendered offline:

- `tools/render-impostors.py` renders vegetation in Blender, run without a window:
  `Blender -b --factory-startup --python tools/render-impostors.py -- <folder with scenery.json> [<output>]`.
  The tree impostors in `App/Impostors/` come from it.
- `tools/make-impostors.swift` renders building facades with SceneKit:
  `swift tools/make-impostors.swift LocalModels/Commercial`. It writes
  `LocalModels/Commercial/impostors/` and `impostors.json`, which the build copies into the app.
  Without them the city falls back to Kenney buildings.

The full 3D models (`LocalModels/Commercial/scenery/`) are only the source for impostors and are not
put in the app. Loading them directly (`LocalAssets.sceneryEnabled`) is switched off, because it
looked out of place and made frame times worse.

### Scenery licences

| Asset | Source | Licence |
|---|---|---|
| Region panoramas: Wide Street 01, Spiaggia di Mondello, Goegap, Je Gray 02, Snowy Hillside | [Poly Haven HDRIs](https://polyhaven.com/hdris) | CC0 |
| Garage panorama: Kart Club | [Poly Haven HDRIs](https://polyhaven.com/hdris) | CC0 |
| Trees: Island Tree 01–03, Jacaranda Tree, Fir Tree 01, Pine Tree 01, Fir Sapling Medium | [Poly Haven models](https://polyhaven.com/models) | CC0 |
| Ground, asphalt, floor and wall textures: Concrete Floor Worn 001, Leafy Grass, Aerial Beach 01, Aerial Sand, Snow 01, Asphalt Track, Large Red Bricks, White Sandstone Bricks, Stacked Stone Wall, Wood Plank Wall, Red Sandstone Wall | [Poly Haven textures](https://polyhaven.com/textures) | CC0 |
| Building facades: Facade 018A, 019A, 020A, 006, 001 | [ambientCG](https://ambientcg.com/list?category=Facade) | CC0 |
| Building ground floor and cornices: Stone Tile Wall, Beige Wall 001 | [Poly Haven textures](https://polyhaven.com/textures) | CC0 |
| Building facade impostors (local only, fallback): Buildings Pack 1 by G. (gunn24), Old Residential Building by Andrej Grave | Sketchfab | CC BY 4.0, credited in the app |

CC0 assets need no attribution; the app lists them on the credits screen anyway. CC BY assets are
credited in the app (Settings → "Autorzy i licencje"), as the licence requires.

## Race effects

- **Wheels:** the realistic car models have their wheel parts (wheel, tyre, rim, disc; not the
  steering wheel or brake calipers) found by name and grouped into four wheels by position, then
  hung on an axle at each wheel's centre. They roll with the distance driven, and the front wheels
  steer: angle ≈ wheelbase × yaw rate / speed (Ackermann), with counter-steer in a drift.
- **Suspension:** the body leans out of corners, squats when accelerating and dives when braking,
  smoothed like a spring. Only the body moves: it pivots around the axle height while the wheels stay
  on the road (unsprung), with road-car angles (up to 3.5° roll, 2° pitch).
- **Tyre contact:** cars stand on the asphalt surface (y 0.02), with the tyre bottoms aligned to it;
  road paint is 8 mm above the asphalt. A baked contact shadow (soft patch under the body and darker
  spots under each tyre) grounds the car where the sun's shadow map is too coarse.
- **Skid marks:** while drifting, the rear tyres leave dark marks with soft edges. All marks are one
  mesh with a ring buffer (the oldest disappear); a small mesh with the newest segments is updated
  every frame, so the mark starts right under the tyre.
- **Tyre smoke:** many faint, growing particles born along the path the wheel travelled in the
  frame, so the smoke is a haze rather than separate puffs.
- **Speed lines:** thin streaks at the screen edges during nitro and above 260 km/h.
- **Smooth motion:** physics runs at a fixed 120 Hz; the render interpolates cars between the last
  two physics steps, so motion is even at any refresh rate (no stop-then-jump frames).
- **Post-processing (iOS 26+):** a `PostProcessEffect` adds bloom on bright spots, aerial fog read
  from the depth buffer (tinted with the panorama's horizon colour), a gentle tone curve,
  saturation, vignette and dither; plus MSAA 4×. Shaders compile in the background at launch.
  `-noPostFX` / `-noMSAA` turn them off in test builds.
- **Sun from the panorama:** the sun's direction and tint come from the brightest spot of the
  region's sky photo, so shadows fall where the photo says.
- **Camera:** spring distance and height, a kick on nitro, mini-turbo and wall hits; shake from
  smooth noise scaled by "trauma" squared instead of per-frame random jitter.
- **Wall hits:** a wall contact without a wreck sends sparks, a camera shake and a metal scrape.
- **Collisions:** wrecked cars are obstacles (others steer around them) and restart without a speed
  jump; rivals only push each other — takedowns are the player's.

## Loading

Loading works the way game engines do it:

- The system launch screen is dark with the logo (`App/Info.plist`), then the app's splash covers
  the menu until the garage photo and the player's car are ready (about 1.5 s).
- While the child is in the menu, `ScenePreloader` prepares the region of the next track in the
  background. Images are decoded off the main thread, and textures are created with RealityKit's
  async API.
- A race starts on a light loading screen right away: region photo, track name, a tip with a
  pictogram and a real progress bar. The scene is built from the ready textures and renders its first
  frames under the cover (shader and effect warm-up). Only then does the countdown start, so there
  are no black screens and no hitches at the start.
- Memory: the garage and one region at a time; preparing another region frees the previous one.

## Project layout

```
RaceCore/
  Sources/RaceCore/   Config, Car, Nitro, Pickups, Track, Collisions, Controllers (AI), RaceSim,
                      CarCatalog, TrackData, ObjModel (OBJ/MTL parser)
  Tests/RaceCoreTests/
App/
  SimpleRacerApp.swift, AppModel.swift   app entry point, screens, saved profile
  Input/              touch, keyboard and controller input
  Models/             CC0 3D models (OBJ + palette textures) and their licence
  Sky/                CC0 panoramas: one per region and the garage
  Impostors/          CC0 tree impostors (front and side photos) and impostors.json
  Buildings/          CC0 PBR facade, ground-floor and cornice textures
  Ground/             CC0 ground and barrier textures
  Render/             RealityKit: model library, cars, track, materials and textures,
                      sky lighting, race (RaceGame), garage preview
  Views/              SwiftUI: menu, garage, HUD, touch controls, results
project.yml           XcodeGen project definition
tools/                app icon, impostor renderers (Blender, SceneKit)
```

## License

MIT, see [LICENSE](LICENSE).
