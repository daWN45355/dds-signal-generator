# ============================================================
# Vivado 批处理构建脚本（工程骨架）
#
# 用法：把本文件放到工程根目录，与 src/ 和 pins.xdc 同级，然后
#       build.bat <工程目录名>
#
# 需要改的只有下面三个变量。
#
# 适用前提：
#   - 纯 RTL 工程，单顶层，无 Block Design、无 IP 核
#   - 源文件全部放在 src/*.v（若是 .sv 请改 glob 的扩展名）
#   - 约束文件名为 pins.xdc
# 若工程含 BD/IP / MIG / AXI 互联，本流程不够用，需改成：
#     add_files -fileset sources_1 ./xxx.bd
#     set_property synth_checkpoint_mode None [get_files ./xxx.bd]
#     generate_target all [get_files ./xxx.bd]
# ============================================================

# ---------- 改这三行 ----------
set proj_name "phase7_keyctl"          ;# 工程名，建议与目录名一致
set top_name  "dds_key_top"            ;# 顶层模块名
set part_name "xc7z010clg400-1"        ;# 器件型号，用 get_parts 查准确写法

set script_dir [file normalize [file dirname [info script]]]
cd $script_dir

if {[file exists ./proj]} {
    file delete -force ./proj
}

create_project $proj_name ./proj -part $part_name -force

foreach f [glob -nocomplain ./src/*.v] {
    add_files -norecurse $f
}

if {[file exists ./pins.xdc]} {
    add_files -fileset constrs_1 -norecurse ./pins.xdc
} else {
    error "pins.xdc not found"
}

set_property top $top_name [current_fileset]
update_compile_order -fileset sources_1

launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[expr {[get_property PROGRESS [get_runs synth_1]] != "100%"}]} {
    error "SYNTHESIS FAILED"
}

launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[expr {[get_property PROGRESS [get_runs impl_1]] != "100%"}]} {
    error "IMPLEMENTATION FAILED"
}

open_run impl_1
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]

puts "======================================================"
puts "BUILD OK   WNS = $wns ns"
puts "BIT: [file normalize ./proj/$proj_name.runs/impl_1/$top_name.bit]"
puts "======================================================"
# 实现报告（供 03_checks/check_impl.py 解析）位于：
#   ./proj/$proj_name.runs/impl_1/${top_name}_timing_summary_routed.rpt
#   ./proj/$proj_name.runs/impl_1/${top_name}_utilization_placed.rpt
