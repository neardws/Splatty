# Mac mini training

Target: home Mac mini (Apple Silicon), [msplat](https://github.com/rayanht/msplat) (Apache-2.0).

## Expected inputs

An asset folder exported by the iOS app (AirDrop the `.zip`, unzip):

- `transforms.json` — Nerfstudio format, ARKit poses + intrinsics (msplat's Nerfstudio loader)
- `raw/frame_*.jpg` — images
- `arkit/points3D.ply` — seed points (referenced by `ply_file_path`)
- `depth/` — optional LiDAR depth (msplat ignores it; Nerfstudio depth losses can use it)

Untested first run (unverified until real data exists):

```bash
msplat-train ~/Splatty/20261017_pikachu_k7m2qx -n 7000 --eval
```

Optional later: COLMAP refinement of the ARKit poses into `sfm/`.

## Expected outputs

- `splat/vNNN/*.ply` or `.spz` plus a cover image

## Status

Pipeline scripts TBD — do not assume a stable CLI yet.
