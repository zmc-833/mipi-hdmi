#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
vdepth.py —— Verilog 组合逻辑级数（流水线深度）静态自检

用途：在交给 TD 综合之前，先估算一个模块里「寄存器 → 寄存器」之间最长的
      组合赋值链有多少级。本项目 74.25MHz(13.33ns) 下，单级建议 ≤5~6 级 LUT。

为什么要用它：2026-10-07 的 image_enhance v1 就是因为在两个寄存器之间堆了
约 18 级组合（blur→diff→cored→y_dn→inc→y_sh→y_final→dmag→r_o …），
直接造成 HDMI 像素域 18 级违例路径（slack -0.057ns）。交付前跑一次即可避免。

用法：
    python tools/vdepth.py <file.v> [--top <module>] [--max 6]

原理（启发式，不是综合器，仅供预警）：
  · 把 always @(posedge ...) 里的赋值视为「寄存器」，其 LHS 记 depth=0；
  · 把 assign / wire = / always @(*) 里的赋值视为「组合节点」，
      depth = 1 + max(输入信号 depth)，每多一层推导 +1；
  · 输入端口 / 被实例驱动的 wire（如行 RAM 的输出）= 外部源，depth=0；
  · 报告 depth 最大的若干条链。

注意：单条语句内部的多操作数算术（如 77*r+150*g+29*b）会额外多 1~2 级，
      因此阈值取 6 比较保守；值只需横向对比自己模块的改动前后。
"""

import re
import sys


def strip_comments(s):
    s = re.sub(r'/\*.*?\*/', ' ', s, flags=re.S)
    s = re.sub(r'//[^\n]*', ' ', s)
    return s


def parse_module(src, top=None):
    """返回 (名字, 正文) 列表"""
    mods = []
    for m in re.finditer(r'\bmodule\s+(\w+)(.*?)\bendmodule\b', src, flags=re.S):
        mods.append((m.group(1), m.group(2)))
    if top:
        mods = [x for x in mods if x[0] == top]
    return mods


def get_ids(expr):
    return set(re.findall(r'[A-Za-z_]\w*', expr))


KEYWORDS = set('''begin end if else case endcase for while posedge negedge always
assign wire reg input output inout parameter localparam integer genvar generate
endgenerate default signed unsigned initial logic bit byte shortint int longint
and or not xor nand nor xnor buf'''.split())


def analyze(name, body, thresh):
    # ---- 找 always 块，区分时序/组合 ----
    regs, comb = set(), []      # comb: (lhs, rhs)
    inst_wires = set()          # 被实例驱动的 wire

    # 实例端口连接（.Port(sig)）与实例名
    for m in re.finditer(r'\.\s*(\w+)\s*\(\s*([^)]*?)\s*\)', body):
        pass
    # 先收集实例的输出：模块名 #(...) instname ( .O_data(net) ... )
    # 简化：把所有 .xxx( net ) 中的 net 都当"可能是实例输出"，稍后按是否有驱动修正
    inst_out = set()
    for m in re.finditer(r'\b(\w+)\s*(?:#\s*\([^;]*?\))?\s*(\w+)\s*\(([^;]*?)\)\s*;', body, flags=re.S):
        ports = m.group(3)
        for pm in re.finditer(r'\.\s*(\w+)\s*\(\s*([A-Za-z_]\w*)\s*\)', ports):
            pname, pnet = pm.group(1), pm.group(2)
            if re.match(r'(?i)^(o_|.*_out$)', pname):
                inst_out.add(pnet)

    # always 块
    for m in re.finditer(r'always\s*@\s*\(([^)]*)\)', body):
        pass

    # 用括号配平切出每个 always 块
    blocks = []
    for m in re.finditer(r'\balways\s*@\s*\(', body):
        start = m.start()
        j = m.end() - 1
        depth = 0
        while j < len(body):
            if body[j] == '(':
                depth += 1
            elif body[j] == ')':
                depth -= 1
                if depth == 0:
                    break
            j += 1
        sens = body[m.end():j]
        # 找块体：begin...end 配平，或到下一条 ;
        k = j + 1
        while k < len(body) and body[k] in ' \t\r\n':
            k += 1
        if body[k:k+5] == 'begin':
            d = 0
            p = k
            while p < len(body):
                if body[p:p+5] == 'begin' and (p == 0 or not (body[p-1].isalnum() or body[p-1] == '_')):
                    d += 1
                elif body[p:p+3] == 'end' and d > 0 and not (p+3 < len(body) and (body[p+3].isalnum() or body[p+3] == '_')):
                    d -= 1
                    if d == 0:
                        p += 3
                        break
                p += 1
            blk = body[k:p]
        else:
            p = body.find(';', k)
            blk = body[k:p+1]
        blocks.append((sens, blk))

    if 'posedge' in sens or 'negedge' in sens:
        for stmt in re.finditer(r'([A-Za-z_]\w*)\s*(?:\[[^\]]*\])?\s*(<=|=)\s*([^;]*);', blk):
            regs.add(stmt.group(1))
    else:
        for stmt in re.finditer(r'([A-Za-z_]\w*)\s*(?:\[[^\]]*\])?\s*(<=|=)\s*([^;]*);', blk):
            comb.append((stmt.group(1), stmt.group(3)))

    # 连续赋值
    for m in re.finditer(r'(?:\bassign\b|\bwire\b[^;]*?)\s+([A-Za-z_]\w*)\s*=\s*([^;]*);', body):
        comb.append((m.group(1), m.group(2)))

    # ---- 迭代求 depth ----
    depth = {}
    order = list(comb)
    for _ in range(len(order) + 2):
        changed = False
        for lhs, rhs in order:
            d = 0
            for i in get_ids(rhs):
                if i in KEYWORDS:
                    continue
                d = max(d, depth.get(i, 0))
            nd = d + 1
            if nd > depth.get(lhs, 0):
                depth[lhs] = nd
                changed = True
        if not changed:
            break

    # 源头（外部输入 / 实例输出 / 端口）不参与计数：去掉它们自身造成的 1
    srcs = inst_out | {'clk', 'rst_n'}
    items = [(v, k) for k, v in depth.items() if k not in srcs]
    items.sort(reverse=True, key=lambda x: x[0])

    print("=" * 72)
    print("模块 %s：组合推导链最深处 %d 级（阈值 %d）" % (name, items[0][0] if items else 0, thresh))
    print("-" * 72)
    for v, k in items[:8]:
        if v < 2:
            break
        print("   %-22s depth=%d" % (k, v))
    worst = items[0][0] if items else 0
    if worst > thresh:
        print("   ⚠️ 超过阈值：请把链条拆开，在中间插入寄存器（或改流水线）")
    else:
        print("   OK：单级组合在建议范围内")
    return worst


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    path = sys.argv[1]
    top = None
    thresh = 6
    if '--top' in sys.argv:
        top = sys.argv[sys.argv.index('--top') + 1]
    if '--max' in sys.argv:
        thresh = int(sys.argv[sys.argv.index('--max') + 1])

    src = strip_comments(open(path, encoding='utf-8', errors='replace').read())
    mods = parse_module(src, top)
    if not mods:
        print("未找到模块（可用 --top 指定）")
        return 2
    bad = 0
    for name, body in mods:
        if analyze(name, body, thresh) > thresh:
            bad += 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
