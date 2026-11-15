#!/usr/bin/env python3
"""Reference-style final YOLO decoder for board head outputs.

This script is intentionally outside the RTL structural checker. It assumes the
board has already produced L14/L20 tensors under the agreed output contract and
only applies the reference YOLO interpretation: sigmoid, bbox decode,
thresholding, and NMS.
"""

import argparse
import math
import re
from dataclasses import dataclass
from pathlib import Path


@dataclass
class Detection:
    layer: str
    row: int
    col: int
    anchor: int
    cls: int
    prob: float
    objectness: float
    x: float
    y: float
    w: float
    h: float


def sigmoid(x):
    return 1.0 / (1.0 + math.exp(-x))


def i8(value):
    value &= 0xFF
    return value - 256 if value >= 128 else value


def read_names(path):
    return [line.strip() for line in Path(path).read_text().splitlines() if line.strip()]


def parse_cfg(path):
    net_w = net_h = None
    yolo = []
    section = None
    fields = {}

    def flush():
        nonlocal net_w, net_h, fields, section
        if section == "net":
            net_w = int(fields.get("width", net_w or 0))
            net_h = int(fields.get("height", net_h or 0))
        elif section == "yolo":
            anchors = [float(x) for x in re.split(r"\s*,\s*|\s+", fields["anchors"].strip()) if x]
            mask = [int(x) for x in re.split(r"\s*,\s*|\s+", fields["mask"].strip()) if x]
            yolo.append({
                "mask": mask,
                "anchors": anchors,
                "classes": int(fields["classes"]),
                "n": len(mask),
            })
        fields = {}

    for raw in Path(path).read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            flush()
            section = line[1:-1].strip()
            continue
        if "=" in line:
            key, value = line.split("=", 1)
            fields[key.strip()] = value.split("#", 1)[0].strip()
    flush()
    if net_w is None or net_h is None or len(yolo) < 2:
        raise RuntimeError(f"{path}: failed to parse net/yolo layers")
    return net_w, net_h, yolo


def parse_snapshot_words(path):
    words = []
    for line in Path(path).read_text().splitlines():
        m = re.search(r"val=0x([0-9a-fA-F]+)", line)
        if m:
            words.append(int(m.group(1), 16) & 0xFFFFFFFF)
            continue
        s = line.strip()
        if s:
            words.append(int(s, 16) & 0xFFFFFFFF)
    if not words:
        raise RuntimeError(f"{path}: no words found")
    return words


def tensor_from_l2_snapshot(path, channels, pad_channels, height, width):
    words = parse_snapshot_words(path)
    groups = (pad_channels + 3) // 4
    expected = height * width * groups
    if len(words) != expected:
        raise RuntimeError(f"{path}: expected {expected} words, got {len(words)}")
    plane = height * width
    data = [0] * (channels * plane)
    idx = 0
    for y in range(height):
        for x in range(width):
            pix = y * width + x
            for group in range(groups):
                word = words[idx]
                idx += 1
                for lane in range(4):
                    ch = group * 4 + lane
                    if ch < channels:
                        data[ch * plane + pix] = (word >> (8 * lane)) & 0xFF
    return data


def s16(value):
    value &= 0xFFFF
    return value - 65536 if value >= 32768 else value


def s32(value):
    value &= 0xFFFFFFFF
    return value - 0x100000000 if value >= 0x80000000 else value


def tensor_from_l2_snapshot_int16_q4(path, channels, pad_channels, height, width, next_input_mult):
    words = parse_snapshot_words(path)
    groups = (pad_channels + 1) // 2
    expected = height * width * groups
    if len(words) != expected:
        raise RuntimeError(f"{path}: expected {expected} words, got {len(words)}")
    plane = height * width
    data = [0.0] * (channels * plane)
    idx = 0
    denom = float(next_input_mult * 16)
    for y in range(height):
        for x in range(width):
            pix = y * width + x
            for group in range(groups):
                word = words[idx]
                idx += 1
                for lane in range(2):
                    ch = group * 2 + lane
                    if ch < channels:
                        raw = s16((word >> (16 * lane)) & 0xFFFF)
                        data[ch * plane + pix] = raw / denom
    return data


def tensor_from_l2_snapshot_int32_partitioned(path, channels, height, width, partition_channels, denom):
    words = parse_snapshot_words(path)
    plane = height * width
    expected = channels * plane
    if len(words) != expected:
        raise RuntimeError(f"{path}: expected {expected} words, got {len(words)}")
    data = [0.0] * (channels * plane)
    idx = 0
    ch_start = 0
    while ch_start < channels:
        count = min(partition_channels, channels - ch_start)
        for pix in range(plane):
            for local in range(count):
                raw = s32(words[idx])
                idx += 1
                data[(ch_start + local) * plane + pix] = raw / float(denom)
        ch_start += partition_channels
    return data


def tensor_from_c_hex(path, channels, height, width):
    values = []
    for line in Path(path).read_text().splitlines():
        s = line.strip()
        if s:
            values.append(int(s, 16) & 0xFF)
    expected = channels * height * width
    if len(values) != expected:
        raise RuntimeError(f"{path}: expected {expected} bytes, got {len(values)}")
    return values


def tensor_from_float_txt(path, channels, height, width):
    values = []
    for line in Path(path).read_text().splitlines():
        s = line.strip()
        if s:
            values.append(float(s))
    expected = channels * height * width
    if len(values) != expected:
        raise RuntimeError(f"{path}: expected {expected} floats, got {len(values)}")
    return values


def yolo_forward(input_u8, width, height, n, classes, signed_bytes=True):
    plane = width * height
    entries = classes + 5
    out = [float(i8(v)) if signed_bytes else float(v) for v in input_u8]
    for anchor in range(n):
        base = anchor * entries * plane
        for entry in (0, 1):
            off = base + entry * plane
            for i in range(plane):
                out[off + i] = sigmoid(out[off + i])
        off = base + 4 * plane
        for i in range((1 + classes) * plane):
            out[off + i] = sigmoid(out[off + i])
    return out


def bbox_iou(a, b):
    ax1, ay1 = a.x - a.w / 2, a.y - a.h / 2
    ax2, ay2 = a.x + a.w / 2, a.y + a.h / 2
    bx1, by1 = b.x - b.w / 2, b.y - b.h / 2
    bx2, by2 = b.x + b.w / 2, b.y + b.h / 2
    iw = max(0.0, min(ax2, bx2) - max(ax1, bx1))
    ih = max(0.0, min(ay2, by2) - max(ay1, by1))
    inter = iw * ih
    union = a.w * a.h + b.w * b.h - inter
    return inter / union if union > 0 else 0.0


def decode_layer(layer_name, input_u8, width, height, yolo_cfg, net_w, net_h, thresh, signed_bytes=True):
    classes = yolo_cfg["classes"]
    masks = yolo_cfg["mask"]
    anchors = yolo_cfg["anchors"]
    n = yolo_cfg["n"]
    entries = classes + 5
    plane = width * height
    out = yolo_forward(input_u8, width, height, n, classes, signed_bytes=signed_bytes)
    dets = []
    for pix in range(plane):
        row, col = divmod(pix, width)
        for a in range(n):
            base = a * entries * plane
            objectness = out[base + 4 * plane + pix]
            if objectness <= thresh:
                continue
            box_x = (col + out[base + 0 * plane + pix]) / width
            box_y = (row + out[base + 1 * plane + pix]) / height
            raw_w = out[base + 2 * plane + pix]
            raw_h = out[base + 3 * plane + pix]
            mask_idx = masks[a]
            box_w = math.exp(raw_w) * anchors[2 * mask_idx] / net_w
            box_h = math.exp(raw_h) * anchors[2 * mask_idx + 1] / net_h
            for cls in range(classes):
                cls_prob = out[base + (5 + cls) * plane + pix]
                prob = objectness * cls_prob
                if prob > thresh:
                    dets.append(Detection(layer_name, row, col, mask_idx, cls, prob, objectness,
                                          box_x, box_y, box_w, box_h))
    return dets


def apply_nms(dets, classes, nms_thresh):
    keep_prob = [d.prob for d in dets]
    for cls in range(classes):
        order = sorted(
            [i for i, d in enumerate(dets) if d.cls == cls and keep_prob[i] > 0],
            key=lambda i: keep_prob[i],
            reverse=True,
        )
        for pos, i in enumerate(order):
            if keep_prob[i] == 0:
                continue
            for j in order[pos + 1:]:
                if keep_prob[j] and bbox_iou(dets[i], dets[j]) > nms_thresh:
                    keep_prob[j] = 0.0
    kept = []
    for d, p in zip(dets, keep_prob):
        if p > 0:
            d.prob = p
            kept.append(d)
    return sorted(kept, key=lambda d: d.prob, reverse=True)


def write_report(path, dets, names, img_w, img_h):
    lines = []
    for idx, d in enumerate(dets):
        left = round((d.x - d.w / 2) * img_w)
        top = round((d.y - d.h / 2) * img_h)
        w = round(d.w * img_w)
        h = round(d.h * img_h)
        label = names[d.cls] if d.cls < len(names) else f"class_{d.cls}"
        lines.append(
            f"{idx:02d} {label} prob={d.prob:.4f} obj={d.objectness:.4f} "
            f"box=({left},{top},{w},{h}) layer={d.layer} cell=({d.row},{d.col}) anchor={d.anchor}"
        )
    Path(path).write_text("\n".join(lines) + ("\n" if lines else ""))


def draw_image(image_path, out_path, dets, names):
    from PIL import Image, ImageDraw
    im = Image.open(image_path).convert("RGB")
    draw = ImageDraw.Draw(im)
    img_w, img_h = im.size
    for d in dets:
        left = int(round((d.x - d.w / 2) * img_w))
        top = int(round((d.y - d.h / 2) * img_h))
        right = int(round((d.x + d.w / 2) * img_w))
        bottom = int(round((d.y + d.h / 2) * img_h))
        label = names[d.cls] if d.cls < len(names) else f"class_{d.cls}"
        text = f"{label} {d.prob * 100:.0f}%"
        draw.rectangle([left, top, right, bottom], outline=(255, 64, 64), width=3)
        box = draw.textbbox((left, top), text)
        draw.rectangle([box[0], box[1], box[2] + 4, box[3] + 2], fill=(255, 64, 64))
        draw.text((left + 2, top), text, fill=(255, 255, 255))
    im.save(out_path)


def run_decode(args):
    net_w, net_h, yolo = parse_cfg(args.cfg)
    names = read_names(args.names)
    if args.mode == "snapshot":
        l14 = tensor_from_l2_snapshot(args.l14, 195, 196, 8, 8)
        l20 = tensor_from_l2_snapshot(args.l20, 195, 196, 16, 16)
        signed_bytes = True
    elif args.mode == "snapshot-int16-q4":
        l14 = tensor_from_l2_snapshot_int16_q4(args.l14, 195, 196, 8, 8, args.l14_next_input_mult)
        l20 = tensor_from_l2_snapshot_int16_q4(args.l20, 195, 196, 16, 16, args.l20_next_input_mult)
        signed_bytes = False
    elif args.mode == "snapshot-int32-partition":
        l14 = tensor_from_l2_snapshot_int32_partitioned(args.l14, 195, 8, 8, 32, 8192)
        l20 = tensor_from_l2_snapshot_int32_partitioned(args.l20, 195, 16, 16, 32, 4096)
        signed_bytes = False
    elif args.mode == "c-ref":
        l14 = tensor_from_c_hex(args.c_l14, 195, 8, 8)
        l20 = tensor_from_c_hex(args.c_l20, 195, 16, 16)
        signed_bytes = True
    else:
        l14 = tensor_from_float_txt(args.c_float_l14, 195, 8, 8)
        l20 = tensor_from_float_txt(args.c_float_l20, 195, 16, 16)
        signed_bytes = False
    dets = []
    dets.extend(decode_layer("L14", l14, 8, 8, yolo[0], net_w, net_h, args.thresh, signed_bytes=signed_bytes))
    dets.extend(decode_layer("L20", l20, 16, 16, yolo[1], net_w, net_h, args.thresh, signed_bytes=signed_bytes))
    dets = apply_nms(dets, yolo[0]["classes"], args.nms)

    from PIL import Image
    img_w, img_h = Image.open(args.image).size
    write_report(args.report, dets, names, img_w, img_h)
    if args.out_image:
        draw_image(args.image, args.out_image, dets, names)
    print(f"[postprocess] mode={args.mode} detections={len(dets)} report={args.report}")
    for line in Path(args.report).read_text().splitlines()[: args.print_limit]:
        print(line)


def main():
    parser = argparse.ArgumentParser(
        description="Decode final L14/L20 YOLO head tensors into detections"
    )
    parser.add_argument("--mode", choices=["snapshot", "snapshot-int16-q4", "snapshot-int32-partition", "c-ref", "c-float"], default="snapshot")
    parser.add_argument("--l14", type=Path, default=Path("verification/l0_to_l11/results/board_compare_run2/l2_snapshot_L14.txt"))
    parser.add_argument("--l20", type=Path, default=Path("verification/l0_to_l11/results/board_compare_run2/l2_snapshot_L20.txt"))
    parser.add_argument("--c-l14", type=Path, default=Path("C:/skeleton/bin/log_feamap/CONV14_output.hex"))
    parser.add_argument("--c-l20", type=Path, default=Path("C:/skeleton/bin/log_feamap/CONV20_output.hex"))
    parser.add_argument("--c-float-l14", type=Path, default=Path("C:/skeleton/bin/log_feamap/CONV14_pre_yolo_float.txt"))
    parser.add_argument("--c-float-l20", type=Path, default=Path("C:/skeleton/bin/log_feamap/CONV20_pre_yolo_float.txt"))
    parser.add_argument("--l14-next-input-mult", type=int, default=64)
    parser.add_argument("--l20-next-input-mult", type=int, default=1)
    parser.add_argument("--cfg", type=Path, default=Path("C:/skeleton/bin/aix2024.cfg"))
    parser.add_argument("--names", type=Path, default=Path("C:/skeleton/bin/yolohw.names"))
    parser.add_argument("--image", type=Path, default=Path("C:/skeleton/bin/test01.jpg"))
    parser.add_argument("--report", type=Path, default=Path("verification/l0_to_l11/results/board_yolo_detections.txt"))
    parser.add_argument("--out-image", type=Path, default=Path("verification/l0_to_l11/results/board_yolo_detections.png"))
    parser.add_argument("--thresh", type=float, default=0.24)
    parser.add_argument("--nms", type=float, default=0.2)
    parser.add_argument("--print-limit", type=int, default=20)
    args = parser.parse_args()
    run_decode(args)


if __name__ == "__main__":
    main()
