"""Score the output tensors of the NumPy model as 32-bit and as 16-bit values with the Python scorer.

The 16-bit version is what the RTL wrote before the 32-bit output path: the 32-bit sum is shifted right
(truncating toward zero) to a Q4 value and clamped to 16 bits. L14 keeps 1/1024 and L20 1/16 of a unit.
usage: python eval_heads.py --reference reference --dataset <contest bin>/dataset --out <dir>
"""
import argparse
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "pyscore"))
import board_map_tools as B  # noqa: E402
import yolo_board_postprocess as Y  # noqa: E402

HEADS = {"L14": (8, 8, 8192, 3, 64), "L20": (16, 16, 4096, 8, 1)}


def trunc_shift(v, s):
    return -((-v) >> s) if v < 0 else v >> s


def to_int16_q4_file(src, dst, h, w, shift):
    raw = Y.tensor_from_l2_snapshot_int32_partitioned(src, 195, h, w, 32, 1)
    plane = h * w
    words = []
    for pix in range(plane):
        for g in range(98):
            pair = []
            for lane in range(2):
                ch = 2 * g + lane
                v = trunc_shift(int(raw[ch * plane + pix]), shift) if ch < 195 else 0
                v = max(-32768, min(32767, v))
                pair.append(v & 0xFFFF)
            words.append(pair[0] | (pair[1] << 16))
    dst.write_text("\n".join(f"{x:08x}" for x in words) + "\n")


ap = argparse.ArgumentParser()
ap.add_argument("--reference", type=Path, required=True)
ap.add_argument("--stems", type=Path, default=HERE / "stems_229.tsv")
ap.add_argument("--dataset", type=Path, required=True)
ap.add_argument("--cfg", type=Path, default=None)
ap.add_argument("--names", type=Path, default=None)
ap.add_argument("--out", type=Path, required=True)
args = ap.parse_args()
cfg = args.cfg or args.dataset.parent / "aix2024.cfg"
names = args.names or args.dataset.parent / "yolohw.names"

args.out.mkdir(parents=True, exist_ok=True)
rows = [l.split("\t") for l in args.stems.read_text().splitlines()[1:]]
manifest = args.out / "manifest.tsv"
manifest.write_text("index\timage\tinput\tstem\n" +
                    "".join(f"{i}\t{(args.dataset / img).as_posix()}\t\t{stem}\n" for i, img, stem in rows))

q4 = args.out / "int16_q4"
q4.mkdir(exist_ok=True)
for _, _, stem in rows:
    for name, (h, w, _denom, shift, _mult) in HEADS.items():
        dst = q4 / f"{stem}_{name}.txt"
        if not dst.exists():
            to_int16_q4_file(args.reference / f"{stem}_{name}.txt", dst, h, w, shift)

for mode, snap in (("int32-partition", args.reference), ("int16-q4", q4)):
    ns = argparse.Namespace(manifest=manifest, snapshot_dir=snap, report=args.out / f"map_{mode}.txt",
                            cfg=cfg, names=names, ap_thresh=0.005, score_thresh=0.24, nms=0.45,
                            iou_thresh=0.5, snapshot_mode=mode, start=0, limit=None)
    B.evaluate(ns)
