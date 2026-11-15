import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from quantlib import (CONV_IDS, IN_MULT, W_MULT, layer_scales,
                      load_folded_float_params_exact, quantize_layer_c,
                      read_log_param, write_log_param)

ERA = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("contest/bin/log_param")
OUT = Path(__file__).resolve().parent / "log_param_replica"

def main():
    params = load_folded_float_params_exact()
    all_ok = True
    for cid in CONV_IDS:
        p = params[cid]
        w_q, b_q = quantize_layer_c(p["weights"], p["biases"],
                                    W_MULT[cid], IN_MULT[cid])
        scale = layer_scales(cid)
        scales = np.full(p["n"], scale, dtype=np.int64)
        write_log_param(OUT, cid, w_q, b_q, scales)

        w_ref, b_ref, s_ref = read_log_param(ERA, cid, p["n"], p["c"], p["k"])
        w_ok = np.array_equal(w_q, w_ref)
        b_ok = np.array_equal(b_q, b_ref)
        s_ok = np.array_equal(scales, s_ref)
        nw = w_q.size
        wdiff = int(np.sum(w_q != w_ref))
        bdiff = int(np.sum(b_q != b_ref))
        status = "EXACT" if (w_ok and b_ok and s_ok) else "MISMATCH"
        print(f"CONV{cid:02d}: {status}  weights {nw - wdiff}/{nw} match "
              f"(diff={wdiff})  biases diff={bdiff}  scales "
              f"{'ok' if s_ok else 'BAD'}  scale={scale}")
        if not (w_ok and b_ok and s_ok):
            all_ok = False
            if wdiff:
                idx = np.argwhere(w_q != w_ref)[:10]
                for i in idx:
                    t = tuple(int(v) for v in i)
                    wf = p["weights"][t]
                    print(f"   w{t}: py={int(w_q[t])} ref={int(w_ref[t])} "
                          f"float={wf!r} scaled={np.float32(wf)*np.float32(W_MULT[cid])!r}")
            if bdiff:
                idx = np.argwhere(b_q != b_ref)[:10]
                for i in idx:
                    t = int(i[0])
                    print(f"   b[{t}]: py={int(b_q[t])} ref={int(b_ref[t])} "
                          f"float={p['biases'][t]!r}")
    print("STEP1:", "ALL LAYERS BYTE-IDENTICAL" if all_ok else "FAILED")
    return 0 if all_ok else 1

if __name__ == "__main__":
    sys.exit(main())
