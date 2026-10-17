# Splatty

**Capture keepsakes. Keep the light.**

Splatty turns figures, badges, bricks, and other collectibles into interactive [3D Gaussian Splats](https://repo-sam.inria.fr/fungraph/3d-gaussian-splatting/) — shoot on iPhone, train on a Mac at home, browse in-app.

中文一句话：用手办级收藏品的多视角照片，在家里 Mac mini 上训出 3DGS，再在 iPhone App 里转着看。

## Status

Early MVP scaffolding. APIs and folder layout may change.

## Architecture

```text
iPhone (Splatty App)          Mac mini (Apple Silicon)         iPhone
  capture + ARKit poses  --->  msplat train  --->  .ply/.spz  --->  MetalSplatter preview
  asset library                export splat                     asset library
```

| Layer | Role | Stack (planned) |
|-------|------|-----------------|
| **App** | Guided capture, library, preview | SwiftUI · ARKit · [MetalSplatter](https://github.com/scier/MetalSplatter) |
| **Train** | Reconstruct splat offline | [msplat](https://github.com/rayanht/msplat) on Mac mini |
| **Assets** | Naming / versions / meta | see `docs/architecture.md` |

On-device **training** is intentionally out of MVP scope (viewing on device is in).

## Repo layout

```text
Apps/Splatty/     iOS app (capture MVP; XcodeGen project + SplattyCore package)
Mac/train/        Mac mini training notes & scripts
docs/             architecture & capture notes
```

## Non-goals (for now)

- Selling or posting collectibles for commerce
- Buying hardware without Neil’s go-ahead
- Shipping closed-source training inside the iPhone MVP

## License

[MIT](LICENSE)
