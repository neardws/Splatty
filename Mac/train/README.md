# Mac mini training

Target: home Mac mini (Apple Silicon). Poses come from COLMAP (via `pycolmap`),
training from [msplat](https://github.com/rayanht/msplat) (Apache-2.0).
ARKit poses are not used, so the same pipeline works for orbit captures and for
turntable captures (object rotates, phone still), where ARKit world poses are wrong.

## Setup (once, no sudo)

```bash
uv venv -p 3.12 ~/Developer/splat-env/.venv
uv pip install -p ~/Developer/splat-env/.venv "msplat[cli]" pycolmap numpy pillow
# optional, only for --remask:  uv pip install -p ~/Developer/splat-env/.venv "rembg[cpu]"
```

`SPLATTY_PY` overrides the interpreter path.

## Run

```bash
Mac/train/colmap_then_msplat.sh ~/SplattyCaptures/<...>/20261017_brick_a674er --eval
```

Input: an asset folder from the iOS app (`raw/frame_*.jpg`; `transforms.json` is
optional and only seeds the shared intrinsics; `masks/` optional).

Stages:

1. Optional `--remask` (rembg / BiRefNet-lite) into `masks_rembg/`.
2. COLMAP feature extraction: one shared OPENCV camera, SIFT at 2000 px,
   masks passed as `ImageReader.mask_path` (white = object, black = ignore;
   `masks/<stem>.png` or `masks/<image>.png` are both accepted and re-linked to
   COLMAP's `<image>.png` naming).
3. Exhaustive matching (< 200 images, else sequential), incremental mapping;
   the largest model becomes `sfm/sparse/0`.
4. Warn if < 80 % of images register (`物体纹理太少，建议改用绕拍`).
5. Masked: images are composited onto solid black and msplat trains with the
   same background colour (msplat drops alpha on load).
6. msplat training (`keep_crs`, default 7000 iters at 1/4 resolution).
7. Crop the splat to the 2–98 % bounds of the sparse points (+15 %) to remove
   floaters (on by default when masked, `--crop on|off` to force).

Output: `sfm/` (COLMAP workspace, symlinks only) and
`splat/vNNN/{splat.ply, splat_uncropped.ply, report.json}`. `report.json` has
registered count, reprojection error, eval PSNR/SSIM (with `--eval`) and
per-stage timings.

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
