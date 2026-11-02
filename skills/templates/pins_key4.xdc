# ============================================================
# 约束模板：50 MHz 时钟 + 4 个板载按键 + 串行 DAC + UART
#
# 【只对 EBAZ4205 + EXBOARD 扩展板成立】
# 换板卡必须重新查引脚，但下面的“判据”部分仍然适用。
#
# 本文件同时是一份教学样本：每条 set_property 后面都写了
# “为什么这么写”和“写错会怎样”，可以直接对照自己的板子改。
# ============================================================

# ------------------------------------------------------------
# 1. 系统时钟
# ------------------------------------------------------------
# 有源晶振直接进 PL 的全局时钟引脚，不需要 IBUF 例化（Vivado 自动推断）。
# 约束周期必须与实际晶振一致；写大了会漏掉时序违例，写小了会白费优化。
set_property -dict {PACKAGE_PIN N18 IOSTANDARD LVCMOS33} [get_ports clk]
create_clock -period 20.000 -name sys_clk [get_ports clk]

# ------------------------------------------------------------
# 2. 按键（4 个，低有效）
# ------------------------------------------------------------
# 电路：引脚 --220R-- VCC_3V3，按键另一端接 GND
#   => 未按下：被外部上拉到 3.3V，读 1
#   => 按下  ：被短接到 GND，读 0
#
# 【关键：PULLTYPE 必须写 PULLUP】
#   写 PULLUP  -> 与外部上拉并联，空闲稳读 1       （正确）
#   写 PULLDOWN-> 内部下拉与外部 220R 分压，电平不确定（错误）
#   写 NONE    -> 只剩外部上拉，多数板子可用，但若板上电阻未装配则浮空乱跳
# 这也是最容易踩的坑：一旦极性反了，消抖模块会把“空闲”当成“一直按住”。
#
# 【判据（换板卡时照这个做）】
#   打印四路按键的原始电平，不按任何键时应为全 1；
#   按住第 n 个键时第 n 位变 0。若空闲是全 0，说明你的板子是“下拉 + 按下接 VCC”，
#   PULLTYPE 要改 PULLDOWN，且消抖模块内部逻辑要按高有效改写。
set_property -dict {PACKAGE_PIN G19 IOSTANDARD LVCMOS33 PULLTYPE PULLUP} [get_ports key_wave]
set_property -dict {PACKAGE_PIN J19 IOSTANDARD LVCMOS33 PULLTYPE PULLUP} [get_ports key_freq]
set_property -dict {PACKAGE_PIN K19 IOSTANDARD LVCMOS33 PULLTYPE PULLUP} [get_ports key_phase]
set_property -dict {PACKAGE_PIN L16 IOSTANDARD LVCMOS33 PULLTYPE PULLUP} [get_ports key_dir]

# 按键是异步慢速信号，不参与时序分析。不加这一行会报大量 input delay 违例，
# 但功能上并不影响 —— 属于“报告难看但不致命”的那类，还是加上干净。
set_false_path -from [get_ports {key_wave key_freq key_phase key_dir}]

# ------------------------------------------------------------
# 3. 串行 DAC（TLV5618A：DIN / SCLK / CS）
# ------------------------------------------------------------
# 输出延迟按半个时钟周期给（5 ns），覆盖 PCB/杜邦线传播 + DAC 建立时间。
# 若 SCLK 提到 20 MHz 以上，这个值要重新核算，不能照抄。
set_property -dict {PACKAGE_PIN F19 IOSTANDARD LVCMOS33} [get_ports dac_din]
set_property -dict {PACKAGE_PIN F20 IOSTANDARD LVCMOS33} [get_ports dac_sclk]
set_property -dict {PACKAGE_PIN D19 IOSTANDARD LVCMOS33} [get_ports dac_cs]
set_output_delay -clock sys_clk 5.000 [get_ports {dac_din dac_sclk dac_cs}]

# ------------------------------------------------------------
# 4. UART
# ------------------------------------------------------------
# RX 是异步输入，必须 false_path；TX 是同步输出，给 output_delay。
# 不给 TX 的 output_delay，Vivado 会按 0 处理，115200 下也能跑，
# 但换到高速率或长线就可能出错，建议一开始就写全。
set_property -dict {PACKAGE_PIN D18 IOSTANDARD LVCMOS33} [get_ports uart_rx]
set_property -dict {PACKAGE_PIN D20 IOSTANDARD LVCMOS33} [get_ports uart_tx]
set_false_path -from [get_ports uart_rx]
set_output_delay -clock sys_clk 5.000 [get_ports uart_tx]

# ------------------------------------------------------------
# 5. 心跳灯
# ------------------------------------------------------------
set_property -dict {PACKAGE_PIN C20 IOSTANDARD LVCMOS33} [get_ports heart]

# ============================================================
# 附：EBAZ4205 上 P4 排针其实是 OV5640 摄像头接口
#   A20=OV_RESET  B20=OV_D0    H16=OV_PWDN  H17=OV_D3
#   E19=OV_PCLK   J18=OV_SCL   G20=OV_SDA   C20=OV_D2
#   F19=OV_HREF   F20=OV_XCLK  D19=OV_D7    D18=OV_D5
#   D20=OV_D4     H18=OV_D6    K17=OV_VSYNC
# 不接摄像头时可以挪用（本模板中的 DAC 与 UART 就是这么占用的）。
#
# 【社区资料声称的 KEY1~5 = T19 / P19 / U20 / U19 / V20 是错的】
# 那五个网络实际是 VGA_G2 / VGA_B4 / VGA_HSYNC / VGA_G3 / VGA_VSYNC。
# 按错误资料接线，按键永远读不到变化 —— 本项目为此浪费了一天。
# ============================================================
