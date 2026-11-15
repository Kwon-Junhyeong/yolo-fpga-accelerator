import argparse
import csv
import sys
from pathlib import Path

import numpy as np

TB = Path(__file__).resolve().parent.parent / "sim"
sys.path.insert(0, str(TB))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from golden import (conv3x3_accum, maxpool2,
                              maxpool2_stride1_clamp, relu_shift_u8)
from quantlib import read_log_param

LAYER_DEFS = {
    0: (3, 16, 3), 2: (16, 32, 3), 4: (32, 64, 3), 6: (64, 128, 3),
    8: (128, 256, 3), 10: (256, 512, 3), 12: (512, 256, 1),
    13: (256, 512, 3), 14: (512, 195, 1), 17: (256, 128, 1),
    20: (384, 195, 1),
}

def load_params(log_param_dir):
    out = {}
    for cid, (c, n, k) in LAYER_DEFS.items():
        w, b, s = read_log_param(log_param_dir, cid, n, c, k)
        assert np.all(s > 0) and np.all((s & (s - 1)) == 0), f"CONV{cid:02d} scale not pow2"
        shift = np.array([int(v).bit_length() - 1 for v in s], dtype=np.int64)
        out[cid] = dict(w=w.astype(np.int64), b=b, shift=shift)
    return out

def load_ifm32_fast(path):
    words = np.array([int(s, 16) for s in Path(path).read_text().split()],
                     dtype=np.int64)
    assert words.size == 65536, f"{path}: {words.size} words"
    x = np.zeros((4, 65536), dtype=np.uint8)
    x[0] = words & 0xFF
    x[1] = (words >> 8) & 0xFF
    x[2] = (words >> 16) & 0xFF
    x[3] = (words >> 24) & 0xFF
    return x.reshape(4, 256, 256)

def conv1x1_accum(x, kernels, bias):
    y = np.einsum("oi,ihw->ohw", kernels[:, :, 0, 0].astype(np.int64),
                  x.astype(np.int64), optimize=True)
    return y + bias[:, None, None]

def forward(params, ifm):
    o = {}
    x = ifm

    def conv3(cid, xin):
        p = params[cid]
        w = p["w"]
        if w.shape[1] < xin.shape[0]:
            pad = np.zeros((w.shape[0], xin.shape[0] - w.shape[1], 3, 3),
                           dtype=w.dtype)
            w = np.concatenate([w, pad], axis=1)
        return conv3x3_accum(xin, w, p["b"]), p["shift"]

    acc, sh = conv3(0, x)
    x = maxpool2(relu_shift_u8(acc, sh)); o["L0"] = x
    acc, sh = conv3(2, x)
    x = maxpool2(relu_shift_u8(acc, sh)); o["L2"] = x
    acc, sh = conv3(4, x)
    x = maxpool2(relu_shift_u8(acc, sh)); o["L4"] = x
    acc, sh = conv3(6, x)
    x = maxpool2(relu_shift_u8(acc, sh)); o["L6"] = x
    acc, sh = conv3(8, x)
    o["L8RAW"] = relu_shift_u8(acc, np.maximum(sh - 1, 0))
    x = maxpool2(relu_shift_u8(acc, sh)); o["L8"] = x
    acc, sh = conv3(10, x)
    x = relu_shift_u8(acc, sh); o["L10"] = x
    x = maxpool2_stride1_clamp(x); o["L11"] = x
    p = params[12]
    x = relu_shift_u8(conv1x1_accum(x, p["w"], p["b"]), p["shift"]); o["L12"] = x
    acc, sh = conv3(13, x)
    l13 = relu_shift_u8(acc, sh); o["L13"] = l13
    p = params[14]
    o["HEAD14"] = conv1x1_accum(l13, p["w"], p["b"])
    p = params[17]
    l17 = relu_shift_u8(conv1x1_accum(o["L12"], p["w"], p["b"]), p["shift"])
    o["L17"] = l17
    up17 = np.repeat(np.repeat(l17, 2, axis=1), 2, axis=2)
    l20_in = np.concatenate([up17, o["L8RAW"]], axis=0)
    p = params[20]
    o["HEAD20"] = conv1x1_accum(l20_in, p["w"], p["b"])
    return o

def write_head32_snapshot(path, raw, partition_channels=32):
    channels, h, w = raw.shape
    plane = h * w
    flat = raw.reshape(channels, plane)
    lines = []
    for ch_start in range(0, channels, partition_channels):
        count = min(partition_channels, channels - ch_start)
        block = flat[ch_start:ch_start + count]
        vals = block.T.reshape(-1)
        lines.extend(f"{int(v) & 0xFFFFFFFF:08x}" for v in vals)
    Path(path).write_text("\n".join(lines) + "\n")

def cmd_check_equiv(args):
    pa = load_params(args.params_a)
    pb = load_params(args.params_b)
    ifm = load_ifm32_fast(args.input)
    oa = forward(pa, ifm)
    ob = forward(pb, ifm)
    print(f"{'layer':8s} {'shape':16s} {'maxabs':>6s} {'meanabs':>8s} {'pct_diff':>8s}")
    for k in ["L0", "L2", "L4", "L6", "L8", "L8RAW", "L10", "L11", "L12",
              "L13", "L17", "HEAD14", "HEAD20"]:
        d = oa[k].astype(np.int64) - ob[k].astype(np.int64)
        print(f"{k:8s} {str(oa[k].shape):16s} {int(np.max(np.abs(d))):6d} "
              f"{float(np.mean(np.abs(d))):8.3f} "
              f"{100.0 * np.mean(d != 0):7.2f}%")

def cmd_run(args):
    params = load_params(args.params)
    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    rows = list(csv.DictReader(Path(args.manifest).open(newline=""),
                               delimiter="\t"))
    rows = rows[args.start:args.start + args.limit] if args.limit else rows[args.start:]

    def one(row):
        ifm = load_ifm32_fast(row["input"])
        o = forward(params, ifm)
        write_head32_snapshot(out_dir / f"{row['stem']}_L14.txt", o["HEAD14"])
        write_head32_snapshot(out_dir / f"{row['stem']}_L20.txt", o["HEAD20"])
        return row["stem"]

    if args.jobs > 1:
        from multiprocessing import Pool
        with Pool(args.jobs) as pool:
            for i, stem in enumerate(pool.imap_unordered(_worker_run,
                    [(args.params, str(out_dir), row) for row in rows]), 1):
                if i % 10 == 0 or i == len(rows):
                    print(f"[run] {i}/{len(rows)}")
    else:
        for i, row in enumerate(rows, 1):
            one(row)
            if i % 10 == 0 or i == len(rows):
                print(f"[run] {i}/{len(rows)}")
    print(f"[run] snapshots -> {out_dir}")

_PARAM_CACHE = {}

def _worker_run(job):
    params_dir, out_dir, row = job
    if params_dir not in _PARAM_CACHE:
        _PARAM_CACHE[params_dir] = load_params(params_dir)
    params = _PARAM_CACHE[params_dir]
    ifm = load_ifm32_fast(row["input"])
    o = forward(params, ifm)
    out_dir = Path(out_dir)
    write_head32_snapshot(out_dir / f"{row['stem']}_L14.txt", o["HEAD14"])
    write_head32_snapshot(out_dir / f"{row['stem']}_L20.txt", o["HEAD20"])
    return row["stem"]

def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("check-equiv")
    p.add_argument("--params-a", required=True)
    p.add_argument("--params-b", required=True)
    p.add_argument("--input", required=True)
    p.set_defaults(func=cmd_check_equiv)

    p = sub.add_parser("run")
    p.add_argument("--params", required=True)
    p.add_argument("--manifest", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--start", type=int, default=0)
    p.add_argument("--limit", type=int, default=None)
    p.add_argument("--jobs", type=int, default=1)
    p.set_defaults(func=cmd_run)

    args = ap.parse_args()
    args.func(args)

if __name__ == "__main__":
    main()
