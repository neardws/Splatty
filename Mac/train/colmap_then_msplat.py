#!/usr/bin/env python3
"""Splatty capture folder -> COLMAP poses -> undistort -> msplat -> cleaned Gaussian splat.

Usage: colmap_then_msplat.py <capture_folder> [options]   (see --help)

Input  : <capture>/raw/frame_*.jpg (required); optional <capture>/transforms.json
         (seeds shared intrinsics only); optional masks (<capture>/masks, --mask DIR,
         or --remask to generate them with rembg/BiRefNet). White = object.
Output : <capture>/sfm/            COLMAP workspace (raw-space) + sfm/undist (PINHOLE)
         <capture>/splat/vNNN/     splat.ply (cleaned), splat_raw.ply, splat.splat,
                                   model.ckpt, report.json, sparse/0 (cameras for viewers)
ARKit poses are not used. With masks, SfM uses only object pixels, so the object may be
rotated by hand / on a turntable, and clutter is never modelled.

Lessons from pilot 1 (2026-10-17, see README): masked SfM + training on black, tight masks,
undistortion, and dropping views where the object was moved/changed are what matter;
opacity / huge-splat / visual-hull pruning is cheap and safe; statistical-outlier and
largest-cluster filters destroy large surface splats (-4..-10 dB) and are not used.
"""
import argparse, json, os, shutil, struct, sys, time
from pathlib import Path

import numpy as np

T0 = time.time()
TIMES = {}


def log(*a):
    print(*a, flush=True)


def stage(name):
    TIMES[name] = round(time.time() - stage.t, 1)
    stage.t = time.time()
    log(f"[{name}] {TIMES[name]} s")
stage.t = time.time()


def parse():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("capture", type=Path)
    p.add_argument("--mask", type=Path, help="mask dir (default: <capture>/masks if it exists)")
    p.add_argument("--no-mask", action="store_true", help="ignore masks even if present")
    p.add_argument("--remask", action="store_true",
                   help="generate object masks with rembg (BiRefNet; ~5 s/image on M4 Pro, 1 GB model download once)")
    p.add_argument("--rembg-model", default="birefnet-general")
    p.add_argument("--matcher", choices=["exhaustive", "sequential"], default=None,
                   help="default: exhaustive if <200 images else sequential")
    p.add_argument("--max-image-size", type=int, default=4096, help="SIFT extraction size (object is small: keep high)")
    p.add_argument("--iters", "-n", type=int, default=15000)
    p.add_argument("--downscale", "-d", type=float, default=2.0, help="msplat image downscale")
    p.add_argument("--densify-grad-thresh", type=float, default=None)
    p.add_argument("--bg", default=None, help="r,g,b in [0,1]; default 0,0,0 when masked else msplat default")
    p.add_argument("--exclude", default="", help="frame numbers/ranges to drop, e.g. 16-25,41-47")
    p.add_argument("--drop-inconsistent", action="store_true",
                   help="retrain without views that do not fit (object moved / changed between shots)")
    p.add_argument("--clean", choices=["auto", "on", "off"], default="auto",
                   help="prune low-opacity / huge splats and carve with the mask visual hull (auto = on when masked)")
    p.add_argument("--eval", action="store_true", help="hold out every 8th view and report PSNR/SSIM")
    p.add_argument("--version", default=None, help="output version folder name (default next vNNN)")
    p.add_argument("--reuse-sfm", action="store_true", help="skip COLMAP if sfm/sparse/0 exists")
    return p.parse_args()


def frame_no(name):
    digits = "".join(c for c in Path(name).stem if c.isdigit())
    return int(digits) if digits else -1


def parse_ranges(s):
    out = set()
    for part in filter(None, s.split(",")):
        a, _, b = part.partition("-")
        out |= set(range(int(a), int(b or a) + 1))
    return out


# ---------------------------------------------------------------- COLMAP helpers
def read_images_bin(path):
    """name -> (qvec wxyz, tvec, camera_id, image_id) from a COLMAP images.bin."""
    d = Path(path).read_bytes(); n = struct.unpack_from("<Q", d, 0)[0]; off = 8; out = {}
    for _ in range(n):
        iid, qw, qx, qy, qz, tx, ty, tz, cid = struct.unpack_from("<i4d3di", d, off); off += 64
        e = d.index(b"\0", off); name = d[off:e].decode(); off = e + 1
        n2 = struct.unpack_from("<Q", d, off)[0]; off += 8 + n2 * 24
        out[name] = (np.array([qw, qx, qy, qz]), np.array([tx, ty, tz]), cid, iid)
    return out


def write_images_bin(path, entries):
    with open(path, "wb") as f:
        f.write(struct.pack("<Q", len(entries)))
        for name, (q, t, cid, iid) in sorted(entries.items()):
            f.write(struct.pack("<i4d3di", iid, *q, *t, cid) + name.encode() + b"\0" + struct.pack("<Q", 0))


def c2w_cv(q, t):
    w, x, y, z = q / np.linalg.norm(q)
    R = np.array([[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
                  [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
                  [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]])
    M = np.eye(4); M[:3, :3] = R.T; M[:3, 3] = -R.T @ t
    return M


def read_pinhole(cameras_bin):
    d = Path(cameras_bin).read_bytes()
    _, cid, model, w, h = struct.unpack_from("<Qiiqq", d, 0)
    assert model == 1, "expected PINHOLE after undistortion"
    fx, fy, cx, cy = struct.unpack_from("<4d", d, 8 + 4 + 4 + 16)
    return dict(fx=fx, fy=fy, cx=cx, cy=cy, w=w, h=h)


def write_points_ply(path, xyz, rgb):
    with open(path, "wb") as f:
        f.write((f"ply\nformat binary_little_endian 1.0\nelement vertex {len(xyz)}\n"
                 "property float x\nproperty float y\nproperty float z\n"
                 "property uchar red\nproperty uchar green\nproperty uchar blue\nend_header\n").encode())
        a = np.zeros(len(xyz), dtype=[("p", "<f4", 3), ("c", "u1", 3)]); a["p"] = xyz; a["c"] = rgb
        f.write(a.tobytes())


# ---------------------------------------------------------------- splat helpers
def read_ply(path):
    d = Path(path).read_bytes(); i = d.index(b"end_header\n") + 11; h = d[:i].decode()
    props = [l.split()[-1] for l in h.splitlines() if l.startswith("property float")]
    n = int([l for l in h.splitlines() if l.startswith("element vertex")][0].split()[-1])
    return h, props, np.frombuffer(d, np.float32, n * len(props), i).reshape(n, len(props)).copy()


def write_ply(path, h, props, a):
    n0 = int([l for l in h.splitlines() if l.startswith("element vertex")][0].split()[-1])
    Path(path).write_bytes(h.replace(f"element vertex {n0}", f"element vertex {len(a)}").encode()
                           + a.astype(np.float32).tobytes())


def prune_ckpt(src, dst, keep):
    """msplat checkpoint: 56-byte header (N at offset 12) + tensors (int32 ndim, int64 dims, int64 nbytes, f32 data);
    every tensor's first dim is the gaussian index (params + Adam moments)."""
    d = Path(src).read_bytes(); head = bytearray(d[:56]); off = 56; out = []
    while off < len(d):
        nd = struct.unpack_from("<i", d, off)[0]; dims = struct.unpack_from(f"<{nd}q", d, off + 4)
        nb = struct.unpack_from("<q", d, off + 4 + 8 * nd)[0]; s = off + 12 + 8 * nd
        t = np.frombuffer(d, np.float32, nb // 4, s).reshape(dims)[keep]; off = s + nb
        out.append(struct.pack("<i", t.ndim) + struct.pack(f"<{t.ndim}q", *t.shape) + struct.pack("<q", t.nbytes) + t.tobytes())
    struct.pack_into("<I", head, 12, int(keep.sum()))
    Path(dst).write_bytes(bytes(head) + b"".join(out))


def clean_mask(ply, cams, K, mask_dir, dil=25, frac=0.7, min_opacity=0.05, max_scale_frac=0.08):
    """keep-mask: inside the mask visual hull (>= frac of views that see it, masks dilated `dil` px at 1/4 res),
    opacity >= min_opacity, largest axis < max_scale_frac * object extent."""
    from PIL import Image
    from scipy.ndimage import grey_dilation
    h, props, a = read_ply(ply); P = a[:, :3].astype(np.float64); ix = {p: i for i, p in enumerate(props)}
    op = 1 / (1 + np.exp(-a[:, ix["opacity"]]))
    sc = np.exp(a[:, [ix["scale_0"], ix["scale_1"], ix["scale_2"]]]).max(1)
    inside = np.zeros(len(a)); seen = np.zeros(len(a))
    for name, M in cams.items():
        W = np.linalg.inv(M); X = (W[:3, :3] @ P.T).T + W[:3, 3]; z = X[:, 2]
        with np.errstate(divide="ignore", invalid="ignore"):
            u = K["fx"] * X[:, 0] / z + K["cx"]; v = K["fy"] * X[:, 1] / z + K["cy"]
        ok = (z > 0) & (u >= 0) & (u < K["w"]) & (v >= 0) & (v < K["h"])
        m = np.asarray(Image.open(mask_dir / f"{Path(name).stem}.png").convert("L").resize((K["w"] // 4, K["h"] // 4))) > 64
        m = grey_dilation(m, size=(dil, dil))
        ui = (u[ok] / 4).astype(int).clip(0, m.shape[1] - 1); vi = (v[ok] / 4).astype(int).clip(0, m.shape[0] - 1)
        seen[ok] += 1; inside[np.where(ok)[0]] += m[vi, ui]
    hull = (seen >= 3) & (inside >= frac * seen)
    core = P[hull & (op > 0.3)]
    ext = float(np.linalg.norm(np.percentile(core, 98, 0) - np.percentile(core, 2, 0))) if len(core) else np.inf
    keep = hull & (op >= min_opacity) & (sc < max_scale_frac * ext)
    stats = dict(total=len(a), kept=int(keep.sum()), removed_hull=int((~hull).sum()),
                 removed_low_opacity=int((hull & (op < min_opacity)).sum()),
                 removed_huge=int((hull & (op >= min_opacity) & (sc >= max_scale_frac * ext)).sum()))
    return keep, (h, props, a), stats


# ---------------------------------------------------------------- main
def main():
    a = parse()
    cap = a.capture.expanduser().resolve()
    raw = cap / "raw"
    images = sorted(p for p in raw.iterdir() if p.suffix.lower() in (".jpg", ".jpeg", ".png"))
    excl = parse_ranges(a.exclude)
    if not images:
        sys.exit(f"no images in {raw}")
    log(f"{len(images)} images in {raw}" + (f", excluding {sorted(excl)}" if excl else ""))
    import pycolmap
    from PIL import Image
    sfm = cap / "sfm"; sparse = sfm / "sparse"; und = sfm / "undist"
    report = {"capture": str(cap), "num_images": len(images)}

    # ---- masks (raw image space)
    mask_src = None
    if not a.no_mask:
        if a.remask:
            mask_src = remask(images, cap / "masks_rembg", a.rembg_model); stage("remask")
        elif a.mask:
            mask_src = a.mask.expanduser().resolve()
        elif (cap / "masks").is_dir():
            mask_src = cap / "masks"
    masked = mask_src is not None
    report["masked"] = masked

    # ---- COLMAP (object pixels only when masked)
    if not (a.reuse_sfm and (sparse / "0").exists()):
        if sfm.exists():
            shutil.rmtree(sfm)
        (sfm / "images").mkdir(parents=True)
        for img in images:
            (sfm / "images" / img.name).symlink_to(img)
        reader = pycolmap.ImageReaderOptions(); reader.camera_model = "OPENCV"
        if masked:
            (sfm / "masks").mkdir()
            for img in images:
                m = find_mask(mask_src, img)
                if m:
                    (sfm / "masks" / f"{img.name}.png").symlink_to(m)
            reader.mask_path = str(sfm / "masks")
        tj = cap / "transforms.json"
        if tj.exists():
            t = json.loads(tj.read_text()); iw, ih = Image.open(images[0]).size; sx, sy = iw / t["w"], ih / t["h"]
            reader.camera_params = ",".join(map(str, [t["fl_x"] * sx, t["fl_y"] * sy, t["cx"] * sx, t["cy"] * sy, 0, 0, 0, 0]))
            report["intrinsics_seed"] = "transforms.json"
        ext = pycolmap.FeatureExtractionOptions(); ext.max_image_size = a.max_image_size; ext.sift.max_num_features = 16384
        db = sfm / "database.db"
        pycolmap.extract_features(db, sfm / "images", camera_mode=pycolmap.CameraMode.SINGLE,
                                  reader_options=reader, extraction_options=ext)
        stage("colmap_features")
        matcher = a.matcher or ("exhaustive" if len(images) < 200 else "sequential")
        report["matcher"] = matcher
        (pycolmap.match_exhaustive if matcher == "exhaustive" else pycolmap.match_sequential)(db)
        stage("colmap_matching")
        sparse.mkdir(exist_ok=True)
        maps = pycolmap.incremental_mapping(db, sfm / "images", sparse)
        stage("colmap_mapping")
        if not maps:
            sys.exit("COLMAP failed to register any model")
        best = max(maps, key=lambda k: maps[k].num_reg_images())
        if best != 0:
            if (sparse / "0").exists():
                shutil.move(str(sparse / "0"), str(sparse / "0_small"))
            shutil.move(str(sparse / str(best)), str(sparse / "0"))
        # ---- undistort images (+ masks) to PINHOLE: msplat ignores distortion terms
        pycolmap.undistort_images(str(und), str(sparse / "0"), str(sfm / "images"))
        if masked:
            undistort_masks(sparse / "0", und, images, mask_src)
        stage("undistort")

    rec = pycolmap.Reconstruction(str(und / "sparse"))
    nreg = rec.num_reg_images()
    report.update(num_registered=nreg, num_points3D=rec.num_points3D(),
                  mean_reprojection_error_px=round(rec.compute_mean_reprojection_error(), 3))
    log(f"COLMAP: {nreg}/{len(images)} registered, {rec.num_points3D()} points, reproj {report['mean_reprojection_error_px']} px")
    if nreg < 0.8 * len(images):
        report["warning"] = "物体纹理太少，建议改用绕拍 (fewer than 80% of images registered)"
        log("WARNING:", report["warning"])
    K = read_pinhole(und / "sparse" / "cameras.bin")
    all_entries = read_images_bin(und / "sparse" / "images.bin")
    xyz = np.array([p.xyz for p in rec.points3D.values()]); rgb = np.array([p.color for p in rec.points3D.values()])

    # ---- output version
    out_root = cap / "splat"; out_root.mkdir(exist_ok=True)
    ver = a.version or "v%03d" % (1 + max([int(p.name[1:]) for p in out_root.glob("v[0-9][0-9][0-9]")] or [0]))
    out = out_root / ver; out.mkdir(parents=True, exist_ok=True)
    bg = tuple(float(v) for v in a.bg.split(",")) if a.bg else ((0.0, 0.0, 0.0) if masked else None)

    # ---- training images: composited onto bg with the (tight) mask
    train_imgs = out / "train_images"; train_imgs.mkdir(exist_ok=True)
    for f in (und / "images").iterdir():
        dst = train_imgs / f.name
        if dst.exists() or dst.is_symlink():
            continue
        if masked and (und / "masks" / f"{f.stem}.png").exists():
            im = Image.open(f).convert("RGB")
            mk = Image.open(und / "masks" / f"{f.stem}.png").convert("L")
            bg255 = tuple(int(round(c * 255)) for c in bg)
            Image.composite(im, Image.new("RGB", im.size, bg255), mk).save(dst, quality=95)
        else:
            dst.symlink_to(f)
    if masked:
        stage("composite")

    def train(entries, tag):
        d = out / f"_data_{tag}"
        if d.exists():
            shutil.rmtree(d)
        (d / "sparse" / "0").mkdir(parents=True); (d / "images").mkdir()
        shutil.copy(und / "sparse" / "cameras.bin", d / "sparse" / "0" / "cameras.bin")
        write_images_bin(d / "sparse" / "0" / "images.bin", entries)
        write_points_ply(d / "sparse" / "0" / "points3D.ply", xyz, rgb)
        for n in entries:
            (d / "images" / n).symlink_to(train_imgs / n)
        import msplat
        ds = msplat.Dataset(str(d), downscale_factor=a.downscale, eval_mode=a.eval)
        cfg = msplat.TrainingConfig(iterations=a.iters, output=str(out / "splat_raw.ply"), keep_crs=True)
        if bg is not None:
            cfg.bg_color = list(bg)
        if a.densify_grad_thresh:
            cfg.densify_grad_thresh = a.densify_grad_thresh
        tr = msplat.GaussianTrainer(ds, cfg)
        tr.train(lambda s: log(f"  step {s.iteration} splats {s.splat_count}"), 1000)
        return d, ds, tr

    entries = {n: e for n, e in all_entries.items() if frame_no(n) not in excl}
    d, ds, tr = train(entries, "train")
    stage("msplat_train")

    # ---- per-view fit: views that cannot be fitted = object moved / changed between shots
    fit = view_fit(tr, ds, sorted(entries), a.eval, und, masked)
    report["view_fit_psnr"] = fit
    # reference = well-fitting views (75th percentile): when the object moved mid-capture,
    # up to half the views can be bad, so the median is not a safe reference.
    ref = float(np.percentile(list(fit.values()), 75))
    bad = sorted(n for n, v in fit.items() if v < ref - 6)
    if bad:
        report["inconsistent_views"] = bad
        log(f"WARNING: {len(bad)} views fit > 6 dB worse than p75 {ref:.1f} dB: {[frame_no(n) for n in bad]} "
            "— object probably moved or changed (e.g. hand-rotated, parts moved)")
    if bad and a.drop_inconsistent:
        entries = {n: e for n, e in entries.items() if n not in bad}
        d, ds, tr = train(entries, "train2")
        stage("msplat_retrain")
        report["dropped_views"] = bad
    report["num_train_views"] = len(entries)

    tr.export_ply(str(out / "splat_raw.ply")); tr.save_checkpoint(str(out / "model.ckpt"))
    if a.eval:
        report["eval"] = {k: (round(v, 4) if isinstance(v, float) else v) for k, v in tr.evaluate().items()}
        log("eval:", report["eval"])

    # ---- cleanup
    do_clean = a.clean == "on" or (a.clean == "auto" and masked)
    if do_clean and masked:
        cams = {n: c2w_cv(q, t) for n, (q, t, _, _) in entries.items()}
        keep, (h, props, arr), st = clean_mask(out / "splat_raw.ply", cams, K, und / "masks")
        write_ply(out / "splat.ply", h, props, arr[keep])
        prune_ckpt(out / "model.ckpt", out / "model.ckpt", keep)
        import msplat
        tr2 = msplat.GaussianTrainer(ds, msplat.TrainingConfig(keep_crs=True, bg_color=list(bg)))
        tr2.load_checkpoint(str(out / "model.ckpt"))
        tr2.export_splat(str(out / "splat.splat"))
        if a.eval:
            report["eval_cleaned"] = {k: (round(v, 4) if isinstance(v, float) else v) for k, v in tr2.evaluate().items()}
        report["cleanup"] = st
        log("cleanup:", st)
    else:
        shutil.copy(out / "splat_raw.ply", out / "splat.ply")
        tr.export_splat(str(out / "splat.splat"))
    stage("cleanup_export")

    # cameras next to the ply so viewers can frame the object in this splat's coordinate system
    (out / "sparse" / "0").mkdir(parents=True, exist_ok=True)
    shutil.copy(d / "sparse" / "0" / "cameras.bin", out / "sparse" / "0" / "cameras.bin")
    shutil.copy(d / "sparse" / "0" / "images.bin", out / "sparse" / "0" / "images.bin")
    report.update(output_ply=str(out / "splat.ply"), output_mb=round((out / "splat.ply").stat().st_size / 1e6, 1),
                  settings=dict(iters=a.iters, downscale=a.downscale, bg=bg, densify_grad_thresh=a.densify_grad_thresh),
                  timings_s=TIMES, total_s=round(time.time() - T0, 1))
    (out / "report.json").write_text(json.dumps(report, indent=2, ensure_ascii=False))
    log(json.dumps({k: v for k, v in report.items() if k != "view_fit_psnr"}, indent=2, ensure_ascii=False))


def view_fit(tr, ds, names, eval_mode, und, masked):
    """PSNR of each training view against its own target (inside the mask when masked)."""
    from PIL import Image
    train_names = [n for i, n in enumerate(names) if not (eval_mode and i % 8 == 0)]
    out = {}
    for i, n in enumerate(train_names):
        r = np.clip(tr.render(i), 0, 1); size = (r.shape[1], r.shape[0])
        g = np.asarray(Image.open(und / "images" / n).convert("RGB").resize(size), np.float32) / 255
        err = (r - g) ** 2
        mp = und / "masks" / f"{Path(n).stem}.png"
        if masked and mp.exists():
            m = np.asarray(Image.open(mp).convert("L").resize(size)) > 127
            err = err[m] if m.any() else err
        out[n] = round(float(-10 * np.log10(err.mean() + 1e-12)), 2)
    return out


def undistort_masks(raw_sparse, und, images, mask_src):
    """Warp raw-space masks into the undistorted PINHOLE images (nearest neighbour, OPENCV model)."""
    import pycolmap
    from PIL import Image
    cam = next(iter(pycolmap.Reconstruction(str(raw_sparse)).cameras.values()))
    fx, fy, cx, cy, k1, k2, p1, p2 = list(cam.params) + [0.0] * (8 - len(cam.params))
    K = read_pinhole(und / "sparse" / "cameras.bin")
    W, H = K["w"], K["h"]
    u, v = np.meshgrid(np.arange(W, dtype=np.float64), np.arange(H, dtype=np.float64))
    x = (u - K["cx"]) / K["fx"]; y = (v - K["cy"]) / K["fy"]; r2 = x * x + y * y; rad = 1 + k1 * r2 + k2 * r2 * r2
    xd = x * rad + 2 * p1 * x * y + p2 * (r2 + 2 * x * x); yd = y * rad + p1 * (r2 + 2 * y * y) + 2 * p2 * x * y
    ur = np.clip(np.rint(fx * xd + cx), 0, cam.width - 1).astype(np.int32)
    vr = np.clip(np.rint(fy * yd + cy), 0, cam.height - 1).astype(np.int32)
    (und / "masks").mkdir(exist_ok=True)
    for img in images:
        m = find_mask(mask_src, img)
        if not m or not (und / "images" / img.name).exists():
            continue
        a = np.asarray(Image.open(m).convert("L").resize((cam.width, cam.height)))
        Image.fromarray(((a[vr, ur] > 127) * 255).astype(np.uint8)).save(und / "masks" / f"{img.stem}.png")


def find_mask(mask_dir, img):
    for cand in (f"{img.name}.png", f"{img.stem}.png"):
        f = mask_dir / cand
        if f.exists():
            return f
    return None


def remask(images, out_dir, model):
    try:
        from rembg import remove, new_session
    except ImportError:
        sys.exit("--remask needs rembg: uv pip install -p <venv> 'rembg[cpu]'")
    from PIL import Image
    out_dir.mkdir(parents=True, exist_ok=True)
    sess = new_session(model)
    for img in images:
        f = out_dir / f"{img.stem}.png"
        if f.exists():
            continue
        im = Image.open(img).convert("RGB"); small = im.resize((im.width // 2, im.height // 2))
        remove(small, session=sess, only_mask=True).resize(im.size, Image.BILINEAR).save(f)
    return out_dir


if __name__ == "__main__":
    main()
