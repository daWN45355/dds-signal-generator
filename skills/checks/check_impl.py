#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
check_impl.py —— 解析 Vivado 实现报告，与基线比对资源占用与时序

解决的问题：每次改完代码都要人工翻 *_timing_summary_routed.rpt 和
*_utilization_placed.rpt，既慢又容易漏看“WNS 从 +3.0 掉到 +0.2”这种隐性回退。
本脚本把这两个报告的关键数字抽出来，和上一次的基线做差，回退就报警。

用法：
    # 第一次：把当前结果存成基线
    python check_impl.py --proj D:\\fpga\\phase7_keyctl --init

    # 之后每次改完跑一次
    python check_impl.py --proj D:\\fpga\\phase7_keyctl

    # 只看不比对
    python check_impl.py --proj D:\\fpga\\phase7_keyctl --no-baseline

退出码：0 全部通过；1 有时序或资源回退；2 报告文件找不到或解析失败。

依赖：只用标准库。
"""
import argparse
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
BASELINE = os.path.join(HERE, 'baseline.json')

# ---- 回退判定阈值（可按项目调整）----
WNS_DROP_TOL = 0.30      # WNS 允许下降 0.30 ns
RES_INC_TOL_PCT = 2.0    # 任一资源占用率允许增加 2 个百分点


def find_reports(proj_dir):
    """在 proj 目录下找时序总结报告与利用率报告（不限工程名）"""
    tim = util = None
    for root, _dirs, files in os.walk(proj_dir):
        if os.path.basename(root) != 'impl_1':
            continue
        for f in files:
            if f.endswith('_timing_summary_routed.rpt'):
                tim = os.path.join(root, f)
            elif f.endswith('_utilization_placed.rpt'):
                util = os.path.join(root, f)
    return tim, util


def parse_timing(path):
    """从 Design Timing Summary 表里读 WNS/TNS/WHS/THS"""
    with open(path, encoding='utf-8', errors='ignore') as fh:
        text = fh.read()
    i = text.find('Design Timing Summary')
    if i < 0:
        return None
    lines = text[i:i + 1200].splitlines()
    for k, line in enumerate(lines):
        s = line.strip()
        # 找到纯 '- ' 组成的分隔行，下一行就是数值行
        if s and set(s) <= set('- ') and len(s) > 10:
            vals = lines[k + 1].split()
            if len(vals) >= 4:
                try:
                    return {'WNS': float(vals[0]), 'TNS': float(vals[1]),
                            'WHS': float(vals[4]), 'THS': float(vals[5])}
                except (ValueError, IndexError):
                    return None
    return None


# (报告里的行首关键字, 输出用的键名, 是否取 Util%)
RES_KEYS = [
    ('Slice LUTs', 'LUT'),
    ('Slice Registers', 'FF'),
    ('Block RAM Tile', 'BRAM'),
    ('DSPs', 'DSP'),
    ('Bonded IOB', 'IOB'),
]


def parse_util(path):
    """从利用率报告里读 Used / Available / Util%"""
    out = {}
    with open(path, encoding='utf-8', errors='ignore') as fh:
        for line in fh:
            if not line.startswith('|'):
                continue
            cells = [c.strip() for c in line.strip().strip('|').split('|')]
            if len(cells) < 4:
                continue
            name = cells[0]
            for key, short in RES_KEYS:
                if name == key:
                    try:
                        out[short] = {'used': int(cells[1]),
                                      'avail': int(cells[3]),
                                      'pct': float(cells[4])}
                    except (ValueError, IndexError):
                        pass
    return out


def fmt_row(name, cur, base=None):
    used, avail, pct = cur['used'], cur['avail'], cur['pct']
    extra = ''
    if base:
        d = pct - base['pct']
        extra = f'  Δ{pct - base["pct"]:+.2f}pp'
    return f'  {name:<6} {used:>6} / {avail:<6} {pct:>6.2f} %{extra}'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--proj', default='.', help='工程根目录（含 proj/ 子目录）')
    ap.add_argument('--init', action='store_true', help='把当前结果存为基线')
    ap.add_argument('--no-baseline', action='store_true', help='不做基线比对')
    args = ap.parse_args()

    tim_p, util_p = find_reports(args.proj)
    if not tim_p:
        print('[ERR] 找不到 *_timing_summary_routed.rpt，先跑一次实现')
        return 2
    timing = parse_timing(tim_p)
    if not timing:
        print('[ERR] 时序报告格式无法识别：', tim_p)
        return 2
    util = parse_util(util_p) if util_p else {}

    print('=' * 58)
    print('实现结果:', os.path.relpath(tim_p, args.proj))
    print('=' * 58)
    print(f'  WNS {timing["WNS"]:+.3f} ns    TNS {timing["TNS"]:.3f} ns')
    print(f'  WHS {timing["WHS"]:+.3f} ns    THS {timing["THS"]:.3f} ns')
    if timing['WNS'] > 0:
        fmax = 1000.0 / (20.0 - timing['WNS']) if timing['WNS'] < 20 else 0
        print(f'  关键路径 {20 - timing["WNS"]:.3f} ns（按 20 ns 约束估算最高约 {fmax:.1f} MHz）')

    if util:
        print('-' * 58)
        base_util = {}
        base_timing = {}
        if os.path.exists(BASELINE) and not args.no_baseline:
            with open(BASELINE, encoding='utf-8') as fh:
                bl = json.load(fh)
            base_util = bl.get('util', {})
            base_timing = bl.get('timing', {})
        for short in ('LUT', 'FF', 'BRAM', 'DSP', 'IOB'):
            if short in util:
                print(fmt_row(short, util[short], base_util.get(short)))

    # ---- 比对 ----
    fails = []
    if os.path.exists(BASELINE) and not args.no_baseline and not args.init:
        with open(BASELINE, encoding='utf-8') as fh:
            bl = json.load(fh)
        b_w = bl.get('timing', {}).get('WNS')
        if b_w is not None and timing['WNS'] < b_w - WNS_DROP_TOL:
            fails.append(f'WNS 回退 {timing["WNS"] - b_w:+.3f} ns '
                         f'(基线 {b_w:+.3f}，容差 {WNS_DROP_TOL})')
        for short, cur in util.items():
            b = bl.get('util', {}).get(short)
            if b and cur['pct'] > b['pct'] + RES_INC_TOL_PCT:
                fails.append(f'{short} 占用增加 {cur["pct"] - b["pct"]:+.2f} pp '
                             f'(基线 {b["pct"]:.2f}%，容差 {RES_INC_TOL_PCT})')

    print('=' * 58)
    if args.init:
        data = {'timing': timing, 'util': util,
                'source': os.path.basename(os.path.dirname(tim_p))}
        with open(BASELINE, 'w', encoding='utf-8') as fh:
            json.dump(data, fh, ensure_ascii=False, indent=2)
        print('[OK] 基线已写入', os.path.relpath(BASELINE, HERE))
        return 0
    if fails:
        print('[FAIL] 发现回退：')
        for f in fails:
            print('   -', f)
        return 1
    if os.path.exists(BASELINE) and not args.no_baseline:
        print('[PASS] 与基线一致（时序未回退、资源未超容差）')
    else:
        print('[INFO] 无基线，仅输出结果。运行 --init 可建立基线。')
    return 0


if __name__ == '__main__':
    sys.exit(main())
