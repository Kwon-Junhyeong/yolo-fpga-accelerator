import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from quantlib import (CONV_IDS, HEAD_LAYERS, IN_MULT, W_MULT, layer_scales,
                      load_folded_float_params_exact, quantize_layer_c,
                      write_log_param)

OUT = Path(__file__).resolve().parent / "log_param_pc"
MAX_SHIFT = 15

def round_half_away(x):
    x = np.asarray(x, dtype=np.float64)
    return np.where(x >= 0, np.floor(x + 0.5), np.ceil(x - 0.5)).astype(np.int64)

def main():
    params = load_folded_float_params_exact()
    report = {}
    for cid in CONV_IDS:
        p = params[cid]
        n = p["n"]
        w = p["weights"].astype(np.float64)
        b = p["biases"].astype(np.float64)
        base_scale = layer_scales(cid)
        base_shift = int(base_scale).bit_length() - 1
        wm, im = W_MULT[cid], IN_MULT[cid]

        if cid in HEAD_LAYERS:
            w_q, b_q = quantize_layer_c(p["weights"], p["biases"], wm, im)
            scales = np.full(n, base_scale, dtype=np.int64)
            write_log_param(OUT, cid, w_q, b_q, scales)
            report[f"CONV{cid:02d}"] = dict(head=True, e_hist={0: n})
            print(f"CONV{cid:02d}: HEAD (kept per-layer, byte-exact), shift={base_shift}")
            continue

        e_arr = np.zeros(n, dtype=np.int64)
        limiter = []
        w_q = np.zeros_like(w, dtype=np.int64)
        b_q = np.zeros(n, dtype=np.int64)
        scales = np.zeros(n, dtype=np.int64)
        for oc in range(n):
            wmax = float(np.max(np.abs(w[oc])))
            bval = float(b[oc])
            e_cap = MAX_SHIFT - base_shift
            e = e_cap
            lim = "shift_cap"
            while e > 0:
                ok_w = round_half_away(wmax * wm * (1 << e))[()] <= 127
                ok_b = abs(round_half_away(bval * im * wm * (1 << e))[()]) <= 32767
                if ok_w and ok_b:
                    break
                lim = "weight" if not ok_w else "bias"
                e -= 1
            e_arr[oc] = e
            limiter.append(lim if e < e_cap else "shift_cap")
            mult = wm * (1 << e)
            w_q[oc] = np.clip(round_half_away(w[oc] * mult), -127, 127)
            b_q[oc] = np.clip(round_half_away(bval * im * mult), -32768, 32767)
            scales[oc] = base_scale << e
            assert base_shift + e <= MAX_SHIFT

        write_log_param(OUT, cid, w_q, b_q, scales)
        hist = {int(k): int(v) for k, v in
                zip(*np.unique(e_arr, return_counts=True))}
        lim_hist = {}
        for lim in limiter:
            lim_hist[lim] = lim_hist.get(lim, 0) + 1
        report[f"CONV{cid:02d}"] = dict(
            head=False, base_shift=base_shift, w_mult=wm, in_mult=im,
            e_hist=hist, limiter=lim_hist,
            e_mean=float(np.mean(e_arr)), e_min=int(e_arr.min()),
            e_max=int(e_arr.max()),
            shift_max=int(base_shift + e_arr.max()))
        print(f"CONV{cid:02d}: base_shift={base_shift} e_hist={hist} "
              f"e_mean={np.mean(e_arr):.2f} limiter={lim_hist}")

    (OUT / "_per_channel_report.json").write_text(json.dumps(report, indent=2))
    print(f"wrote {OUT}")

if __name__ == "__main__":
    main()
