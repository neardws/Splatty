# Splatty architecture

## Data flow

1. **Capture (iPhone)** — guided orbit + elevation; lock AE/AF; store images + ARKit poses/intrinsics.
2. **Transfer** — package asset folder to home Mac mini (AirDrop / SMB / local sync — TBD).
3. **Train (Mac mini)** — [msplat](https://github.com/rayanht/msplat) (Metal, Apple Silicon); export `.ply` / `.spz`.
4. **Preview (iPhone)** — import splat; render with MetalSplatter; update asset status `ready`.

## Asset folder layout

```text
YYYYMMDD_<slug>_<shortid>/
  raw/           originals (images or video frames)
  sfm/           poses / sparse points (if produced)
  splat/
    v001/        trained splat + cover preview
  meta.json      name, category, notes, versions, status
```

### `meta.json` (draft)

```json
{
  "id": "shortid",
  "name": "Display name",
  "category": "figure|badge|brick|toy|other",
  "capturedAt": "2026-10-17T16:00:00+08:00",
  "status": "captured|processing|ready|failed",
  "splatVersion": "v001",
  "notes": ""
}
```

## Capture notes (iPhone)

- Main camera; prefer stills or slow video → frames
- Soft light; textured (not blank) background
- ~36–72 views around; add 1–2 tilt rings
- Glossy/transparent pieces: expect harder quality; soft-matte subjects first
