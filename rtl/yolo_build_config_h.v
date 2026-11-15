`ifndef YOLO_BUILD_CONFIG_H
`define YOLO_BUILD_CONFIG_H

// Heads L14/L20 leave as raw int32, one 32-channel partition at a time.
`define YOLO_HEAD32_PARTITION_DDR

// No L2-to-L1 refill on partition restart when the whole input fits one L1 page.
`define YOLO_REFILL_SKIP

// L0: issue the 16 output channels of a tile back to back.
`define YOLO_L0_OC_BURST

// 3x3 layers: next output channel issues right after the last beat of the current one.
`define YOLO_OC_PIPELINE

// L0: compute starts while the input image is still arriving from DDR.
`define YOLO_L0_IFM_OVERLAP

// 1x1 layers: same output-channel pipelining as YOLO_OC_PIPELINE.
`define YOLO_IMODE_OCP

// Weights of DDR-fed layers stream in while compute runs; issue waits per 288-bit entry.
`define YOLO_WT_STREAM

// Head partition stores to DDR overlap the next partition's compute.
`define YOLO_STORE_OVERLAP

// Cycle counter stops at network completion, not at the first head store.
`define YOLO_TRUE_LATENCY_COUNTER

`endif
