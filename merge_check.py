# -*- coding: utf-8 -*-
"""
D1 合并冲突预检工具（张铭晨 ← 张金艺）

用法:
    python merge_check.py <张金艺的工程目录>

功能:
    1. 识别他的基线 commit（若包里带 .git）
    2. 把他的文件分成三类: 可直接拷 / 需手工合 / 完全一致
    3. 检查是否自己写了坐标计数器（方案 1.3 禁止）
    4. 输出建议的 CompileOrder 起始值
"""
import os
import re
import sys
import hashlib

LOCAL_ROOT = os.path.dirname(os.path.abspath(__file__))
BASELINE = "a33df37"          # v6.6，合并基线
HDL = os.path.join("user_source", "hdl_source")
AL = os.path.join("td_project", "camera_to_dsi_display.al")

# 不需要拷贝的垃圾文件
SKIP_EXT = (".log", ".logw", ".bit", ".bin", ".bak", ".pyc", ".tmp")
SKIP_DIR = ("_tmp", "_td", "impl", ".git", "__pycache__", "simulation", "output")


def md5(path):
    h = hashlib.md5()
    try:
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
        return h.hexdigest()
    except Exception:
        return None


def find_src_root(base):
    """他的包可能是整个工程，也可能只是 user_source，智能定位 HDL 源根"""
    for rel in (HDL, os.path.join("user_source", "hdl_source"), "."):
        p = os.path.join(base, rel)
        if os.path.isdir(p):
            return p
    return base


def get_baseline(base):
    """若包里带 .git，读出他的 HEAD"""
    head = os.path.join(base, ".git", "HEAD")
    if not os.path.isfile(head):
        return None
    try:
        txt = open(head, encoding="utf-8").read().strip()
        if txt.startswith("ref:"):
            ref = txt.split(None, 1)[1]
            rp = os.path.join(base, ".git", *ref.split("/"))
            if os.path.isfile(rp):
                return open(rp, encoding="utf-8").read().strip()[:7]
        return txt[:7]
    except Exception:
        return None


def has_own_coord_counter(vpath):
    """检测模块是否自己生成了像素坐标（方案 1.3 禁止各写一份）"""
    pats = [
        r"\bO_pix_x\b", r"\bO_pix_y\b", r"\bo_pix_x\b", r"\bo_pix_y\b",
        r"\boutput\s+(?:wire\s+|reg\s+)?\[?\s*10\s*:\s*0\s*\]?\s+\w*x_cnt",
        r"\boutput\s+(?:wire\s+|reg\s+)?\[?\s*10\s*:\s*0\s*\]?\s+\w*h_cnt",
    ]
    try:
        txt = open(vpath, encoding="utf-8", errors="ignore").read()
    except Exception:
        return []
    return sorted({p for p in pats if re.search(p, txt)})


def main():
    if len(sys.argv) < 2:
        print("用法: python merge_check.py <张金艺的工程目录>")
        sys.exit(1)

    src_base = os.path.abspath(sys.argv[1])
    if not os.path.isdir(src_base):
        print("目录不存在:", src_base)
        sys.exit(1)

    src_root = find_src_root(src_base)

    print("=" * 66)
    print("D1 合并冲突预检")
    print("=" * 66)
    print("他的包   :", src_base)
    print("源根     :", src_root)
    print("本地仓库 :", LOCAL_ROOT)

    # ---- 1. 基线检查 -------------------------------------------------
    bl = get_baseline(src_base)
    print("\n【1】基线检查")
    if bl is None:
        print("  ⚠️  包里没有 .git，无法自动确认基线")
        print("      → 务必口头问他：代码是从 v6.6 (a33df37) 改的吗？")
    elif bl.startswith(BASELINE):
        print(f"  ✅ 基线一致: {bl} == 本地基线 {BASELINE}")
    else:
        print(f"  🔴 基线不一致: 他的 {bl} ≠ 本地 {BASELINE}")
        print("      → 先让他同步到 v6.6 再合并，否则会把郭的旧代码混进来")

    # ---- 2. 文件分类 -------------------------------------------------
    new, conflict, same = [], [], []
    for r, ds, fs in os.walk(src_root):
        ds[:] = [d for d in ds if d.lower() not in SKIP_DIR]
        for f in fs:
            if f.lower().endswith(SKIP_EXT):
                continue
            src = os.path.join(r, f)
            rel = os.path.relpath(src, src_root)
            dst = os.path.join(LOCAL_ROOT, HDL, rel)
            if not os.path.isfile(dst):
                new.append((rel, src))
            elif md5(src) == md5(dst):
                same.append(rel)
            else:
                conflict.append((rel, src, dst))

    print("\n【2】文件分类")
    print(f"  🟢 可直接拷（本地没有，零冲突）: {len(new)} 个")
    for rel, _ in sorted(new)[:40]:
        print("      +", rel)
    if len(new) > 40:
        print(f"      ... 另有 {len(new) - 40} 个")

    print(f"\n  🟡 需手工合（两边都有且内容不同）: {len(conflict)} 个")
    for rel, _, _ in sorted(conflict):
        print("      ~", rel)

    print(f"\n  ⚪ 完全一致（无需处理）: {len(same)} 个")

    # ---- 3. 顶层/mixer/al 是否被他改过 -------------------------------
    print("\n【3】公共文件改动检测（最关键）")
    top_his = os.path.join(src_root, "design_top_wrapper.v")
    top_loc = os.path.join(LOCAL_ROOT, HDL, "design_top_wrapper.v")
    mix_his = os.path.join(src_root, "hdmi_mixer.v")
    mix_loc = os.path.join(LOCAL_ROOT, HDL, "hdmi_mixer.v")
    al_his = os.path.join(os.path.dirname(os.path.dirname(src_root)), AL)

    for name, hp, lp in (
        ("design_top_wrapper.v", top_his, top_loc),
        ("hdmi_mixer.v", mix_his, mix_loc),
        ("camera_to_dsi_display.al", al_his,
         os.path.join(LOCAL_ROOT, AL)),
    ):
        if os.path.isfile(hp) and os.path.isfile(lp):
            if md5(hp) == md5(lp):
                print(f"  ✅ {name}: 未改动")
            else:
                print(f"  🟡 {name}: 他改过 → 需要三方合并")
        elif not os.path.isfile(hp):
            print(f"  ⚪ {name}: 包里没有（可能只交了模块）")

    # ---- 4. 坐标计数器重复检测 ---------------------------------------
    print("\n【4】坐标计数器重复检测（方案 1.3）")
    hits = []
    for rel, src in new:
        if not rel.lower().endswith((".v", ".sv")):
            continue
        ps = has_own_coord_counter(src)
        if ps:
            hits.append((rel, ps))
    if hits:
        print("  🟡 以下模块疑似自己生成了坐标，合并时要改接 S_pix_x / S_pix_y:")
        for rel, ps in hits:
            print(f"      {rel}  匹配: {', '.join(ps)}")
    else:
        print("  ✅ 未发现自建坐标计数器")

    # ---- 5. CompileOrder 建议 ----------------------------------------
    print("\n【5】.al 清单合并建议")
    try:
        txt = open(os.path.join(LOCAL_ROOT, AL), encoding="utf-8").read()
        orders = [int(x) for x in re.findall(r'CompileOrder"\s+Val="(\d+)"', txt)]
        mx = max(orders)
        print(f"  本地最大 CompileOrder = {mx}")
        print(f"  他的 rtl 应从 {mx + 1} 开始排（不要复用已有编号）")
    except Exception as e:
        print("  读取 .al 失败:", e)

    print("\n" + "=" * 66)
    print("下一步: git checkout integration → 按 🟢🟡 顺序合并 → iverilog 检查")
    print("=" * 66)


if __name__ == "__main__":
    main()
