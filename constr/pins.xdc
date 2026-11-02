# ============================================================
# phase7_keyctl 引脚约束 —— 双通道 DDS + 四按键 + 串口调参
# 板卡：EBAZ4205 (XC7Z010CLG400-1) + hellofpga 扩展板
#
# 【按键来自扩展板原理图 EBAZ4205_EXBOARD_20200313.pdf + 实测】
#   扩展板自带 4 个按键 S1~S4，丝印 KEY_1~KEY_4，串 220R 接 VCC_3V3：
#     KEY_1 -> G19    KEY_2 -> J19    KEY_3 -> K19    KEY_4 -> L16
#   按键另一端接 GND，所以是 **低有效**：未按 = 1，按下 = 0
#   实测原始电平（K= 字段，顺序 L16 K19 J19 G19）：
#     空闲 1111 / 按 K1 1110 / 按 K2 1101 / 按 K3 1011 / 按 K4 0111
#   => 内部必须写 PULLUP（和外部上拉并联，未按读 1 更稳）
#   => 写 PULLDOWN 会和 3.3V 上拉对抗，极性被搞反，按键全部失效
#
# 【P4 排针其实是摄像头接口】
#   F19/F20/D19/D18/D20/C20 = OV_HREF/OV_XCLK/OV_D7/OV_D5/OV_D4/OV_D2
#   不接摄像头时正好可以挪用，本项目就是这么用的
# ============================================================

# ---- 系统时钟 50MHz ----
set_property -dict {PACKAGE_PIN N18 IOSTANDARD LVCMOS33} [get_ports clk]
create_clock -period 20.000 -name sys_clk [get_ports clk]

# ---- 四个板载按键（低有效，内部上拉兜底）----
# 外部上拉到 3.3V，内部上拉并联只会更强，未按一定读到 1。
# 按下时被按键短到 GND（串联 220R 限流），照样读 0。
set_property -dict {PACKAGE_PIN G19 IOSTANDARD LVCMOS33 PULLTYPE PULLUP} [get_ports key_wave]
set_property -dict {PACKAGE_PIN J19 IOSTANDARD LVCMOS33 PULLTYPE PULLUP} [get_ports key_freq]
set_property -dict {PACKAGE_PIN K19 IOSTANDARD LVCMOS33 PULLTYPE PULLUP} [get_ports key_phase]
set_property -dict {PACKAGE_PIN L16 IOSTANDARD LVCMOS33 PULLTYPE PULLUP} [get_ports key_dir]

set_false_path -from [get_ports {key_wave key_freq key_phase key_dir}]

# ---- TLV5618 SPI ----
set_property -dict {PACKAGE_PIN F19 IOSTANDARD LVCMOS33} [get_ports dac_din]
set_property -dict {PACKAGE_PIN F20 IOSTANDARD LVCMOS33} [get_ports dac_sclk]
set_property -dict {PACKAGE_PIN D19 IOSTANDARD LVCMOS33} [get_ports dac_cs]
set_output_delay -clock sys_clk 5.000 [get_ports {dac_din dac_sclk dac_cs}]

# ---- 串口（CH340）----
set_property -dict {PACKAGE_PIN D18 IOSTANDARD LVCMOS33} [get_ports uart_rx]
set_property -dict {PACKAGE_PIN D20 IOSTANDARD LVCMOS33} [get_ports uart_tx]
set_false_path -from [get_ports uart_rx]
set_output_delay -clock sys_clk 5.000 [get_ports uart_tx]

# ---- 1Hz 心跳 ----
set_property -dict {PACKAGE_PIN C20 IOSTANDARD LVCMOS33} [get_ports heart]

# ============================================================
# 备用方案：如果板上 S1~S4 机械键坏了，改用外接开关。
# 下面这些脚用户已确认可用，把上面四行 G19/J19/K19/L16 换掉即可。
# 接法：开关一端接 IO、另一端接 GND（低有效），PULLUP 不用改，
#       顶层也【不需要】加任何取反 —— 极性和板载按键完全一致。
#
#   A20  原 OV_RESET
#   H16  原 OV_PWDN
#   J18  原 OV_SCL
#   E19  原 OV_PCLK
#   E17  待确认
# ============================================================
