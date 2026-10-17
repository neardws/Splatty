# Capture UX: guided, short

Feedback from the first device test (iPhone 15 Pro Max, 2026-10-17): capture worked, but
「不知道要怎么移动，而且采集的照片有点过于多了 … 太麻烦了」. Neil didn't know where to move,
and 120 shots was too many.

## Decision: (B) keep our ARKit pipeline and build the guided UX ourselves

### What we checked: Apple `ObjectCaptureSession` + `ObjectCaptureView` (RealityKit)

| Question | Finding |
|---|---|
| Devices | iOS 17+ with LiDAR and A14+ (Apple's "Scanning objects using Object Capture" sample needs iOS/iPadOS 18). **Non-Pro iPhones are excluded.** |
| Per-shot pose / intrinsics on iPhone | **Not exposed.** The iOS API surface is `start(imagesDirectory:configuration:)`, `startDetecting/startCapturing`, `numberOfShotsTaken`, `feedback`, `userCompletedScanPass`, `beginNewScanPass(AfterFlip)`, `finish()`. You get a folder of HEIC images (with embedded depth/gravity metadata) plus an optional checkpoint directory. |
| Getting poses afterwards | Possible on the Mac: `PhotogrammetrySession` with `Request.poses` returns `PhotogrammetrySession.Pose` per sample (`rotation`, `translation`, `intrinsics?`, `lensDistortionData?`), and `Request.pointCloud` returns a sparse point cloud. This **re-estimates** everything with Apple's photogrammetry, so a transforms.json is possible, but only with an extra Mac reconstruction step that can fail. The coordinate frame and conventions are undocumented. |
| Small objects (5–30 cm) | Apple/partner guidance: objects **≥ 8 cm (3 in)** in each dimension (range 8 cm–1.8 m). Bounding-box detection needs a volume. **Badges and minifigures are below the limit or flat**, which is exactly our core category. |
| Shot count / UI control | No image-count setting. It auto-captures until the dial is full, then Apple recommends **3 passes** (often 100+ images, capped at `maximumNumberOfInputImages`). The dial, prompts and box UI are Apple's and not customizable. |
| UX quality | Excellent for ≥ 8 cm opaque objects: a guided dial, auto shot selection and haptics. |

### Why B

1. **Fewer photos is a hard requirement**, and Object Capture doesn't let us set it. With our
   plan we control it exactly (default ≈ 44).
2. **Small and flat collectibles** (吧唧, 积木人仔) fall under Object Capture's 8 cm minimum.
3. **Poses are free and exact in our pipeline**: ARKit gives c2w + intrinsics per shot, so
   transforms.json and points3D.ply come straight from the phone. msplat trains with no COLMAP
   and no PhotogrammetrySession pass.
4. It works on **non-LiDAR iPhones** too (depth just becomes optional).
5. The parts of Object Capture's UX that matter (a dial that fills up, auto-shooting, haptics, pass
   prompts) are not hard to rebuild on our data, and we can localize and tune them.

Object Capture is a possible future "Apple 扫描" mode for larger objects. The path would be a
Mac script calling `PhotogrammetrySession` `.poses` + `.pointCloud` to write transforms.json and
points3D.ply. It isn't needed now.

## The guided flow (what the user sees)

1. **First run: 3 tip cards** (放好物体 / 光线柔和 / 慢慢绕一圈). Reopen any time with **?**.
2. **Pick the centre**: a reticle and the text "第一步：对准物体，轻点它的中心"; or tap
   **就是中间这个** to use the screen centre. Exposure and white balance lock automatically.
3. **Ring 1 · 中位** (phone slightly above the object): a ring of grey segments appears
   **around the object in AR**. The next segment to reach is **yellow**, covered ones turn
   **green**. A big pill says **向右慢慢绕 → / 向左慢慢绕 ←** with the degrees left, or
   **把手机抬高/放低一点** when you're at the wrong height.
4. **Auto-shot** when you enter an uncovered segment and the frame is good. A light haptic tick
   and flash per shot. Covered segments are **never re-shot**. When the frame is bad, a red pill
   says why: 太快了 / 太暗了 / 跟踪不稳 (+ reason) / 太近了 / 太远了.
5. **Ring done**: success haptic and a card "✓ 中位一圈完成 → 把手机抬高，从上往下再绕一圈" with a
   bobbing arrow. The card hides when you reach the next height. **这圈跳过** is available (e.g. a
   flat badge has no useful low ring).
6. **Ring 2 · 高位** (looking down), then **ring 3 · 低位** (almost level with the object).
7. **"可以了！共 N 张"** with **完成**, or **继续补拍** to fill the remaining grey segments.

A 2D dial (outer = 低, middle = 中, inner = 高; white = you, yellow = target) and a
progress list (中位 12/22 …) sit at the bottom. A manual shutter (camera button) is always
there for extra close-ups.

## Photo budget

| Preset | 中位 | 高位 | 低位 | Done at (90 %/ring) | Max |
|---|---|---|---|---|---|
| 快速 | 16 (22.5°) | 8 (45°) | 8 | 31 | 32 |
| **标准 (default)** | **24 (15°)** | **12 (30°)** | **12** | **44** | 48 |
| 精细 | 36 (10°) | 18 (20°) | 18 | 65 | 72 |

Rings by camera elevation relative to the object centre: 低 < 15°, 中 15–40°, 高 ≥ 40°.

## Rejection rules (GuidedShotGate)

A shot fires only if all of these hold:
- the camera is in an **uncovered** bin of any non-skipped ring
- tracking is `normal`
- estimated motion blur ≤ 4 px at stream resolution, and angular speed ≤ 45°/s
- ambient light ≥ 250 lm and exposure ≤ 1/30 s
- distance is 12–100 cm
- the object is within 35° of the view centre
- ≥ 0.3 s since the last shot, with no save in flight

Logic lives in `SplattyCore` (`CapturePlan`, `CoverageMap(plan:)`, `Guidance.hint`,
`GuidedShotGate`) with unit tests, including a simulated orbit that takes exactly one shot per bin.

## Output

Unchanged: `transforms.json` at the asset root + `arkit/points3D.ply` (see `architecture.md`).
`meta.json` `capture.targetShots` now records the plan's target (minus skipped rings).
