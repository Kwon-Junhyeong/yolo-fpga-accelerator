# YOLO FPGA Accelerator

A CNN accelerator in Verilog that runs all eleven convolutional layers of a YOLOv2 detector on the Artix-7 FPGA of a Nexys A7-100T board. It recognizes 60 kinds of shelf products. Built for the 2026 Deep Learning Hardware Design Contest (3rd place).

| | |
|---|---|
| Frame rate on the board | 12.7 frames per second at 100 MHz |
| Accuracy | 80.91% mAP with 8-bit weights, against 55.04% for the organizers' 8-bit reference |
| On-chip power | 1.730 W |

![System](docs/system.png)

## Power and clock

The contest score rewards accuracy and frame rate relative to on-chip power, so each gain in frame rate is weighed against its power cost. The accelerator uses 72 of the 240 DSP slices and runs at 100 MHz on its own clock, apart from the DDR2 controller's 81.25 MHz.

## Reuse data across the memory hierarchy

On a small FPGA, moving data between memory and the multipliers sets the frame time more than multiplier speed does, so the design is built around reuse.

- Feature maps stay on chip between layers. Only the input image, the weights of the later layers and the two outputs go to or from DDR2.
- A tile stays in the window buffer while the weights of every output channel pass over it, so each tile is fetched once.
- Two ping-pong window buffers overlap loading and compute: one feeds the multipliers while the other refills.
- Each buffer is split into 16 banks, so reading any 4 x 4 window touches each bank once.

One weight word serves four outputs, and one DSP slice multiplies a weight by two activations: 144 products per clock from 72 slices.

Overlapping the transfers with computation, layer by layer, cut the simulated frame time by a factor of 2.24.

## Checked bit for bit

An integer model using the hardware's arithmetic matched the RTL simulation after every layer. On the board, all 458 output tensors of the 229 test images matched the integer model bit for bit.

## Build

- ROM contents for synthesis: `quant/make_roms.py`
- Bitstream: `fpga/create_project.tcl`, `fpga/create_bd.tcl`, `fpga/implement.tcl` (Vivado 2022.2)
- Firmware: `firmware/create_app.tcl`
- Board run from the contest's C program: `host/yolo_jtag_forward.ps1`
