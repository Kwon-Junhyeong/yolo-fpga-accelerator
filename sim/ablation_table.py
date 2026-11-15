"""Table of frame cycles and time per layer from the logs of run_variant.ps1.

The time of a layer runs from the previous layer switch to its PERF line (sim/tb_frame.v prints $time in ps when
layer_id leaves the layer); L10 includes the stride-1 pooling L11. The frame starts inference_cycles x 10 ns before
the CSR_LATCH line.
usage: python ablation_table.py <name>=<log> [<name>=<log> ...] > ablation.txt
"""
import re
import sys

LAYERS = [0, 2, 4, 6, 8, 10, 12, 13, 14, 17, 20]
print("config\tcycles\tbit_exact\t" + "\t".join(f"L{l}_ms" for l in LAYERS))
for arg in sys.argv[1:]:
    name, path = arg.split("=", 1)
    text = open(path, encoding="utf-8", errors="replace").read().replace("\x00", "")
    perf = [(int(l), int(t)) for t, l in re.findall(r"\[(\d+)\] PERF L(\d+):", text)]
    m = re.search(r"\[(\d+)\] CSR_LATCH: inference_cycles=(\d+)", text)
    end_ps, cycles = int(m.group(1)), int(m.group(2))
    t = end_ps - cycles * 10_000
    ms = {}
    for layer, ps in perf:
        ms[layer] = (ps - t) / 1e9
        t = ps
    ok = "[compare-hw] PASS" in text and "[check-heads] PASS" in text and "FAIL" not in text
    print(f"{name}\t{cycles}\t{'yes' if ok else 'no'}\t" + "\t".join(f"{ms[l]:.4f}" for l in LAYERS))
