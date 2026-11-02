# ============================================================
#  可复现构建脚本  build.tcl
#
#  用法（两种都行）：
#    1) 双击同目录的 build.bat
#    2) 命令行： vivado -mode batch -source build.tcl -nojournal -nolog
#
#  产物：
#    ./build/proj/<proj_name>.runs/impl_1/dds_key_top.bit     比特流
#    ./build/proj/<proj_name>.runs/impl_1/*.rpt               综合实现报告
#
#  三处需要改的地方都在下面的"参数"一节（改工程名 / 顶层名 / 器件型号）。
#  换别的题目用这套脚本时，只需要改这三个变量 + 换掉 src/ 与 pins.xdc。
# ============================================================

# ---------------- 参数 ----------------
set proj_name "eabaz4205_dds"
set top_name  "dds_key_top"
set part_name "xc7z010clg400-1"

# ---------------- 路径 ----------------
set script_dir [file normalize [file dirname [info script]]]
# 本脚本位于 <root>/build/，源码在 <root>/src/，约束在 <root>/constr/
# 工程目录建在 <root>/build/proj/，不污染上层。
set root_dir  [file normalize [file join $script_dir ".."]]
cd $script_dir

set src_dir  [file join $root_dir "src"]
set xdc_file [file join $root_dir "constr" "pins.xdc"]
set proj_dir [file join $script_dir "proj"]

if {![file isdirectory $src_dir]} {
    error "src/ not found at $src_dir"
}
if {![file exists $xdc_file]} {
    error "pins.xdc not found at $xdc_file"
}

# ---------------- 清理旧工程 ----------------
# 每次都从零建工程，避免上一次的 run 状态干扰结果。
# 代价是综合时间不能复用；对 4 分钟的规模这是值得的 —— 
# "可复现"的前提是"每次都一样"，增量构建不满足这一点。
if {[file exists $proj_dir]} {
    puts "removing old project dir ..."
    file delete -force $proj_dir
}

# ---------------- 建工程 ----------------
create_project $proj_name $proj_dir -part $part_name -force

foreach f [glob -nocomplain [file join $src_dir "*.v"]] {
    add_files -norecurse $f
}
add_files -fileset constrs_1 -norecurse $xdc_file

set_property top $top_name [current_fileset]
update_compile_order -fileset sources_1

puts "======================================================"
puts "PROJECT : $proj_name"
puts "TOP     : $top_name"
puts "PART    : $part_name"
puts "SRC     : [llength [glob -nocomplain [file join $src_dir *.v]]] verilog files"
puts "XDC     : $xdc_file"
puts "======================================================"

# ---------------- 综合 ----------------
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[expr {[get_property PROGRESS [get_runs synth_1]] != "100%"}]} {
    error "SYNTHESIS FAILED -- see proj/$proj_name.runs/synth_1/runme.log"
}

# ---------------- 实现 + 比特流 ----------------
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[expr {[get_property PROGRESS [get_runs impl_1]] != "100%"}]} {
    error "IMPLEMENTATION FAILED -- see proj/$proj_name.runs/impl_1/runme.log"
}

# ---------------- 结果 ----------------
open_run impl_1
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]

puts ""
puts "======================================================"
puts "BUILD OK"
puts "  WNS = $wns ns"
puts "  BIT = [file normalize [file join $proj_dir $proj_name.runs impl_1 $top_name.bit]]"
puts "======================================================"

if {$wns < 0} {
    puts "\[WARN\] WNS is negative -- timing NOT met."
    puts "       the bitstream was generated but its behaviour on board"
    puts "       is unpredictable. fix the critical path and rebuild."
}
