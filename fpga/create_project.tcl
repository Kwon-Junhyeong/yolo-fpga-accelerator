set project_dir [lindex $argv 0]
set repo_dir [lindex $argv 1]
set board_store [lindex $argv 2]
set_param board.repoPaths [list $board_store]
create_project yolo_tiny_v2_acc $project_dir -part xc7a100tcsg324-1 -force
set_property board_part digilentinc.com:nexys-a7-100t:part0:1.2 [current_project]
add_files -fileset sources_1 [glob $repo_dir/rtl/*.v $repo_dir/contest/*.v]
foreach h {yolo_build_config_h.v user_define_h.v user_param_h.v} {
    set_property file_type {Verilog Header} [get_files -of_objects [get_filesets sources_1] "*$h"]
}
set_property include_dirs [list $repo_dir/rtl $repo_dir/contest] [get_filesets sources_1]
set_property verilog_define {USE_DSP_PACKED} [get_filesets sources_1]
close_project
exit 0
