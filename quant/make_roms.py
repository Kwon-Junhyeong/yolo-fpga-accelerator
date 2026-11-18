import argparse
from pathlib import Path

STATIC_LAYERS = [
    ("L0", 0, 16, 3, 4, 1, 0),
    ("L2", 2, 32, 16, 16, 4, 128),
    ("L4", 4, 64, 32, 32, 8, 512),
]

BSC_LAYERS = [
    (0, 0, 16), (2, 16, 32), (4, 48, 64), (6, 112, 128), (8, 240, 256),
    (10, 496, 512), (12, 1008, 256), (13, 1264, 512), (14, 1776, 195),
    (17, 1971, 128), (20, 2099, 195),
]

BSC_DEPTH = 2560
ROM72_DEPTH = 4096

def read_hex_lines(path):
    vals = []
    for line in Path(path).read_text().splitlines():
        s = line.strip()
        if s:
            vals.append(int(s, 16))
    return vals

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--skeleton-bin", default="params")
    ap.add_argument("--out", default="rom")
    args = ap.parse_args()
    sk = Path(args.skeleton_bin)
    log_param = sk / "log_param"
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    entries = [[0] * 9 for _ in range(ROM72_DEPTH)]
    for name, lid, out_ch, file_ic, rom_ic, fill_ch_max, wet_base in STATIC_LAYERS:
        w = read_hex_lines(log_param / f"CONV{lid:02d}_param_weight.hex")
        assert len(w) == out_ch * file_ic * 9, f"{name}: weight count {len(w)}"
        fsz = file_ic * 9
        for oc in range(out_ch):
            for ch_tile in range(fill_ch_max):
                wet_addr = wet_base + oc * fill_ch_max + ch_tile
                for ic_off in range(4):
                    ic = ch_tile * 4 + ic_off
                    if ic >= file_ic:
                        continue
                    off = oc * fsz + ic * 9
                    entries[wet_addr * 4 + ic_off] = w[off:off + 9]

    rom72 = out / "weight_4096x72.hex"
    with open(rom72, "w") as f:
        for e in entries:
            f.write("".join(f"{b & 0xFF:02x}" for b in e[::-1]) + "\n")
    print(f"[make_roms] wrote {rom72} ({ROM72_DEPTH} x 72-bit)")

    rom288 = out / "weight_1024x288.hex"
    lines72 = ["".join(f"{b & 0xFF:02x}" for b in e[::-1]) for e in entries]
    with open(rom288, "w") as f:
        for a in range(ROM72_DEPTH // 4):
            f.write(lines72[4 * a + 3] + lines72[4 * a + 2]
                    + lines72[4 * a + 1] + lines72[4 * a + 0] + "\n")
    print(f"[make_roms] wrote {rom288} (1024 x 288-bit)")

    bsc = [0] * BSC_DEPTH
    for lid, base, out_ch in BSC_LAYERS:
        biases = read_hex_lines(log_param / f"CONV{lid:02d}_param_biases.hex")
        scales = read_hex_lines(log_param / f"CONV{lid:02d}_param_scales.hex")
        assert len(biases) >= out_ch and len(scales) >= out_ch, f"CONV{lid:02d}"
        for oc in range(out_ch):
            scale = scales[oc]
            assert scale & (scale - 1) == 0 and scale > 0, \
                f"CONV{lid:02d} ch{oc}: scale 0x{scale:x} not power of two"
            shift = scale.bit_length() - 1
            bsc[base + oc] = ((biases[oc] & 0xFFFF) << 16) | (shift & 0xFFFF)

    bsc_path = out / "bias_scale.hex"
    with open(bsc_path, "w") as f:
        for wword in bsc:
            f.write(f"{wword:08x}\n")
    print(f"[make_roms] wrote {bsc_path} ({BSC_DEPTH} x 32-bit)")

if __name__ == "__main__":
    main()
