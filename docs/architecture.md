# Splatty architecture

## Data flow

1. **Capture (iPhone)** — guided orbit + elevation; lock AE/AF; store images + ARKit poses/intrinsics.
2. **Transfer** — package asset folder to home Mac mini (AirDrop / SMB / local sync — TBD).
3. **Train (Mac mini)** — [msplat](https://github.com/rayanht/msplat) (Metal, Apple Silicon); export `.ply` / `.spz`.
4. **Preview (iPhone)** — import splat; render with MetalSplatter; update asset status `ready`.

## Asset folder layout

On the iPhone: `Documents/Splatty/<YYYYMMDD>_<slug>_<shortid>/` (date in the phone's local
time zone; slug is ASCII, Chinese names are transliterated, e.g. 皮卡丘 → `pi-ka-qiu`;
shortid is 6 chars from `23456789abcdefghjkmnpqrstuvwxyz`).

```text
YYYYMMDD_<slug>_<shortid>/
  meta.json                  name, category, status, device, counts, capture settings
  cover.jpg                  ~480 px portrait thumbnail
  transforms.json            Nerfstudio-format poses + intrinsics (msplat / ns-train read this)
  raw/frame_00001.jpg        RGB stills (or .heic), sensor-native landscape orientation
  depth/frame_00001.png      LiDAR only: 16-bit PNG, millimetres (0 = invalid), ~256×192
  depth/frame_00001_conf.png LiDAR only: 8-bit PNG, ARConfidenceLevel 0/1/2 (raw values)
  arkit/points3D.ply         seed points: ARKit feature points + LiDAR samples (binary PLY)
  splat/
    v001/                    trained splat + cover preview (Mac mini, later)
```

> Changed from the first draft (`sfm/` + `arkit/frames.json`): msplat's Nerfstudio loader only
> looks for `<dataset>/transforms.json`, resolves paths relative to that folder (and treats
> paths starting with `.` as CWD-relative), and needs a seed PLY. So `transforms.json` sits at
> the asset root with root-relative paths, and `ply_file_path` points at `arkit/points3D.ply`.
> `sfm/` stays reserved for a Mac-side COLMAP refinement.

### `transforms.json`

Standard Nerfstudio keys plus `splatty_*` extras (ignored by trainers):

```json
{
  "camera_model": "OPENCV",
  "fl_x": 1597.2, "fl_y": 1597.2, "cx": 1001.6, "cy": 754.3, "w": 2016, "h": 1512,
  "k1": 0, "k2": 0, "p1": 0, "p2": 0,
  "ply_file_path": "arkit/points3D.ply",
  "depth_unit_scale_factor": 0.001,
  "frames": [
    {
      "file_path": "raw/frame_00001.jpg",
      "depth_file_path": "depth/frame_00001.png",
      "confidence_file_path": "depth/frame_00001_conf.png",
      "transform_matrix": [[r00, r01, r02, tx], [r10, r11, r12, ty], [r20, r21, r22, tz], [0, 0, 0, 1]],
      "fl_x": 1597.2, "fl_y": 1597.2, "cx": 1001.6, "cy": 754.3, "w": 2016, "h": 1512,
      "timestamp": 51234.567, "captured_at": "2026-10-17T16:00:00+08:00",
      "exposure_duration": 0.0083, "exposure_offset": 0, "ambient_intensity": 980,
      "ambient_color_temperature": 5200, "tracking": "normal", "high_resolution": true,
      "depth_timestamp": 51234.551, "ring": 1, "azimuth_bin": 7, "splatty_index": 1
    }
  ],
  "splatty_format": 1,
  "splatty_pose_source": "arkit",
  "splatty_object_anchor": [0.01, -0.12, -0.31]
}
```

(numbers are illustrative.) Per-frame `fl_x … h` override the top-level ones (hi-res stills
and fallback video frames can differ in size).

**Camera convention.** `transform_matrix` is camera-to-world, row-major, in the
OpenGL/Nerfstudio convention (+X right, +Y up, camera looks down −Z). That is exactly
ARKit's `ARCamera.transform` *for the sensor-native landscape-right orientation*, and the
app saves `capturedImage` in that orientation without rotating it, so the matrix is written
as-is (column-major simd → row-major JSON). For OpenCV/COLMAP (+Y down, +Z forward)
right-multiply by `diag(1, −1, −1, 1)` (`CameraConvention.arkitToOpenCV`). World frame is
ARKit's: metres, +Y up (gravity), origin where the session started. Intrinsics come from
`ARCamera.intrinsics` rescaled to the saved image size.

### `meta.json`

```json
{
  "schemaVersion": 1,
  "id": "k7m2qx",
  "folder": "20261017_pikachu_k7m2qx",
  "name": "Pikachu",
  "category": "figure",
  "createdAt": "2026-10-17T16:00:00+08:00",
  "capturedAt": "2026-10-17T16:12:40+08:00",
  "timeZone": "Asia/Shanghai",
  "status": "captured",
  "device": { "model": "iPhone", "identifier": "iPhone18,1", "systemVersion": "26.0", "hasLiDAR": true },
  "counts": { "images": 124, "depth": 124 },
  "capture": { "targetShots": 120, "imageFormat": "jpeg", "highResolutionFrames": true,
               "depthEnabled": true, "videoFormat": "1920×1440@30 + hi-res stills", "exposureLocked": true },
  "splatVersion": null,
  "notes": "",
  "appVersion": "0.1.0 (1)"
}
```

`category`: `figure | badge | brick | toy | other`.
`status`: `draft` (created, no shots) → `captured` → `processing` → `ready | failed`.

## Capture notes (iPhone)

- Main camera; prefer stills or slow video → frames
- Soft light; textured (not blank) background
- ~36–72 views around; add 1–2 tilt rings
- Glossy/transparent pieces: expect harder quality; soft-matte subjects first
