# Out-of-context synthesis of the 72-multiplier array (rtl/mac_stack.v) for the XC7A100T.
# packed:      rtl/mul.v as used, two products per DSP48 slice
# unpacked:    one 8 x 8 multiplier per product, mapped as Vivado chooses
# unpacked_dsp: one 8 x 8 multiplier per product, forced into DSP48 slices
# usage: vivado -mode batch -source synth_mul_array.tcl -tclargs <rtl dir> <mode> <report file>
set rtl_dir [lindex $argv 0]
set mode [lindex $argv 1]
set report [lindex $argv 2]

set mul_src [file join $rtl_dir mul.v]
if {$mode ne "packed"} {
    set fd [open $mul_src r]
    set text [read $fd]
    close $fd
    regsub -all {`ifdef SYNTHESIS\s*\n\s*`define MUL_LOCAL_USE_DSP_PACKED\s*\n\s*`endif} $text {} text
    if {$mode eq "unpacked_dsp"} {
        regsub {module mul\(} $text {(* use_dsp = "yes" *) module mul(} text
    }
    set mul_src [file join [pwd] mul_$mode.v]
    set fd [open $mul_src w]
    puts -nonewline $fd $text
    close $fd
}
read_verilog [list $mul_src [file join $rtl_dir mac.v] [file join $rtl_dir adder_tree.v] [file join $rtl_dir mac_stack.v]]
synth_design -top mac_stack -part xc7a100tcsg324-1 -mode out_of_context
report_utilization -file $report
puts "MUL_ARRAY mode=$mode DSP48E1=[llength [get_cells -hierarchical -filter {REF_NAME == DSP48E1}]]"
exit 0
