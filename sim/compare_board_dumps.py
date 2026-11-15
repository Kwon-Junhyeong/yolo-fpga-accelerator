import argparse
import re
import zipfile
from pathlib import Path

val_re = re.compile(rb"val=0x([0-9a-fA-F]{8})")


def board_words(data):
    return [m.group(1).lower() for m in val_re.finditer(data)]


def ref_words(path):
    return [w.lower().encode() for w in path.read_text().split()]


def board_files(src):
    if src.is_dir():
        return {p.name: p.read_bytes for p in src.glob("*_L*.txt")}
    z = zipfile.ZipFile(src)
    return {Path(n).name: (lambda n=n: z.read(n)) for n in z.namelist() if n.endswith(".txt")}


ap = argparse.ArgumentParser()
ap.add_argument("board", type=Path, help="zip or folder of board dumps (*_L14.txt, *_L20.txt)")
ap.add_argument("reference", type=Path, help="folder of reference tensors from quant/hw_pipeline.py")
ap.add_argument("--present-only", action="store_true",
                help="compare only the reference files that the board set contains")
args = ap.parse_args()

names = board_files(args.board)
refs = sorted(args.reference.glob("*_L14.txt")) + sorted(args.reference.glob("*_L20.txt"))
if args.present_only:
    refs = [r for r in refs if r.name in names]
print(f"board_files={len(names)} reference_files={len(refs)}")
bad = missing = words = 0
for rf in refs:
    if rf.name not in names:
        missing += 1
        print(f"MISSING {rf.name}")
        continue
    a = board_words(names[rf.name]())
    b = ref_words(rf)
    words += len(b)
    if a != b:
        bad += 1
        print(f"MISMATCH {rf.name} board={len(a)} ref={len(b)}")
print(f"files={len(refs)} missing={missing} mismatch={bad} words_compared={words}")
