set ddr_base 0x80000000
set repo_root [file dirname [file dirname [file normalize [info script]]]]
set gen_dir [file join $repo_root sim generated]
set default_manifest [file join $repo_root manifest.tsv]
set out_dir [file join $repo_root runtime]
set manifest $default_manifest
set chunk_words 256
set actual_core_hz 100000000.0

set stage_input_offset 0x01000000
set stage_w06_offset 0x01100000
set stage_w08_offset 0x01120000
set stage_w10_offset 0x01180000
set stage_w12_offset 0x01300000
set stage_w13_offset 0x01360000
set stage_w14_offset 0x014E0000
set stage_w17_offset 0x01530000
set stage_w20_offset 0x01550000
set stage_o14_offset 0x01600000
set stage_o20_offset 0x01610000

set status_offset 0x007F0000
set status_words 16
set mailbox_cmd_run 0x594F4C4F
set status_done 0xC0DE600D
set status_fail 0xC0DEFA11
set target_serial {}

set o14_words 12480
set o20_words 49920
set head_mode {head32_partition_int32}

if {[info exists ::env(YOLO_BATCH_WEIGHT_DIR)]} {
    set gen_dir $::env(YOLO_BATCH_WEIGHT_DIR)
}
if {[info exists ::env(YOLO_BATCH_OUT_DIR)]} {
    set out_dir $::env(YOLO_BATCH_OUT_DIR)
}
if {[info exists ::env(YOLO_BATCH_MANIFEST)]} {
    set manifest $::env(YOLO_BATCH_MANIFEST)
}
set max_images -1
set start_seq 1
if {[info exists ::env(YOLO_BATCH_MAX_IMAGES)]} {
    set max_images [expr {int($::env(YOLO_BATCH_MAX_IMAGES))}]
}
if {[info exists ::env(YOLO_BATCH_START_SEQ)]} {
    set start_seq [expr {int($::env(YOLO_BATCH_START_SEQ))}]
}
set skip_weight_stage 0
if {[info exists ::env(YOLO_BATCH_SKIP_WEIGHT_STAGE)]} {
    set skip_weight_stage [expr {int($::env(YOLO_BATCH_SKIP_WEIGHT_STAGE)) != 0}]
}
set reload_first 1
if {[info exists ::env(YOLO_BATCH_RELOAD_FIRST)]} {
    set reload_first [expr {int($::env(YOLO_BATCH_RELOAD_FIRST)) != 0}]
}
if {[info exists ::env(YOLO_BATCH_TARGET_SERIAL)]} {
    set target_serial $::env(YOLO_BATCH_TARGET_SERIAL)
}

file mkdir $out_dir
set cycle_report [file join $out_dir cycles.tsv]
set fps_report [file join $out_dir fps_report.txt]

set_msg_config -id {Labtoolstcl 44-481} -suppress

proc norm_word {line} {
    set s [string trim $line]
    set s [string map [list "_" ""] $s]
    if {$s eq ""} {
        return ""
    }
    return [format %08X [expr "wide(0x$s) & 0xffffffff"]]
}

proc axi_delete_old {} {
    set old_txns [get_hw_axi_txns -quiet yolo_*]
    if {[llength $old_txns] > 0} {
        delete_hw_axi_txn $old_txns
    }
}

proc axi_write_words {axi addr words name} {
    if {[llength $words] == 0} {
        return
    }
    set txn yolo_wr_$name
    create_hw_axi_txn $txn $axi -type write -address [format %08X $addr] -len [llength $words] -data $words -force
    run_hw_axi [get_hw_axi_txns $txn]
    delete_hw_axi_txn [get_hw_axi_txns $txn]
}

proc axi_read_words {axi addr len name} {
    set txn yolo_rd_$name
    create_hw_axi_txn $txn $axi -type read -address [format %08X $addr] -len $len -force
    run_hw_axi [get_hw_axi_txns $txn]
    set data [get_property DATA [get_hw_axi_txns $txn]]
    delete_hw_axi_txn [get_hw_axi_txns $txn]
    set packed [string map [list " " "" "\n" "" "\r" "" "\t" ""] $data]
    set words {}
    for {set idx [expr {[string length $packed] - 8}]} {$idx >= 0} {incr idx -8} {
        lappend words [string range $packed $idx [expr {$idx + 7}]]
    }
    return $words
}

proc load_hex_to_ddr {axi file base_addr expected_words chunk_words label} {
    set fd [open $file r]
    set addr $base_addr
    set count 0
    set chunk_idx 0
    while {$count < $expected_words} {
        set words {}
        while {[llength $words] < $chunk_words && $count < $expected_words} {
            if {[gets $fd line] < 0} {
                break
            }
            set w [norm_word $line]
            if {$w eq ""} {
                continue
            }
            lappend words $w
            incr count
        }
        if {[llength $words] == 0} {
            break
        }
        axi_write_words $axi $addr $words load_${label}_${chunk_idx}
        set addr [expr {$addr + 4 * [llength $words]}]
        incr chunk_idx
    }
    close $fd
    if {$count != $expected_words} {
        puts "ERROR: $file loaded $count words, expected $expected_words"
        exit 1
    }
}

proc dump_ddr_words {axi base_addr words path chunk_words} {
    set fd [open $path w]
    set done 0
    set addr $base_addr
    set chunk_idx 0
    while {$done < $words} {
        set n $chunk_words
        if {$done + $n > $words} {
            set n [expr {$words - $done}]
        }
        set data [axi_read_words $axi $addr $n dump_${chunk_idx}]
        foreach word $data {
            set v [norm_word $word]
            set num [expr "wide(0x$v) & 0xffffffff"]
            set b0 [expr {$num & 0xff}]
            set b1 [expr {($num >> 8) & 0xff}]
            set b2 [expr {($num >> 16) & 0xff}]
            set b3 [expr {($num >> 24) & 0xff}]
            puts $fd [format "addr=%d val=0x%08x b0=0x%02x b1=0x%02x b2=0x%02x b3=0x%02x" $done $num $b0 $b1 $b2 $b3]
            incr done
        }
        set addr [expr {$addr + 4 * $n}]
        incr chunk_idx
    }
    close $fd
}

proc stage_weights {axi} {
    global ddr_base gen_dir chunk_words
    global stage_w06_offset stage_w08_offset stage_w10_offset stage_w12_offset
    global stage_w13_offset stage_w14_offset stage_w17_offset stage_w20_offset

    set loads [list \
        [list CONV06_param_weight_packed24.hex $stage_w06_offset 24576] \
        [list CONV08_param_weight_packed24.hex $stage_w08_offset 98304] \
        [list CONV10_param_weight_packed24.hex $stage_w10_offset 393216] \
        [list CONV12_param_weight_packed24.hex $stage_w12_offset 98304] \
        [list CONV13_param_weight_packed24.hex $stage_w13_offset 393216] \
        [list CONV14_param_weight_packed24.hex $stage_w14_offset 74880] \
        [list CONV17_param_weight_packed24.hex $stage_w17_offset 24576] \
        [list CONV20_param_weight_packed24.hex $stage_w20_offset 56160] \
    ]

    puts "YOLO_BATCH_STAGE_WEIGHTS_BEGIN"
    foreach item $loads {
        set file [file join $gen_dir [lindex $item 0]]
        set byte_addr [expr {$ddr_base + [lindex $item 1]}]
        set words [lindex $item 2]
        load_hex_to_ddr $axi $file $byte_addr $words $chunk_words [file rootname [lindex $item 0]]
        puts "YOLO_BATCH_STAGE_WEIGHT_DONE file=[lindex $item 0] words=$words"
    }
    puts "YOLO_BATCH_STAGE_WEIGHTS_DONE"
}

proc send_run_and_wait {axi seq flags} {
    global ddr_base status_offset status_words mailbox_cmd_run status_done status_fail
    set status_addr [expr {$ddr_base + $status_offset}]

    axi_write_words $axi [expr {$status_addr + 4}] [list [format %08X $seq]] mb_seq
    axi_write_words $axi [expr {$status_addr + 12}] [list [format %08X $flags]] mb_flags
    axi_write_words $axi $status_addr [list [format %08X $mailbox_cmd_run]] mb_cmd

    set done 0
    set poll 0
    set words {}
    while {$done == 0 && $poll < 600} {
        set words [axi_read_words $axi $status_addr $status_words mb_status]
        set status_num [expr "wide(0x[lindex $words 0]) & 0xffffffff"]
        set done_seq [expr "wide(0x[lindex $words 2]) & 0xffffffff"]
        if {$status_num == $status_done && $done_seq == $seq} {
            set done 1
        }
        if {$status_num == $status_fail && $done_seq == $seq} {
            puts "ERROR: MicroBlaze forward failed at seq=$seq"
            exit 1
        }
        if {$done == 0} {
            after 100
        }
        incr poll
    }
    if {$done == 0} {
        puts "ERROR: MicroBlaze forward timeout at seq=$seq"
        exit 1
    }
    return $words
}

proc run_one {axi idx stem input_file batch_seq reload_weights cycle_fd} {
    global ddr_base stage_input_offset stage_o14_offset stage_o20_offset
    global o14_words o20_words chunk_words out_dir actual_core_hz

    puts [format "YOLO_BATCH_IMAGE_START index=%d seq=%d stem=%s reload=%d" $idx $batch_seq $stem $reload_weights]
    load_hex_to_ddr $axi $input_file [expr {$ddr_base + $stage_input_offset}] 65536 $chunk_words input_${idx}

    set flags [expr {$reload_weights ? 1 : 0}]
    set words [send_run_and_wait $axi $batch_seq $flags]

    set status_num [expr "wide(0x[lindex $words 0]) & 0xffffffff"]
    set done_seq [expr "wide(0x[lindex $words 2]) & 0xffffffff"]
    set cycles [expr "wide(0x[lindex $words 4]) & 0xffffffff"]
    set mb_polls [expr "wide(0x[lindex $words 5]) & 0xffffffff"]
    set reg0 [expr "wide(0x[lindex $words 6]) & 0xffffffff"]
    set err [expr "wide(0x[lindex $words 7]) & 0xffffffff"]
    set weights_loaded [expr "wide(0x[lindex $words 10]) & 0xffffffff"]
    set run_count [expr "wide(0x[lindex $words 14]) & 0xffffffff"]
    set fps_actual [expr {$actual_core_hz / double($cycles)}]
    set fps_100 [expr {100000000.0 / double($cycles)}]

    set l14_path [file join $out_dir "${stem}_L14.txt"]
    set l20_path [file join $out_dir "${stem}_L20.txt"]
    dump_ddr_words $axi [expr {$ddr_base + $stage_o14_offset}] $o14_words $l14_path $chunk_words
    dump_ddr_words $axi [expr {$ddr_base + $stage_o20_offset}] $o20_words $l20_path $chunk_words

    puts $cycle_fd [format "%d\t%s\t%d\t%.9f\t%.9f\t%d\t0x%08X\t%d\t%d\t%d\t0x%08X" \
        $idx $stem $cycles $fps_actual $fps_100 $mb_polls $reg0 $weights_loaded $run_count $done_seq $status_num]
    flush $cycle_fd

    puts [format "YOLO_BATCH_IMAGE_DONE index=%d mode=head32_partition_int32 seq=%d cycles=%d fps=%.6f l14=%s l20=%s" \
        $idx $batch_seq $cycles $fps_actual $l14_path $l20_path]

    if {$err != 0} {
        puts "ERROR: MicroBlaze error code $err at image $idx"
        exit 1
    }
    return $cycles
}

open_hw_manager
connect_hw_server
if {$target_serial eq ""} {
    set targets [get_hw_targets -quiet]
} else {
    set targets [get_hw_targets -quiet *$target_serial*]
}
if {[llength $targets] == 0} {
    if {$target_serial eq ""} {
        puts "ERROR: no hardware target found"
    } else {
        puts "ERROR: no hardware target found for serial $target_serial"
    }
    exit 1
}
open_hw_target [lindex $targets 0]
set dev [lindex [get_hw_devices xc7a100t*] 0]
if {$dev eq ""} {
    puts "ERROR: no xc7a100t hardware device found"
    exit 1
}
current_hw_device $dev
refresh_hw_device $dev
set axis [get_hw_axis]
if {[llength $axis] == 0} {
    puts "ERROR: no JTAG AXI master found"
    exit 1
}
set axi [lindex $axis 0]
axi_delete_old

if {$skip_weight_stage == 0} {
    stage_weights $axi
} else {
    puts "YOLO_BATCH_STAGE_WEIGHTS_SKIPPED"
}

puts "YOLO_BATCH_HEAD_MODE=$head_mode"

set cycle_fd [open $cycle_report w]
puts $cycle_fd "index\tstem\tcycles\tfps_actual\tfps_100mhz\tmb_polls\treg0\tweights_loaded\trun_count\tdone_seq\tstatus"
flush $cycle_fd

set fd [open $manifest r]
set header [gets $fd]
set count 0
set seq $start_seq
set sum_cycles 0
set min_cycles 0
set max_cycles 0

while {[gets $fd line] >= 0} {
    if {[string trim $line] eq ""} {
        continue
    }
    if {$max_images >= 0 && $count >= $max_images} {
        break
    }
    set fields [split $line "\t"]
    set idx [expr {int([lindex $fields 0])}]
    set input_file [lindex $fields 2]
    set stem [lindex $fields 3]
    set reload [expr {($count == 0 && $reload_first) ? 1 : 0}]
    set cycles [run_one $axi $idx $stem $input_file $seq $reload $cycle_fd]

    set sum_cycles [expr {wide($sum_cycles) + wide($cycles)}]
    if {$count == 0 || $cycles < $min_cycles} {
        set min_cycles $cycles
    }
    if {$count == 0 || $cycles > $max_cycles} {
        set max_cycles $cycles
    }
    incr count
    incr seq
}
close $fd
close $cycle_fd

if {$count > 0} {
    set avg_cycles [expr {double($sum_cycles) / double($count)}]
    set batch_fps_actual [expr {$actual_core_hz * double($count) / double($sum_cycles)}]
    set batch_fps_100 [expr {100000000.0 * double($count) / double($sum_cycles)}]
} else {
    set avg_cycles 0.0
    set batch_fps_actual 0.0
    set batch_fps_100 0.0
}

set report_fd [open $fps_report w]
puts $report_fd "head_mode = $head_mode"
puts $report_fd "images = $count"
puts $report_fd "sum_cycles = $sum_cycles"
puts $report_fd [format "avg_cycles = %.3f" $avg_cycles]
puts $report_fd [format "min_cycles = %d" $min_cycles]
puts $report_fd [format "max_cycles = %d" $max_cycles]
puts $report_fd [format "actual_core_hz = %.0f" $actual_core_hz]
puts $report_fd [format "batch_fps_actual = %.6f" $batch_fps_actual]
puts $report_fd [format "batch_fps_100mhz = %.6f" $batch_fps_100]
puts $report_fd "cycles_file = $cycle_report"
close $report_fd

puts [format "YOLO_BATCH_DONE images=%d avg_cycles=%.3f fps=%.6f fps_100mhz=%.6f out_dir=%s" \
    $count $avg_cycles $batch_fps_actual $batch_fps_100 $out_dir]
close_hw_manager
