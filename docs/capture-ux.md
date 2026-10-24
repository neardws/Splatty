# Capture UX

Two modes, picked on the object screen (拍摄方式):

| Mode | Who moves | Poses | Default |
|---|---|---|---|
| **转物体（桌面小物件）** `turntable` | the object (hand or lazy susan); the user sits still | **none on the phone**: COLMAP on the Mac | **yes** |
| 绕拍（大物件）`orbit` | the user walks around | ARKit, exact | no |

## Turntable mode (default, since 2026-10-17 second device test)

### Why

After the guided orbit test Neil reported 「绕圈拍照的体验还是很不好」:

1. **Low angles mean scooping.** To look up at a figure you hold the phone upside-down with the
   camera at the bottom. The old UI was portrait-only, so the text ended up upside-down.
2. **Behind the object you can't see the screen.** Walking round a desk puts the phone between
   you and the object, with the screen facing away, or blocked by a monitor or wall.
3. Walking round a desk at all is awkward: chairs, cables, a desk against the wall.

Real desk problems we designed for:

| Problem | Design answer |
|---|---|
| Can't walk round the desk | The user stays seated and **turns the object**. The phone stays in front. |
| Can't see the screen | **Spoken Chinese prompts** (zh-CN `AVSpeechSynthesizer`, toggle 语音提示) plus distinct haptics: shot = one light tick, 太快了 = two firm taps, ring done = success pattern + voice 「这一圈拍完了，抬高手机，开始下一圈」. UI is huge and high-contrast (30 pt status, 190 pt dial) so it reads from ~50 cm. |
| Low angles need scooping | Tip: raise the object on a cup or box, then eye level *is* low angle. The eye ring accepts −35°…30°, so scooping still counts. Any grip works: the overlay **rotates with gravity** (portrait, both landscapes, upside-down) using ARKit's gravity vector (works even when the phone is nearly flat, unlike `UIDevice.orientation`). |
| Static background fools SfM (it "sees" the camera standing still) | Every shot also saves a **foreground mask** (Vision subject lifting) in COLMAP naming, so COLMAP only matches features on the object. A patterned paper under the object that **rotates with it** adds texture for plain objects. |
| Hard shadows rotate relative to the object | Tips card: soft diffuse light (cloudy window, lamp bounced off a white wall), no flash or torch. |
| Exposure drift (pilot renders came out brighter than photos) | Tap → single-shot AF/AE on the object → after 0.9 s **lock exposure, white balance and focus** (`AVCaptureDevice` via ARKit's configurable device). On iOS 26+ hi-res stills use `captureHighResolutionFrame(using:)` with `photoQualityPrioritization = .speed`, so stills aren't multi-frame fused or tone-mapped differently. The real device state (`AE/WB/AF`, ISO, shutter) is logged with **every shot** in `capture_log.json`, so the lock can be checked after the fact. |
| Hand in the frame while turning | Registration samples with large motion across the turning axis are rejected. The shutter waits for a steady frame ("turn a bit, stop"). |
| Phone wobbles in the hand | The crop is re-centred each frame on the projected object centre (ARKit), which cancels small phone motion. Big phone motion pauses angle tracking and says 「手机别动，转物体就行」. A phone stand is optional and recommended. |

### What the user does

1. Choose **转物体（桌面小物件）** (default) and **开始拍摄**.
2. **Tips card (~10 s, auto-continues):** patterned paper under the object, soft light, phone still, plain background.
3. **Tap the object** (or 就是中间这个). The object centre is fixed with ARKit raycast. Vision subject
   lifting draws a **yellow box** round the object. Exposure, white balance and focus lock.
   The voice says 「开始。手机别动，慢慢转物体，转一点停一下」.
4. **Ring 1 · 平视** (phone about level, 10–20° above; −35…30° accepted): turn the object a bit and stop.
   Every ~36° of object rotation (standard preset), one auto shot (light tick and flash). The **dial**
   fills **red → amber → green** by azimuth sector and a white needle shows the estimated angle. Big
   status text: 慢慢转物体 / 停一下 / 太快了 / 手机别动 / 手机抬高一点 / 对准物体 / 太暗了.
5. Ring done: success haptic, voice 「这一圈拍完了。抬高手机，开始下一圈」, card with a bobbing arrow.
   Focus re-locks for the new distance.
6. **Ring 2 · 斜上方** (32–64°): same, one turn.
7. **Ring 3 · 正上方** (≥ 66°): a few top-down shots. Turn the object about a third between them; each fires
   when the view changed enough and is steady (≥ 1.5 s apart).
8. **Soft 「可以导出了」** (wesbos-style): when eye+high azimuth coverage ≥ ~85% **and** shots ≥ 12
   (standard), a non-blocking banner appears with 导出. **Save/Export is never disabled** for incomplete
   coverage — the menu always has 「现在就结束」. Full plan complete still shows **「可以了！共 N 张」**
   with 完成 / 继续补拍. Rings can be skipped from the menu, and there's a manual shutter.

### Photo budget (turntable)

少拍 first step (2026-10-24): standard target moved into the **12–20** range. Soft export suggestion
fires earlier than plan-complete.

| Preset | 平视 bins | 斜上方 bins | 正上方 | Done at (92 %) | Soft「可以导出了」 | Max |
|---|---|---|---|---|---|---|
| 快速 | 8 (45°) | 4 (90°) | 1 | 13 | ≥8 张且方位≥85% | 13 |
| **标准** | **10 (36°)** | **6 (60°)** | **2** | **18** | **≥12 张且方位≥85%** | **18** |
| 精细 | 16 (22.5°) | 12 (30°) | 3 | 30 | ≥16 张且方位≥85% | 31 |

### How rotation is detected (no markers)

`RotationTracker` (SplattyCore, unit-tested) plus `TurntableAnalyzer` (app):

1. At ~10 Hz the app crops a window round the object: the subject box from Vision, positioned on the
   object centre projected with the current ARKit pose, scaled by distance. It downsizes the crop to
   256 px grayscale and registers it against a **keyframe** crop with
   `VNTranslationalImageRegistrationRequest`. On macOS with synthetic shifts we checked that content
   moving by (+dx, +dy) gives `tx = −dx, ty = +dy`.
2. An object spinning about the vertical axis slides sideways at ≈ ω·R_pix, where R_pix is its
   apparent radius along the image-horizontal axis. That axis comes from gravity, so it works in any
   grip. So **Δθ ≈ shift_along_axis / R_pix**, independent of distance and focal length.
3. Vision returns whole pixels, so we register against a keyframe and **re-key every 8°** rather than
   integrating tiny frame-to-frame shifts.
4. The direction locks after 10°. Angles map to ring-relative bins (mod 360), so turning back a bit or
   doing a second lap simply fills the missing bins.
5. **Shot trigger** (`TurntableShotGate`): the angle is in an uncovered bin **and** the frame is sharp,
   meaning estimated object blur (turn speed × R × exposure) ≤ 2.5 px and phone blur ≤ 2.5 px. Other
   conditions: phone ≤ 25°/s and ≤ 12 cm/s, object turn ≤ 45°/s, phone at the ring's height, object in
   view, enough light, ≥ 0.4 s since the last shot.
6. **Fallback:** if registration keeps failing (8 bad samples in a row: textureless or symmetric object,
   hand in the way), the trigger becomes "**content changed enough since the last shot (16×16 thumbnail
   MAD ≥ 14) and steady (MAD vs previous ≤ 4)**", and progress counts shots. The voice says so once. The
   top-down ring always uses this trigger.

Known limits:
- **Under-estimates on purpose.** Registration over the whole object averages the fast-moving front with
  the slow edges and some static background. A synthetic textured cylinder read 2°→1.9°, 5°→3.8°,
  10°→8.6–9.5°. So one "360°" ring is really about 380–450° of object turn: more overlap, never gaps.
- Flat badges seen face-on, mirror-like or glossy surfaces, and plain, rotationally symmetric objects
  (a white ball) give weak or no signal. The content-change fallback still triggers shots, and the
  dial then counts shots.
- A big hand in the box adds cross-axis motion. Those samples are rejected, which shows up as 停一下.
- If the object fills most of the frame, ARKit world tracking can itself be fooled by the moving
  texture. Keep the object at about half the frame and the background static.
- The angle is approximate (±20–30 %). It decides *when* to shoot, not the poses, which come from COLMAP.

### Export format (turntable)

Same folder layout, plus `masks/` and `capture_log.json`:

```
<asset>/
  meta.json            schemaVersion 2, captureMode "turntable", posesValid false,
                       masks {source "vision_preliminary", folder "masks", convention, count},
                       capture {exposureLocked, whiteBalanceLocked, focusLocked, captureMode, preset, voicePrompts…}
  transforms.json      splatty_format 2
  raw/frame_00001.jpg  sensor-native landscape, NOT rotated (one camera model for COLMAP)
  masks/frame_00001.jpg.png   COLMAP naming masks/<image file name>.png, 8-bit, same size as the image,
                              255 = object (keep), 0 = background (ignore)
  depth/frame_00001.png(+_conf)  optional LiDAR depth, camera-relative (still valid per frame)
  capture_log.json     shots (with AE/WB/AF state, ISO, shutter), rejected-shot reasons + totals, errors
```

`transforms.json` in turntable mode:
- top level: `splatty_capture_mode: "turntable"`, **`splatty_poses_valid: false`**,
  `splatty_pose_source: "none_needs_sfm"`, `splatty_mask_source: "vision_preliminary"`, intrinsics
  `fl_x fl_y cx cy w h` from ARKit (use as a COLMAP prior, `OPENCV`/`PINHOLE` single camera), and
  **no `ply_file_path`**: the ARKit world point cloud is meaningless when the object turns.
- frames: **no `transform_matrix`**, so a Nerfstudio or msplat loader fails loudly instead of training
  on wrong poses. Instead each frame has `pose_valid: false` and `device_transform_matrix` (the phone's
  ARKit pose: debugging only, NOT camera-to-object). It also carries per-frame intrinsics, `mask_path`
  (Nerfstudio's key; same file COLMAP uses), `upright_rotation_cw` (0/90/180/270: rotate the stored
  image clockwise by this to make it upright), `device_orientation`, `gravity_camera` (world up in OpenGL
  camera axes; valid in every mode, useful to level the COLMAP model), `object_rotation_deg` (estimated,
  approximate), `elevation_deg` (phone above the object centre, from ARKit, reliable), `turntable_ring`
  (eye/high/top), `azimuth_bin`, exposure and light fields.

**Images are not rotated.** COLMAP wants consistent intrinsics per camera. Rotating portrait shots
would need a second camera with swapped fx/fy and cx/cy. SIFT is rotation-invariant, so raw
landscape images plus `upright_rotation_cw` are simplest and correct. Rotate only for viewing.

Mac side (`Mac/train/colmap_then_msplat.*`, separate work): if `splatty_poses_valid` is false → COLMAP
with `--ImageReader.mask_path <asset>/masks` (or re-masked by BiRefNet/SAM 2), then write a new
transforms.json with real poses → msplat.

### NaN fix (pilot capture, 2026-10-17)

In the first pilot's 47 shots, `transforms.json` and `meta.json` were never written; only
`points3D.ply` was. `JSONEncoder` throws on NaN/inf (likely light estimate or exposure offset on
hi-res frames), and the three files shared one `do` block. Now:
- `FrameRecord` encodes non-finite required numbers as 0 and drops non-finite optionals.
- `TransformsDocument.make` skips frames with non-finite pose or intrinsics.
- `ShotWriter.persist` writes each file in its own `try`/`catch` and logs failures to `capture_log.json`.

---

# Orbit mode (绕拍, 大物件): guided, short

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
