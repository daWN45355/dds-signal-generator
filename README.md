# 基于 Zynq-7000 的双通道 DDS 信号发生器

全国大学生嵌入式芯片与系统设计竞赛 2026 · FPGA 创新设计赛道（AMD 自主选题）

平台：EBAZ4205 核心板（Zynq-7000 XC7Z010-CLG400-1）+ 扩展板 + TLV5618A 双通道 12 位 SPI DAC
工具链：Vivado 2017.4 WebPACK　|　上位机：Python 3 标准库 + HTML5 Canvas

全部波形生成与参数控制逻辑在 PL 侧实现；PS 不参与信号生成。`src/host/` 是运行在 PC 上的
图形上位机，通过 UART 与板卡通信，承担"PS 侧软件"的角色。

---

## 一、目录结构

本工程按赛题 3.3.5.4 的推荐目录组织，目录名与文件名一律小写英文，中文只出现在文件正文中：

```
dds_project/
├── README.md              本文件
├── src/                   RTL 源码（11 个 .v，共 2274 行）
│   └── host/              上位机软件（Python + HTML，运行在 PC）
├── sim/                   测试平台、仿真脚本、仿真日志
├── constr/                引脚与时序约束 pins.xdc
├── bit/                   预编译比特流 dds_key_top.bit
├── build/                 构建脚本、上板脚本、校验入口
│   ├── build.tcl          参数化构建（综合→实现→比特流→打印 WNS）
│   ├── build.bat          Windows 双击入口
│   ├── repro_all.bat      一键复现：校验→构建→结果比对
│   ├── run_board.bat      上板运行菜单（烧录/串口调参/网页控制台/自检）
│   ├── program_bit.tcl    JTAG 烧录脚本
│   ├── selftest.ps1       串口接线自检
│   └── tools/             串口调参与监听脚本
├── data/                  数据与报告
│   ├── impl_1/            5 份 Vivado 原始报告（时序/资源/功耗/DRC/布线）
│   ├── impl_report.md     综合与实现报告汇总
│   ├── sim_report.md      仿真验证结果说明
│   ├── measured_vs_ref.md 实测输出与参考值比对
│   └── uart_capture.txt   串口状态报文原始样例
└── skills/                技能包（见 3.3.5.2）
    ├── README.md          技能包索引：适用范围、使用方法、失效条件
    ├── prompts/           提示词工作流
    ├── templates/         工程模板、约束模板、报告骨架
    ├── checks/            可自动运行的校验脚本
    └── pitfalls/          踩坑清单
```

赛题 3.3.5.2 中技能包目录写作 `skill/`，本工程按 3.3.5.4 的推荐结构统一为 `skills/`，
内容组织与 README 说明方式完全按 3.3.5.2 执行。

---

## 二、三步复现

### 第 1 步　仿真（约 1 分钟，不需要板卡）

```
cd sim
run_sim.bat
```

预期 13 行 `[ OK ]` 与 `ALL TESTS PASSED`。覆盖合法指令、非法字符丢弃、边界值、
连续指令粘连、按键事件等情形。只看功能正确性的话，做到这一步就够了。

### 第 2 步　构建（约 4 分钟）

双击 `build/build.bat`。首次使用前修改 `build.bat` 第 14 行的 `VIVADO` 变量，
指向本机 `vivado.bat`。

产物：`build/proj/eabaz4205_dds.runs/impl_1/dds_key_top.bit`
预期结果：WNS ≈ **+3.089 ns**，WHS +0.121 ns，LUT 1003/17600（5.70%），
FF 677/35200（1.92%），BRAM 1/60，DSP 6/80，片上功耗 0.097 W。
与 `data/impl_1/` 中的归档报告逐项一致。

也可以运行 `build/repro_all.bat`，它会先做静态检查，再构建，最后把新结果与
`data/impl_1/` 里的基线比对，任何一项超差都会报出来。

### 第 3 步　上板

1. `bit/dds_key_top.bit` 用 JTAG 下载（`build/program_bit.tcl`，或 Vivado 硬件管理器）。
2. 按第四节接线。
3. 双击 `build/run_board.bat`，选「串口自检」，发一个 `?`，应回一行状态报文。

---

## 三、引脚

| 信号 | 引脚 | 说明 |
|---|---|---|
| clk | N18 | 50 MHz 板载有源晶振 |
| key_wave / key_freq / key_phase / key_dir | G19 / J19 / K19 / L16 | 板载 S1~S4，低有效，内部上拉 |
| dac_din / dac_sclk / dac_cs | F19 / F20 / D19 | TLV5618A 三线 SPI |
| uart_rx / uart_tx | D18 / D20 | CH340 USB 转串口，115200-8-N-1 |
| heart | C20 | 1 Hz 心跳指示 |

F19/F20/D19/D18/D20/C20 在原理图上属 P4 排针（OV5640 摄像头接口），本项目不接摄像头，
直接挪用。完整约束与每条取值的理由见 `constr/pins.xdc` 注释。

---

## 四、串口指令（115200-8-N-1，回车结尾）

| 指令 | 说明 | 取值范围 |
|---|---|---|
| `?` | 回传一行当前状态 | — |
| `F<n>` | 设频率（Hz） | 1 ~ 20000 |
| `P<n>` | 设两通道相位差（度） | 0 ~ 359 |
| `W<n>` | 波形：0 正弦 / 1 方波 / 2 三角 / 3 锯齿 / 4 自动轮换 | 0 ~ 4 |
| `A<n>` | 幅度百分比（12 位数字域缩放） | 1 ~ 100 |
| `D<n>` | 按键步进方向：0 减 / 1 增 | 0 ~ 1 |
| `S<n>` | 连续回传开关 | 0 ~ 1 |

状态行：`F=01000 P=090 W=0 A=100 D=1 K=1111`
（`K` 为四键原始电平，空闲全 1，按下变 0，位序 L16 K19 J19 G19）

超范围的值会被丢弃且不改变当前参数，这是设计上的保护而非故障。

---

## 五、关键指标

| 项 | 值 | 出处 |
|---|---|---|
| 相位累加器 | 32 位 @ 50 MHz | `src/dds_key_top.v` |
| 频率分辨率 | 0.0116 Hz | 50 MHz / 2³² |
| DAC 更新率 | ≈347 kSPS | 双帧 144 拍 @ 50 MHz |
| 相位分辨率 | 360°/2³²，零漂移 | 数字相位字直接给定 |
| 实测稳定频段 | 100 Hz ~ 20 kHz | `data/measured_vs_ref.md` |
| 资源占用 | LUT 5.70%、FF 1.92%、BRAM 1 块 | `data/impl_1/` |
| 时序 | WNS +3.089 ns，TNS 0 | `data/impl_1/` |
| 片上功耗 | 0.097 W（动态 0.004 + 静态 0.093） | `data/impl_1/` |

---

## 六、依赖与约定

- Vivado 2017.4（WebPACK 即可，XC7Z010 在免费器件范围内）
- Python 3.6+，只用标准库（`http.server`、`serial` 需另装 pyserial）
- 路径全部为 ASCII，可直接拷到任意英文路径下构建；含中文的路径会让 Vivado 2017.4
  在 `add_files` 阶段报 `file not found`
- 每个 `.bat` 用 GBK 编码、每个 `.md` 用 UTF-8 编码，改动脚本时请保持原编码，
  否则 cmd 里的中文提示会变成乱码

---

## 七、许可

MIT License，见 [LICENSE](LICENSE)。可自由用于学习、二次开发与商业项目，
保留版权声明即可。

工程内的 `bit/dds_key_top.bit` 是按本工程源码在 Vivado 2017.4 下构建的产物，
与 `data/impl_1/` 中的时序、资源报告一一对应；重新构建可复现同一组数字。

## 八、可复现性

这不是一个"只能跑一次的截图工程"。三条证据链：

1. **静态检查**：`build/` 下有 `check_repro` 与 `check_impl` 两个脚本，
   前者核对源码、约束、比特流三者时间戳与依赖完整性，后者把当次构建结果与
   `data/impl_1/` 的基线逐项比对，超差即报错。
2. **归档原始报告**：`data/impl_1/` 保存了交付时的 5 份 Vivado 原始报告，
   未经二次编辑。WNS +3.089 ns、LUT 5.70%、功耗 0.097 W 均可直接查阅。
3. **从零重建**：把仓库克隆到任意英文路径，双击 `build/build.bat`，
   产物覆盖 `build/proj/`，WNS 与资源占用与归档报告逐项一致。

## 九、问题反馈

发现构建失败、引脚不符或指标对不上，欢迎开 Issue，附上 Vivado 版本、
操作系统与 `data/impl_1/` 里的对应报告。
