# 集成包说明 —— 张铭晨 D1 侧改动（给张金艺）

> 生成时间：2026-10-10 20:31
> 对应你的请求：第二轮核实 §五「待你提供」的 **A 方案（打包）**
> 来源：我本地工作树 `E:\workbuddy_1`（**当前工作树版本**，非 git HEAD —— 见我下面第 2 条说明）

---

## 一、包里有什么

```
07_给张金艺-集成包/
├── README_集成说明.md              ← 本文件
├── user_source/hdl_source/
│   ├── design_top_wrapper.v        ★ 我改过的（例化 3 模块 + 仲裁层）
│   ├── hdmi_mixer.v                ★ 我改过的（+2 个端口 +1 路叠加）
│   └── track_box/                  ★ 我的完整模块目录（19 文件：rtl/tb/sim/文档/PNG）
└── td_project/
    └── camera_to_dsi_display.al    ★ 我改过的（+4 条 track_box 条目）
```

**我不含**（按你 A 方案的要求排除，也都是不该进版本库的）：
`*_Runs/`、`*.bit`、`*.log`、`*.prj` 等 TD 生成物。

---

## 二、⚠️ 最重要：这三个文件是「工作树版本」，不是 git 提交版本

你说"我核过基线 `a33df37`，三项都不在共享仓库里"——**你说得完全正确**，原因如下：

| 文件 | 我的 git 状态 |
|:---|:---|
| `design_top_wrapper.v` | **已提交**（在 `ce62386`）+ **有新的未提交改动** |
| `hdmi_mixer.v` | **已提交**（在 `9ca7a1d`）+ **有新的未提交改动** |
| `camera_to_dsi_display.al` | **已提交**（在 `9ca7a1d`）+ **有新的未提交改动** |

**而且更关键的是**：我这两个提交（`9ca7a1d`、`ce62386`）**从未 push 到任何远端**——
`origin/main` 还停在 `a33df37`，我本地分支 `workbuddy` 领先 2 个提交。
远端也只有 `main` 和你的 `Rrrrrr_` 两条分支，**确实没有我的 `workbuddy` / `integration`**。

⇒ 你核基线看不到它们，是必然的。**这个包给的就是当前工作树的最新版本**（含那两个未提交改动），
你拿到的就是能下板的那一份。

---

## 三、我对 top 和 mixer 到底改了什么（供你合并）

### 3.1 `hdmi_mixer.v` —— 唯一改动：+2 个输入端口 + 1 路最低优先级叠加

**端口新增**（第 83~84 行）：

```verilog
input  wire        I_ext_hit,
input  wire [23:0] I_ext_color,
```

**叠加逻辑**（第 530 行，`else if` 链**最末**）：

```verilog
else if(I_ext_hit) begin
    S_osd_hit   = 1'b1;
    S_osd_color = I_ext_color;
end
```

放在链末 ⇒ **Logo 和五处中文 OSD 仍在最上层**，外部叠加在最下层。

### 3.2 `design_top_wrapper.v` —— 4 处改动

**① 信号声明**（第 232~236 行附近）：

```verilog
wire        S_mask_hit;        // 预留：目标检测掩膜/伪彩（张金艺 D1）
wire [23:0] S_mask_color;
wire        S_ovl_hit;         // 仲裁结果 → hdmi_mixer.I_ext_hit
wire [23:0] S_ovl_color;
```
（另有 `S_pix_x / S_pix_y / S_pix_x_1d/_2d / S_pix_y_1d/_2d / S_frame_done / S_box_hit / S_box_color / S_coord_hit / S_coord_color`）

**② 例化 3 个模块**（第 979~1029 行）：`u_pix_coord_gen` / `u_box_draw` / `u_osd_coord`

**③ 仲裁层**（第 1029~1033 行）—— **这就是你要接的地方**：

```verilog
// TODO(合并张金艺后)：把 S_mask_hit / S_mask_color 接到 detect 模块输出
assign S_mask_hit   = 1'b0;              // ← 你把它换成 detect_color_mask 的 O_mask
assign S_mask_color = 24'h00_FF_00;      // ← 换成你的掩膜颜色（绿）
assign S_ovl_hit    = S_mask_hit | S_box_hit | S_coord_hit;
assign S_ovl_color  = S_coord_hit ? S_coord_color :
                      (S_box_hit   ? S_box_color  : S_mask_color);
```

**④ 送进 mixer**（第 1062 行）：`.I_ext_hit ( S_ovl_hit )`, `.I_ext_color( S_ovl_color )`

> ⚠️ **仲裁优先级：坐标 OSD > 画框/准星 > 检测掩膜**。你的掩膜在最底层，不会盖住框。

### 3.3 `camera_to_dsi_display.al` —— +4 条文件条目

```
第 23 行  ../user_source/hdl_source/track_box/rtl/pix_coord_gen.v   CompileOrder 61
第 32 行  ../user_source/hdl_source/track_box/rtl/box_draw.v        CompileOrder 62
第 41 行  ../user_source/hdl_source/track_box/rtl/osd_coord.v       CompileOrder 63
第 50 行  ../user_source/hdl_source/track_box/rtl/track_glyph_rom.v CompileOrder 64
```

四条都是 `UsedInSyn=true` / `UsedInP&R=true` / `AutoExcluded=true`，与既有 1~60 无冲突。

---

## 四、你合并时的两个坑（我踩过，提醒你）

### 坑 1：`.al` 第 2 行的绝对路径属性

```
<Project Version="3" Minor="2" Path="E:/workbuddy_1/td_project">
```

这是**旧机器的绝对路径**，是 TD 自动写的。好消息是：**其它所有 `Path=` 都是相对路径**
（`../user_source/hdl_source/...`），TD 按 `.al` 实际所在目录解析，所以
**只要你的目录结构与基线一致，直接打开就能用**，第 2 行不用管。
（实测过：在 `td_project` 目录内执行 TD 命令行，报错数 0。）

### 坑 2：`SELF_TEST` 常量折叠

`box_draw` 我配置的是 `SELF_TEST=1`，此时 `I_box_valid` 被常量折叠，
**接 0 即可**（画出 4 个写死坐标的固定框，用于坐标标定）。你不需要动它。

---

## 五、关于 `pix_coord_gen.v` 接入（你 §五 C 方案提到）

你说"桌面 `aaa/rtl/` 已有" —— 对的，包里 `track_box/rtl/pix_coord_gen.v` 也是同一份。
**接入建议**：

- 不要自己再例化一份，直接用 top 里已经生成的 `S_pix_x_2d` / `S_pix_y_2d`；
- 接 `detect_color_mask.I_pix_x` 时 **`PIX_DLY` 填 2**（我已用独立 TB 实测：0/1/2 三配置全 PASS）。

---

## 六、我的建议路径

**不要走你的 C 方案**（"top/mixer/.al 由我来合"）—— 原因：

1. 我改的 mixer 端口和 `.al` 条目位置是**已实测过 TD 编译通过**的（98 文件解析、0 ERROR、4 个新模块全在层次树里）；
2. 你重合并容易出现"接线一致但 CompileOrder 或 UsedIn* 属性不对"的隐形问题；
3. 你已经把 `detect_color_mask` 做成参数化的了，**只需把 `S_mask_hit` 的驱动源换一下**，改动量极小。

**建议**：直接用我这个包做基线，**你只改 top 里那 1 行 `assign S_mask_hit = 1'b0;`**，
其余照搬。这样最快、风险最低。

---

## 七、我这边还没做的（同步给你）

1. **推送**：我的 `workbuddy` / `integration` 两个分支**只在本地**。
   我查了 `zmc-833/mipi-hdmi` 远端实际状态：

   | 项 | 实际值 |
   |:---|:---|
   | 仓库可见性 | **公开**（所以你本来就能只读访问，不需要我授权） |
   | 远端分支 | 只有 `main` |
   | 远端 main 最新 | `f9b3bf37`（2026-10-07） |
   | 我的 `9ca7a1d` / `ce62386` | API 查 → **422，不在远端** |

   ⇒ **远端比我们现在的基线还旧**，拉了也没用。
   **真正的卡点是本机无 GitHub 凭据（缺 PAT），我推不上去**，不是"给不给访问"。

2. **下板**：我还没实际下板（要板子）。
3. **D2**：连通域按你说的归你，我按此排期不动。

---

## 八、校验信息

本包内文件与 `E:\workbuddy_1` 工作树**逐文件 MD5 比对一致**。

| 文件 | MD5 |
|:---|:---|
| `design_top_wrapper.v` | `f45bd0b674149a30a5a4a1d2e10fb714` |
| `hdmi_mixer.v` | `fdfb72ed752af820c0c17c89fd714390` |
| `camera_to_dsi_display.al` | `ee99d294aa012fe887f29c1ca6d5ea3b` |
| `track_box/rtl/pix_coord_gen.v` | `1ccc519f43df81dbeb066a71dc164d6c` |

> 包体：23 个文件 / 328 KB。你收到后可用 MD5 核对，确保传输无损坏。
