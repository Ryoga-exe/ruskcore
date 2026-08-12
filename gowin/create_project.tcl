set script_dir [file dirname [file normalize [info script]]]
set project_dir [file normalize [file join $script_dir ".."]]

set gowin_dir [file join $project_dir "gowin"]
set filelist  [file join $project_dir "ruskcore.f"]

set cst [file join $project_dir "fpga" "tangnano20k" "tangnano20k.cst"]
set sdc [file join $project_dir "fpga" "tangnano20k" "timing.sdc"]

create_project \
    -name ruskcore \
    -dir $gowin_dir \
    -pn GW2AR-LV18QN88C8/I7 \
    -device_version C \
    -force

set fp [open $filelist r]
while {[gets $fp line] != -1} {
    set line [string trim $line]
    # skip blank or comment line
    if {$line eq "" || [string index $line 0] eq "#"} {
        continue
    }
    # add file to project
    add_file $line
}
close $fp

add_file $cst
add_file $sdc

set init_dir [file join $project_dir "target"]
foreach relpath {bootrom.hex test/zig/gpu.hex} {
    set init_src [file join $project_dir $relpath]
    set init_dst [file join $init_dir $relpath]

    file mkdir [file dirname $init_dst]
    file copy -force $init_src $init_dst
}

set_option -verilog_std sysv2017
set_option -top_module ruskcore_top_tang
set_option -output_base_name ruskcore

run close
