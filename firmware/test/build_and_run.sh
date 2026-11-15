#!/bin/sh
# Host test of the driver with a model of the control registers and DDR2, and a MicroBlaze compile of the firmware.
# usage: sh build_and_run.sh <host gcc> [<mb-gcc>]
set -e
cd "$(dirname "$0")"
"$1" -std=c99 -O1 -Wall -Wextra -DYOLO_HW_HOST_TEST -o test_yolo_hw test_yolo_hw.c ../yolo_hw_forward.c
./test_yolo_hw
if [ -n "$2" ]; then
    "$2" -mlittle-endian -mcpu=v11.0 -Os -Wall -Wextra -c ../yolo_hw_forward.c ../uart_host.c ../yolo_mb_smoke.c
    echo "MicroBlaze compile: OK"
fi
