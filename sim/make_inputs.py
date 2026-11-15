import argparse
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from golden import conv00_chw_bytes_to_ifm32

ap = argparse.ArgumentParser()
ap.add_argument("--exe", type=Path, required=True,
                help="build of the contest C program with the multiplier tables of quant/quantlib.py")
ap.add_argument("--contest-bin", type=Path, default=Path("C:/skeleton/bin"))
ap.add_argument("--stems", type=Path, default=Path(__file__).resolve().parent.parent / "quant" / "stems_229.tsv")
ap.add_argument("--out", type=Path, required=True)
args = ap.parse_args()

args.out.mkdir(parents=True, exist_ok=True)
lines = args.stems.read_text().splitlines()[1:]
rows = []
for line in lines:
    index, image, stem = line.split("\t")
    out_hex = args.out / f"{stem}_CONV00_input_32b.hex"
    if not out_hex.exists():
        subprocess.run([str(args.exe), "detector", "test", "yolohw.names", "aix2024.cfg", "aix2024.weights",
                        "-thresh", "0.24", str(args.contest_bin / "dataset" / image),
                        "-out_filename", "inputs_tmp", "-quantized", "-dont_show"],
                       cwd=str(args.contest_bin), capture_output=True, timeout=300)
        n = conv00_chw_bytes_to_ifm32(args.contest_bin / "log_feamap" / "CONV00_input.hex", out_hex)
        if n != 65536:
            raise SystemExit(f"{stem}: {n} words")
    rows.append(f"{index}\t{image}\t{out_hex.resolve().as_posix()}\t{stem}")

(args.out / "manifest.tsv").write_text("index\timage\tinput\tstem\n" + "\n".join(rows) + "\n")
print(f"{len(rows)} inputs, manifest {args.out / 'manifest.tsv'}")
