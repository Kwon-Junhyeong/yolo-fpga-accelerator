set project_dir [lindex $argv 0]
set board_store [lindex $argv 1]
set_param board.repoPaths [list $board_store]
open_project [file join $project_dir {yolo_tiny_v2_acc.xpr}]

set verilog_defines {USE_DSP_PACKED}
set_property verilog_define $verilog_defines [get_filesets sources_1]
set_property top yolo_mb_board_bd_wrapper [get_filesets sources_1]
update_compile_order -fileset sources_1

set yolo_ooc_run [get_runs -quiet yolo_mb_board_bd_yolo_0_0_synth_1]
if {[llength $yolo_ooc_run] > 0} {
    reset_run $yolo_ooc_run
    set_property -name {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} -value "-verilog_define {$verilog_defines}" -objects $yolo_ooc_run
    launch_runs $yolo_ooc_run -jobs 4
    wait_on_run $yolo_ooc_run
}

set synth_run [get_runs synth_1]
set impl_run  [get_runs impl_1]
set_property strategy Flow_PerfOptimized_high $synth_run
set_property strategy Performance_ExplorePostRoutePhysOpt $impl_run
set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED true $impl_run
set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore $impl_run
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED true $impl_run
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore $impl_run

reset_run synth_1
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {![string match {*Complete*} [get_property STATUS $synth_run]]} {
    puts "ERROR: synthesis did not complete"
    exit 1
}
reset_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {![string match {*Complete*} [get_property STATUS $impl_run]]} {
    puts "ERROR: implementation did not complete"
    exit 1
}

open_run impl_1
report_utilization -file [file join $project_dir utilization.rpt]
report_timing_summary -file [file join $project_dir timing_summary.rpt]
report_power -file [file join $project_dir power.rpt]
write_checkpoint -force [file join $project_dir routed.dcp]
write_hw_platform -fixed -include_bit -force -file [file join $project_dir {yolo_mb_board_bd_wrapper.xsa}]
close_project
exit 0
