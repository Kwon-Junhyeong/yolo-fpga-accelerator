import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from quantlib import (CONV_IDS, HEAD_LAYERS, IN_MULT, W_MULT, layer_scales,
                      load_folded_float_params_exact, quantize_layer_c,
                      write_log_param)

HERE = Path(__file__).resolve().parent
MAX_SHIFT = 15
MIN_E = -2

def round_half_away(x):
    x = np.asarray(x, dtype=np.float64)
    return np.where(x >= 0, np.floor(x + 0.5), np.ceil(x - 0.5)).astype(np.int64)

def quant_pc_layer(w, b, wm, im, base_scale):
    base_shift = int(base_scale).bit_length() - 1
    n = w.shape[0]
    w_q = np.zeros_like(w, dtype=np.int64)
    b_q = np.zeros(n, dtype=np.int64)
    scales = np.zeros(n, dtype=np.int64)
    e_arr = np.zeros(n, dtype=np.int64)
    for oc in range(n):
        wmax = float(np.max(np.abs(w[oc])))
        bval = float(b[oc])
        e = MAX_SHIFT - base_shift
        while e > MIN_E:
            ok_w = int(round_half_away(wmax * wm * 2.0 ** e)) <= 127
            ok_b = abs(int(round_half_away(bval * im * wm * 2.0 ** e))) <= 32767
            if ok_w and ok_b:
                break
            e -= 1
        assert base_shift + e >= 0
        mult = wm * 2.0 ** e
        w_q[oc] = np.clip(round_half_away(w[oc] * mult), -127, 127)
        b_q[oc] = np.clip(round_half_away(bval * im * mult), -32768, 32767)
        scales[oc] = base_scale << e if e >= 0 else base_scale >> -e
        e_arr[oc] = e
    return w_q, b_q, scales, e_arr

def main():
    params = load_folded_float_params_exact()
    out2 = HERE / "log_param_pc2"
    out3 = HERE / "log_param_pc3"
    for cid in CONV_IDS:
        p = params[cid]
        n = p["n"]
        wm, im = W_MULT[cid], IN_MULT[cid]
        base_scale = layer_scales(cid)
        if cid in HEAD_LAYERS:
            w_q, b_q = quantize_layer_c(p["weights"], p["biases"], wm, im)
            scales = np.full(n, base_scale, dtype=np.int64)
            write_log_param(out2, cid, w_q, b_q, scales)
            w_r = np.clip(round_half_away(p["weights"].astype(np.float64) * wm), -127, 127)
            b_r = np.clip(round_half_away(p["biases"].astype(np.float64) * im * wm), -32768, 32767)
            write_log_param(out3, cid, w_r, b_r, scales)
            print(f"CONV{cid:02d}: head  pc2=exact-May  pc3=rounded "
                  f"(w diff {int(np.sum(w_r != w_q))}/{w_q.size})")
            continue
        w_q, b_q, scales, e_arr = quant_pc_layer(
            p["weights"].astype(np.float64), p["biases"].astype(np.float64),
            wm, im, base_scale)
        write_log_param(out2, cid, w_q, b_q, scales)
        write_log_param(out3, cid, w_q, b_q, scales)
        neg = int(np.sum(e_arr < 0))
        hist = {int(k): int(v) for k, v in zip(*np.unique(e_arr, return_counts=True))}
        print(f"CONV{cid:02d}: e_hist={hist} neg_e_channels={neg}")
    print("wrote", out2, "and", out3)

if __name__ == "__main__":
    main()
