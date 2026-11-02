# ============================================================
#  program_bit.tcl -- 用 Vivado batch 模式把比特流烧进 PL
#
#  用法： vivado -mode batch -source program_bit.tcl -nojournal -nolog
#  由 05_board/上板运行脚本.bat 的 [4] 调用。
#
#  前提：hw_server 已在 localhost:3121 运行。
#        最省事的办法是先打开一次 Vivado 的 Hardware Manager，
#        Open Target -> Auto Connect 成功一次，hw_server 就会常驻。
# ============================================================

set here    [file normalize [file dirname [info script]]]
set bitfile [file normalize [file join $here ".." "bit" "dds_key_top.bit"]]

puts "======================================================"
puts "PROGRAM BITSTREAM"
puts "  file : $bitfile"
puts "======================================================"

if {![file exists $bitfile]} {
    puts "\[ERROR\] bitstream not found: $bitfile"
    puts "        run 02_build/build.bat first."
    exit 1
}

set hw_opened 0
set srv_connected 0

if {[catch { open_hw_manager } err]} {
    puts "\[ERROR\] open_hw_manager failed: $err"
    exit 2
}
set hw_opened 1

if {[catch { connect_hw_server -url localhost:3121 } err]} {
    puts "\[ERROR\] connect_hw_server failed: $err"
    puts "        hw_server is not running."
    puts "        Open Vivado -> Open Hardware Manager -> Open Target -> Auto Connect once,"
    puts "        then re-run this script."
    if {$hw_opened} { catch { close_hw_manager } }
    exit 3
}
set srv_connected 1

if {[catch { open_hw_target } err]} {
    puts "\[ERROR\] open_hw_target failed: $err"
    puts "        check the JTAG cable and board power."
    if {$srv_connected} { catch { disconnect_hw_server } }
    if {$hw_opened}    { catch { close_hw_manager } }
    exit 4
}

set devs [get_hw_devices]
if {[llength $devs] == 0} {
    puts "\[ERROR\] no hw device found."
    catch { close_hw_target }
    if {$srv_connected} { catch { disconnect_hw_server } }
    if {$hw_opened}    { catch { close_hw_manager } }
    exit 5
}

set dev [lindex $devs 0]
puts "  device : $dev"
current_hw_device $dev
refresh_hw_device -update_hw_profiles $dev

if {[catch { set_property PROGRAM.FILE $bitfile [current_hw_device] } err]} {
    puts "\[ERROR\] set PROGRAM.FILE failed: $err"
    catch { close_hw_target }
    if {$srv_connected} { catch { disconnect_hw_server } }
    if {$hw_opened}    { catch { close_hw_manager } }
    exit 6
}

if {[catch { program_hw_devices [current_hw_device] } err]} {
    puts "\[ERROR\] program_hw_devices failed: $err"
    catch { close_hw_target }
    if {$srv_connected} { catch { disconnect_hw_server } }
    if {$hw_opened}    { catch { close_hw_manager } }
    exit 7
}

puts ""
puts "======================================================"
puts "PROGRAM OK"
puts "  next: UNPLUG THE JTAG CABLE NOW."
puts "        this board's JTAG socket is loose -- wiggling it"
puts "        can interrupt the config stream and the waveform"
puts "        will suddenly disappear."
puts "======================================================"

catch { close_hw_target }
catch { disconnect_hw_server }
catch { close_hw_manager }

exit 0
