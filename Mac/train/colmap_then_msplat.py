#!/usr/bin/env python3
"""Splatty capture folder -> COLMAP (pycolmap) poses -> msplat Gaussian splat .ply.

Usage: colmap_then_msplat.py <capture_folder> [options]   (see --help)

Input  : <capture>/raw/frame_*.jpg (required), optional <capture>/transforms.json
         (seeds shared intrinsics), optional masks (<capture>/masks or --mask DIR;
         white = object, black = ignore; named <stem>.png or <image>.png).
Output : <capture>/sfm/{database.db,images,masks,sparse/0}  COLMAP workspace
         <capture>/splat/vNNN/{splat.ply,report.json,train/}
ARKit poses are NOT used (turntable captures make them invalid); only intrinsics.
"""
import argparse, json, os, shutil, sys, time
from pathlib import Path

import numpy as np

T0 = time.time()
TIMES = {}


def stage(name):
    TIMES[name] = round(time.time() - stage.t, 1)
    stage.t = time.time()
    log(f"[{name}] {TIMES[name]} s")
stage.t = time.time()


def log(*a):
    print(*a, flush=True)


def parse():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("capture", type=Path)
    p.add_argument("--mask", type=Path, help="mask dir (default: <capture>/masks if it exists)")
    p.add_argument("--no-mask", action="store_true", help="ignore masks even if present")
    p.add_argument("--remask", action="store_true", help="regenerate masks with rembg (must be installed)")
    p.add_argument("--matcher", choices=["exhaustive", "sequential"], default=None,
                   help="default: exhaustive if <200 images else sequential")
    p.add_argument("--max-image-size", type=int, default=2000, help="SIFT extraction size")
    p.add_argument("--iters", "-n", type=int, default=7000)
    p.add_argument("--downscale", "-d", type=float, default=4.0, help="msplat image downscale")
    p.add_argument("--bg", default=None, help="r,g,b in [0,1]; default 0,0,0 when masked else msplat default")
    p.add_argument("--crop", choices=["auto", "on", "off"], default="auto",
                   help="crop splat to sparse-point bounds (auto = on when masked)")
    p.add_argument("--eval", action="store_true", help="hold out every 8th view and report PSNR/SSIM")
    p.add_argument("--version", default=None, help="output version folder name (default next vNNN)")
    p.add_argument("--reuse-sfm", action="store_true", help="skip COLMAP if sfm/sparse/0 exists")
    return p.parse_args()


def find_mask(mask_dir, img):
    for cand in (f"{img.name}.png", f"{img.stem}.png"):
        f = mask_dir / cand
        if f.exists():
            return f
    return None


def remask(images, out_dir):
    try:
        from rembg import remove, new_session
    except ImportError:
        sys.exit("--remask needs rembg: uv pip install -p <venv> 'rembg[cpu]'")
    from PIL import Image
    out_dir.mkdir(parents=True, exist_ok=True)
    sess = new_session("birefnet-general-lite")
    for img in images:
        m = remove(Image.open(img), session=sess, only_mask=True)
        m.point(lambda v: 255 if v > 127 else 0).save(out_dir / f"{img.stem}.png")
    return out_dir


def main():
    a = parse()
    cap = a.capture.expanduser().resolve()
    raw = cap / "raw"
    images = sorted([p for p in raw.iterdir() if p.suffix.lower() in (".jpg", ".jpeg", ".png", ".heic")])
    if not images:
        sys.exit(f"no images in {raw}")
    log(f"{len(images)} images in {raw}")

    import pycolmap
    sfm = cap / "sfm"
    sparse = sfm / "sparse"
    report = {"capture": str(cap), "num_images": len(images)}

    # ---- masks
    mask_src = None
    if not a.no_mask:
        if a.remask:
            mask_src = remask(images, cap / "masks_rembg"); stage("remask")
        elif a.mask:
            mask_src = a.mask.expanduser().resolve()
        elif (cap / "masks").is_dir():
            mask_src = cap / "masks"
    masked = mask_src is not None
    report["masked"] = masked

    # ---- COLMAP workspace (symlinks, nothing copied)
    if not (a.reuse_sfm and (sparse / "0").exists()):
        if sfm.exists():
            shutil.rmtree(sfm)
        (sfm / "images").mkdir(parents=True)
        for img in images:
            (sfm / "images" / img.name).symlink_to(img)
        mask_dir = None
        if masked:
            mask_dir = sfm / "masks"; mask_dir.mkdir()
            missing = 0
            for img in images:
                m = find_mask(mask_src, img)
                if m:
                    (mask_dir / f"{img.name}.png").symlink_to(m)  # COLMAP naming: <image>.png
                else:
                    missing += 1
            if missing:
                log(f"WARNING: {missing} images have no mask (fully used)")

        reader = pycolmap.ImageReaderOptions()
        reader.camera_model = "OPENCV"
        tj = cap / "transforms.json"
        if tj.exists():
            t = json.loads(tj.read_text())
            w, h = int(t["w"]), int(t["h"])
            from PIL import Image
            iw, ih = Image.open(images[0]).size
            sx, sy = iw / w, ih / h
            reader.camera_params = ",".join(str(v) for v in
                                            [t["fl_x"] * sx, t["fl_y"] * sy, t["cx"] * sx, t["cy"] * sy, 0, 0, 0, 0])
            report["intrinsics_seed"] = "transforms.json"
        if mask_dir:
            reader.mask_path = str(mask_dir)
        ext = pycolmap.FeatureExtractionOptions()
        ext.max_image_size = a.max_image_size
        ext.sift.max_num_features = 8192
        db = sfm / "database.db"
        pycolmap.extract_features(db, sfm / "images", camera_mode=pycolmap.CameraMode.SINGLE,
                                  reader_options=reader, extraction_options=ext)
        stage("colmap_features")
        matcher = a.matcher or ("exhaustive" if len(images) < 200 else "sequential")
        report["matcher"] = matcher
        (pycolmap.match_exhaustive if matcher == "exhaustive" else pycolmap.match_sequential)(db)
        stage("colmap_matching")
        sparse.mkdir(exist_ok=True)
        mopts = pycolmap.IncrementalPipelineOptions()
        if reader.camera_params:
            mopts.ba_refine_focal_length = True  # seed only; still refine
        maps = pycolmap.incremental_mapping(db, sfm / "images", sparse, options=mopts)
        stage("colmap_mapping")
        if not maps:
            sys.exit("COLMAP failed to register any model")
        best = max(maps, key=lambda k: maps[k].num_reg_images())
        if best != 0:  # msplat reads sparse/0
            tmp = sparse / "_best"
            maps[best].write(str(tmp.mkdir(exist_ok=True) or tmp))
            if (sparse / "0").exists():
                shutil.move(str(sparse / "0"), str(sparse / "0_small"))
            shutil.move(str(tmp), str(sparse / "0"))
    rec = pycolmap.Reconstruction(str(sparse / "0"))
    nreg = rec.num_reg_images()
    report.update(num_registered=nreg, num_points3D=rec.num_points3D(),
                  mean_reprojection_error_px=round(rec.compute_mean_reprojection_error(), 3))
    log(f"COLMAP: {nreg}/{len(images)} registered, {rec.num_points3D()} points, "
        f"reproj {report['mean_reprojection_error_px']} px")
    if nreg < 0.8 * len(images):
        msg = "物体纹理太少，建议改用绕拍 (fewer than 80% of images registered)"
        report["warning"] = msg
        log("WARNING:", msg)

    # ---- msplat dataset: images (composited onto black if masked) + sparse/0
    out_root = cap / "splat"
    out_root.mkdir(exist_ok=True)
    ver = a.version or "v%03d" % (1 + max([int(p.name[1:]) for p in out_root.glob("v[0-9][0-9][0-9]")] or [0]))
    out = out_root / ver
    train = out / "train"
    (train / "images").mkdir(parents=True, exist_ok=True)
    if (train / "sparse").exists() or (train / "sparse").is_symlink():
        (train / "sparse").unlink()
    (train / "sparse").symlink_to(sparse)
    if masked:
        from PIL import Image
        bg = tuple(float(v) for v in (a.bg or "0,0,0").split(","))
        bg255 = tuple(int(round(v * 255)) for v in bg)
        for img in images:
            m = sfm / "masks" / f"{img.name}.png"
            im = Image.open(img).convert("RGB")
            if m.exists():
                mk = Image.open(m).convert("L").resize(im.size)
                im = Image.composite(im, Image.new("RGB", im.size, bg255), mk)
            im.save(train / "images" / img.name, quality=95)
        stage("composite")
    else:
        bg = tuple(float(v) for v in a.bg.split(",")) if a.bg else None
        for img in images:
            dst = train / "images" / img.name
            if not dst.exists():
                dst.symlink_to(img)

    import msplat
    ds = msplat.Dataset(str(train), downscale_factor=a.downscale, eval_mode=a.eval)
    cfg = msplat.TrainingConfig(iterations=a.iters, output=str(out / "splat.ply"), keep_crs=True)
    if bg is not None:
        cfg.bg_color = list(bg)
    trainer = msplat.GaussianTrainer(ds, cfg)
    trainer.train(lambda s: log(f"  step {s.iteration} splats {s.splat_count}"), 1000)
    raw_ply = out / "splat_uncropped.ply"
    trainer.export_ply(str(raw_ply))
    stage("msplat_train")
    if a.eval:
        ev = trainer.evaluate()
        report["eval"] = {k: (round(v, 4) if isinstance(v, float) else v) for k, v in ev.items()}
        log("eval:", report["eval"])
    report["num_gaussians"] = trainer.splat_count

    # ---- crop to sparse-point bounds (floater removal)
    crop = a.crop == "on" or (a.crop == "auto" and masked)
    final = out / "splat.ply"
    if crop:
        pts = np.array([p.xyz for p in rec.points3D.values()])
        kept = crop_ply(raw_ply, final, pts)
        report["crop"] = {"kept": kept[0], "total": kept[1]}
        log(f"cropped: kept {kept[0]}/{kept[1]} gaussians")
    else:
        shutil.move(str(raw_ply), str(final))
    stage("crop_export")
    report["output_ply"] = str(final)
    report["output_mb"] = round(final.stat().st_size / 1e6, 1)
    report["timings_s"] = TIMES
    report["total_s"] = round(time.time() - T0, 1)
    (out / "report.json").write_text(json.dumps(report, indent=2, ensure_ascii=False))
    log(json.dumps(report, indent=2, ensure_ascii=False))


def crop_ply(src, dst, pts):
    """Keep gaussians inside the robust (2-98 %) bounds of the COLMAP sparse points, +15 % margin.
    Training uses keep_crs=True, so the splat is in COLMAP world coordinates."""
    data = src.read_bytes()
    hdr_end = data.index(b"end_header\n") + len(b"end_header\n")
    header = data[:hdr_end].decode()
    props = [l.split()[-1] for l in header.splitlines() if l.startswith("property float")]
    n = int([l for l in header.splitlines() if l.startswith("element vertex")][0].split()[-1])
    arr = np.frombuffer(data, dtype=np.float32, count=n * len(props), offset=hdr_end).reshape(n, len(props))
    xyz = arr[:, :3]
    lo, hi = np.percentile(pts, 2, axis=0), np.percentile(pts, 98, axis=0)
    pad = (hi - lo) * 0.15
    lo, hi = np.minimum(lo, hi), np.maximum(lo, hi)
    keep = np.all((xyz >= lo) & (xyz <= hi), axis=1)
    out = arr[keep]
    header = header.replace(f"element vertex {n}", f"element vertex {len(out)}")
    dst.write_bytes(header.encode() + out.astype(np.float32).tobytes())
    return int(keep.sum()), n


if __name__ == "__main__":
    main()
