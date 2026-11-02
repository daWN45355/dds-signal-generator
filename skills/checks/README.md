# 校验脚本

两个脚本，都是**在综合之前就能发现问题**，省掉一轮 4 分钟的往返。

| 脚本 | 回答什么问题 | 依赖 |
|---|---|---|
| `check_repro.py` | 这个工程别人拿到能不能跑起来？我手里的 bit 是不是当前代码编的？ | 无（仅标准库） |
| `check_impl.py` | 这次实现比上次好还是差了？时序/资源有没有偷偷回退？ | 无（仅标准库），需 Vivado 报告 |

---

## check_repro.py —— 可复现性检查

### 它查四件事

1. **例化模块是否都有源文件**。这是本项目真实踩过的坑：
   `phase7` 工程从 `phase4` 复制过来时，`key_debounce.v` 还在 `phase6` 的目录里，
   综合时才报 `module 'key_debounce' not found`，白等一轮。
2. **顶层端口是否都被 XDC 约束**。改了端口忘了改约束，Vivado 不一定报错，
   有时会按默认位置布线，上板才发现引脚不对。
3. **bit 是否比源文件新**。判断“我烧的这份 bit 到底是不是当前代码”，
   这个问题在反复迭代时出现频率极高，靠人工看时间戳容易看错。
4. **构建脚本与约束文件是否存在**。

### 用法

```bash
python check_repro.py --proj D:\fpga\phase7_keyctl
python check_repro.py --proj D:\fpga\phase7_keyctl --top dds_key_top   # 手动指定顶层
```

顶层默认自动判定为“没有被任何模块例化的那个模块”。

### 已验证效果

**在本项目 `phase7_keyctl` 上：**

```
源文件: 11 个，共 2274 行
  [OK]   build.tcl 存在
  [OK]   pins.xdc 存在
  [OK]   工程目录有构建入口脚本（build.bat）
  [OK]   所有例化模块均有源文件（11 个模块，15 处例化）
  [OK]   顶层 dds_key_top 的 11 个端口全部已约束
  [OK]   bit 与源文件时间差 0.0 s，在容差 10 s 内（整批拷贝/解压所致，时间戳不可判定，未计为问题）
结论：可复现性检查通过
```

第三条检查（bit 是不是最新代码编的）有个 10 秒容差，这是踩出来的：
把工程打成 zip 发给别人，对方解压后整批文件的 mtime 会被重写成同一时刻，
源码和 .bit 只差零点几秒，严格比较必然误报"bit 过期"。
而真实场景下改完源码忘了重编，差值会立刻拉到分钟级 —— 实测把源码推到
bit 之后 60 s，脚本仍正常报 `[FAIL] 源文件比 bit 新 1.0 分钟`。
所以容差只吞掉秒级噪音，不掩盖真问题。

**在一个故意构造的坏工程上**（顶层例化了不存在的 `key_debounce`、`led` 端口未约束）：

```
  [FAIL] top.v 例化了 key_debounce（实例 u_kd），但 src/ 里没有这个模块
  [FAIL] 顶层 top 有 1 个端口未在 XDC 中约束：led
结论：2 项问题需要处理
```

两个真实故障都被抓到，说明检测逻辑有效。

### 失效条件

- **只认 `src/` `rtl/` `hdl/` 三个目录名**。用别的目录名需要改 `VERILOG_DIRS`。
- **模块检测基于正则，不是完整 Verilog 解析**。以下情况会误判：
  - 用 `generate` 动态例化（模块名是变量）；
  - 例化时模块名与实例名之间没有空格（如 `foo u_foo(` 有空格，OK；`foou_foo(` 不合法，不会出现）；
  - 使用厂商原语（`IBUF` `BUFG` `MMCME2_BASE` 等）。脚本已放行全大写开头的标识符，
    但如果原语是小写命名，需要手动加白名单。
- **端口检查只解析 ANSI 风格端口列表**（`module x (input wire a, ...)`）。
  老式非 ANSI 写法（端口名与方向分开声明）会解析不全，此时结果不可信。

---

## check_impl.py —— 实现结果与基线比对

### 它做什么

从 `*_timing_summary_routed.rpt` 读 WNS/TNS/WHS/THS，
从 `*_utilization_placed.rpt` 读 LUT/FF/BRAM/DSP/IOB，
打印成一张表，并与 `baseline.json` 比对。**回退就报警，退出码非 0**，
可以直接挂到 CI 或提交前脚本里。

### 用法

```bash
# 第一次：建立基线
python check_impl.py --proj D:\fpga\phase7_keyctl --init

# 之后每次实现完跑一次
python check_impl.py --proj D:\fpga\phase7_keyctl

# 只看结果，不比对
python check_impl.py --proj D:\fpga\phase7_keyctl --no-baseline
```

判定阈值写在文件顶部，可按项目调整：

```python
WNS_DROP_TOL    = 0.30   # WNS 允许下降 0.30 ns
RES_INC_TOL_PCT = 2.0    # 任一资源占用率允许增加 2 个百分点
```

### 已验证效果

本项目 `phase7_keyctl` 的实测输出：

```
  WNS +3.089 ns    TNS 0.000 ns
  WHS +0.121 ns    THS 0.000 ns
  关键路径 16.911 ns（按 20 ns 约束估算最高约 59.1 MHz）
----------------------------------------------------------
  LUT      1003 / 17600    5.70 %  Δ+0.00pp
  FF        677 / 35200    1.92 %  Δ+0.00pp
  BRAM        1 / 60       1.67 %  Δ+0.00pp
  DSP         6 / 80       7.50 %  Δ+0.00pp
  IOB        11 / 100     11.00 %  Δ+0.00pp
[PASS] 与基线一致（时序未回退、资源未超容差）
```

这些数字与报告正文表 5-3、表 5-4 完全一致，说明脚本读数可信。

### 失效条件

- **只能解析 `impl_1` 目录下的 routed/placed 报告**。跑综合没跑实现时没有这些文件。
- **依赖报告文本格式**。Vivado 2019+ 的报告表头列顺序有变化，
  需要改 `parse_timing()` 里按列号取值的部分。正则已集中在函数内，便于修改。
- **不做智能根因分析**。它只告诉你“回退了 0.5 ns”，不告诉你是哪条路径。
  定位瓶颈请用 `01_prompts/` 的模板 2。
- **基线是单工程的**。多工程共用一份 `baseline.json` 会互相覆盖，
  建议每个工程目录放一份脚本副本，或用 `--init` 时先备份。
