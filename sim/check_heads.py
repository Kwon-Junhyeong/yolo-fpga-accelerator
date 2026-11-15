import re
import sys
from pathlib import Path

import numpy as np

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
import golden as V

SKELETON_BIN = Path(sys.argv[1]) if len(sys.argv) > 1 else SCRIPT_DIR / "params"
GENERATED = SCRIPT_DIR / "generated"
RESULTS = SCRIPT_DIR / "results"
SNAP_PC3 = Path(sys.argv[3]) if len(sys.argv) > 3 else SCRIPT_DIR / "reference"
STEM = sys.argv[2] if len(sys.argv) > 2 else "0078_CAPP_testset_long_10115"

def head_raw_int32(skeleton_bin, generated_dir):
    outputs = V.compute_hw_outputs(skeleton_bin, generated_dir, head16=True)
    bias, _shift = V.load_bsc(V.ROM_DIR / "bias_scale.hex")
    res = {}
    for name, lid, in_ch, base in [("L14", 14, 512, 1776), ("L20", 20, 384, 2099)]:
        if name == "L14":
            x = outputs["L13"]
        else:
            up17 = np.repeat(np.repeat(outputs["L17"], 2, axis=1), 2, axis=2)
            x = np.concatenate([up17, outputs["L8RAW"]], axis=0)
        k = V.raw_weights_to_array(
            skeleton_bin / "log_param" / f"CONV{lid:02d}_param_weight.hex", 195, in_ch, 1)
        y = np.einsum("oi,ihw->ohw", k[:, :, 0, 0].astype(np.int64),
                      x.astype(np.int64), optimize=True)
        y += bias[base:base + 195][:, None, None]
        res[name] = y
    return res

def pack_partition_int32(t, part=32):
    ch, h, w = t.shape
    out = []
    for cs in range(0, ch, part):
        cnt = min(part, ch - cs)
        blk = t[cs:cs + cnt].reshape(cnt, h * w)
        out.append(blk.T.reshape(-1))
    return np.concatenate(out).astype(np.int64)

def parse_ddr_snapshot(path):
    vals = {}
    for line in open(path):
        m = re.search(r"addr=(\d+)\s+val=0x([0-9a-fA-F]+)", line)
        if m:
            vals[int(m.group(1))] = int(m.group(2), 16) & 0xFFFFFFFF
    arr = np.zeros(max(vals) + 1, dtype=np.int64)
    for a, v in vals.items():
        arr[a] = v
    return np.where(arr >= 2**31, arr - 2**32, arr)

def parse_plain_hex(path):
    text = Path(path).read_text()
    vals = re.findall(r"val=0x([0-9a-fA-F]+)", text) or text.split()
    arr = np.array([int(s, 16) & 0xFFFFFFFF for s in vals], dtype=np.int64)
    return np.where(arr >= 2**31, arr - 2**32, arr)

def cmp(name, a, b):
    if len(a) != len(b):
        print(f"[{name}] FAIL size {len(a)} vs {len(b)}")
        return False
    n_mism = int(np.count_nonzero(a != b))
    status = "PASS" if n_mism == 0 else "FAIL"
    print(f"[{name}] {status} words={len(a)} word_mismatches={n_mism}")
    if n_mism:
        idx = np.flatnonzero(a != b)[:10]
        for i in idx:
            print(f"  addr={i} a={a[i]} b={b[i]}")
    return n_mism == 0

def main():
    heads = head_raw_int32(SKELETON_BIN, GENERATED)
    ok = True
    for name in ("L14", "L20"):
        golden = pack_partition_int32(heads[name])
        snap = SNAP_PC3 / f"{STEM}_{name}.txt"
        ref = parse_plain_hex(snap) if snap.exists() else None
        if ref is not None:
            ok &= cmp(f"{name} golden(params) vs reference", golden, ref)
        else:
            print(f"[{name}] reference reference missing: {snap} (skipped)")
        rtl_path = RESULTS / f"ddr_snapshot_{name}.txt"
        if rtl_path.exists():
            rtl = parse_ddr_snapshot(rtl_path)
            ok &= cmp(f"{name} RTL ddr vs golden(params)", rtl, golden)
            if ref is not None:
                ok &= cmp(f"{name} RTL ddr vs reference numpy ref", rtl, ref)
        else:
            print(f"[{name}] RTL snapshot not present yet: {rtl_path}")
    print("[check-heads] " + ("PASS" if ok else "FAIL"))
    return 0 if ok else 1

if __name__ == "__main__":
    sys.exit(main())
