#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
check_repro.py —— 检查工程可复现性

解决的问题（都是本项目实际踩过的）：
  1. 例化了某个模块，但源文件没拷进 src/ —— 综合时才会报 "module not found"，
     一次往返好几分钟。本脚本在综合前就能查出来。
  2. 顶层端口改了，XDC 却没同步 —— 实现时报 unrouted port 或直接按默认位置布线。
  3. 手里的 .bit 是上一版代码编出来的 —— 上板现象和源码对不上，排查方向全错。
  4. 构建脚本、约束文件缺失 —— 别人拿到工程根本跑不起来。

用法：
    python check_repro.py --proj D:\\fpga\\phase7_keyctl
    python check_repro.py --proj D:\\fpga\\phase7_keyctl --top dds_key_top

退出码：0 通过；1 有问题；2 目录结构不对。
依赖：只用标准库。
"""
import argparse
import os
import re
import sys

VERILOG_DIRS = ('src', 'rtl', 'hdl')

# 时间戳容差（秒）。压缩包解压、整目录拷贝会把一批文件的 mtime 重置到
# 几乎同一时刻，源码与 .bit 只差几秒并不代表"改过代码没重编译"。
# 真实场景下改完源码不重编，差值会立刻拉开到分钟级，所以 10 s 够用。
TS_TOL_S = 10.0

KEYWORDS = {
    'always', 'always_ff', 'always_comb', 'assign', 'initial', 'begin', 'end',
    'if', 'else', 'case', 'casex', 'casez', 'endcase', 'for', 'while', 'repeat',
    'module', 'endmodule', 'input', 'output', 'inout', 'wire', 'reg', 'integer',
    'parameter', 'localparam', 'posedge', 'negedge', 'or', 'and', 'not',
    'function', 'endfunction', 'task', 'endtask', 'generate', 'endgenerate',
    'genvar', 'default', 'signed', 'unsigned', 'define', 'include', 'timescale',
}


def read(p):
    for enc in ('utf-8', 'gbk', 'latin-1'):
        try:
            with open(p, encoding=enc) as fh:
                return fh.read()
        except UnicodeDecodeError:
            continue
    return ''


def find_src_dirs(proj):
    out = []
    for d in VERILOG_DIRS:
        p = os.path.join(proj, d)
        if os.path.isdir(p):
            out.append(p)
    return out


def collect_sources(dirs):
    files = []
    for d in dirs:
        for f in sorted(os.listdir(d)):
            if f.endswith(('.v', '.sv')):
                files.append(os.path.join(d, f))
    return files


def declared_modules(files):
    """文件名 -> 模块名列表"""
    mods = {}
    for f in files:
        text = read(f)
        for m in re.finditer(r'\bmodule\s+([A-Za-z_]\w*)', text):
            mods.setdefault(m.group(1), []).append(os.path.basename(f))
    return mods


def top_ports(text, top):
    """解析 ANSI 端口列表，返回端口名集合"""
    m = re.search(r'\bmodule\s+' + re.escape(top) + r'\b(.*?)\)\s*;', text, re.S)
    if not m:
        return set()
    body = m.group(1)
    # 去掉端口声明里的位宽与方向，按逗号切分后取最后一个标识符
    ports = set()
    for seg in body.split(','):
        seg = re.sub(r'//.*', '', seg)
        seg = re.sub(r'\[[^\]]*\]', ' ', seg)
        seg = re.sub(r'\b(input|output|inout|wire|reg|signed|unsigned)\b', ' ', seg)
        ids = re.findall(r'[A-Za-z_]\w*', seg)
        if ids:
            ports.add(ids[-1])
    return ports


# 模块名与实例名之间必须至少有一个空白字符，否则 `case (` / `if (` 会被
# 正则回溯切成 `cas`+`e`、`i`+`f`，产生大量假例化。
INST_RE = re.compile(
    r'^\s*([A-Za-z_]\w*)\s+(?:#\s*\((?:[^;]*?)\)\s*)?([A-Za-z_]\w*)\s*\(',
    re.M)


def instances(files):
    """返回 [(模块名, 例化名, 文件名)]"""
    out = []
    for f in files:
        text = read(f)
        text = re.sub(r'//[^\n]*', '', text)
        text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
        for m in INST_RE.finditer(text):
            name, inst = m.group(1), m.group(2)
            if name in KEYWORDS or inst in KEYWORDS:
                continue
            if name in ('module', 'assign', 'always'):
                continue
            out.append((name, inst, os.path.basename(f)))
    return out


def xdc_ports(proj):
    """从 pins.xdc 里收集所有 get_ports 引用的端口名"""
    names = set()
    for f in os.listdir(proj):
        if not f.endswith('.xdc'):
            continue
        text = read(os.path.join(proj, f))
        for m in re.finditer(r'\[get_ports\s+\{?([^\]\}]*)', text):
            for n in re.split(r'[\s{}]+', m.group(1).strip()):
                if n:
                    names.add(n)
    return names


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--proj', default='.', help='工程根目录')
    ap.add_argument('--top', default=None, help='顶层模块名（默认自动取端口最多的模块）')
    args = ap.parse_args()

    proj = os.path.abspath(args.proj)
    if not os.path.isdir(proj):
        print('[ERR] 目录不存在：', proj)
        return 2

    src_dirs = find_src_dirs(proj)
    if not src_dirs:
        print('[ERR] 找不到 src/ rtl/ hdl/ 任一源码目录')
        return 2
    files = collect_sources(src_dirs)
    if not files:
        print('[ERR] 源码目录里没有 .v/.sv 文件')
        return 2

    problems, warns, oks = [], [], []
    print('=' * 60)
    print('工程:', proj)
    print('源文件:', len(files), '个，共',
          sum(len(read(f).splitlines()) for f in files), '行')
    print('=' * 60)

    # ---- 1. 构建脚本与约束 ----
    # 目录布局有两种常见形态：
    #   a) 扁平：build.tcl / pins.xdc 与 src/ 同级
    #   b) 赛题 3.3.5.4 推荐：build/ 放脚本、constr/ 放约束、src/ 放源码
    # 两种都要认。只认扁平布局会在 b 形态上误报"缺少构建脚本"，
    # 而误报比漏报更有害 —— 别人会先去怀疑包坏了。
    walked = []
    for root, dirs, fs in os.walk(proj):
        dirs[:] = [d for d in dirs
                   if not d.startswith('.') and d not in ('proj', 'xsim.dir', '__pycache__')]
        rel = os.path.relpath(root, proj)
        depth = 0 if rel == '.' else rel.count(os.sep) + 1
        if depth > 2:
            dirs[:] = []
            continue
        for n in fs:
            walked.append((depth, '' if rel == '.' else rel, n))
    walked.sort()

    def find_one(names, max_depth=2):
        for d in range(max_depth + 1):
            for depth, rel, n in walked:
                if depth == d and n in names:
                    return os.path.normpath(os.path.join(rel, n)) if rel else n
        return None

    bt = find_one(('build.tcl', 'build_flow.tcl'))
    if bt:
        oks.append(f'构建脚本 {bt} 存在')
    else:
        problems.append('缺少 build.tcl，别人无法重建工程')

    xdc = find_one(('pins.xdc',)) or next(
        (os.path.normpath(os.path.join(rel, n)) if rel else n
         for depth, rel, n in walked if n.endswith('.xdc')), None)
    if xdc:
        oks.append(f'约束文件 {xdc} 存在')
    else:
        problems.append('缺少 .xdc 约束文件，别人无法重建工程')

    entry = find_one(('build.bat', 'build.sh', 'Makefile', 'makefile'))
    if entry:
        oks.append(f'构建入口 {entry} 存在')
    else:
        warns.append('没有找到 build.bat/build.sh/Makefile（若用 IDE 手动构建可忽略）')

    # ---- 2. 模块完整性 ----
    mods = declared_modules(files)
    insts = instances(files)
    missing = set()
    for name, inst, f in insts:
        if name in mods or name in ('IBUF', 'OBUF', 'BUFG', 'IBUFG'):
            continue
        # 排除大写开头、看起来是宏/原语的
        if name.isupper() or name[0].isupper():
            continue
        missing.add((name, inst, f))
    if missing:
        for name, inst, f in sorted(missing):
            problems.append(f'{f} 例化了 {name}（实例 {inst}），但 src/ 里没有这个模块')
    else:
        oks.append(f'所有例化模块均有源文件（{len(mods)} 个模块，{len(insts)} 处例化）')

    # ---- 3. 顶层端口是否全部约束 ----
    if args.top:
        top = args.top
    else:
        # 顶层 = 没有被任何模块例化的那个模块
        used = {name for name, _i, _f in insts}
        cands = [m for m in mods if m not in used]
        top = cands[0] if len(cands) == 1 else (cands[0] if cands else None)
        if len(cands) > 1:
            warns.append(f'有 {len(cands)} 个模块未被例化，默认用 {top}；'
                         f'可用 --top 指定（候选：{", ".join(cands)}）')
    txt_top = ''
    for f in files:
        if re.search(r'\bmodule\s+' + re.escape(top) + r'\b', read(f)):
            txt_top = read(f)
            break
    ports = top_ports(txt_top, top)
    xp = xdc_ports(proj)
    if ports and xp:
        un = sorted(ports - xp)
        if un:
            problems.append(f'顶层 {top} 有 {len(un)} 个端口未在 XDC 中约束：{", ".join(un)}')
        else:
            oks.append(f'顶层 {top} 的 {len(ports)} 个端口全部已约束')

    # ---- 4. bit 与源码的新旧关系 ----
    bits = []
    for root, _d, fs in os.walk(proj):
        for f in fs:
            if f.endswith('.bit'):
                bits.append(os.path.join(root, f))
    if bits:
        newest_bit = max(bits, key=os.path.getmtime)
        newest_src = max(files + [os.path.join(proj, x) for x in os.listdir(proj)
                                  if x.endswith('.xdc')], key=os.path.getmtime)
        dt = os.path.getmtime(newest_src) - os.path.getmtime(newest_bit)
        if dt > TS_TOL_S:
            problems.append(
                f'源文件比 bit 新 {dt/60:.1f} 分钟，当前 bit 不是最新代码编译的\n'
                f'     源码最新: {os.path.basename(newest_src)} '
                f'{_ts(newest_src)}\n'
                f'     bit     : {os.path.basename(newest_bit)} {_ts(newest_bit)}')
        elif dt > 0:
            # 压缩包解压、整目录拷贝会把一批文件的 mtime 重置到几乎同一时刻，
            # 秒级差值不代表"改过源码没重编译"，据此判 FAIL 属于误报。
            oks.append(f'bit 与源文件时间差 {dt:.1f} s，在容差 {TS_TOL_S:.0f} s 内'
                       f'（整批拷贝/解压所致，时间戳不可判定，未计为问题）')
        else:
            oks.append(f'bit 时间晚于全部源文件（{os.path.basename(newest_bit)} {_ts(newest_bit)}）')
    else:
        warns.append('未找到 .bit —— 还没构建过，或产物在别处')

    # ---- 输出 ----
    for s in oks:
        print('  [OK]  ', s)
    for s in warns:
        print('  [WARN]', s)
    for s in problems:
        print('  [FAIL]', s)
    print('=' * 60)
    if problems:
        print(f'结论：{len(problems)} 项问题需要处理')
        return 1
    print('结论：可复现性检查通过')
    return 0


def _ts(p):
    import datetime
    return datetime.datetime.fromtimestamp(os.path.getmtime(p)).strftime('%m-%d %H:%M:%S')


if __name__ == '__main__':
    sys.exit(main())
