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

Not implemented yet: ramps and jumps (barrel rolls, 360s), traffic, a takedown camera, sound,
more tracks, tilt steering.

## Gameplay

| Action | Touch | Keyboard | Controller |
|---|---|---|---|
| Steer | ◀ ▶ | ← / → (A / D) | left stick, d-pad |
| Drift (brake when slow) | DRIFT | ↓ (S, Shift) | B, left trigger |
| Nitro | NITRO | Space (↑, W) | A, right trigger |
| Shockwave | double-tap NITRO | double-tap Space | double-tap A |
| Back to menu | — | Esc | Menu |

The car accelerates by itself.

- **Nitro** fills from drifting, nitro canisters lying on the track, near misses (overtaking a
  rival with a small gap) and takedowns.
  One press fires normal nitro. Pressing again at the end of a burn (the gauge glows and reads
  "TERAZ!") fires **perfect nitro**, which is stronger. A quick double press fires a
  **shockwave**: it burns the whole gauge, gives the biggest boost, and any contact wrecks a rival.
- **Nitro canisters**: rows of three glowing canisters sit on one lane every 130 m. Driving through
  one adds nitro; it comes back after 6 seconds. Rivals collect them too.
- **Drift**: press DRIFT at speed — with or without steering. The car slides into the drift by
  itself (towards the steering direction, or towards the next corner when not steering), turns
  tighter, smokes from the rear tyres and fills the nitro gauge; steering the other way
  counter-steers. Below about 65 km/h the same button brakes.
- **Takedown**: hitting a rival hard from the side or from behind wrecks it and adds nitro.
- **Wreck**: hitting a wall at a steep angle. The car is back on the track after 2 seconds.

## Requirements

- macOS with Xcode 16 or later (built and tested with Xcode 27.1). Deployment target:
  iPadOS 18.0, iPad only, landscape only. Swift language version 5 (`SWIFT_VERSION` in
  `project.yml`).
- [XcodeGen](https://github.com/yonaskolb/XcodeGen). The repository does not commit the
  `.xcodeproj`; it is generated from `project.yml`:

  ```sh
  brew install xcodegen
  ```

## Building

```sh
xcodegen generate
open SimpleRacer.xcodeproj
```

Run on an iPad simulator, or on a device after choosing a team in
**Signing & Capabilities** of the `SimpleRacer` target.

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
- `-finishSoon` puts the player 150 m before the finish line (to reach the results screen quickly).

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

The tests cover the nitro rules (activation, perfect window, shockwave), drifting (the DRIFT
button alone starts a drift instead of braking, its direction follows the next corner, it brakes
when slow), nitro canisters (layout on the track, pickup and respawn), the track geometry (closed
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
  Everything is generated in code, with no asset files: car bodies are smooth lofted meshes
  (cross-sections along the car) with clear-coat paint, glass cabins, spoked wheels and light
  strips; the sky is a procedural equirectangular image used both as the backdrop and as
  image-based lighting, so the paint reflects it; the road, grass and building facades use
  procedural textures; trees, street lights, drift smoke (particles) and nitro flames complete
  the scene.
- The selected car and colour are stored in `UserDefaults`. There is no backend.

## Project layout

```
RaceCore/
  Sources/RaceCore/   Config, Car, Nitro, Pickups, Track, Collisions, Controllers (AI), RaceSim,
                      CarCatalog, TrackData
  Tests/RaceCoreTests/
App/
  SimpleRacerApp.swift, AppModel.swift   app entry point, screens, saved profile
  Input/              touch, keyboard and controller input
  Render/             RealityKit: car models, track, materials and textures, sky lighting,
                      race (RaceGame), garage preview
  Views/              SwiftUI: menu, garage, HUD, touch controls, results
project.yml           XcodeGen project definition
```

## License

MIT, see [LICENSE](LICENSE).
