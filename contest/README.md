# Files provided by the contest

Every file in this folder came with the 2026 Deep Learning Hardware Design Contest package. Most were changed in this project; the results in `../results/` were produced with these versions. The changes below are those visible in a comparison with the contest's original files of February 2026.

| File | Changes |
|---|---|
| `yolo_engine.v` | changed; the contest's original is not in the project's records, so the changes are not listed |
| `axi_dma_ctrl.v` | changed; the contest's original is not in the project's records, so the changes are not listed |
| `axi_dma_rd.v` | `RREADY` driven by a stall input instead of being held high; data valid, word count and done only on a completed handshake |
| `axi_dma_wr.v` | includes `yolo_build_config_h.v`; a register for the write data and a state that waits for it; with `YOLO_STORE_OVERLAP`, a valid and acknowledge handshake with the store; the `fail_check` output removed |
| `yolo_engine_axi.v` | register address width 4 to 5 bits; a fifth register that returns the cycle count |
| `yolo_engine_ip.v` | register address width 5 bits; 32-bit DDR2 addresses; unused AXI side-band outputs tied to 0; the core clocked and reset by the AXI-Lite clock and reset; the cycle count passed to the registers |
| `user_define_h.v` | includes `yolo_build_config_h.v` |
| `user_param_h.v` | unchanged apart from blank space and comments |

These files remain the property of the contest organizers; the MIT license of this repository covers the other folders.
