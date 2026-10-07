# -*- coding: utf-8 -*-
"""
vlint.py —— FPGA 工程轻量 Verilog 自检（不替代综合，只为在 TD 编译前抓笔误）

背景：2026-10-07 awb_frame.v 第一版把输出寄存写成 O_data / O_valid（真名是
      O_tdata / O_tvalid），还错把 divider IP 的 quotient(48bit) 声明成 80bit，
      一编译就是 5 条 Error。这个脚本用来在提交编译前把这类问题扫出来。

用法：
  # 1) 声明检查：所有"赋值目标"(<= 左侧 / assign 左侧) 必须能找到声明
  python tools/vlint.py decl <file1.v> [file2.v ...]

  # 2) 接口比对：实例化时的 .端口名 / parameter 名 必须与模块定义一致
  python tools/vlint.py iface <顶层文件.v> <模块名> <模块定义文件.v>

例：
  python tools/vlint.py decl  user_source/hdl_source/awb_fix/awb_frame.v
  python tools/vlint.py iface user_source/hdl_source/isp/isp_top.v awb_frame \
                             user_source/hdl_source/awb_fix/awb_frame.v

注意：只做文本级静态匹配，宏/`include/生成语句不解析。
"""
import re
import sys


def strip_comments(src):
    src = re.sub(r'/\*.*?\*/', ' ', src, flags=re.S)
    return re.sub(r'//[^\n]*', ' ', src)


def read(path):
    with open(path, encoding='utf-8', errors='ignore') as f:
        return strip_comments(f.read())


def collect_decls(src):
    """收集所有声明出来的符号名（信号 + 参数 + 函数）"""
    decl = set()
    for m in re.finditer(r'\b(input|output|inout|wire|reg|integer)\b([^;]*);', src):
        body = re.sub(r'\[[^\]]*\]', ' ', m.group(2))
        body = re.sub(r'\b(signed|unsigned|wire|reg|integer|input|output|inout)\b', ' ', body)
        decl.update(re.findall(r'[A-Za-z_]\w*', body))
    for m in re.finditer(r'\b(?:parameter|localparam)\b(?:\s+(?:signed|unsigned|integer|real|realtime|time))*\s*(?:\[[^\]]*\]\s*)?([A-Za-z_]\w*)', src):
        decl.add(m.group(1))
    for m in re.finditer(r'\bfunction\b\s*(?:\[[^\]]*\]\s*)?([A-Za-z_]\w*)', src):
        decl.add(m.group(1))
    return decl


def check_decl(path):
    src = read(path)
    decl = collect_decls(src)

    targets = []
    for m in re.finditer(r'([A-Za-z_]\w*)\s*<=', src):
        targets.append((m.group(1), src[:m.start()].count('\n') + 1))
    for m in re.finditer(r'\bassign\s+([A-Za-z_]\w*)', src):
        targets.append((m.group(1), src[:m.start()].count('\n') + 1))

    bad = sorted({(n, l) for n, l in targets if n not in decl})
    print(f"[decl] {path}")
    print(f"       声明符号 {len(decl)} 个，赋值目标 {len(targets)} 个")
    if bad:
        print("       !! 以下赋值目标找不到声明（很可能是笔误）：")
        for n, l in bad:
            print(f"          line {l}: {n}")
    else:
        print("       OK：所有赋值目标都能在声明中找到")
    return len(bad)


def module_iface(path, modname):
    """返回 (参数名集合, 端口名集合)"""
    src = read(path)
    i = src.find('module ' + modname)
    if i < 0:
        raise SystemExit(f"在 {path} 中找不到 module {modname}")
    head = src[i:src.find(');', i)]

    # 参数既可能写在头部 `#( parameter X = ... )`，也可能写在模块【体内】
    # （本工程的 ae_set.v 就是体内声明：`module ae_set(...); parameter X = ...;`）。
    # 两种都要收，否则会把"实例确实传了的参数"误报成"参数不存在"。
    end = src.find('endmodule', i)
    whole = src[i:end if end > 0 else len(src)]
    params = set()
    for m in re.finditer(r'\bparameter\b(?:\s+(?:signed|unsigned|integer|real|realtime|time))*\s*(?:\[[^\]]*\]\s*)?([A-Za-z_]\w*)\s*=', whole):
        params.add(m.group(1))

    ports = set()
    for m in re.finditer(r'\b(input|output|inout)\b([^,;)]*)', head):
        body = re.sub(r'\[[^\]]*\]', ' ', m.group(2))
        body = re.sub(r'\b(wire|reg|signed|unsigned|input|output|inout)\b', ' ', body)
        names = re.findall(r'[A-Za-z_]\w*', body)
        if names:
            ports.add(names[-1])
    return params, ports


def instance_conn(path, modname):
    src = read(path)
    m = re.search(r'\b' + modname + r'\b\s*#\s*\((.*?)\)\s*[A-Za-z_]\w*\s*\((.*?)\)\s*;', src, re.S)
    if m:
        return (set(re.findall(r'\.([A-Za-z_]\w*)\s*\(', m.group(1))),
                set(re.findall(r'\.([A-Za-z_]\w*)\s*\(', m.group(2))))
    m = re.search(r'\b' + modname + r'\b\s+[A-Za-z_]\w*\s*\((.*?)\)\s*;', src, re.S)
    if m:
        return set(), set(re.findall(r'\.([A-Za-z_]\w*)\s*\(', m.group(1)))
    return set(), set()


def check_iface(top, modname, modfile):
    mp, mports = module_iface(modfile, modname)
    ip, iports = instance_conn(top, modname)

    print(f"[iface] {top} 里的 {modname} 实例  vs  {modfile}")
    errs = 0
    if ip - mp:
        print("       !! 参数名在模块定义里不存在：", sorted(ip - mp))
        errs += len(ip - mp)
    if mports and (iports - mports):
        print("       !! 端口名在模块定义里不存在：", sorted(iports - mports))
        errs += len(iports - mports)
    if not ip:
        print("       !! 没找到 #(...) 参数覆盖（若模块无参数可忽略）")
    print("       参数：定义", sorted(mp), " 实例传了", sorted(ip))
    print("       端口：定义", len(mports), "个，实例连接", len(iports), "个")
    miss = mports - iports
    if miss:
        print("       未连接的端口（output 可留空，input 需确认有默认/常量为 0）：", sorted(miss))
    if errs == 0:
        print("       OK：端口/参数名与模块定义一致")
    return errs


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    mode = sys.argv[1]
    if mode == 'decl':
        return 1 if sum(check_decl(p) for p in sys.argv[2:]) else 0
    if mode == 'iface':
        if len(sys.argv) != 5:
            print("用法: python tools/vlint.py iface <顶层文件.v> <模块名> <模块定义文件.v>")
            return 2
        return 1 if check_iface(sys.argv[2], sys.argv[3], sys.argv[4]) else 0
    print(__doc__)
    return 2


if __name__ == '__main__':
    sys.exit(main())
