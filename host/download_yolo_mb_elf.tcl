if {![info exists ::env(YOLO_MB_ELF)]} {
    error "set YOLO_MB_ELF to the firmware ELF, or pass -Elf to yolo_jtag_forward.ps1"
}
set elf_file $::env(YOLO_MB_ELF)

connect
targets -set -nocase -filter {name =~ "*MicroBlaze #0*" && jtag_cable_product =~ "Nexys*"}
rst -processor
dow $elf_file
con

puts "YOLO_MB_FIRMWARE_STARTED elf=$elf_file"
