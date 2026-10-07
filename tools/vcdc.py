# -*- coding: utf-8 -*-
"""
tools/vcdc.py —— 跨时钟域(CDC)静态自检

【为什么有它】2026-10-07 v6.4 事故复盘：
  image_enhance 新增输入 I_ag（AE 增益，24MHz 域）后，顶层出现一条
  pll_clk_24m → HDMI_PIXEL_CLK 的寄存器到寄存器路径（r_ag_reg -> ag_s0_reg），
  3 个端点 setup 违例，WNS = -0.213ns。
  根因不是逻辑级数（Logic-Level = 0，纯走线），而是【跨时钟域且 SDC 未加约束】：
  两时钟同源于 u_PLL，被 set_clock_groups 归入同一组 ⇒ TD 按同步路径检查，
  而 74.25MHz:24MHz = 99:32 存在固定相位关系，会出现几乎重合的时钟沿，
  setup 预算只剩 0.653ns —— 这种路径靠插流水线永远收不收敛，只能按 CDC 约束。
  vlint / vdepth 都查不到这类问题，故补此工具。

【原理】纯文本静态分析（不替代综合）：
  1) clock net：顶层里出现在 `posedge/negedge X` 的 X（排除 rst/reset）。
  2) 实例时钟域 = 它"时钟端口"上连的 net；有多个时钟端口 ⇒ 多域，跳过。
  3) 每个 net 按端口方向分驱动端/接收端，得到【有向】的域对 (驱动域 → 接收域)。
  4) 读 .sdc 的 set_clock_groups / set_false_path：
       两域在【不同】异步组        → 安全（TD 本来就不查）
       两域在【同一】组 + 有 false path（方向一致）→ 通过
       两域在【同一】组 + 无 false path            → 报警（时序必挂）
     ★ 必须按【方向】匹配：只加反方向 false path 是无效的（本次事故就是这么来的）。

【用法】
  python tools/vcdc.py --root D:/GitHub/mipi-hdmi
  python tools/vcdc.py --root <repo> --wrapper <design_top_wrapper.v> --sdc <x.sdc>

【退出码】0 = 无"未覆盖的跨域连接"；1 = 存在（需人工确认或补 false path）
"""

import argparse
import os
import re
import sys


# --------------------------------------------------------------------------
# 文本预处理
# --------------------------------------------------------------------------
def strip_comments(src):
    s = re.sub(r'/\*.*?\*/', ' ', src, flags=re.S)
    s = re.sub(r'//[^\n]*', ' ', s)
    return s


def match_paren(s, i):
    """s[i] == '('，返回配对 ')' 的下标"""
    depth, n = 0, len(s)
    while i < n:
        c = s[i]
        if c == '(':
            depth += 1
        elif c == ')':
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return n - 1


def kill_param_lists(s):
    """把 `#( ... )` 参数表整体替换为一个空格（否则实例名会被参数表吃掉）"""
    out, i, n = [], 0, len(s)
    while i < n:
        if s[i] == '#':
            j = i + 1
            while j < n and s[j] in ' \t\r\n':
                j += 1
            if j < n and s[j] == '(':
                i = match_paren(s, j) + 1
                out.append(' ')
                continue
        out.append(s[i])
        i += 1
    return ''.join(out)


KEYWORDS = {
    'module', 'endmodule', 'input', 'output', 'inout', 'wire', 'reg', 'integer',
    'real', 'time', 'realtime', 'parameter', 'localparam', 'assign', 'always',
    'initial', 'case', 'casex', 'casez', 'if', 'else', 'begin', 'end', 'for',
    'while', 'repeat', 'forever', 'function', 'endfunction', 'task', 'endtask',
    'generate', 'endgenerate', 'genvar', 'defparam', 'specify', 'endspecify',
    'default', 'posedge', 'negedge', 'or', 'and', 'not', 'signed', 'unsigned',
    'return', 'buf', 'xor', 'xnor', 'nand', 'nor',
}

INST_RE = re.compile(r'\b([A-Za-z_]\w*)\s+([A-Za-z_]\w*)\s*\(')
PORT_RE = re.compile(r'\.\s*([A-Za-z_]\w*)\s*\(\s*([A-Za-z_]\w*)\s*\)')
CLK_RE = re.compile(r'\b(?:pos|neg)edge\s+([A-Za-z_]\w*)')


# --------------------------------------------------------------------------
# 顶层解析
# --------------------------------------------------------------------------
def clock_nets_of(src):
    """时钟网络 = 出现在 posedge/negedge 里的 net（排除复位类）"""
    nets = set(CLK_RE.findall(src))
    return {n for n in nets if 'rst' not in n.lower() and 'reset' not in n.lower()}


def _block_end(src, j):
    """返回从 j 开始的 always 语句体结束位置（begin..end 配对 / 或到 ';'）"""
    if not re.compile(r'\bbegin\b').match(src, j):
        k = src.find(';', j)
        return k if k >= 0 else len(src)
    depth, k, pat = 0, j, re.compile(r'\bbegin\b|\bend\b')
    while True:
        mm = pat.search(src, k)
        if not mm:
            return len(src)
        if mm.group(0) == 'begin':
            depth += 1
        else:
            depth -= 1
            if depth == 0:
                return mm.end()
        k = mm.end()


def build_always_domains(src):
    """顶层 always @(posedge CLK) 块里被赋值的 reg -> CLK（补实例分析的盲区）"""
    out = {}
    for m in re.finditer(r'\balways\s*@\s*\(([^)]*)\)', src):
        cls = {c for c in CLK_RE.findall(m.group(1))
               if 'rst' not in c.lower() and 'reset' not in c.lower()}
        if len(cls) != 1:
            continue
        clk = next(iter(cls))
        blk = src[m.end():_block_end(src, m.end())]
        for t in re.findall(r'([A-Za-z_]\w*)\s*<=', blk):
            if 'rst' not in t.lower() and 'reset' not in t.lower():
                out.setdefault(t, clk)
    return out


def parse_instances(src):
    """返回 [(module, inst, {port: net})]，只收"端口用 .name(net) 具名连接"的实例"""
    s = kill_param_lists(src)
    out, pos = [], 0
    while True:
        m = INST_RE.search(s, pos)
        if not m:
            break
        mod, inst = m.group(1), m.group(2)
        lp = m.end() - 1
        rp = match_paren(s, lp)
        if mod in KEYWORDS or inst in KEYWORDS:
            pos = m.end()
            continue
        ports = {p: n for p, n in PORT_RE.findall(s[lp + 1:rp])}
        if ports:
            out.append((mod, inst, ports))
        pos = rp + 1
    return out


def build_port_dirs(root):
    """扫描 user_source 下所有 .v，建立 module -> {port: input|output|inout}"""
    dirs = {}
    hdl = os.path.join(root, 'user_source')
    if not os.path.isdir(hdl):
        return dirs
    for dp, dn, fn in os.walk(hdl):
        dn[:] = [d for d in dn if d != '.git']
        for f in fn:
            if not f.lower().endswith(('.v', '.sv')):
                continue
            try:
                src = strip_comments(open(os.path.join(dp, f),
                                          encoding='utf-8', errors='ignore').read())
            except OSError:
                continue
            for m in re.finditer(r'\bmodule\s+([A-Za-z_]\w*)', src):
                name = m.group(1)
                if name in dirs:
                    continue
                st = m.start()
                en = src.find('endmodule', st)
                body = src[st:en if en > 0 else len(src)]
                d = {}
                # 注：本工程统一 ANSI 风格（方向写在端口表里），故按 [^,;)] 截断
                for pm in re.finditer(r'\b(input|output|inout)\b([^,;)]*)', body):
                    txt = re.sub(r'\[[^\]]*\]', ' ', pm.group(2))
                    txt = re.sub(r'\b(wire|reg|signed|unsigned|integer|logic|bit)\b',
                                 ' ', txt)
                    names = re.findall(r'[A-Za-z_]\w*', txt)
                    if names:
                        d[names[-1]] = pm.group(1)
                dirs[name] = d
    return dirs


# --------------------------------------------------------------------------
# SDC 解析
# --------------------------------------------------------------------------
def parse_sdc(path):
    txt = open(path, encoding='utf-8', errors='ignore').read()
    txt = re.sub(r'\\\s*\n', ' ', txt)     # 拼续行
    txt = re.sub(r'#[^\n]*', '', txt)      # 去 # 注释
    groups, false_paths, clocks = [], set(), set()
    for line in txt.splitlines():
        line = line.strip()
        if line.startswith('set_clock_groups'):
            # 一条 set_clock_groups 的每个 -group 子句 = 一个"同步组"；
            # 展平成 groups = [组1, 组2, ...]，两时钟同组 ⇒ TD 按同步路径检查。
            for g in re.findall(r'-group\s*\[\s*get_clocks\s*\{([^}]*)\}', line):
                groups.append(set(g.split()))
        elif line.startswith('set_false_path'):
            f = re.search(r'-from\s*\[\s*get_clocks\s*\{([^}]*)\}', line)
            t = re.search(r'-to\s*\[\s*get_clocks\s*\{([^}]*)\}', line)
            if f and t:
                for a in f.group(1).split():
                    for b in t.group(1).split():
                        false_paths.add((a, b))     # 有向！
        elif line.startswith(('create_clock', 'rename_clock')):
            for c in re.findall(r'-name\s*\{([^}]*)\}', line):
                clocks.add(c)
    return groups, false_paths, clocks


def same_group(a, b, groups):
    for g in groups:
        if a in g and b in g:
            return True
    return False


_GENERIC = {'clk', 'clock', 's', 'i', 'o', 'p', 'n', 'pad', 'net', 'int', 'ext'}


def _tokens(x):
    return {t for t in re.split(r'[^0-9A-Za-z]+', x.lower())
            if t and t not in _GENERIC}


def map_domain(net, sdc_clocks):
    """把顶层的时钟 net 名映射到 .sdc 里的时钟名（按共同特征 token 打分）"""
    best, score, tn = None, 0, _tokens(net)
    for c in sorted(sdc_clocks):
        sc = len(tn & _tokens(c))
        if sc > score:
            best, score = c, sc
    return best


# --------------------------------------------------------------------------
# 主分析
# --------------------------------------------------------------------------
def _fmt_dom(d, mod):
    return "%s(%s)" % (mod or d, d)


def analyze(root, wrapper, sdc_path):
    src = strip_comments(open(wrapper, encoding='utf-8', errors='ignore').read())
    clks = clock_nets_of(src)
    insts = parse_instances(src)
    groups, false_paths, sdc_clocks = parse_sdc(sdc_path)
    port_dirs = build_port_dirs(root)

    inst_dom, inst_mod, multi = {}, {}, []
    for mod, inst, ports in insts:
        inst_mod[inst] = mod
        ds = {n for n in ports.values() if n in clks}
        if len(ds) == 1:
            inst_dom[inst] = next(iter(ds))
        elif len(ds) > 1:
            multi.append((inst, sorted(ds)))
        else:
            inst_dom[inst] = None

    net_conn = {}
    for _mod, inst, ports in insts:
        for p, n in ports.items():
            if n in clks:
                continue
            net_conn.setdefault(n, []).append((inst, p))

    always_dom = build_always_domains(src)   # 顶层 always 块驱动的信号

    print("=" * 78)
    print("CDC 自检: %s" % root)
    print("  wrapper : %s" % os.path.relpath(wrapper, root).replace('\\', '/'))
    print("  sdc     : %s" % os.path.relpath(sdc_path, root).replace('\\', '/'))
    print("  实例 %d 个（多时钟域 %d 个已跳过）；clock net %d 个：%s"
          % (len(insts), len(multi), len(clks), ', '.join(sorted(clks))))
    print("-" * 78)

    bad, warn, ok = [], [], []
    for n, lst in sorted(net_conn.items()):
        drv, ld, alldom = {}, {}, set()
        if n in always_dom:                     # 顶层 always 块驱动
            alldom.add(always_dom[n])
            drv.setdefault(always_dom[n], []).append('(顶层 always 块)')
        for inst, p in lst:
            d = inst_dom.get(inst)
            if not d:
                continue
            alldom.add(d)
            dirn = port_dirs.get(inst_mod[inst], {}).get(p)
            tag = "%s.%s" % (inst, p)
            if dirn == 'input':
                ld.setdefault(d, []).append(tag)
            elif dirn in ('output', 'inout'):
                drv.setdefault(d, []).append(tag)
            else:                       # 方向未知 -> 两侧都记，偏保守
                drv.setdefault(d, []).append(tag + '?')
                ld.setdefault(d, []).append(tag + '?')
        if len(alldom) < 2:
            continue

        verdicts, worst = [], 0        # 0=ok, 1=warn, 2=bad
        for a in sorted(drv):
            for b in sorted(ld):
                if a == b:
                    continue
                ma, mb = map_domain(a, sdc_clocks), map_domain(b, sdc_clocks)
                if ma is None or mb is None:
                    verdicts.append((a, b, ma, mb, '?'))
                    worst = max(worst, 1)
                    continue
                if same_group(ma, mb, groups):
                    if (ma, mb) in false_paths:
                        verdicts.append((a, b, ma, mb, 'fp'))
                    else:
                        verdicts.append((a, b, ma, mb, 'BAD'))
                        worst = max(worst, 2)
                else:
                    verdicts.append((a, b, ma, mb, 'async'))
        if not verdicts:
            continue
        item = (n, drv, ld, verdicts)
        (bad if worst == 2 else warn if worst == 1 else ok).append(item)

    def show(item, mark):
        n, drv, ld, verdicts = item
        print("  %s %s" % (mark, n))
        for d, users in sorted(drv.items()):
            print("        驱动 域 %-18s <- %s" % (d, ', '.join(sorted(users))))
        for d, users in sorted(ld.items()):
            print("        接收 域 %-18s <- %s" % (d, ', '.join(sorted(users))))
        for a, b, ma, mb, v in verdicts:
            if v == 'BAD':
                print("        !! %s -> %s 在 SDC 里【同组】(=%s -> %s) 会被按同步路径检查，"
                      % (a, b, ma, mb))
                print("           但没有【方向一致】的 false path → 时序必挂（纯走线也收不收敛）")
            elif v == '?':
                print("        ?? %s -> %s 无法映射到 SDC 时钟名，请人工确认" % (a, b))
            elif v == 'fp':
                print("        ok %s -> %s 同组但已有 false path (%s -> %s)" % (a, b, ma, mb))
            else:
                print("        ok %s -> %s 分属不同异步组，安全" % (a, b))

    for it in bad:
        show(it, "[X]")
    for it in warn:
        show(it, "[?]")
    for it in ok:
        show(it, "[v]")

    print("-" * 78)
    if bad:
        print("结论：发现 %d 条【未覆盖的跨时钟域连接】—— 需在 .sdc 补 "
              "set_false_path（方向要与驱动->接收一致），且跨域信号在接收端需 >=2 级同步"
              % len(bad))
        return 1
    print("结论：未发现未覆盖的跨时钟域连接（跨域 %d 条，均已约束/异步组，见上表）"
          % len(ok))
    return 0


def main():
    ap = argparse.ArgumentParser(description="跨时钟域(CDC)静态自检")
    ap.add_argument('--root', default='.', help="仓库根目录（默认当前目录）")
    ap.add_argument('--wrapper', default=None,
                    help="顶层文件（默认自动找 design_top_wrapper.v）")
    ap.add_argument('--sdc', default=None, help="约束文件（默认 td_project/*.sdc）")
    a = ap.parse_args()

    root = os.path.abspath(a.root)
    wrapper = a.wrapper
    if not wrapper:
        for dp, dn, fn in os.walk(root):
            dn[:] = [d for d in dn if d != '.git']
            for f in fn:
                if f == 'design_top_wrapper.v':
                    wrapper = os.path.join(dp, f)
                    break
            if wrapper:
                break
    sdc_path = a.sdc
    if not sdc_path:
        td = os.path.join(root, 'td_project')
        if os.path.isdir(td):
            cands = sorted(f for f in os.listdir(td) if f.endswith('.sdc'))
            if cands:
                sdc_path = os.path.join(td, cands[0])

    if not wrapper or not os.path.isfile(wrapper):
        raise SystemExit("找不到顶层文件，请用 --wrapper 指定")
    if not sdc_path or not os.path.isfile(sdc_path):
        raise SystemExit("找不到 .sdc，请用 --sdc 指定")

    sys.exit(analyze(root, wrapper, sdc_path))


if __name__ == '__main__':
    main()
