# Splatty iOS app — capture MVP

SwiftUI + ARKit app that captures a collectible from many viewpoints and writes a
dataset the home Mac mini can train with [msplat](https://github.com/rayanht/msplat)
(Nerfstudio `transforms.json` format). Training and the splat viewer are **not** in
this module yet.

- iOS 18+, iPhone only, portrait
- Swift 6 (strict concurrency), SwiftUI, ARKit + RealityKit `ARView` for the preview
- No third-party dependencies
- Pure logic lives in the local Swift package [`SplattyCore/`](SplattyCore) (pose math,
  coverage binning, `transforms.json` / `meta.json` writers, naming, depth/PLY encoding)
  and is unit-tested with XCTest

## Build & run (Mac)

```bash
brew install xcodegen            # once (spec checked with XcodeGen 2.44.1)
cd Apps/Splatty
xcodegen generate                # writes Splatty.xcodeproj (git-ignored)
open Splatty.xcodeproj
```

Then in Xcode:

1. Select the **Splatty** target → **Signing & Capabilities** → choose your **Team**
   (`DEVELOPMENT_TEAM` is intentionally empty in `project.yml`). If the bundle id
   `com.neardws.splatty` is taken for your team, change it there (or in `project.yml`).
2. Plug in the iPhone (Developer Mode on), pick it as the run destination, **⌘R**.
3. First launch: allow camera access.

CLI alternative:

```bash
xcodebuild -project Splatty.xcodeproj -scheme Splatty \
  -destination 'generic/platform=iOS' DEVELOPMENT_TEAM=XXXXXXXXXX -allowProvisioningUpdates build
```

### Tests

```bash
cd Apps/Splatty/SplattyCore && swift test          # fastest, runs on macOS (or Linux)
# or in Xcode: Product → Test (⌘U) on an iOS Simulator — runs SplattyCoreTests
```

ARKit capture itself needs a real device (the simulator has no camera / ARKit tracking).

## What the app does

**Library** — list of objects (cover, name, category, view count, status). `+` creates an
object (name + category: figure / badge / brick / toy / other); swipe or the detail page
deletes it (with confirmation).

**Capture** (object page → *Start capture*)

- `ARWorldTrackingConfiguration`, preferring `recommendedVideoFormatForHighResolutionFrameCapturing`
  and saving each shot via `ARSession.captureHighResolutionFrame` (falls back to the video
  frame if that fails, or to the largest back-wide video format if hi-res isn't supported)
- per shot: image (JPEG default, HEIC optional) in **sensor-native landscape orientation**,
  intrinsics (scaled to the saved image size), camera-to-world pose, ARKit timestamp,
  wall-clock time with offset, exposure duration/offset, ambient light, tracking state
- LiDAR devices: `sceneDepth` depth (16-bit PNG, mm) + confidence (8-bit PNG, 0/1/2);
  toggle in the capture screen, default on when supported
- **Manual shutter** and **Auto** mode: fires when the camera moved ≥ 3 cm or turned ≥ 5°
  since the last shot, ≥ 0.35 s apart, tracking is `normal`, the estimated motion blur is
  under ~4 px and you're aiming at the object
- **AE/AF lock** button: locks exposure, focus and white balance through
  `configurableCaptureDeviceForPrimaryCamera` (frame the object first, then lock)
- **Coverage overlay**: shot count vs target (default 120, adjustable on the object page),
  three elevation rings (outer = low < 15°, middle = mid 15–40°, inner = high ≥ 40°) × 24
  azimuth bins (15° each) around the object anchor; white = where you are now
- Object anchor: a default point 30 cm in front of the camera once tracking is normal;
  **tap the object** to set it properly (raycast onto estimated planes; yellow dot)
- Warnings: tracking limited (with reason), too dark, moving too fast, not aimed at object
- Seed point cloud `arkit/points3D.ply`: ARKit feature points + (LiDAR) high-confidence depth
  samples coloured from the image. msplat initialises Gaussians from this file.

**Export** — *Share .zip* zips the object folder with the system zipper
(`NSFileCoordinator` `.forUploading`) and opens the share sheet → AirDrop to the Mac mini.
The folder is also visible in **Files → On My iPhone → Splatty → Splatty**
(`UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`), and in Finder when the
phone is connected by cable.

## On-disk format

See [`docs/architecture.md`](../../docs/architecture.md). Short version:

```text
Documents/Splatty/20261017_pikachu_k7m2qx/
  meta.json
  cover.jpg
  transforms.json        # Nerfstudio format; msplat-train <this folder>
  raw/frame_00001.jpg
  depth/frame_00001.png  depth/frame_00001_conf.png   (LiDAR only)
  arkit/points3D.ply
```

On the Mac mini (once unzipped): `msplat-train ~/Splatty/20261017_pikachu_k7m2qx -n 7000`
(see `Mac/train/`). Nerfstudio also reads it: `ns-train splatfacto --data <folder>`.

## Real-device test checklist

Use a matte, textured object on a textured surface, soft light. Ideally test on one LiDAR
(Pro) and one non-LiDAR iPhone.

- [ ] App installs and launches; camera permission prompt shows the bilingual text
- [ ] Create object "Test 测试" / figure → appears in library as `draft`, 0 views; folder name
      looks like `YYYYMMDD_test-ce-shi_xxxxxx` (date in local time)
- [ ] Start capture → preview runs; tracking goes `initializing` → `normal`; yellow dot appears
- [ ] Tap the object → yellow dot moves onto it; coverage re-centres
- [ ] Manual shutter → flash, count +1, no visible hitch; bottom panel shows `saved W×H`
      (expect ~12 MP / 4032×3024-ish on recent iPhones if hi-res stills work; 1920×1440 if not)
- [ ] Auto on, walk slowly around the object → shots fire every few degrees; stop moving → stops
- [ ] Wave the phone fast → "Moving too fast", auto pauses; cover the lens → tracking limited / too dark
- [ ] Coverage arcs turn green as you orbit; do low / mid / high rings, aim ≥ 80–120 shots
- [ ] AE/AF lock toggles without errors (brightness stops adapting)
- [ ] LiDAR phone: "depth: N" increases; toggle Depth off → new shots have no depth
- [ ] Done → library shows cover, view count, status `captured`
- [ ] Files app → On My iPhone → Splatty → folder contains `raw/`, `transforms.json`,
      `meta.json`, `arkit/points3D.ply` (+ `depth/` on LiDAR)
- [ ] Share .zip → AirDrop to the Mac → unzip → `python3 -m json.tool transforms.json` is valid,
      image count = frame count, open `points3D.ply` in MeshLab/Blender: points sit around the object
- [ ] Mac: `msplat-train <folder> -n 2000` starts and converges to something recognisable
- [ ] Re-shoot an object (clears old views) and delete an object (folder disappears)
- [ ] Background the app mid-capture and return → session resumes (or shows interrupted), no crash

Please note for the Mac side: the actual saved resolution, whether ARKit attaches
`sceneDepth` to hi-res frames (`depth_timestamp` ≠ `timestamp` means it didn't), and
whether msplat's result looks aligned.

## Known limits / unverified

- Not compiled here: the app target was written on Linux without Xcode. `SplattyCore` builds
  and its 33 tests pass with Swift 6.0.3 (Linux); the ARKit/SwiftUI code was checked against
  Apple's API docs but has **not** been compiled — expect a few fix-ups on first build.
- Images are stored unrotated (landscape sensor orientation) so intrinsics and poses line up;
  viewers will show them sideways. That's intended.
- Hi-res stills: ARKit's `captureHighResolutionFrame` resolution varies by device (often 12 MP;
  48 MP not expected). One still at a time; auto mode waits for the previous save.
- Depth for hi-res stills may come from the video frame at trigger time (a few ms earlier).
- Distortion is assumed zero (`k1..p2 = 0`); ARKit images are already rectified enough for
  splatting, but COLMAP refinement on the Mac is still an option.
- ARKit poses drift a little over long captures; a re-shoot always starts a fresh ARKit
  world (no resume across sessions — poses would not share a frame).
- Exposure lock depends on the device exposing `configurableCaptureDeviceForPrimaryCamera`.
- No turntable mode (ARKit assumes the object is static and you move).
- Blur check is a motion model (angular/linear speed × exposure), not an image sharpness metric.
- No app icon artwork yet (empty AppIcon set → Xcode warning).
