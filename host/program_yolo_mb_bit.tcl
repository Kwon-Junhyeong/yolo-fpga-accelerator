if {![info exists ::env(YOLO_MB_BIT)]} {
    error "set YOLO_MB_BIT to the bitstream, or pass -Bitstream to yolo_jtag_forward.ps1"
}
set bit_file $::env(YOLO_MB_BIT)

connect
targets -set -nocase -filter {name =~ "*xc7a100t*" && jtag_cable_product =~ "Nexys*"}
fpga -file $bit_file
after 2000

puts "YOLO_MB_FPGA_PROGRAMMED bit=$bit_file"
