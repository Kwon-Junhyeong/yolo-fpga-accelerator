import argparse
import re
import sys
from pathlib import Path

import numpy as np

SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_SKELETON_BIN = SCRIPT_DIR / "params"
ROM_DIR = SCRIPT_DIR / "rom"
DEFAULT_GENERATED_DIR = SCRIPT_DIR / "generated"
DEFAULT_RESULTS_DIR = SCRIPT_DIR / "results"

HW_LAYERS = [
    dict(name="L0", layer_id=0, in_ch=4, out_ch=16, height=256, width=256,
         out_h=128, out_w=128, pool=True, rom=True, fill_ch_max=1,
         wet_base=0, bsc_base=0),
    dict(name="L2", layer_id=2, in_ch=16, out_ch=32, height=128, width=128,
         out_h=64, out_w=64, pool=True, rom=True, fill_ch_max=4,
         wet_base=128, bsc_base=16),
    dict(name="L4", layer_id=4, in_ch=32, out_ch=64, height=64, width=64,
         out_h=32, out_w=32, pool=True, rom=True, fill_ch_max=8,
         wet_base=512, bsc_base=48),
    dict(name="L6", layer_id=6, in_ch=64, out_ch=128, height=32, width=32,
         out_h=16, out_w=16, pool=True, rom=False, bsc_base=112),
    dict(name="L8", layer_id=8, in_ch=128, out_ch=256, height=16, width=16,
         out_h=8, out_w=8, pool=True, rom=False, bsc_base=240),
    dict(name="L10", layer_id=10, in_ch=256, out_ch=512, height=8, width=8,
         out_h=8, out_w=8, pool=False, rom=False, bsc_base=496),
    dict(name="L12", layer_id=12, in_ch=512, out_ch=256, height=8, width=8,
         out_h=8, out_w=8, pool=False, rom=False, bsc_base=1008, kernel=1),
    dict(name="L13", layer_id=13, in_ch=256, out_ch=512, height=8, width=8,
         out_h=8, out_w=8, pool=False, rom=False, bsc_base=1264),
    dict(name="L14", layer_id=14, in_ch=512, out_ch=195, height=8, width=8,
         out_h=8, out_w=8, pool=False, rom=False, bsc_base=1776, kernel=1, pad_ch=196,
         linear=True),
    dict(name="L17", layer_id=17, in_ch=256, out_ch=128, height=8, width=8,
         out_h=8, out_w=8, pool=False, rom=False, bsc_base=1971, kernel=1),
    dict(name="L20", layer_id=20, in_ch=384, out_ch=195, height=16, width=16,
         out_h=16, out_w=16, pool=False, rom=False, bsc_base=2099, kernel=1, pad_ch=196,
         linear=True),
]

EXTRA_HW_LAYERS = [
    dict(name="L8RAW"),
    dict(name="L11"),
]

C_REF_LAYERS = [
    ("L0", 16, 128, 128, "CONV02_input.hex"),
    ("L2", 32, 64, 64, "CONV04_input.hex"),
    ("L4", 64, 32, 32, "CONV06_input.hex"),
    ("L6", 128, 16, 16, "CONV08_input.hex"),
    ("L8RAW", 256, 16, 16, "CONV08_output.hex"),
    ("L8", 256, 8, 8, "CONV10_input.hex"),
    ("L10", 512, 8, 8, "CONV10_output.hex"),
    ("L11", 512, 8, 8, "CONV12_input.hex"),
    ("L12", 256, 8, 8, "CONV13_input.hex"),
    ("L13", 512, 8, 8, "CONV14_input.hex"),
    ("L17", 128, 8, 8, "CONV17_output.hex"),
]

WEIGHT_LAYERS = [
    (6, 128, 64),
    (8, 256, 128),
    (10, 512, 256),
    (12, 256, 512),
    (13, 512, 256),
    (14, 195, 512),
    (17, 128, 256),
    (20, 195, 384),
]

def s8(v):
    return v if v < 128 else v - 256

def read_hex_bytes(path):
    vals = []
    with open(path, "r") as f:
        for line_no, line in enumerate(f, 1):
            s = line.strip()
            if not s:
                continue
            if s.lower().startswith("0x"):
                s = s[2:]
            try:
                vals.append(int(s, 16) & 0xFF)
            except ValueError as exc:
                raise ValueError(f"{path}:{line_no}: invalid byte hex {s!r}") from exc
    return vals

def read_hex_words(path):
    vals = []
    with open(path, "r") as f:
        for line_no, line in enumerate(f, 1):
            s = line.strip()
            if not s:
                continue
            try:
                vals.append(int(s, 16))
            except ValueError as exc:
                raise ValueError(f"{path}:{line_no}: invalid word hex {s!r}") from exc
    return vals

def coe_words_to_hex(coe_path, out_path):
    tokens = []
    in_vector = False
    with open(coe_path, "r") as f:
        for line in f:
            s = line.strip()
            if not s:
                continue
            if "memory_initialization_vector" in s:
                in_vector = True
                if "=" in s:
                    s = s.split("=", 1)[1]
                else:
                    continue
            if not in_vector:
                continue
            s = s.replace(",", " ").replace(";", " ")
            for tok in s.split():
                if re.fullmatch(r"[0-9a-fA-F]+", tok):
                    tokens.append(f"{int(tok, 16) & 0xFFFFFFFF:08x}")
    if len(tokens) != 65536:
        raise RuntimeError(f"{coe_path}: expected 65536 32-bit IFM words, got {len(tokens)}")
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text("\n".join(tokens) + "\n")
    return len(tokens)

def conv00_chw_bytes_to_ifm32(conv00_input_path, out_path):
    data = read_hex_bytes(conv00_input_path)
    expected = 3 * 256 * 256
    if len(data) != expected:
        raise RuntimeError(f"{conv00_input_path}: expected {expected} CHW bytes, got {len(data)}")

    plane = 256 * 256
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with open(out_path, "w") as f:
        for pix in range(plane):
            b0 = data[0 * plane + pix]
            b1 = data[1 * plane + pix]
            b2 = data[2 * plane + pix]
            f.write(f"{(b0 | (b1 << 8) | (b2 << 16)):08x}\n")
    return plane

def raw_weight_bytes_to_72bit_words(weights, out_ch, in_ch, out_ch_per_part, kernel_size=3):
    part_words = []
    if kernel_size not in (1, 3):
        raise RuntimeError(f"unsupported kernel_size={kernel_size}")
    filter_size = in_ch * kernel_size * kernel_size

    for part_start in range(0, out_ch, out_ch_per_part):
        words = []
        part_end = min(part_start + out_ch_per_part, out_ch)
        for oc in range(part_start, part_end):
            if kernel_size == 1:
                for ic_base in range(0, in_ch, 16):
                    block = []
                    for ic_off in range(16):
                        block.append(weights[oc * filter_size + ic_base + ic_off])
                    block += [0] * 20
                    for word_idx in range(4):
                        group = block[word_idx * 9:word_idx * 9 + 9]
                        words.append("".join(f"{b:02x}" for b in group[::-1]))
            else:
                for ic in range(in_ch):
                    off = oc * filter_size + ic * 9
                    group = weights[off:off + 9]
                    words.append("".join(f"{b:02x}" for b in group[::-1]))
        if len(words) > 4096:
            raise RuntimeError(
                f"partition starting oc={part_start}: weight buffer holds 4096 72-bit words, got {len(words)}"
            )
        part_words.append(words)

    return part_words

def write_72bit_partitions(out_dir, layer_id, part_words):
    for part_idx, words in enumerate(part_words):
        out_path = out_dir / f"CONV{layer_id:02d}_param_weight_part{part_idx:02d}_4096x72.hex"
        out_path.parent.mkdir(parents=True, exist_ok=True)
        with open(out_path, "w") as f:
            for word in words:
                f.write(word + "\n")

def write_packed24_from_72bit_partitions(out_path, part_words):
    beat_count = 0
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with open(out_path, "w") as f:
        for words in part_words:
            for word in words:
                bytes_lsb_first = [int(word[i:i + 2], 16) for i in range(0, 18, 2)][::-1]
                for idx in range(0, 9, 3):
                    beat = (
                        bytes_lsb_first[idx]
                        | (bytes_lsb_first[idx + 1] << 8)
                        | (bytes_lsb_first[idx + 2] << 16)
                    )
                    f.write(f"{beat:08x}\n")
                    beat_count += 1
    return beat_count

def pack_weight_raw_to_files(raw_path, generated_dir, layer_id, out_ch, in_ch, out_ch_per_part, kernel_size=3):
    weights = read_hex_bytes(raw_path)
    expected = out_ch * in_ch * kernel_size * kernel_size
    if len(weights) != expected:
        raise RuntimeError(f"{raw_path}: expected {expected} weight bytes, got {len(weights)}")

    part_words = raw_weight_bytes_to_72bit_words(weights, out_ch, in_ch, out_ch_per_part, kernel_size)
    write_72bit_partitions(generated_dir, layer_id, part_words)
    beat_path = generated_dir / f"CONV{layer_id:02d}_param_weight_packed24.hex"
    beat_count = write_packed24_from_72bit_partitions(beat_path, part_words)
    return len(part_words), beat_count

def prepare(args):
    skeleton_bin = Path(args.skeleton_bin)
    generated_dir = Path(args.generated_dir)
    log_param = skeleton_bin / "log_param"
    log_feamap = skeleton_bin / "log_feamap"

    input_out = generated_dir / "CONV00_input_32b.hex"
    input_hex = log_feamap / "CONV00_input.hex"
    input_coe = log_feamap / "CONV00_input_RGBA_32bit.coe"
    if input_hex.exists():
        n_ifm = conv00_chw_bytes_to_ifm32(input_hex, input_out)
        print(f"[prepare] {input_out}: {n_ifm} IFM words from {input_hex.name}")
    else:
        n_ifm = coe_words_to_hex(input_coe, input_out)
        print(f"[prepare] {input_out}: {n_ifm} IFM words from {input_coe.name}")

    out_ch_per_part_by_layer = {6: 64, 8: 32, 10: 16, 12: 32, 13: 16, 14: 32, 17: 64, 20: 32}
    kernel_size_by_layer = {6: 3, 8: 3, 10: 3, 12: 1, 13: 3, 14: 1, 17: 1, 20: 1}
    for layer_id, out_ch, in_ch in WEIGHT_LAYERS:
        raw_path = log_param / f"CONV{layer_id:02d}_param_weight.hex"
        n_parts, n_words = pack_weight_raw_to_files(
            raw_path,
            generated_dir,
            layer_id,
            out_ch,
            in_ch,
            out_ch_per_part_by_layer[layer_id],
            kernel_size_by_layer[layer_id],
        )
        out_path = generated_dir / f"CONV{layer_id:02d}_param_weight_packed24.hex"
        print(f"[prepare] CONV{layer_id:02d}: {n_parts} weight partitions")
        print(f"[prepare] {out_path}: {n_words} DMA 24-bit words")

    l4 = compute_hw_outputs(skeleton_bin, generated_dir, stop_name="L4")["L4"]
    l4_words = pack_l2(l4)
    l4_preload = generated_dir / "l2_preload_L4.hex"
    write_plain_hex_words(l4_preload, l4_words)
    print(f"[prepare] {l4_preload}: {len(l4_words)} L2 preload words")

    l11 = compute_hw_outputs(skeleton_bin, generated_dir, stop_name="L10")["L11"]
    l11_words = pack_l2(l11)
    l11_preload = generated_dir / "l2_preload_L11.hex"
    write_plain_hex_words(l11_preload, l11_words)
    print(f"[prepare] {l11_preload}: {len(l11_words)} L2 preload words")

def load_bsc(path):
    bias = []
    shift = []
    for word in read_hex_words(path):
        b = (word >> 16) & 0xFFFF
        if b >= 0x8000:
            b -= 0x10000
        bias.append(b)
        shift.append(word & 0xFFFF)
    return np.array(bias, dtype=np.int64), np.array(shift, dtype=np.int64)

def load_weight_rom(path):
    entries = []
    for line_no, line in enumerate(open(path, "r"), 1):
        s = line.strip()
        if not s:
            continue
        if len(s) != 18:
            raise RuntimeError(f"{path}:{line_no}: expected 18 hex digits, got {len(s)}")
        raw = [int(s[i:i + 2], 16) for i in range(0, 18, 2)]
        entries.append([s8(v) for v in raw[::-1]])
    if len(entries) < 4096:
        raise RuntimeError(f"{path}: expected at least 4096 ROM entries, got {len(entries)}")
    return entries

def rom_weights_to_array(weight_rom, cfg):
    kernels = np.zeros((cfg["out_ch"], cfg["in_ch"], 3, 3), dtype=np.int8)
    for oc in range(cfg["out_ch"]):
        for ch_tile in range(cfg["fill_ch_max"]):
            wet_addr = cfg["wet_base"] + oc * cfg["fill_ch_max"] + ch_tile
            for ic_off in range(4):
                ic = ch_tile * 4 + ic_off
                if ic >= cfg["in_ch"]:
                    continue
                entry = weight_rom[wet_addr * 4 + ic_off]
                for ky in range(3):
                    for kx in range(3):
                        kernels[oc, ic, ky, kx] = entry[ky * 3 + kx]
    return kernels

def raw_weights_to_array(path, out_ch, in_ch, kernel_size=3):
    vals = read_hex_bytes(path)
    expected = out_ch * in_ch * kernel_size * kernel_size
    if len(vals) != expected:
        raise RuntimeError(f"{path}: expected {expected} bytes, got {len(vals)}")
    signed = np.array([s8(v) for v in vals], dtype=np.int8)
    return signed.reshape(out_ch, in_ch, kernel_size, kernel_size)

def load_ifm32(path):
    words = read_hex_words(path)
    if len(words) != 65536:
        raise RuntimeError(f"{path}: expected 65536 words, got {len(words)}")
    x = np.zeros((4, 256, 256), dtype=np.uint8)
    for pix, word in enumerate(words):
        y = pix // 256
        col = pix % 256
        x[0, y, col] = word & 0xFF
        x[1, y, col] = (word >> 8) & 0xFF
        x[2, y, col] = (word >> 16) & 0xFF
        x[3, y, col] = (word >> 24) & 0xFF
    return x

def conv3x3_accum(x, kernels, bias):
    in_ch, height, width = x.shape
    out_ch = kernels.shape[0]
    padded = np.pad(x.astype(np.int64), ((0, 0), (1, 1), (1, 1)), mode="constant")
    y = np.zeros((out_ch, height, width), dtype=np.int64)
    for ky in range(3):
        for kx in range(3):
            y += np.einsum(
                "oi,ihw->ohw",
                kernels[:, :, ky, kx].astype(np.int64),
                padded[:, ky:ky + height, kx:kx + width],
                optimize=True,
            )
    y += bias[:, None, None]
    return y

def relu_shift_u8(y, shift):
    y = np.maximum(y, 0)
    y = y >> shift[:, None, None]
    return np.clip(y, 0, 255).astype(np.uint8)

def conv3x3_hw(x, kernels, bias, shift):
    return relu_shift_u8(conv3x3_accum(x, kernels, bias), shift)

def signed_shift_trunc_np(values, shift):
    mag = np.abs(values)
    return np.where(values < 0, -(mag >> shift), mag >> shift)

def conv1x1_hw(x, kernels, bias, shift, linear=False, head16=False):
    y = np.einsum(
        "oi,ihw->ohw",
        kernels[:, :, 0, 0].astype(np.int64),
        x.astype(np.int64),
        optimize=True,
    )
    y += bias[:, None, None]
    if not linear:
        y = np.maximum(y, 0)
        y = y >> shift[:, None, None]
    else:
        sh = shift[:, None, None]
        if head16:
            sh = np.maximum(sh - 4, 0)
        y = signed_shift_trunc_np(y, sh)
    if linear:
        if head16:
            return np.clip(y, -32768, 32767).astype(np.int16)
        return np.clip(y, -128, 127).astype(np.int16)
    return np.clip(y, 0, 255).astype(np.uint8)

def maxpool2(x):
    return np.maximum.reduce([
        x[:, 0::2, 0::2],
        x[:, 0::2, 1::2],
        x[:, 1::2, 0::2],
        x[:, 1::2, 1::2],
    ])

def maxpool2_stride1_clamp(x):
    channels, height, width = x.shape
    y = np.zeros_like(x)
    for row in range(height):
        row1 = row + 1 if row + 1 < height else row
        for col in range(width):
            col1 = col + 1 if col + 1 < width else col
            y[:, row, col] = np.maximum.reduce([
                x[:, row, col],
                x[:, row, col1],
                x[:, row1, col],
                x[:, row1, col1],
            ])
    return y

def pack_l2(tensor, pad_ch=None, elem_bits=8):
    channels, height, width = tensor.shape
    stored_channels = pad_ch if pad_ch is not None else channels
    groups = (stored_channels + (1 if elem_bits == 16 else 3)) // (2 if elem_bits == 16 else 4)
    words = []
    for y in range(height):
        for x in range(width):
            for group in range(groups):
                if elem_bits == 16:
                    base = group * 2
                    h0 = (int(tensor[base + 0, y, x]) & 0xFFFF) if base + 0 < channels else 0
                    h1 = (int(tensor[base + 1, y, x]) & 0xFFFF) if base + 1 < channels else 0
                    words.append(h0 | (h1 << 16))
                else:
                    base = group * 4
                    b0 = (int(tensor[base + 0, y, x]) & 0xFF) if base + 0 < channels else 0
                    b1 = (int(tensor[base + 1, y, x]) & 0xFF) if base + 1 < channels else 0
                    b2 = (int(tensor[base + 2, y, x]) & 0xFF) if base + 2 < channels else 0
                    b3 = (int(tensor[base + 3, y, x]) & 0xFF) if base + 3 < channels else 0
                    words.append(b0 | (b1 << 8) | (b2 << 16) | (b3 << 24))
    return words

def write_plain_hex_words(path, words):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w") as f:
        for word in words:
            f.write(f"{int(word) & 0xFFFFFFFF:08x}\n")

def compute_hw_outputs(skeleton_bin, generated_dir, stop_name=None, head16=True):
    weight_rom = load_weight_rom(ROM_DIR / "weight_4096x72.hex")
    bias, shift = load_bsc(ROM_DIR / "bias_scale.hex")
    x = load_ifm32(generated_dir / "CONV00_input_32b.hex")
    outputs = {}
    route12 = None

    for cfg in HW_LAYERS:
        if cfg["name"] == "L17":
            if route12 is None:
                raise RuntimeError("L17 needs route12 from L12")
            x = route12
        elif cfg["name"] == "L20":
            if route12 is None or "L17" not in outputs or "L8RAW" not in outputs:
                raise RuntimeError("L20 needs L17 output and route8 raw output")
            up17 = np.repeat(np.repeat(outputs["L17"], 2, axis=1), 2, axis=2)
            x = np.concatenate([up17, outputs["L8RAW"]], axis=0)

        if cfg["rom"]:
            kernels = rom_weights_to_array(weight_rom, cfg)
        else:
            raw_path = skeleton_bin / "log_param" / f"CONV{cfg['layer_id']:02d}_param_weight.hex"
            kernels = raw_weights_to_array(raw_path, cfg["out_ch"], cfg["in_ch"], cfg.get("kernel", 3))

        b0 = cfg["bsc_base"]
        if cfg.get("kernel", 3) == 1:
            conv = conv1x1_hw(
                x,
                kernels,
                bias[b0:b0 + cfg["out_ch"]],
                shift[b0:b0 + cfg["out_ch"]],
                linear=cfg.get("linear", False),
                head16=head16,
            )
        else:
            acc = conv3x3_accum(x, kernels, bias[b0:b0 + cfg["out_ch"]])
            layer_shift = shift[b0:b0 + cfg["out_ch"]]
            conv = relu_shift_u8(acc, layer_shift)
        if cfg["name"] == "L8":
            route_shift = np.maximum(layer_shift - 1, 0)
            outputs["L8RAW"] = relu_shift_u8(acc, route_shift)

        x = maxpool2(conv) if cfg["pool"] else conv
        outputs[cfg["name"]] = x

        if cfg["name"] == "L12":
            route12 = x

        if cfg["name"] == "L10":
            outputs["L11"] = maxpool2_stride1_clamp(x)
            x = outputs["L11"]

        if stop_name is not None and cfg["name"].upper() == stop_name.upper():
            break

    return outputs

def debug_target(args):
    if args.target_layer.upper() != "L20":
        raise RuntimeError("Only L20 target debug is implemented")

    skeleton_bin = Path(args.skeleton_bin)
    generated_dir = Path(args.generated_dir)
    cfg = next(item for item in HW_LAYERS if item["name"] == "L20")
    row = args.row
    col = args.col
    ch = args.channel
    if not (0 <= row < cfg["out_h"] and 0 <= col < cfg["out_w"] and 0 <= ch < cfg["out_ch"]):
        raise RuntimeError(f"target out of range: row={row} col={col} ch={ch}")

    outputs = compute_hw_outputs(skeleton_bin, generated_dir, head16=args.head16)
    up17 = np.repeat(np.repeat(outputs["L17"], 2, axis=1), 2, axis=2)
    l20_ifm = np.concatenate([up17, outputs["L8RAW"]], axis=0)
    kernels = raw_weights_to_array(
        skeleton_bin / "log_param" / "CONV20_param_weight.hex",
        cfg["out_ch"],
        cfg["in_ch"],
        cfg.get("kernel", 1),
    ).astype(np.int64)
    bias, shift = load_bsc(ROM_DIR / "bias_scale.hex")

    bsc_idx = cfg["bsc_base"] + ch
    weight = kernels[ch, :, 0, 0]
    ifm = l20_ifm[:, row, col].astype(np.int64)
    contrib = weight * ifm
    psum = int(np.sum(contrib))
    bias_val = int(bias[bsc_idx])
    shift_val = int(shift[bsc_idx])
    pre_relu = psum + bias_val
    relu = max(pre_relu, 0)
    rnd = (1 << (shift_val - 1)) if shift_val > 0 else 0
    shifted = (relu + rnd) >> shift_val
    final = max(0, min(255, shifted))

    elem_bits = 16 if args.head16 else 8
    lanes_per_word = 2 if args.head16 else 4
    groups = (cfg.get("pad_ch", cfg["out_ch"]) + lanes_per_word - 1) // lanes_per_word
    word_addr = ((row * cfg["out_w"]) + col) * groups + (ch // lanes_per_word)
    lane = ch % lanes_per_word
    packed = pack_l2(outputs["L20"], cfg.get("pad_ch"), elem_bits)
    packed_value = (packed[word_addr] >> (elem_bits * lane)) & ((1 << elem_bits) - 1)

    print(f"[target] layer=L20 row={row} col={col} channel={ch}")
    print(f"  l2_addr={word_addr} lane={lane} elem_bits={elem_bits} packed_value={packed_value}")
    print(f"  raw_dot_product={psum}")
    print(f"  bias={bias_val}")
    print(f"  shift={shift_val} round={rnd}")
    print(f"  pre_relu={pre_relu}")
    print(f"  relu={relu}")
    print(f"  shifted_rounded={shifted}")
    print(f"  final_uint8={final}")

    order = np.argsort(-np.abs(contrib))[:args.topk]
    print(f"  top_contributions={len(order)}")
    for rank, ic in enumerate(order, 1):
        ic = int(ic)
        if ic < 128:
            src = f"L17_up ch={ic} row={row // 2} col={col // 2}"
        else:
            src = f"L8RAW ch={ic - 128} row={row} col={col}"
        print(
            f"    #{rank:02d} ic={ic:03d} ifm={int(ifm[ic]):3d} "
            f"weight={int(weight[ic]):4d} product={int(contrib[ic]):6d} {src}"
        )
    return 0

def write_snapshot(path, words):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w") as f:
        for addr, word in enumerate(words):
            f.write(
                f"addr={addr} val=0x{word:08x} "
                f"b0=0x{word & 0xff:02x} "
                f"b1=0x{(word >> 8) & 0xff:02x} "
                f"b2=0x{(word >> 16) & 0xff:02x} "
                f"b3=0x{(word >> 24) & 0xff:02x}\n"
            )

def parse_rtl_snapshot(path):
    values = {}
    with open(path, "r") as f:
        for line in f:
            m = re.search(r"addr=(\d+)\s+val=0x([0-9a-fA-F]+)", line)
            if m:
                values[int(m.group(1))] = int(m.group(2), 16) & 0xFFFFFFFF
    if not values:
        raise RuntimeError(f"{path}: no snapshot words parsed")
    size = max(values) + 1
    words = [0] * size
    for addr, word in values.items():
        words[addr] = word
    return words

def compare_words(name, golden, rtl):
    ok = True
    if len(golden) != len(rtl):
        print(f"[{name}] SIZE MISMATCH golden_words={len(golden)} rtl_words={len(rtl)}")
        ok = False
    n = min(len(golden), len(rtl))
    word_mismatches = 0
    byte_mismatches = 0
    examples = []

    for addr in range(n):
        gw = int(golden[addr])
        rw = int(rtl[addr])
        if gw != rw:
            word_mismatches += 1
            for byte in range(4):
                gb = (gw >> (8 * byte)) & 0xFF
                rb = (rw >> (8 * byte)) & 0xFF
                if gb != rb:
                    byte_mismatches += 1
                    if len(examples) < 30:
                        examples.append((addr, byte, gb, rb))

    status = "PASS" if ok and word_mismatches == 0 else "FAIL"
    print(
        f"[{name}] {status} words={n} "
        f"word_mismatches={word_mismatches} byte_mismatches={byte_mismatches}"
    )
    for addr, byte, gb, rb in examples:
        print(f"  addr={addr} byte={byte} golden=0x{gb:02x} rtl=0x{rb:02x} diff={gb-rb}")
    return ok and word_mismatches == 0

def selected_layers(args):
    if not args.layers:
        return None
    return set(item.strip().upper() for item in args.layers.split(",") if item.strip())

def compare_hw(args):
    skeleton_bin = Path(args.skeleton_bin)
    generated_dir = Path(args.generated_dir)
    rtl_dir = Path(args.rtl_dir)
    layer_filter = selected_layers(args)
    outputs = compute_hw_outputs(skeleton_bin, generated_dir, head16=args.head16)

    all_ok = True
    compare_layers = HW_LAYERS if layer_filter is None else (HW_LAYERS + EXTRA_HW_LAYERS)
    for cfg in compare_layers:
        name = cfg["name"]
        if layer_filter is not None and name.upper() not in layer_filter:
            continue

        elem_bits = 16 if (args.head16 and cfg.get("linear", False)) else 8
        golden = pack_l2(outputs[name], cfg.get("pad_ch"), elem_bits)
        write_snapshot(generated_dir / f"golden_hw_{name}.txt", golden)
        rtl_path = rtl_dir / f"l2_snapshot_{name}.txt"
        if not rtl_path.exists():
            print(f"[{name}] FAIL missing RTL snapshot: {rtl_path}")
            all_ok = False
            continue
        all_ok = compare_words(name, golden, parse_rtl_snapshot(rtl_path)) and all_ok

    if all_ok:
        print("[compare-hw] PASS: RTL snapshots match hardware-style golden for selected layers.")
    else:
        print("[compare-hw] FAIL: mismatch or missing snapshot.")
    return 0 if all_ok else 1

def feature_to_l2_words(path, channels, height, width, pad_ch=None):
    data = read_hex_bytes(path)
    expected = channels * height * width
    if len(data) != expected:
        raise RuntimeError(f"{path}: expected {expected} feature bytes, got {len(data)}")
    stored_channels = pad_ch if pad_ch is not None else channels
    groups = (stored_channels + 3) // 4
    words = []
    plane = height * width
    for y in range(height):
        for x in range(width):
            pix = y * width + x
            for group in range(groups):
                base_ch = group * 4
                b0 = data[(base_ch + 0) * plane + pix] if base_ch + 0 < channels else 0
                b1 = data[(base_ch + 1) * plane + pix] if base_ch + 1 < channels else 0
                b2 = data[(base_ch + 2) * plane + pix] if base_ch + 2 < channels else 0
                b3 = data[(base_ch + 3) * plane + pix] if base_ch + 3 < channels else 0
                words.append(b0 | (b1 << 8) | (b2 << 16) | (b3 << 24))
    return words

def compare_c_ref(args):
    skeleton_bin = Path(args.skeleton_bin)
    rtl_dir = Path(args.rtl_dir)
    generated_dir = Path(args.generated_dir)
    log_feamap = skeleton_bin / "log_feamap"
    layer_filter = selected_layers(args)
    all_ok = True

    print("[compare-c-ref] NOTE: this is a log_feamap sanity check only.")
    print("[compare-c-ref] NOTE: L14/L20 YOLO heads are excluded; use yolo_board_postprocess.py for final detections.")

    for item in C_REF_LAYERS:
        name, channels, height, width, ref_file = item[:5]
        pad_ch = item[5] if len(item) > 5 else None
        if layer_filter is not None and name.upper() not in layer_filter:
            continue
        golden = feature_to_l2_words(log_feamap / ref_file, channels, height, width, pad_ch)
        write_snapshot(generated_dir / f"golden_c_ref_{name}.txt", golden)
        rtl_path = rtl_dir / f"l2_snapshot_{name}.txt"
        if not rtl_path.exists():
            print(f"[{name}] FAIL missing RTL snapshot: {rtl_path}")
            all_ok = False
            continue
        all_ok = compare_words(name, golden, parse_rtl_snapshot(rtl_path)) and all_ok

    if all_ok:
        print("[compare-c-ref] PASS: RTL snapshots match C log_feamap reference for selected layers.")
    else:
        print("[compare-c-ref] FAIL: mismatch or missing snapshot.")
    return 0 if all_ok else 1

def build_parser():
    parser = argparse.ArgumentParser(description="Prepare RTL structural goldens and run optional C-log sanity checks.")
    parser.add_argument("command", choices=["prepare", "compare-hw", "compare-c-ref", "debug-target"])
    parser.add_argument("--skeleton-bin", default=str(DEFAULT_SKELETON_BIN))
    parser.add_argument("--generated-dir", default=str(DEFAULT_GENERATED_DIR))
    parser.add_argument("--rtl-dir", default=str(DEFAULT_RESULTS_DIR))
    parser.add_argument("--layers", default="", help="Optional comma list, e.g. L0,L2,L4")
    parser.add_argument("--target-layer", default="L20")
    parser.add_argument("--row", type=int, default=4)
    parser.add_argument("--col", type=int, default=3)
    parser.add_argument("--channel", type=int, default=193)
    parser.add_argument("--topk", type=int, default=12)
    parser.add_argument(
        "--head16",
        action="store_true",
        default=True,
        help="Compatibility flag; signed int16 Q4 packing is the fixed L14/L20 contract.",
    )
    return parser

def main():
    args = build_parser().parse_args()
    if args.command == "prepare":
        prepare(args)
        return 0
    if args.command == "compare-hw":
        return compare_hw(args)
    if args.command == "compare-c-ref":
        return compare_c_ref(args)
    if args.command == "debug-target":
        return debug_target(args)
    raise AssertionError(args.command)

if __name__ == "__main__":
    sys.exit(main())
