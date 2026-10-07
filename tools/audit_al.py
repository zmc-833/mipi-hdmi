#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
audit_al.py —— TD 工程清单（.al）体检工具

用途：交付/编译前自查"文件是否都正确进了工程"，专治两类历史事故：
  ① 清单引用的文件在磁盘上不存在            → 断链
  ② 顶层实例化了的模块，其定义文件没进清单  → 综合报 HDL-8007 "is a black box"
     （2026-10-07 实发：chroma_denoise.v 在 Add Files 过程中被挤出清单，
       编译直接失败。此工具本该提前拦下。）

用法：
    python tools/audit_al.py                           # 自动在仓库里找 td_project/*.al
    python tools/audit_al.py <path/to/xxx.al>          # 指定工程文件
    python tools/audit_al.py --root D:/GitHub/mipi-hdmi

退出码：0 = 全部通过；1 = 发现必须修的问题（断链 / 黑盒）。
"""

import os
import re
import sys


def find_al(root):
    cand = []
    td = os.path.join(root, 'td_project')
    if os.path.isdir(td):
        for f in sorted(os.listdir(td)):
            if f.lower().endswith('.al'):
                cand.append(os.path.join(td, f))
    return cand


def strip_comments(txt):
    txt = re.sub(r'/\*.*?\*/', '', txt, flags=re.S)
    txt = re.sub(r'//[^\n]*', '', txt)
    return txt


def main():
    args = [a for a in sys.argv[1:]]
    root = os.getcwd()
    if '--root' in args:
        i = args.index('--root')
        root = args[i + 1]
        args = args[:i] + args[i + 2:]

    if args:
        al_paths = [os.path.abspath(args[0])]
        root = os.path.dirname(os.path.dirname(al_paths[0]))
    else:
        al_paths = find_al(root)
    if not al_paths:
        print("找不到 .al 工程文件；用 --root 指定仓库根目录。")
        return 2

    fail = False
    for al in al_paths:
        print("=" * 74)
        print("工程文件:", al)
        al_dir = os.path.dirname(al)
        txt = open(al, encoding='utf-8', errors='replace').read()
        listed = re.findall(r'File\s+Path="([^"]+)"', txt)
        print("清单条目: %d" % len(listed))

        # ---------- 1. 断链检查 ----------
        resolved = {}
        for p in listed:
            q = p.replace('\\', '/')
            full = q if (q.startswith('/') or re.match(r'^[A-Za-z]:', q)) \
                else os.path.normpath(os.path.join(al_dir, q))
            resolved[p] = os.path.normcase(os.path.abspath(full))
        missing = [p for p, f in resolved.items() if not os.path.exists(f)]
        print("\n[1] 清单断链（引用了但磁盘不存在）")
        if missing:
            fail = True
            for p in missing:
                print("    MISSING:", p)
        else:
            print("    通过：%d 条路径全部存在" % len(listed))

        listed_set = set(resolved.values())

        # ---------- 2. 自研模块定义 -> 文件 ----------
        hdl = os.path.join(root, 'user_source', 'hdl_source')
        defs = {}
        if os.path.isdir(hdl):
            for dp, dn, fn in os.walk(hdl):
                for f in fn:
                    if not f.lower().endswith(('.v', '.sv')):
                        continue
                    if '.enc.' in f.lower():
                        continue
                    fp = os.path.join(dp, f)
                    try:
                        t = strip_comments(open(fp, encoding='utf-8',
                                                errors='replace').read())
                    except OSError:
                        continue
                    for m in re.finditer(r'\bmodule\s+([A-Za-z_]\w*)', t):
                        defs.setdefault(m.group(1), os.path.normcase(
                            os.path.abspath(fp)))

        # ---------- 3. 黑盒风险 ----------
        print("\n[2] 黑盒风险（顶层实例化但定义文件未进工程）")
        top_files = [p for p in listed if os.path.basename(p) in
                     ('design_top_wrapper.v', 'top.v', 'design_top.v')]
        if not top_files or not defs:
            print("    跳过（未找到顶层文件或自研模块）")
        else:
            bad = []
            for tf in top_files:
                fp = resolved[tf]
                if not os.path.exists(fp):
                    continue
                wt = strip_comments(open(fp, encoding='utf-8',
                                         errors='replace').read())
                for name, dfile in defs.items():
                    if os.path.abspath(dfile) == os.path.abspath(fp):
                        continue
                    inst = re.search(
                        r'\b%s\s*(?:#\s*\(|\w+\s*\()' % re.escape(name), wt)
                    if inst and dfile not in listed_set:
                        bad.append((name, dfile))
            if bad:
                fail = True
                for name, dfile in sorted(bad):
                    print("    BLACKBOX: %-22s 定义在 %s"
                          % (name, os.path.relpath(dfile, root).replace('\\', '/')))
                print("    ⇒ TD 会报 HDL-8007 \"is a black box\"，必须 Add Files。")
            else:
                print("    通过：顶层实例化的自研模块均有定义文件在清单内")

        # ---------- 4. 未纳入工程的自研文件（提示，不算失败）----------
        print("\n[3] 磁盘上未纳入工程的自研 .v/.sv（多数为旧版/未用，确认非漏加即可）")
        # IP 生成的 RTL（.xml/.ipc 同目录下）由 TD 自行展开，不计入漏加
        ip_dirs = set()
        for p, f in resolved.items():
            if p.lower().endswith(('.xml', '.ipc')):
                ip_dirs.add(os.path.dirname(f))
        orphan = []
        if os.path.isdir(hdl):
            for dp, dn, fn in os.walk(hdl):
                for f in fn:
                    if not f.lower().endswith(('.v', '.sv')):
                        continue
                    fp = os.path.normcase(os.path.abspath(os.path.join(dp, f)))
                    if fp in listed_set or '.enc.' in f.lower():
                        continue
                    if any(os.path.normcase(d) in fp for d in ip_dirs):
                        continue
                    orphan.append(os.path.relpath(fp, root).replace('\\', '/'))
        for o in sorted(orphan):
            print("    NOT-IN-PRJ:", o)
        if not orphan:
            print("    （无）")

    print("=" * 74)
    print("结论:", "❌ 发现问题，先修再编译" if fail else "✅ 通过")
    return 1 if fail else 0


if __name__ == '__main__':
    sys.exit(main())
