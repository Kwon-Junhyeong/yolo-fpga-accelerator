#!/usr/bin/env python3
"""Helpers for board-side validation mAP runs.

The board runner consumes prepacked CONV00_input_32b.hex files and emits L14/L20
snapshots.  This script creates those input files with the same resize and
uint8 input quantization used by the reference C, then evaluates dumped
snapshots with the same 11-point AP style used by validate_detector_map().
"""

import argparse
import csv
import math
import subprocess
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PIL import Image

import yolo_board_postprocess as yolo


@dataclass
class Box:
    x: float
    y: float
    w: float
    h: float


@dataclass
class BoxProb:
    box: Box
    prob: float
    cls: int
    image_index: int
    truth_flag: int
    unique_truth_index: int


def read_manifest(path):
    rows = []
    with Path(path).open(newline="") as f:
        reader = csv.DictReader(f, delimiter="\t")
        for row in reader:
            rows.append(row)
    return rows


def darknet_resize_rgb(image_path, width=256, height=256):
    src = np.asarray(Image.open(image_path).convert("RGB"), dtype=np.float32) / np.float32(255.0)
    src_h, src_w, channels = src.shape
    part = np.zeros((src_h, width, channels), dtype=np.float32)
    resized = np.zeros((height, width, channels), dtype=np.float32)

    w_scale = np.float32(src_w - 1) / np.float32(width - 1)
    h_scale = np.float32(src_h - 1) / np.float32(height - 1)

    for c in range(width):
        if c == width - 1 or src_w == 1:
            part[:, c, :] = src[:, src_w - 1, :]
        else:
            sx = np.float32(c) * w_scale
            ix = int(sx)
            dx = np.float32(sx - np.float32(ix))
            part[:, c, :] = (np.float32(1.0) - dx) * src[:, ix, :] + dx * src[:, ix + 1, :]

    for r in range(height):
        sy = np.float32(r) * h_scale
        iy = int(sy)
        dy = np.float32(sy - np.float32(iy))
        resized[r, :, :] = (np.float32(1.0) - dy) * part[iy, :, :]
        if r != height - 1 and src_h != 1:
            resized[r, :, :] += dy * part[iy + 1, :, :]

    return resized


def image_to_ifm32_words(image_path):
    resized = darknet_resize_rgb(image_path)
    chw = np.transpose(resized, (2, 0, 1))
    q = np.floor(chw * np.float32(256.0)).clip(0, 255).astype(np.uint8)
    words = []
    plane = 256 * 256
    flat = q.reshape(3, plane)
    for pix in range(plane):
        word = int(flat[0, pix]) | (int(flat[1, pix]) << 8) | (int(flat[2, pix]) << 16)
        words.append(word)
    return words


def write_hex_words(path, words):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w") as f:
        for word in words:
            f.write(f"{word & 0xFFFFFFFF:08x}\n")


def read_chw_hex_bytes(path):
    values = []
    for line in Path(path).read_text().splitlines():
        s = line.strip()
        if s:
            values.append(int(s, 16) & 0xFF)
    return values


def conv00_chw_file_to_ifm32_words(path):
    data = read_chw_hex_bytes(path)
    expected = 3 * 256 * 256
    if len(data) != expected:
        raise RuntimeError(f"{path}: expected {expected} CHW bytes, got {len(data)}")
    plane = 256 * 256
    words = []
    for pix in range(plane):
        words.append(data[pix] | (data[plane + pix] << 8) | (data[2 * plane + pix] << 16))
    return words


def make_inputs(args):
    image_list = [line.strip() for line in Path(args.image_list).read_text().splitlines() if line.strip()]
    if args.limit is not None:
        image_list = image_list[args.start:args.start + args.limit]
    else:
        image_list = image_list[args.start:]

    out_dir = Path(args.out_dir)
    input_dir = out_dir / "inputs"
    rows = []
    for idx, image in enumerate(image_list):
        image_path = Path(image)
        stem = image_path.stem
        input_path = input_dir / f"{idx:04d}_{stem}_CONV00_input_32b.hex"
        write_hex_words(input_path, image_to_ifm32_words(image_path))
        rows.append({
            "index": str(idx),
            "image": image_path.as_posix(),
            "input": input_path.resolve().as_posix(),
            "stem": f"{idx:04d}_{stem}",
        })
        if (idx + 1) % 10 == 0 or idx + 1 == len(image_list):
            print(f"[make-inputs] {idx + 1}/{len(image_list)}")

    manifest = out_dir / "manifest.tsv"
    out_dir.mkdir(parents=True, exist_ok=True)
    with manifest.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=["index", "image", "input", "stem"], delimiter="\t")
        writer.writeheader()
        writer.writerows(rows)
    print(f"[make-inputs] wrote {manifest} rows={len(rows)}")


def make_inputs_c(args):
    image_list = [line.strip() for line in Path(args.image_list).read_text().splitlines() if line.strip()]
    if args.limit is not None:
        image_list = image_list[args.start:args.start + args.limit]
    else:
        image_list = image_list[args.start:]

    out_dir = Path(args.out_dir)
    input_dir = out_dir / "inputs"
    log_dir = out_dir / "c_preprocess_logs"
    input_dir.mkdir(parents=True, exist_ok=True)
    log_dir.mkdir(parents=True, exist_ok=True)

    skeleton_bin = Path(args.skeleton_bin)
    rows = []
    for idx, image in enumerate(image_list):
        image_path = Path(image)
        stem = f"{idx:04d}_{image_path.stem}"
        out_name = f"yolo_preprocess_{stem}"
        cmd = [
            str(skeleton_bin / "yolo_cpu.exe"),
            "detector", "test",
            "yolohw.names", "aix2024.cfg", "aix2024.weights",
            "-thresh", "0.24",
            str(image_path),
            "-out_filename", out_name,
            "-quantized",
            "-dont_show",
        ]
        proc = subprocess.run(
            cmd,
            cwd=skeleton_bin,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        (log_dir / f"{stem}.log").write_text(proc.stdout)
        if proc.returncode != 0:
            raise RuntimeError(f"C preprocess failed for {image_path}; see {log_dir / (stem + '.log')}")

        png = skeleton_bin / f"{out_name}.png"
        if png.exists():
            png.unlink()

        input_path = input_dir / f"{stem}_CONV00_input_32b.hex"
        write_hex_words(input_path, conv00_chw_file_to_ifm32_words(skeleton_bin / "log_feamap" / "CONV00_input.hex"))
        rows.append({
            "index": str(idx),
            "image": image_path.as_posix(),
            "input": input_path.resolve().as_posix(),
            "stem": stem,
        })
        if (idx + 1) % 10 == 0 or idx + 1 == len(image_list):
            print(f"[make-inputs-c] {idx + 1}/{len(image_list)}")

    manifest = out_dir / "manifest.tsv"
    with manifest.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=["index", "image", "input", "stem"], delimiter="\t")
        writer.writeheader()
        writer.writerows(rows)
    print(f"[make-inputs-c] wrote {manifest} rows={len(rows)}")


def parse_truth_label(path):
    labels = []
    for line in Path(path).read_text().splitlines():
        parts = line.strip().split()
        if len(parts) < 5:
            continue
        labels.append((int(parts[0]), Box(*(float(x) for x in parts[1:5]))))
    return labels


def box_iou(a, b):
    ax1, ay1 = a.x - a.w / 2.0, a.y - a.h / 2.0
    ax2, ay2 = a.x + a.w / 2.0, a.y + a.h / 2.0
    bx1, by1 = b.x - b.w / 2.0, b.y - b.h / 2.0
    bx2, by2 = b.x + b.w / 2.0, b.y + b.h / 2.0
    iw = min(ax2, bx2) - max(ax1, bx1)
    ih = min(ay2, by2) - max(ay1, by1)
    if iw < 0 or ih < 0:
        return 0.0
    inter = iw * ih
    union = a.w * a.h + b.w * b.h - inter
    return inter / union if union > 0 else 0.0


def decode_snapshot_pair(l14_path, l20_path, cfg_path, thresh, nms, snapshot_mode):
    net_w, net_h, yolo_cfg = yolo.parse_cfg(cfg_path)
    if snapshot_mode == "int16-q4":
        l14 = yolo.tensor_from_l2_snapshot_int16_q4(l14_path, 195, 196, 8, 8, 64)
        l20 = yolo.tensor_from_l2_snapshot_int16_q4(l20_path, 195, 196, 16, 16, 1)
        signed_bytes = False
    elif snapshot_mode == "int32-partition":
        l14 = yolo.tensor_from_l2_snapshot_int32_partitioned(l14_path, 195, 8, 8, 32, 8192)
        l20 = yolo.tensor_from_l2_snapshot_int32_partitioned(l20_path, 195, 16, 16, 32, 4096)
        signed_bytes = False
    else:
        raise RuntimeError(f"unsupported snapshot mode: {snapshot_mode}")
    dets = []
    dets.extend(yolo.decode_layer("L14", l14, 8, 8, yolo_cfg[0], net_w, net_h, thresh, signed_bytes=signed_bytes))
    dets.extend(yolo.decode_layer("L20", l20, 16, 16, yolo_cfg[1], net_w, net_h, thresh, signed_bytes=signed_bytes))
    return yolo.apply_nms(dets, yolo_cfg[0]["classes"], nms), yolo_cfg[0]["classes"]


def evaluate(args):
    rows = read_manifest(args.manifest)
    if args.limit is not None:
        rows = rows[args.start:args.start + args.limit]
    else:
        rows = rows[args.start:]
    names = yolo.read_names(args.names)
    classes = len(names)
    detections = []
    unique_truth_count = 0
    truth_classes_count = [0] * classes
    avg_iou = 0.0
    tp_for_thresh = 0
    fp_for_thresh = 0

    snapshot_dir = Path(args.snapshot_dir)
    for image_index, row in enumerate(rows):
        stem = row["stem"]
        l14 = snapshot_dir / f"{stem}_L14.txt"
        l20 = snapshot_dir / f"{stem}_L20.txt"
        dets, cfg_classes = decode_snapshot_pair(l14, l20, args.cfg, args.ap_thresh, args.nms, args.snapshot_mode)
        if cfg_classes != classes:
            raise RuntimeError(f"class count mismatch cfg={cfg_classes} names={classes}")

        label_path = Path(row["image"]).with_suffix(".txt")
        truth = parse_truth_label(label_path)
        for cls, _ in truth:
            truth_classes_count[cls] += 1

        checkpoint = len(detections)
        for det in dets:
            box = Box(det.x, det.y, det.w, det.h)
            truth_index = -1
            max_iou = 0.0
            for j, (truth_cls, truth_box) in enumerate(truth):
                current_iou = box_iou(box, truth_box)
                if current_iou > args.iou_thresh and det.cls == truth_cls and current_iou > max_iou:
                    max_iou = current_iou
                    truth_index = unique_truth_count + j

            detections.append(BoxProb(box, det.prob, det.cls, image_index, 1 if truth_index > -1 else 0, truth_index))
            if det.prob > args.score_thresh:
                found = any(d.unique_truth_index == truth_index for d in detections[checkpoint:-1])
                if truth_index > -1 and not found:
                    avg_iou += max_iou
                    tp_for_thresh += 1
                else:
                    fp_for_thresh += 1

        unique_truth_count += len(truth)
        if (image_index + 1) % 10 == 0 or image_index + 1 == len(rows):
            print(f"[eval-map] decoded {image_index + 1}/{len(rows)} detections={len(detections)}")

    if tp_for_thresh + fp_for_thresh > 0:
        avg_iou /= (tp_for_thresh + fp_for_thresh)

    detections.sort(key=lambda d: d.prob, reverse=True)
    pr = [[{"tp": 0, "fp": 0, "fn": 0, "precision": 0.0, "recall": 0.0} for _ in detections] for _ in range(classes)]
    truth_flags = [0] * unique_truth_count

    for rank, det in enumerate(detections):
        if rank > 0:
            for cls in range(classes):
                pr[cls][rank]["tp"] = pr[cls][rank - 1]["tp"]
                pr[cls][rank]["fp"] = pr[cls][rank - 1]["fp"]
        if det.truth_flag == 1 and truth_flags[det.unique_truth_index] == 0:
            truth_flags[det.unique_truth_index] = 1
            pr[det.cls][rank]["tp"] += 1
        else:
            pr[det.cls][rank]["fp"] += 1

        for cls in range(classes):
            tp = pr[cls][rank]["tp"]
            fp = pr[cls][rank]["fp"]
            fn = truth_classes_count[cls] - tp
            pr[cls][rank]["fn"] = fn
            pr[cls][rank]["precision"] = tp / (tp + fp) if (tp + fp) > 0 else 0.0
            pr[cls][rank]["recall"] = tp / (tp + fn) if (tp + fn) > 0 else 0.0

    ap_by_class = []
    included = 0
    mean_ap = 0.0
    for cls in range(classes):
        if truth_classes_count[cls] == 0:
            ap_by_class.append(0.0)
            continue
        included += 1
        ap = 0.0
        for point in range(11):
            cur_recall = point * 0.1
            cur_precision = 0.0
            for rank in range(len(detections)):
                if pr[cls][rank]["recall"] >= cur_recall:
                    cur_precision = max(cur_precision, pr[cls][rank]["precision"])
            ap += cur_precision
        ap /= 11.0
        ap_by_class.append(ap)
        mean_ap += ap
    mean_ap = mean_ap / included if included else 0.0

    precision = tp_for_thresh / (tp_for_thresh + fp_for_thresh) if (tp_for_thresh + fp_for_thresh) else 0.0
    recall = tp_for_thresh / (tp_for_thresh + unique_truth_count - tp_for_thresh) if unique_truth_count else 0.0
    f1 = 2.0 * precision * recall / (precision + recall) if (precision + recall) else 0.0

    lines = [
        f"images = {len(rows)}",
        f"detections_count = {len(detections)}, unique_truth_count = {unique_truth_count}",
    ]
    for cls, ap in enumerate(ap_by_class):
        lines.append(f"class_id = {cls}, name = {names[cls]}, \t ap = {ap * 100:.2f} % ")
    lines.append(f" for thresh = {args.score_thresh:.2f}, precision = {precision:.2f}, recall = {recall:.2f}, F1-score = {f1:.2f} ")
    lines.append(f" for thresh = {args.score_thresh:.2f}, TP = {tp_for_thresh}, FP = {fp_for_thresh}, FN = {unique_truth_count - tp_for_thresh}, average IoU = {avg_iou * 100:.2f} % ")
    lines.append("")
    lines.append(f" mean average precision (mAP) = {mean_ap:.6f}, or {mean_ap * 100:.2f} % ")

    report = Path(args.report)
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text("\n".join(lines) + "\n")
    print("\n".join(lines[-4:]))
    print(f"[eval-map] report={report}")


def main():
    parser = argparse.ArgumentParser(description="Board mAP input generation and evaluation helpers")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("make-inputs")
    p.add_argument("--image-list", type=Path, default=Path("C:/skeleton/bin/dataset/target.txt"))
    p.add_argument("--out-dir", type=Path, required=True)
    p.add_argument("--start", type=int, default=0)
    p.add_argument("--limit", type=int)
    p.set_defaults(func=make_inputs)

    p = sub.add_parser("make-inputs-c")
    p.add_argument("--image-list", type=Path, default=Path("C:/skeleton/bin/dataset/target.txt"))
    p.add_argument("--out-dir", type=Path, required=True)
    p.add_argument("--skeleton-bin", type=Path, default=Path("C:/skeleton/bin"))
    p.add_argument("--start", type=int, default=0)
    p.add_argument("--limit", type=int)
    p.set_defaults(func=make_inputs_c)

    p = sub.add_parser("eval-map")
    p.add_argument("--manifest", type=Path, required=True)
    p.add_argument("--snapshot-dir", type=Path, required=True)
    p.add_argument("--report", type=Path, required=True)
    p.add_argument("--cfg", type=Path, default=Path("C:/skeleton/bin/aix2024.cfg"))
    p.add_argument("--names", type=Path, default=Path("C:/skeleton/bin/yolohw.names"))
    p.add_argument("--ap-thresh", type=float, default=0.005)
    p.add_argument("--score-thresh", type=float, default=0.24)
    p.add_argument("--nms", type=float, default=0.45)
    p.add_argument("--iou-thresh", type=float, default=0.5)
    p.add_argument("--snapshot-mode", choices=["int16-q4", "int32-partition"], default="int16-q4")
    p.add_argument("--start", type=int, default=0)
    p.add_argument("--limit", type=int)
    p.set_defaults(func=evaluate)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
