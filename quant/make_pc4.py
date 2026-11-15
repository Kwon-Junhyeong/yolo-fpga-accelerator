import json
import shutil
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from quantlib import (CONV_IDS, HEAD_LAYERS, IN_MULT, W_MULT, layer_scales,
                      load_folded_float_params_exact, read_log_param,
                      write_log_param)

HERE = Path(__file__).resolve().parent
PC3 = HERE / "log_param_pc3"
MAX_SHIFT = 15
MIN_E = -2
PCTL = 99.9

LAYER_DEFS = {0: (3, 16, 3), 2: (16, 32, 3), 4: (32, 64, 3), 6: (64, 128, 3),
              8: (128, 256, 3), 10: (256, 512, 3), 12: (512, 256, 1),
              13: (256, 512, 3), 14: (512, 195, 1), 17: (256, 128, 1),
              20: (384, 195, 1)}

def round_half_away(x):
    x = np.asarray(x, dtype=np.float64)
    return np.where(x >= 0, np.floor(x + 0.5), np.ceil(x - 0.5)).astype(np.int64)

def quant_pc_layer(w, b, wm, im, base_scale, wfit):
    base_shift = int(base_scale).bit_length() - 1
    n = w.shape[0]
    w_q = np.zeros_like(w, dtype=np.int64)
    b_q = np.zeros(n, dtype=np.int64)
    scales = np.zeros(n, dtype=np.int64)
    e_arr = np.zeros(n, dtype=np.int64)
    sat = np.zeros(n, dtype=np.int64)
    for oc in range(n):
        wstat = float(wfit(w[oc]))
        bval = float(b[oc])
        e = MAX_SHIFT - base_shift
        while e > MIN_E:
            ok_w = int(round_half_away(wstat * wm * 2.0 ** e)) <= 127
            ok_b = abs(int(round_half_away(bval * im * wm * 2.0 ** e))) <= 32767
            if ok_w and ok_b:
                break
            e -= 1
        assert base_shift + e >= 0
        mult = wm * 2.0 ** e
        raw = round_half_away(w[oc] * mult)
        w_q[oc] = np.clip(raw, -127, 127)
        sat[oc] = int(np.sum(np.abs(raw) > 127))
        b_q[oc] = np.clip(round_half_away(bval * im * mult), -32768, 32767)
        assert abs(int(round_half_away(bval * im * mult))) <= 32767, \
            f"bias clip oc={oc}"
        scales[oc] = base_scale << e if e >= 0 else base_scale >> -e
        e_arr[oc] = e
    return w_q, b_q, scales, e_arr, sat

def copy_head_from_pc3(out_dir, cid):
    out_dir.mkdir(parents=True, exist_ok=True)
    for kind in ("weight", "biases", "scales"):
        src = PC3 / f"CONV{cid:02d}_param_{kind}.hex"
        shutil.copy2(src, out_dir / src.name)

def main():
    params = load_folded_float_params_exact()
    out4 = HERE / "log_param_pc4"
    out4b = HERE / "log_param_pc4b"
    report = {}
    for cid in CONV_IDS:
        p = params[cid]
        n = p["n"]
        wm, im = W_MULT[cid], IN_MULT[cid]
        base_scale = layer_scales(cid)
        base_shift = int(base_scale).bit_length() - 1
        if cid in HEAD_LAYERS:
            copy_head_from_pc3(out4, cid)
            copy_head_from_pc3(out4b, cid)
            print(f"CONV{cid:02d}: head bytes copied from pc3")
            report[f"CONV{cid:02d}"] = dict(head=True)
            continue
        w = p["weights"].astype(np.float64)
        b = p["biases"].astype(np.float64)

        wq4, bq4, s4, e4, sat4 = quant_pc_layer(
            w, b, wm, im, base_scale, lambda wo: np.max(np.abs(wo)))
        write_log_param(out4, cid, wq4, bq4, s4)

        wq4b, bq4b, s4b, e4b, sat4b = quant_pc_layer(
            w, b, wm, im, base_scale,
            lambda wo: np.percentile(np.abs(wo), PCTL))
        write_log_param(out4b, cid, wq4b, bq4b, s4b)

        for s in (s4, s4b):
            assert np.all(s > 0) and np.all((s & (s - 1)) == 0)
            sh = np.array([int(v).bit_length() - 1 for v in s])
            assert sh.min() >= 0 and sh.max() <= MAX_SHIFT
        for wq, bq in ((wq4, bq4), (wq4b, bq4b)):
            assert wq.min() >= -127 and wq.max() <= 127
            assert bq.min() >= -32768 and bq.max() <= 32767

        c, nn, k = LAYER_DEFS[cid]
        w3, b3, s3 = read_log_param(PC3, cid, nn, c, k)
        same4 = (np.array_equal(wq4, w3) and np.array_equal(bq4, b3)
                 and np.array_equal(s4, s3))
        de = e4b - e4
        de_hist = {int(kk): int(v) for kk, v in zip(*np.unique(de, return_counts=True))}
        e4_hist = {int(kk): int(v) for kk, v in zip(*np.unique(e4, return_counts=True))}
        e4b_hist = {int(kk): int(v) for kk, v in zip(*np.unique(e4b, return_counts=True))}
        wdiff = int(np.sum(wq4b != wq4))
        report[f"CONV{cid:02d}"] = dict(
            head=False, base_shift=base_shift,
            pc4_equals_pc3=bool(same4),
            e_pc4_hist=e4_hist, e_pc4b_hist=e4b_hist, e_delta_hist=de_hist,
            channels_boosted=int(np.sum(de > 0)),
            pc4b_sat_weights=int(sat4b.sum()), weights_total=int(wq4.size),
            pc4b_w_changed_vs_pc4=wdiff)
        print(f"CONV{cid:02d}: pc4==pc3 {same4} | e4 {e4_hist} | e4b {e4b_hist} "
              f"| d_e {de_hist} | boosted {int(np.sum(de>0))}/{n} "
              f"| sat_w {int(sat4b.sum())}/{wq4.size} | w_changed {wdiff}")
    (HERE / "_pc4_report.json").write_text(json.dumps(report, indent=2))
    print("wrote", out4, "and", out4b)

if __name__ == "__main__":
    main()
