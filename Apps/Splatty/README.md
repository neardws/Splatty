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

`project.yml` already sets `DEVELOPMENT_TEAM` to `YNQ2233752` (same as MacShot / Octoshot).

### Simulator (verified)

```bash
xcodegen generate
xcodebuild -project Splatty.xcodeproj -scheme Splatty \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -configuration Debug build
```

Verified **BUILD SUCCEEDED** on Neil's Mac mini (Xcode 26.2 / iOS Simulator 26.3.1, iPhone 17 Pro) on 2026-10-17. `SplattyCore` `swift test`: 33/33 pass.

### Real iPhone

ARKit capture needs a physical device (simulator has no camera / world tracking).

1. Open `Splatty.xcodeproj` in Xcode (or run `open Splatty.xcodeproj` after `xcodegen generate`).
2. Confirm **Splatty** target → **Signing & Capabilities** → Team is **Xincao Xu (YNQ2233752)**. If the bundle id `com.neardws.splatty` clashes, change it there (or in `project.yml` and regenerate).
3. On the iPhone: **Settings → Privacy & Security → Developer Mode → On**, then reboot if prompted.
4. USB-connect (or wireless after pairing) the phone; unlock it and tap **Trust**.
5. In Xcode pick the phone as the run destination → **⌘R**.
6. First launch: allow **Camera** (and motion/AR if prompted).

CLI alternative:

```bash
xcodebuild -project Splatty.xcodeproj -scheme Splatty \
  -destination 'generic/platform=iOS' -allowProvisioningUpdates build
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

**Capture** (object page → *开始拍摄*): a guided flow, see [`docs/capture-ux.md`](../../docs/capture-ux.md).

- 3-page Chinese onboarding on first run (**?** to reopen)
- Tap the object centre (or **就是中间这个**). Exposure + white balance lock automatically
- 3 rings in order 中位 → 高位 → 低位. An AR ring of segments around the object (grey →
  green, yellow = next target), a 2D dial, and a big direction pill (向左/向右慢慢绕, 抬高/放低)
- **One auto-shot per uncovered bin**, never in covered bins. Bad frames are rejected with a
  reason (太快 / 太暗 / 跟踪不稳 / 太近 / 太远)
- Haptic tick per shot, success haptic + "next ring" card when a ring completes, "可以了"
  with 完成 / 继续补拍 at the end. Rings can be skipped (… menu or the ring card)
- Default plan **标准**: 24 + 12 + 12 bins, done at 44 photos (快速 31, 精细 65; set on the object page)
- Per shot (unchanged): hi-res still via `captureHighResolutionFrame` (falls back to the video
  frame), intrinsics scaled to the saved image, c2w pose, timestamps, exposure/light, tracking.
  LiDAR depth (16-bit mm PNG) + confidence when enabled. Seed points go to `arkit/points3D.ply`

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
- [ ] First 开始拍摄 shows the 3 tip cards; 开始拍摄/跳过 closes them; **?** reopens
- [ ] Placing: reticle + "轻点它的中心"; tap the object → AR ring of grey segments around it, one yellow
- [ ] Walk slowly as the pill says (向右/向左慢慢绕) → each new segment shoots once (tick + flash), turns
      green, and the yellow target moves on; walking back over green segments takes **no** photos
- [ ] Move fast / cover lens / step very close or far → red reason pill, no shot
- [ ] Mid ring done (22/24) → success haptic + "把手机抬高…" card with a bobbing arrow; raise the phone → card hides
- [ ] High then low ring; "这圈跳过" works; final "可以了！共 ~44 张" → 完成 (or 继续补拍)
- [ ] Bottom-right camera button still takes a manual extra shot
- [ ] LiDAR phone: library shows "N 深度"; … menu → turn off 保存 LiDAR 深度 → new shots have no depth
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
