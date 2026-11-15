# Vitis (XSCT) build of the firmware ELF from the hardware platform written by fpga/implement.tcl.
# usage: xsct create_app.tcl <xsa file> <workspace dir>
set xsa [file normalize [lindex $argv 0]]
set workspace [file normalize [lindex $argv 1]]
set src_dir [file dirname [file normalize [info script]]]

if {[file exists $workspace]} {
    file delete -force $workspace
}
setws $workspace
platform create -name yolo_mb_platform -hw $xsa
domain create -name standalone_domain -os standalone -proc microblaze_0
platform generate
app create -name yolo_mb_smoke -platform yolo_mb_platform -domain standalone_domain -template {Empty Application}
foreach f [glob -nocomplain -directory $src_dir *.c *.h] {
    importsources -name yolo_mb_smoke -path $f
}
app build -name yolo_mb_smoke
puts "YOLO_MB_ELF=[file join $workspace yolo_mb_smoke Debug yolo_mb_smoke.elf]"
