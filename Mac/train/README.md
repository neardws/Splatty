# Mac mini training

Target: home Mac mini (Apple Silicon). Poses come from COLMAP (via `pycolmap`),
training from [msplat](https://github.com/rayanht/msplat) (Apache-2.0).
ARKit poses are not used, so the same pipeline works for orbit captures and for
turntable captures (object rotates, phone still), where ARKit world poses are wrong.

## Setup (once, no sudo)

```bash
uv venv -p 3.12 ~/Developer/splat-env/.venv
uv pip install -p ~/Developer/splat-env/.venv "msplat[cli]" pycolmap numpy pillow scipy
# optional, for --remask (BiRefNet, ~1 GB model download on first use):
uv pip install -p ~/Developer/splat-env/.venv "rembg[cpu]"
```

`SPLATTY_PY` overrides the interpreter path.

## Run

```bash
# capture with masks/ (turntable build) or generate them:
Mac/train/colmap_then_msplat.sh <capture> --remask --drop-inconsistent --eval
```

Defaults: SIFT at 4096 px, 1/2-res training, 15k iterations, black background when masked.

Stages:

1. Masks: `masks/` from the app, `--mask DIR`, or `--remask` (rembg BiRefNet, 1/2-res input).
2. COLMAP on object pixels only (`ImageReader.mask_path`), one shared OPENCV camera,
   exhaustive matching (< 200 images), incremental mapping, largest model -> `sfm/sparse/0`.
   Warns if < 80 % register (`物体纹理太少，建议改用绕拍`).
3. Undistort images to PINHOLE (`sfm/undist`) and warp masks the same way
   (msplat reads OPENCV params but ignores distortion).
4. Composite onto black with the tight mask (no dilation: a margin leaves a light halo).
5. msplat training (`keep_crs`).
6. Per-view fit check: views that fit > 6 dB worse than the median are reported as
   `inconsistent_views` (object moved / parts moved between shots); `--drop-inconsistent`
   retrains without them, `--exclude 16-25,41-47` drops frames by number.
7. Cleanup (masked): mask visual-hull carving (70 % of views, generous dilation),
   opacity < 0.05, splats larger than 8 % of the object. Writes `splat.ply`,
   `splat_raw.ply`, `splat.splat`, pruned `model.ckpt`.
8. Cameras are copied to `splat/vNNN/sparse/0` so viewers frame the splat in its own coordinates.

## First pilot (2026-10-17, M4 Pro, 47 × 4032×3024, orbit, no masks)

| stage | time |
| --- | --- |
| features | 12.5 s |
| exhaustive matching | 27.2 s |
| mapping | 12.2 s |
| msplat 7000 it @ 1/4 res | 36.4 s |
| total | ~89 s |

47/47 registered, 6.7k points, reprojection 1.08 px. Held-out PSNR 16.1
(cluttered background, ~200° azimuth coverage); training views ~22–24 dB.

## Improvement round on pilot 1 (masked PSNR = held-out views, inside object mask, vs original photo)

| step | held-out masked PSNR (frames 1 / 9) | note |
| --- | --- | --- |
| v001 settings (full frame, 47 views, 1/4 res, 7k) | 21.96 / 19.56 | ghosted truck |
| + undistortion | 22.5 / 19.6 | small |
| + black-bg masks, all 47 views | 20.2 / 16.7 | worse: views disagree |
| rigid segment only (24 views, object-only SfM), masked | 23.5 / 24.5 | the big win |
| + 1/2 res, 15k | 23.8 / 25.0 | +0.4 dB, 228 s |
| + densify 1e-4 | 23.8 / 25.0 | 2.5x splats, no gain |
| cleanup (hull + opacity + huge) | ±0.0 | −2.2k splats; SOR/cluster filters cost 4–10 dB, not used |

Root cause: during capture the truck was turned by hand and its ladder moved
(frames 16–25 and 41–47), so no single rigid model fits all photos. Keep the object
still and unchanged relative to its texture, or use the turntable flow with masks.

End-to-end check of this script on pilot 1 (`--drop-inconsistent --eval`, masks supplied):
42/47 registered on object pixels, 13 views auto-flagged (7, 16, 18–24, 36, 42–44) and dropped,
29 training views, held-out full-frame PSNR 20.4 -> 29.5 dB after the drop; total 349 s
(COLMAP 81 s, two 15k trainings ~170 s each).
