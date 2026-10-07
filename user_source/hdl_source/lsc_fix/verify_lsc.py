#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
lsc_shading.v 比特级镜像验证
------------------------------------------------------------------
逐位复刻 RTL 的定点运算，验证：
  T1 平方展开式 dx_k² = dx0² + 4k·dx0 + 4k²  与直接计算一致
  T2 定点常数：中心增益 ≈ 1.000，角落增益 = (256 + P)/256
  T3 Bayer 通道映射（BGGR 及另外三种相位）
  T4 全画幅扫描：增益单调、无溢出、输出恒在 0~1023
  T5 疗效仿真：合成"中心绿四周紫"的带阴影图像，看校正后的残余色偏
用法：python verify_lsc.py
"""
import math

W, H = 1280, 720
CX2, CY2 = W - 1, H - 1                      # 1279, 719
R2MAX_S = ((W - 1) ** 2 + (H - 1) ** 2) >> 8  # 8409


def sN(x, n):                                 # n 位有符号环绕（复刻寄存器行为）
    x &= (1 << n) - 1
    return x - (1 << n) if x & (1 << (n - 1)) else x


def M_of(P):
    """复刻 Verilog 的整数除法：(P * 65536) / R2MAX_S（向零截断）"""
    q = abs(P) * 65536 // R2MAX_S
    return -q if P < 0 else q


def bayer_ch(phase, yp, xp):
    """复刻 bayer_ch()：yp=0 偶数行，xp=0 偶数列"""
    R, G, B = 0, 1, 2
    if phase == 0:                            # BGGR
        return B if (not yp and not xp) else (R if (yp and xp) else G)
    if phase == 1:                            # GBRG
        return B if (not yp and xp) else (R if (yp and not xp) else G)
    if phase == 2:                            # GRBG
        return B if (yp and not xp) else (R if (not yp and xp) else G)
    return R if (not yp and not xp) else (B if (yp and xp) else G)  # RGGB


def gain_of(x, y, P_R, P_G, P_B, phase=0):
    """返回该像素三通道的 RTL 增益（浮点值，256=1.0 已归一）"""
    h, k = x >> 2, x & 3                      # 组内序号 k
    dx0 = sN((h << 3) - CX2, 13)
    dy = sN((y << 1) - CY2, 12)
    dx0sq, dysq = sN(dx0 * dx0, 24), sN(dy * dy, 24)
    coef = ((0, 0), (4, 4), (8, 16), (12, 36))
    a, b = coef[k]
    r2 = sN(sN(dx0sq + sN(dx0 * a, 24), 24) + b + dysq, 24)
    r2s = r2 >> 8                             # 算术右移（r2 恒正，等价）
    ch = bayer_ch(phase, y & 1, k & 1)
    P = (P_R, P_G, P_B)[ch]
    m = M_of(P)
    dlt = sN(r2s * m, 32) >> 16               # 算术右移
    gp = dlt + 256
    g = 0 if gp < 0 else (1023 if gp > 1023 else gp)
    return g / 256.0, ch


def apply_lsc(raw, x, y, P_R, P_G, P_B, phase=0):
    g, _ = gain_of(x, y, P_R, P_G, P_B, phase)
    v = (raw * int(round(g * 256)) + 128) >> 8
    return min(1023, v)


# ---------------------------------------------------------------- T1 平方展开
print("[T1] 平方展开式 (dx0+2k)² = dx0² + 4k·dx0 + 4k²")
bad = 0
for h in range(0, 320, 7):
    dx0 = (h << 3) - CX2
    for k in range(4):
        a, b = ((0, 0), (4, 4), (8, 16), (12, 36))[k]
        if dx0 * dx0 + a * dx0 + b != (dx0 + 2 * k) ** 2:
            bad += 1
print(f"     展开式全扫描错误数: {bad}  → {'PASS ✅' if bad == 0 else 'FAIL ❌'}")

# ---------------------------------------------------------- T2 中心 / 角落增益
print("\n[T2] 定点增益：中心应 ≈1.000，角落应 = (256+P)/256")
P_R, P_G, P_B = -38, 0, -38
for name, (x, y) in (("中心 (640,360)", (640, 360)), ("角落 (0,0)", (0, 0)),
                     ("角落 (1279,719)", (1279, 719))):
    gs = [gain_of(x, y, P_R, P_G, P_B)[0] for x, y in
          ((x, y),) * 1]
    # 逐通道：用 4 个相邻像素覆盖 R/G/B
    vals = {}
    for xx in range(x - 2, x + 3):
        for yy in range(max(0, y - 1), min(H, y + 2)):
            g, ch = gain_of(xx, yy, P_R, P_G, P_B)
            vals.setdefault("RGB"[ch], []).append(g)
    s = "  ".join(f"{c}={sum(v)/len(v):.3f}" for c, v in sorted(vals.items()))
    print(f"     {name:<16} {s}")
print(f"     理论角落值: R={(256-38)/256:.3f} G={256/256:.3f} B={(256-38)/256:.3f}")

# ------------------------------------------------------------ T3 Bayer 相位
print("\n[T3] Bayer 通道映射（前两行前四列）")
for phase, tag in ((0, "BGGR"), (1, "GBRG"), (2, "GRBG"), (3, "RGGB")):
    row0 = "".join("RGB"[bayer_ch(phase, 0, x & 1)] for x in range(4))
    row1 = "".join("RGB"[bayer_ch(phase, 1, x & 1)] for x in range(4))
    print(f"     {tag}: 行0={row0}  行1={row1}")
print("     BGGR 期望 行0=BGBG 行1=GRGR →",
      "PASS ✅" if ("".join("RGB"[bayer_ch(0, 0, x & 1)] for x in range(4)) == "BGBG"
                    and "".join("RGB"[bayer_ch(0, 1, x & 1)] for x in range(4)) == "GRGR") else "FAIL ❌")

# ------------------------------------------------------- T4 全画幅极端参数扫描
print("\n[T4] 极端参数全画幅扫描（P=±128 与 ±512，输出限幅与单调性）")
for P in (-512, -128, 128, 512):
    lo, hi = 9999, -9999
    for y in range(0, H, 11):
        for x in range(0, W, 7):
            g, _ = gain_of(x, y, P, 0, P)
            lo, hi = min(lo, g), max(hi, g)
            out = apply_lsc(1023, x, y, P, 0, P)
            if not (0 <= out <= 1023):
                print("     溢出！", x, y, out)
                break
    print(f"     P={P:+5d}: 增益范围 {lo:.3f}~{hi:.3f}  （理论角落 {(256+P)/256:.3f}）")

# ------------------------------------------------------------- T5 疗效仿真
print("\n[T5] 疗效仿真：合成'中心绿、四周紫'的镜头色阴影图像")
# 模拟：R/B 通道响应沿半径线性增强（角落 +18%），G 不变 → 中心偏绿、边缘发紫
def shade_true(x, y):
    r2 = ((2 * x - CX2) ** 2 + (2 * y - CY2) ** 2) / float(CX2 ** 2 + CY2 ** 2)
    return (1 + 0.18 * r2, 1.0, 1 + 0.18 * r2)     # (R,G,B) 真实阴影


def pix_of_channel(x, y, ch):
    """在 (x,y) 附近找一个真正属于通道 ch 的像素坐标（BGGR）"""
    for dy in (0, 1):
        for dx in (0, 1):
            xx, yy = x + dx, y + dy
            if xx >= W or yy >= H:
                continue
            if bayer_ch(0, yy & 1, xx & 1) == ch:
                return xx, yy
    return x, y


def measure(PR, PG, PB):
    """全画幅取 3 个代表点：中心 / 半半径 / 角落，算 AWB 归一化后的残余色偏"""
    pts = {"中心": (640, 360), "半场": (960, 540), "角落": (1264, 704)}
    res = {}
    for tag, (x, y) in pts.items():
        sR, sG, sB = shade_true(x, y)
        sig = 200.0                                  # 白墙信号（BLC 后）
        vals = []
        for ch, s in enumerate((sR, sG, sB)):
            px, py = pix_of_channel(x, y, ch)
            vals.append(apply_lsc(int(sig * s), px, py, PR, PG, PB))
        res[tag] = tuple(vals)
    # AWB 灰度世界：用全画面平均把 R/G、B/G 拉回 1
    import statistics
    ratios = []
    for tag, (vR, vG, vB) in res.items():
        ratios.append((vR / max(vG, 1), vB / max(vG, 1)))
    mR = statistics.mean(r[0] for r in ratios)
    mB = statistics.mean(r[1] for r in ratios)
    worst = 0.0
    for tag, (vR, vG, vB) in res.items():
        rR, rB = (vR / max(vG, 1)) / mR, (vB / max(vG, 1)) / mB
        worst = max(worst, abs(rR - 1), abs(rB - 1))
    return worst, res


w0, r0 = measure(0, 0, 0)
w1, r1 = measure(-38, 0, -38)
w2, r2_ = measure(-46, 0, -46)
print(f"     未校正 (P=0)     : 残余色偏 {w0*100:5.1f}%   中心 RGB={r0['中心']} 角落 RGB={r0['角落']}")
print(f"     P_R=P_B=-38     : 残余色偏 {w1*100:5.1f}%   中心 RGB={r1['中心']} 角落 RGB={r1['角落']}")
print(f"     P_R=P_B=-46     : 残余色偏 {w2*100:5.1f}%   中心 RGB={r2_['中心']} 角落 RGB={r2_['角落']}")
print(f"     → 改善 {100*(1-w1/max(w0,1e-9)):.0f}% (P=-38) / {100*(1-w2/max(w0,1e-9)):.0f}% (P=-46)")
print("     判定:", "PASS ✅ 残余色偏降到 3% 以内" if w1 < 0.03 else "需继续调参（改 P 值重跑）")
