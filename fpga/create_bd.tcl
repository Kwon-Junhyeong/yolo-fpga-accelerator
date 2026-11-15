set project_dir [lindex $argv 0]
set board_store [lindex $argv 1]
set project_xpr [file join $project_dir {yolo_tiny_v2_acc.xpr}]
open_project $project_xpr

set pin_xdc [file join $project_dir {board_pins.xdc}]
set pin_fd [open $pin_xdc w]
puts $pin_fd {set_property PACKAGE_PIN E3 [get_ports sys_clk_i]}
puts $pin_fd {set_property IOSTANDARD LVCMOS33 [get_ports sys_clk_i]}
puts $pin_fd {set_property PACKAGE_PIN D4 [get_ports usb_uart_0_txd]}
puts $pin_fd {set_property IOSTANDARD LVCMOS33 [get_ports usb_uart_0_txd]}
puts $pin_fd {set_property PACKAGE_PIN C4 [get_ports usb_uart_0_rxd]}
puts $pin_fd {set_property IOSTANDARD LVCMOS33 [get_ports usb_uart_0_rxd]}
close $pin_fd
if {[llength [get_files -quiet $pin_xdc]] == 0} {
    add_files -fileset constrs_1 -norecurse $pin_xdc
}

set bd_name yolo_mb_board_bd
if {[llength [get_files -quiet "${bd_name}.bd"]] != 0} {
    remove_files [get_files -quiet "${bd_name}.bd"]
}
set bd_dir [file normalize [file join $project_dir "yolo_tiny_v2_acc.srcs/sources_1/bd/${bd_name}"]]
if {[file exists $bd_dir]} {
    file delete -force $bd_dir
}
create_bd_design $bd_name

set mig_prj_src [file join $board_store {Vivado/2022.2/boards/Digilent/nexys-a7-100t/D.0/1.2/mig.prj}]
set mig_prj [file join $project_dir {nexys_mig_nobuf.prj}]
set mig_fd [open $mig_prj_src r]
set mig_cfg [read $mig_fd]
close $mig_fd
set mig_cfg [string map [list {<SystemClock>Single-Ended</SystemClock>} {<SystemClock>No Buffer</SystemClock>}] $mig_cfg]
regsub {(?s)[ \t\r\n]*<System_Clock>.*?</System_Clock>} $mig_cfg {} mig_cfg
set mig_fd [open $mig_prj w]
puts -nonewline $mig_fd $mig_cfg
close $mig_fd

set mig  [create_bd_cell -type ip -vlnv xilinx.com:ip:mig_7series mig_0]
set_property -dict [list CONFIG.XML_INPUT_FILE $mig_prj] $mig

set jtag [create_bd_cell -type ip -vlnv xilinx.com:ip:jtag_axi jtag_axi_0]
set sc   [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect smartconnect_0]
set_property -dict [list CONFIG.NUM_SI {3} CONFIG.NUM_MI {2}] $sc

set yolo_m_clkconv [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_clock_converter yolo_m_clkconv]
set yolo_s_clkconv [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_clock_converter yolo_s_clkconv]
catch {set_property -dict [list CONFIG.PROTOCOL {AXI4}] $yolo_m_clkconv}
catch {set_property -dict [list CONFIG.PROTOCOL {AXI4LITE}] $yolo_s_clkconv}

set clk_wiz [create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz clk_wiz_0]
set_property -dict [list CONFIG.PRIM_SOURCE {Single_ended_clock_capable_pin} CONFIG.PRIM_IN_FREQ {100.000} CONFIG.CLKOUT2_USED {true}] $clk_wiz
set_property -dict [list CONFIG.NUM_OUT_CLKS {2} CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {100.000} CONFIG.CLKOUT2_REQUESTED_OUT_FREQ {200.000}] $clk_wiz

set yolo [create_bd_cell -type module -reference yolo_engine_ip yolo_0]
set_property CONFIG.C_S00_AXI_ADDR_WIDTH 5 $yolo

set yolo_rst_100 [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset yolo_rst_100]

set sys_clk [create_bd_port -dir I -type clk -freq_hz 100000000 sys_clk_i]

set zero [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant clk_wiz_reset_const]
set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {0}] $zero
set one [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant yolo_reset_release_const]
set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {1}] $one

connect_bd_net $sys_clk [get_bd_pins clk_wiz_0/clk_in1]
connect_bd_net [get_bd_pins clk_wiz_reset_const/dout] [get_bd_pins clk_wiz_0/reset]
connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins mig_0/sys_clk_i]
connect_bd_net [get_bd_pins clk_wiz_0/clk_out2] [get_bd_pins mig_0/clk_ref_i]
connect_bd_net [get_bd_pins clk_wiz_0/locked] [get_bd_pins mig_0/sys_rst]

connect_bd_net [get_bd_pins mig_0/ui_clk] [get_bd_pins smartconnect_0/aclk]
connect_bd_net [get_bd_pins mig_0/ui_clk] [get_bd_pins jtag_axi_0/aclk]
connect_bd_net [get_bd_pins mig_0/ui_clk] [get_bd_pins yolo_m_clkconv/m_axi_aclk]
connect_bd_net [get_bd_pins mig_0/ui_clk] [get_bd_pins yolo_s_clkconv/s_axi_aclk]

connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins yolo_0/s00_axi_aclk]
connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins yolo_m_clkconv/s_axi_aclk]
connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins yolo_s_clkconv/m_axi_aclk]
connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins yolo_rst_100/slowest_sync_clk]

connect_bd_net [get_bd_pins mig_0/init_calib_complete] [get_bd_pins mig_0/aresetn]
connect_bd_net [get_bd_pins mig_0/init_calib_complete] [get_bd_pins smartconnect_0/aresetn]
connect_bd_net [get_bd_pins mig_0/init_calib_complete] [get_bd_pins jtag_axi_0/aresetn]
connect_bd_net [get_bd_pins mig_0/init_calib_complete] [get_bd_pins yolo_m_clkconv/m_axi_aresetn]
connect_bd_net [get_bd_pins mig_0/init_calib_complete] [get_bd_pins yolo_s_clkconv/s_axi_aresetn]
connect_bd_net [get_bd_pins clk_wiz_0/locked] [get_bd_pins yolo_rst_100/dcm_locked]
connect_bd_net [get_bd_pins yolo_reset_release_const/dout] [get_bd_pins yolo_rst_100/ext_reset_in]
connect_bd_net [get_bd_pins yolo_rst_100/peripheral_aresetn] [get_bd_pins yolo_0/s00_axi_aresetn]
connect_bd_net [get_bd_pins yolo_rst_100/peripheral_aresetn] [get_bd_pins yolo_m_clkconv/s_axi_aresetn]
connect_bd_net [get_bd_pins yolo_rst_100/peripheral_aresetn] [get_bd_pins yolo_s_clkconv/m_axi_aresetn]

set_property CONFIG.FREQ_HZ 100000000 [get_bd_pins yolo_0/s00_axi_aclk]
set_property CONFIG.FREQ_HZ 100000000 [get_bd_intf_pins yolo_0/M]
set_property CONFIG.FREQ_HZ 100000000 [get_bd_intf_pins yolo_0/s00_axi]

set mb [create_bd_cell -type ip -vlnv xilinx.com:ip:microblaze microblaze_0]
set_property -dict [list CONFIG.C_USE_ICACHE 0 CONFIG.C_USE_DCACHE 0] $mb
apply_bd_automation -rule xilinx.com:bd_rule:microblaze \
    -config {local_mem "16KB" ecc "None" debug_module "Debug Only" axi_periph "1" axi_intc "0" clk "/mig_0/ui_clk"} \
    $mb
set_property -dict [list CONFIG.C_USE_ICACHE 0 CONFIG.C_USE_DCACHE 0] $mb

set mb_axi [get_bd_cells microblaze_0_axi_periph]
set_property CONFIG.NUM_MI 2 $mb_axi
connect_bd_net [get_bd_pins mig_0/ui_clk] [get_bd_pins microblaze_0_axi_periph/M00_ACLK]
connect_bd_net [get_bd_pins mig_0/ui_clk] [get_bd_pins microblaze_0_axi_periph/M01_ACLK]

set uart [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_uartlite axi_uartlite_0]
set_property -dict [list CONFIG.C_BAUDRATE {115200} CONFIG.C_DATA_BITS {8}] $uart
connect_bd_net [get_bd_pins mig_0/ui_clk] [get_bd_pins axi_uartlite_0/s_axi_aclk]

set mb_rst_cells [get_bd_cells -hier -filter {VLNV =~ "*proc_sys_reset*"}]
set mb_rst [lindex $mb_rst_cells 0]
if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins $mb_rst/dcm_locked]]] == 0} {
    connect_bd_net [get_bd_pins mig_0/init_calib_complete] [get_bd_pins $mb_rst/dcm_locked]
}
connect_bd_net [get_bd_pins $mb_rst/peripheral_aresetn] [get_bd_pins microblaze_0_axi_periph/M00_ARESETN]
connect_bd_net [get_bd_pins $mb_rst/peripheral_aresetn] [get_bd_pins microblaze_0_axi_periph/M01_ARESETN]
connect_bd_net [get_bd_pins $mb_rst/peripheral_aresetn] [get_bd_pins axi_uartlite_0/s_axi_aresetn]

connect_bd_intf_net [get_bd_intf_pins jtag_axi_0/M_AXI] [get_bd_intf_pins smartconnect_0/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins yolo_0/M]         [get_bd_intf_pins yolo_m_clkconv/S_AXI]
connect_bd_intf_net [get_bd_intf_pins yolo_m_clkconv/M_AXI] [get_bd_intf_pins smartconnect_0/S01_AXI]
connect_bd_intf_net [get_bd_intf_pins microblaze_0_axi_periph/M00_AXI] [get_bd_intf_pins smartconnect_0/S02_AXI]
connect_bd_intf_net [get_bd_intf_pins microblaze_0_axi_periph/M01_AXI] [get_bd_intf_pins axi_uartlite_0/S_AXI]
connect_bd_intf_net [get_bd_intf_pins smartconnect_0/M00_AXI] [get_bd_intf_pins mig_0/S_AXI]
connect_bd_intf_net [get_bd_intf_pins smartconnect_0/M01_AXI] [get_bd_intf_pins yolo_s_clkconv/S_AXI]
connect_bd_intf_net [get_bd_intf_pins yolo_s_clkconv/M_AXI] [get_bd_intf_pins yolo_0/s00_axi]

make_bd_intf_pins_external -name DDR2 [get_bd_intf_pins mig_0/DDR2]
make_bd_intf_pins_external -name usb_uart_0 [get_bd_intf_pins axi_uartlite_0/UART]

create_bd_addr_seg -range 0x08000000 -offset 0x80000000 \
    [get_bd_addr_spaces jtag_axi_0/Data] [get_bd_addr_segs mig_0/memmap/memaddr] SEG_jtag_ddr
create_bd_addr_seg -range 0x00001000 -offset 0x44A00000 \
    [get_bd_addr_spaces jtag_axi_0/Data] [get_bd_addr_segs yolo_0/s00_axi/reg0] SEG_jtag_yolo_ctrl
create_bd_addr_seg -range 0x08000000 -offset 0x00000000 \
    [get_bd_addr_spaces yolo_0/M] [get_bd_addr_segs mig_0/memmap/memaddr] SEG_yolo_ddr

create_bd_addr_seg -range 0x08000000 -offset 0x80000000 \
    [get_bd_addr_spaces microblaze_0/Data] [get_bd_addr_segs mig_0/memmap/memaddr] SEG_mb_ddr
create_bd_addr_seg -range 0x00001000 -offset 0x44A00000 \
    [get_bd_addr_spaces microblaze_0/Data] [get_bd_addr_segs yolo_0/s00_axi/reg0] SEG_mb_yolo_ctrl
create_bd_addr_seg -range 0x00010000 -offset 0x40600000 \
    [get_bd_addr_spaces microblaze_0/Data] [get_bd_addr_segs axi_uartlite_0/S_AXI/Reg] SEG_mb_uart

foreach seg [get_bd_addr_segs] {
    puts "ADDR_SEG=$seg OFFSET=[get_property OFFSET $seg] RANGE=[get_property RANGE $seg]"
}

validate_bd_design
save_bd_design

set bd_file [get_files "*/${bd_name}.bd"]
generate_target all $bd_file
set wrapper [make_wrapper -files $bd_file -top]
add_files -norecurse $wrapper
set_property top ${bd_name}_wrapper [get_filesets sources_1]
update_compile_order -fileset sources_1

write_hw_platform -fixed -force -file [file join $project_dir {yolo_mb_board_bd_wrapper.xsa}]

close_project
