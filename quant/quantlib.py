import os
import struct
from pathlib import Path

import numpy as np

CONTEST_BIN = Path(os.environ.get("CONTEST_BIN", "contest/bin"))
CFG_PATH = CONTEST_BIN / "aix2024.cfg"
WEIGHTS_PATH = CONTEST_BIN / "aix2024.weights"

CONV_IDS = [0, 2, 4, 6, 8, 10, 12, 13, 14, 17, 20]
W_MULT = {0: 16, 2: 128, 4: 128, 6: 128, 8: 128, 10: 512,
          12: 256, 13: 256, 14: 128, 17: 128, 20: 128}
IN_MULT = {0: 256, 2: 16, 4: 32, 6: 32, 8: 64, 10: 16,
           12: 64, 13: 64, 14: 64, 17: 64, 20: 32}
NEXT_CONV = {0: 2, 2: 4, 4: 6, 6: 8, 8: 10, 10: 12, 12: 13, 13: 14,
             14: 17, 17: 20, 20: None}

HEAD_LAYERS = (14, 20)

def parse_cfg(path=CFG_PATH):
    sections = []
    cur = None
    for raw in Path(path).read_text().splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if line.startswith("["):
            cur = {"type": line.strip("[]"), "opts": {}}
            sections.append(cur)
        elif "=" in line and cur is not None:
            k, v = line.split("=", 1)
            cur["opts"][k.strip()] = v.strip()

    net = sections[0]
    assert net["type"] == "net"
    c = int(net["opts"]["channels"])
    layers = []
    out_ch = []
    for sec in sections[1:]:
        t = sec["type"]
        o = sec["opts"]
        idx = len(layers)
        if t == "convolutional":
            n = int(o.get("filters", 1))
            size = int(o.get("size", 1))
            bn = int(o.get("batch_normalize", 0))
            layers.append(dict(type="conv", idx=idx, n=n, c=c, size=size, bn=bn,
                               activation=o.get("activation", "logistic")))
            c = n
        elif t == "maxpool":
            layers.append(dict(type="maxpool", idx=idx))
        elif t == "route":
            refs = [int(x) for x in o["layers"].replace(",", " ").split()]
            refs = [r if r >= 0 else idx + r for r in refs]
            c = sum(out_ch[r] for r in refs)
            layers.append(dict(type="route", idx=idx, refs=refs))
        elif t == "upsample":
            layers.append(dict(type="upsample", idx=idx))
        elif t == "yolo":
            layers.append(dict(type="yolo", idx=idx))
        else:
            layers.append(dict(type=t, idx=idx))
        out_ch.append(c)
    return layers

def load_folded_float_params(cfg_path=CFG_PATH, weights_path=WEIGHTS_PATH):
    layers = parse_cfg(cfg_path)
    blob = Path(weights_path).read_bytes()
    major, minor, revision = struct.unpack_from("<iii", blob, 0)
    off = 12
    if major * 10 + minor >= 2:
        off += 8
    else:
        off += 4

    out = {}
    for lay in layers:
        if lay["type"] != "conv":
            continue
        n, c, k = lay["n"], lay["c"], lay["size"]
        num_w = n * c * k * k

        def take(cnt):
            nonlocal off
            arr = np.frombuffer(blob, dtype="<f4", count=cnt, offset=off).copy()
            off += 4 * cnt
            return arr

        biases = take(n)
        if lay["bn"]:
            bn_scales = take(n)
            bn_mean = take(n)
            bn_var = take(n)
        weights = take(num_w).reshape(n, c, k, k)

        if lay["bn"]:
            denom = np.sqrt(bn_var, dtype=np.float32) + np.float32(0.000001)
            biases = (biases - (bn_scales * bn_mean) / denom).astype(np.float32)
            weights = (weights * (bn_scales / denom)[:, None, None, None]
                       ).astype(np.float32)
        out[lay["idx"]] = dict(weights=weights, biases=biases, n=n, c=c, k=k,
                               bn=lay["bn"])
    assert off == len(blob), f"weights file not fully consumed: {off} != {len(blob)}"
    return out

def load_folded_float_params_exact(cfg_path=CFG_PATH, weights_path=WEIGHTS_PATH):
    layers = parse_cfg(cfg_path)
    blob = Path(weights_path).read_bytes()
    major, minor, revision = struct.unpack_from("<iii", blob, 0)
    off = 12 + (8 if major * 10 + minor >= 2 else 4)

    out = {}
    for lay in layers:
        if lay["type"] != "conv":
            continue
        n, c, k = lay["n"], lay["c"], lay["size"]

        def take(cnt):
            nonlocal off
            arr = np.frombuffer(blob, dtype="<f4", count=cnt, offset=off).copy()
            off += 4 * cnt
            return arr

        biases = take(n)
        bn_scales = bn_mean = bn_var = None
        if lay["bn"]:
            bn_scales, bn_mean, bn_var = take(n), take(n), take(n)
        weights = take(n * c * k * k).reshape(n, c, k, k)

        if lay["bn"]:
            denom = (np.sqrt(bn_var.astype(np.float32), dtype=np.float32)
                     + np.float32(0.000001)).astype(np.float32)
            t = np.float32(bn_scales) * np.float32(bn_mean)
            t = (t / denom).astype(np.float32)
            biases = (biases - t).astype(np.float32)
            w32 = weights.astype(np.float32)
            w32 = (w32 * bn_scales[:, None, None, None]).astype(np.float32)
            w32 = (w32 / denom[:, None, None, None]).astype(np.float32)
            weights = w32
        out[lay["idx"]] = dict(weights=weights.astype(np.float32),
                               biases=biases.astype(np.float32),
                               n=n, c=c, k=k, bn=lay["bn"])
    assert off == len(blob), f"weights file not fully consumed: {off} != {len(blob)}"
    return out

def max_abs_np(src, max_val):
    src = np.asarray(src, dtype=np.int64)
    neg_clip = -max_val - 1
    return np.where(np.abs(src) > max_val,
                    np.where(src > 0, max_val, neg_clip), src)

def c_trunc_f32(x):
    return np.trunc(np.asarray(x, dtype=np.float32)).astype(np.int64)

def quantize_layer_c(weights_f32, biases_f32, w_mult, in_mult):
    w_scaled = (weights_f32.astype(np.float32) * np.float32(w_mult))
    w_q = max_abs_np(c_trunc_f32(w_scaled), 127)
    b_scaled = biases_f32.astype(np.float32) * np.float32(w_mult * in_mult)
    b_q = max_abs_np(c_trunc_f32(b_scaled), 32767)
    return w_q.astype(np.int64), b_q.astype(np.int64)

def write_log_param(out_dir, conv_id, w_q, b_q, scales):
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    n = w_q.shape[0]
    with open(out_dir / f"CONV{conv_id:02d}_param_weight.hex", "w") as f:
        for v in w_q.reshape(-1):
            f.write(f"{int(v) & 0xFF:02x}\n")
    with open(out_dir / f"CONV{conv_id:02d}_param_biases.hex", "w") as f:
        for v in b_q.reshape(-1):
            f.write(f"{int(v) & 0xFFFF:04x}\n")
    with open(out_dir / f"CONV{conv_id:02d}_param_scales.hex", "w") as f:
        for oc in range(n):
            f.write(f"{int(scales[oc]) & 0xFFFF:04x}\n")

def read_log_param(dir_path, conv_id, n, c, k):
    d = Path(dir_path)
    w = np.array([int(s, 16) for s in
                  (d / f"CONV{conv_id:02d}_param_weight.hex").read_text().split()],
                 dtype=np.int64)
    w = np.where(w >= 128, w - 256, w).reshape(n, c, k, k)
    b = np.array([int(s, 16) for s in
                  (d / f"CONV{conv_id:02d}_param_biases.hex").read_text().split()],
                 dtype=np.int64)
    b = np.where(b >= 0x8000, b - 0x10000, b)
    s = np.array([int(x, 16) for x in
                  (d / f"CONV{conv_id:02d}_param_scales.hex").read_text().split()],
                 dtype=np.int64)
    return w, b, s

def layer_scales(conv_id):
    nxt = NEXT_CONV[conv_id]
    next_in = IN_MULT[nxt] if nxt is not None else 1
    return int((IN_MULT[conv_id] * W_MULT[conv_id]) / next_in)
