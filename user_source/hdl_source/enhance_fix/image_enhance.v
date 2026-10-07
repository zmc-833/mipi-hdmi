//============================================================================
// 文件    ：image_enhance.v
// 功能    ：画质增强 —— 亮度域「边缘保护降噪(Coring) + Unsharp 锐化」
// 位置    ：gamma_lut 之后、chroma_denoise 之前（显示域，彩色通路）
// 版本    ：v3.2（2026-10-07）
//   v1 → v2：把 v1 中约 18 级的组合链**全部逐级寄存**（v1 造成 HDMI 像素域
//            18 级路径、slack -0.057ns；v2 每级 ≤5 级 LUT）。功能完全等价。
//   v2 → v3：新增 ADAPT_EN：降噪强度随 AE 增益自适应（v6.4 进阶5 要求）。
//   v3 → v3.1（★严重 BUG 修复，必须理解）：
//            v3 的 O_de 采用"把 de 打包进 25bit 行缓存"的所谓**结构对齐**，
//            结果上板后彩色画面出现**横向色带 + 右侧约 29% 整片纯黑**
//            （灰度/二值/Sobel 正常，因为它们绕过本模块）。
//            根因：行消隐期列地址被钳在 0，行缓存读出的就是"第 0 列那一位"
//            （写使能为 1 时写入，恒为 1）⇒ **O_de 在整个消隐期恒为 1**。
//            下游 chroma_denoise 的列计数器靠"de 为低清零"对齐行，收到恒 1 的
//            de 便**永不复位**：地址以 1280 为模自由跑，而行周期是 1650 拍 ⇒
//            相位每行漂移 370 拍 ⇒ 列 c ≥ 1280-370 = 910（右侧 370/1280 = 28.9%）
//            的"上一行"抽头读到消隐重复值（= 上一行最后一列的常数）⇒ 该区域
//            整片显示同一颜色；其余列则把隔 370/740 列的像素混进垂直滤波 ⇒
//            横向色带。**实测黑区宽度占屏幕 27%、屏幕宽高比 1755:1000≈16:9，
//            与理论 28.9% 完全吻合。**
//            修复：de 改为**纯寄存器延时链**（de_s3 + S4~S9），消隐期自然为低；
//            行缓存恢复 24bit（不打包 de）。de 与像素的相位差恰为 1 个整行
//            （1650 拍）⇒ 行内相位完全对齐，下游列计数器每次消隐正确复位。
//            ★教训：**凡是"靠 de/valid 复位计数器"的下游，de 必须在消隐期为低。
//              任何从行缓存里取出的 de（消隐期地址被钳位）都不满足此条件。**
//----------------------------------------------------------------------------
//   v3.1 → v3.2（2026-10-07 高增益噪声定量整改；所有数字来自比特级模型
//            tools/img_enh_model.py，不靠"看起来"）：
//
//   【诊断：屏幕噪点到底是什么】
//     对现场照片做定量分析（3×3 高通后统计各通道 std）：
//       · 暗区 std(R-G)/std(Y) = 0.05~0.09，且 R/G/B 三通道高频 std **完全相等**
//         ⇒ **100% 共模亮度噪声**，色度噪声只占 5~10%（不是色度通路的问题）。
//       · 同一台相机、同一时刻：明亮白墙场景 σ≈2，昏暗房间场景 σ≈13（6.5 倍）
//         ⇒ 噪声 ∝ AE 增益。这就是"传感器亮度噪声被增益抬起来"，与通路无关。
//       · 灰度模式取的就是这条亮度（rgb2gray(S_video_bright)），所以
//         **"灰度干净、彩色有噪"在同等增益下不成立**；排查时别再用它当
//         "亮度通路干净"的证据（本项目已因此误判两轮）。
//
//   【本模块的真实问题】不是"制造噪声"，而是**高增益下几乎不工作**：
//     旧档位表在最高增益只用 dz=24，而实测显示域噪声 σ 达 60~80，
//     |Yc-blur| 绝大多数都 > dz ⇒ coring 失效，噪声增益 0.93~0.97（等于没压）。
//
//   【v3.2 三项改动】
//     B1  dz 档位表随增益整体加档：6/10/16/24/34/44/56（原 4/6/9/12/16/20/24）
//           模型实测（输出std/输入std，越小越好）：
//             σ=30 : 0.69 → 0.44      σ=60 : 0.93 → 0.57
//             σ=40 : 0.81 → 0.45      σ=80 : 0.97 → 0.63
//     B2  高增益自动关锐化（参数 SHARP_OFF_AG，默认 5 ⇒ ag 档 ≥5 即 ≥45x 时
//           inc 强制 0）。锐化项在高增益下放大的全是噪声；模型 σ=80：0.63 → 0.52。
//     B3  S9 增加 |delta| 上限 DELTA_MAX（默认 64）——**安全网**。
//           证明：|delta| 在数学上恒 ≤ dz（见下面 S7 注释），正常永不触发；
//           只有上游出现异常样本（行边界残值/位翻转）时才兜底，
//           防止它变成一个"全对比度椒盐点"。
//
//   【★ 两条旧结论已证伪，勿再据此改代码】
//     · S7 的 `blur - cored` **不会 8bit 回绕**：该分支恒等于 Yc+dz，而
//       coring 有效（cored>0）时必有 dz < blur-Yc，故 Yc+dz < blur ≤ 255；
//       另一分支恒为 Yc-dz ≥ 0。两侧都不可能回绕。
//       模型 T4 里出现的 min=5 只出现在**第 0 行**（行 RAM 上电未填充的瞬态，
//       此时 Yc=0、blur 还是初值），从第 1 行起完全正常。
//     · 本模块**不是噪声来源**：σ≤20 时噪声增益 0.5~0.6，是干净的降噪器。
//============================================================================
//
// 【为什么需要本模块 —— 问题定位】
//   1) 噪点：实测灰度模式与彩色模式平坦区亮度 std 相同 ⇒ 噪点在**亮度域**；
//      而原有 chroma_denoise 只对色度 Cb/Cr 做低通，亮度 Y 一根毛都没动。
//   2) 发糊：RAW→HDMI 全链路**没有任何锐化环节**，demosaic 双线性本就偏软。
//
// 【算法：软阈值 Coring + Unsharp（二者共用同一个 3×3 窗口）】
//       detail = Yc - blur                             # 带符号高通分量
//       cored  = sign(detail)·max(|detail|-CORE_DZ, 0)  # 死区内细节归零(消噪)
//       Y_dn   = blur + cored                          # 平坦区=blur，边缘=保留
//       Y_out  = Y_dn ± (cored >>> SHARP_SH)           # 只放大过了死区的真边缘
//       delta  = Y_out - Yc
//       R' = clamp(R + delta), G'、B' 同理（加同一 delta ⇒ 保色相/饱和度）
//   本质：**按幅度区分噪声与边缘**，不是空间平滑 ⇒ 能"消噪但不糊"。
//
// 【流水线结构（★ v2 重点：每级 ≤5 级 LUT，绝不再堆 18 级组合）】
//   S1  RGB→Y，寄存 RGB/Y/col_cnt
//   S2  水平 [1 2 1]/4 得 hY；打包 {Yc,hY}=16bit；RGB 单独寄存（同写地址/使能）
//   S3  行延时 RAM×3 → p1(中心行)/p2(上上行)/rgb_p1(中心行 RGB)
//       ★v6.5：行缓存保持 24bit；de 另走**寄存器延时链**（de_s3）与数据同拍下发。
//   S4  blur = 垂直 [1 2 1]/4                     → 寄存（40 FF）
//   S5  diff_a=|Yc-blur|、符号                    → 寄存
//   S6  cored = max(diff_a-CORE_DZ,0)             → 寄存
//   S7  y_dn = blur ± cored；inc = cored>>SHARP_SH → 寄存
//   S8  y_out = y_dn ± inc（限幅）；MODE 选择     → 寄存
//   S9  dmag=|y_out-Yc|、符号                     → 寄存
//   S10 RGB + delta → 限幅 → rgb_out
//   共 7 级新增寄存（S4~S10），延迟只增加 7 个像素，几何不变。
//
// 【对齐说明】
//   需要"中心行(row n-1)的 RGB"。RGB 与 Y 走**同样的写地址/写使能**，
//   RGB RAM 只做 1 行延时即与 p1(Y 的中心行)严格对齐，无需额外对齐逻辑。
//
// 【资源】
//   3 个行 RAM（16/16/25bit × 1280 深）；⚠️ 行 RAM 里已加
//   `syn_ramstyle="block_ram"` 强制块 RAM（见 line_delay_ram.v 注释），
//   否则会被面积优先策略推断成分布式 RAM，白吃上千 slice 引发布线拥塞。
//   RGB 那条从 24bit 加宽到 25bit（多带 1bit de），不额外多占 RAM 块。
//   本模块自身纯逻辑约 150 LUT + 约 470 FF，**无乘法器**。
//
// 【MODE 参数（编译期 A/B）】0=纯延时直通 1=仅降噪 2=降噪+锐化(默认)；EN=0 ⇒ MODE=0
//============================================================================

module image_enhance #(
    parameter        IMG_WIDTH = 1280,   // 一行像素数，必须与视频时序一致
    parameter        ADDR_W    = 12,     // 列地址位宽（2^12=4096 > 1280）
    parameter [7:0]  CORE_DZ   = 8'd8,   // 细节死区(消噪强度)：越大越干净也越"软"
    parameter [2:0]  SHARP_SH  = 3'd1,   // 锐化增益右移：1=0.5x 2=0.25x
    parameter [1:0]  MODE      = 2'd2,   // 0:直通 1:仅降噪 2:降噪+锐化
    parameter        EN        = 1'b1,   // 总开关：0 时退化为 MODE=0
    parameter        ADAPT_EN  = 1'b1,   // ★v6.4：1 = 降噪强度随 AE 增益自适应（推荐）；0 = 用常量 CORE_DZ
    parameter [7:0]  DELTA_MAX = 8'd64,  // ★v3.2(B3)：|delta| 硬上限（安全网）。正常恒不触发，见文件头注释
    parameter [2:0]  SHARP_OFF_AG = 3'd5 // ★v3.2(B2)：ag 档 ≥此值时自动关闭锐化；填 3'd7 表示永不关
) (
    input  wire             clk,         // 像素时钟（S_hdmi_pixel_clk）
    input  wire             rst_n,       // 低电平复位
    input  wire             I_de,        // 数据有效（与 rgb_in 同拍对齐）
    input  wire [15:0]      I_ag,        // ★v6.4：AE 增益控制字（24MHz 域，异步；16..239，32 码=1 octave）
    input  wire [23:0]      rgb_in,      // 输入 RGB888
    output reg  [23:0]      rgb_out,     // 输出 RGB888（延时：1 行 + 若干拍）
    // 与 rgb_out **同拍**的数据有效（延时 = 1 行 + 10 拍，与像素通路严格一致）。
    //   ★★ 实现要点（v6.5 修正）：**绝不能用"打包进行缓存"的位**！
    //   行消隐期间列地址被钳在 0，行缓存读出的就是"第 0 列那一位"（= 1），
    //   于是 O_de 会在**整个消隐期恒为 1** ⇒ 下游 chroma_denoise 的列计数器
    //   靠"de 为低清零"来对齐行，收到恒 1 的 de 就**永不复位**，地址以 1280
    //   为模自由跑而行周期是 1650 拍 ⇒ 相位每行漂移 370 ⇒ 彩色画面出现
    //   横向色带 + 右侧约 29%（=370/1280）整片单一颜色（实测为黑）。
    //   正确做法：de 只做**纯寄存器延时**（下面 de_s3 + S4~S9），
    //   消隐期自然为低，与 rgb_out 之间的相位差恰为 1 个整行（1650 拍）⇒
    //   行内相位完全对齐，下游列计数器逐行复位。
    output reg              O_de
);

    localparam [1:0] MODE_EFF = EN ? MODE : 2'd0;   // EN=0 统一退化为直通

    //========================================================================
    // ★v6.4 自适应降噪强度：CORE_DZ 跟随 AE 增益
    //   动因：噪声幅度 ∝ 增益。高增益（弱光）需要大死区才压得住；
    //         低增益（明亮）用大死区只会白丢细节。固定 CORE_DZ 必然二选一。
    //   增益关系（实测标定）：AG=16→1x、144→16x、207→63x、239→126x
    //                        ⇒ gain = 2^((AG-16)/32)，即 32 个码字 = 1 octave
    //   I_ag 是 24 MHz 域的慢变控制字（AE 每 ~3 帧才动一次），
    //   对"降噪档位"这种量做 3 级同步即可（万一取到跳变中间值，也只影响个别像素）。
    //========================================================================
    reg [15:0] ag_s0, ag_s1, ag_s2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ag_s0 <= 16'd0;  ag_s1 <= 16'd0;  ag_s2 <= 16'd0;
        end else begin
            ag_s0 <= I_ag;  ag_s1 <= ag_s0;  ag_s2 <= ag_s1;
        end
    end

    //   ★实现：输出**寄存**（不在关键路径上把 16bit 比较器+mux 串进 S6），
    //     且阈值全是 32 的倍数 ⇒ 直接用 ag[7:5] 译码（等效 ag/32），
    //     O_ag 量程 [16,239] < 256，位切片不会越界。
    //   ★v3.2(B1)：档位表整体加档。原表最高只有 24，而增益拉满时实测显示域
    //     噪声 σ 可达 60~80 ⇒ |Yc-blur| 绝大多数都超过 dz，coring 完全失效
    //     （模型实测噪声增益 0.97 ≈ 没压）。新表让 dz 与 σ 同量级。
    reg [7:0] dz_ag;
    reg       sh_off;                       // ★v3.2(B2)：1 = 当前增益档关闭锐化
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dz_ag  <= 8'd16;
            sh_off <= 1'b0;
        end else begin
            case (ag_s2[7:5])              // ag/32：0..7
                3'd0, 3'd1: dz_ag <= 8'd6;   // ≤ 2.8x（明亮）—— 低增益保留细节
                3'd2:       dz_ag <= 8'd10;  // ~5.7x
                3'd3:       dz_ag <= 8'd16;  // ~11x
                3'd4:       dz_ag <= 8'd24;  // ~22x
                3'd5:       dz_ag <= 8'd34;  // ~45x  ← 起，锐化自动关闭
                3'd6:       dz_ag <= 8'd44;  // ~63x
                default:    dz_ag <= 8'd56;  // 7: ≥224 (~126x，弱光) —— 与噪声 σ 同量级
            endcase
            //  ★v3.2(B2)：高增益下锐化项放大的全是噪声（unsharp 只认幅度、不认来源），
            //    所以 ag 档 ≥ SHARP_OFF_AG 时把 inc 强制为 0，退化为"纯降噪"。
            sh_off <= (ag_s2[7:5] >= SHARP_OFF_AG);
        end
    end

    wire [7:0] dz = ADAPT_EN ? dz_ag : CORE_DZ;

    //========================================================================
    // S1 组合：RGB → Y（Rec.601 定点，系数和 256，+128 四舍五入后 >>8）
    //   常数乘法由综合器化为移位加网络，不占 DSP。
    //========================================================================
    wire [7:0]  r_in = rgb_in[23:16];
    wire [7:0]  g_in = rgb_in[15:8];
    wire [7:0]  b_in = rgb_in[7:0];

    wire [17:0] y_sum = 18'd77 * r_in + 18'd150 * g_in + 18'd29 * b_in;
    wire [7:0]  y_w   = (y_sum + 18'd128) >> 8;

    reg        s1_de;
    reg [7:0]  s1_r, s1_g, s1_b;
    reg [7:0]  s1_y;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_de <= 1'b0;
            s1_r  <= 8'd0;  s1_g <= 8'd0;  s1_b <= 8'd0;  s1_y <= 8'd0;
        end else begin
            s1_de <= I_de;
            s1_r  <= r_in;  s1_g <= g_in;  s1_b <= b_in;  s1_y <= y_w;
        end
    end

    //------------------------------------------------------------------------
    // 列地址计数器（用 s1_de 使能；行间清零保证行对齐）
    //------------------------------------------------------------------------
    reg [ADDR_W-1:0] col_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            col_cnt <= {ADDR_W{1'b0}};
        else if (s1_de)
            col_cnt <= (col_cnt == IMG_WIDTH[ADDR_W-1:0] - 1'b1) ? {ADDR_W{1'b0}} : col_cnt + 1'b1;
        else
            col_cnt <= {ADDR_W{1'b0}};
    end

    //========================================================================
    // S2 组合：水平 [1 2 1]/4（只作用于 Y）
    //   窗口 [y_t2, y_t1, s1_y] = [p-1, p, p+1]，中心 = y_t1（同时就是 Yc）
    //========================================================================
    reg [7:0] y_t1, y_t2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            y_t1 <= 8'd0;  y_t2 <= 8'd0;
        end else begin
            y_t1 <= s1_y;  y_t2 <= y_t1;
        end
    end

    wire [9:0] h_sum = y_t2 + (y_t1 << 1) + s1_y;   // 最大 1020
    wire [7:0] h_y   = h_sum[9:2];                  // /4

    reg [7:0] r_t1, g_t1, b_t1;                     // 与中心 Y 对齐的 RGB
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_t1 <= 8'd0;  g_t1 <= 8'd0;  b_t1 <= 8'd0;
        end else begin
            r_t1 <= s1_r;  g_t1 <= s1_g;  b_t1 <= s1_b;
        end
    end

    //------------------------------------------------------------------------
    // S2 寄存器：打包 {Yc,hY} → 16bit；RGB 单独 24bit（同写地址/使能 ⇒ 自动对齐）
    //------------------------------------------------------------------------
    reg              s2_de;
    reg [ADDR_W-1:0] s2_addr;
    reg [15:0]       s2_y16;
    reg [23:0]       s2_rgb;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_de   <= 1'b0;
            s2_addr <= {ADDR_W{1'b0}};
            s2_y16  <= 16'd0;
            s2_rgb  <= 24'd0;
        end else begin
            s2_de   <= s1_de;
            s2_addr <= col_cnt;
            s2_y16  <= {y_t1, h_y};
            s2_rgb  <= {r_t1, g_t1, b_t1};
        end
    end

    //========================================================================
    // S3：行延时 RAM
    //   u_line1_y → p1_y16（中心行 row n-1）   u_line2_y → p2_y16（上上行 row n-2）
    //   u_line_rgb→ rgb_p1 （中心行 RGB，与 p1_y16 严格同拍）
    //========================================================================
    wire [15:0] p1_y16;
    wire [15:0] p2_y16;
    wire [23:0] rgb_p1;

    line_delay_ram #(
        .IMG_WIDTH (IMG_WIDTH), .ADDR_W (ADDR_W), .DW (16)
    ) u_line1_y (
        .clk (clk), .rst_n (rst_n), .I_wen (s2_de), .I_addr (s2_addr),
        .I_data (s2_y16), .O_data (p1_y16)
    );

    reg              p1_de;
    reg [ADDR_W-1:0] p1_addr;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p1_de   <= 1'b0;
            p1_addr <= {ADDR_W{1'b0}};
        end else begin
            p1_de   <= s2_de;
            p1_addr <= s2_addr;
        end
    end

    line_delay_ram #(
        .IMG_WIDTH (IMG_WIDTH), .ADDR_W (ADDR_W), .DW (16)
    ) u_line2_y (
        .clk (clk), .rst_n (rst_n), .I_wen (p1_de), .I_addr (p1_addr),
        .I_data (p1_y16), .O_data (p2_y16)
    );

    // ★v6.5：恢复为纯 24bit 像素行缓存（**不打包 de**，原因见端口 O_de 的注释）。
    //   行缓存读出 1 拍延迟由下面的 de_s3 单独补上，使 de 与数据严格同拍。
    line_delay_ram #(
        .IMG_WIDTH (IMG_WIDTH), .ADDR_W (ADDR_W), .DW (24)
    ) u_line_rgb (
        .clk (clk), .rst_n (rst_n), .I_wen (s2_de), .I_addr (s2_addr),
        .I_data (s2_rgb), .O_data (rgb_p1)
    );

    //------------------------------------------------------------------------
    // ★v6.5：输出 de 的**纯寄存器延时链**
    //   数据通路：I_de +1(s1) +1(s2) +1(行缓存读出) +6(s4..s9) +1(rgb_out) = 1 行 + 10 拍
    //   de  通路：I_de +1(s1) +1(s2) +1(de_s3)     +6(s4..s9) +1(O_de)     = 10 拍
    //   两者相差**恰好 1 个整行（1650 拍）**⇒ 行内相位完全一致，下游逐行对齐的
    //   列计数器（chroma_denoise）每次行消隐都能正确复位。
    //------------------------------------------------------------------------
    reg de_s3;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) de_s3 <= 1'b0;
        else        de_s3 <= s2_de;         // 补上行缓存的 1 拍读出延迟
    end

    reg [15:0] cur_y16;                             // "当前行 row n" 的 {Yc,hY}
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) cur_y16 <= 16'd0;
        else        cur_y16 <= s2_y16;
    end

    //========================================================================
    // S4：垂直 [1 2 1]/4 低通 ⇒ blur   （先水平再垂直 = 完整 3×3 高斯/16）
    //   逻辑 ≈3 级，寄存输出
    //========================================================================
    wire [7:0] Yc     = p1_y16[15:8];
    wire [7:0] hY_p1  = p1_y16[7:0];
    wire [7:0] hY_p2  = p2_y16[7:0];
    wire [7:0] hY_cur = cur_y16[7:0];

    wire [9:0] blur10 = hY_p2 + (hY_p1 << 1) + hY_cur;   // 最大 1020
    wire [7:0] blur_c = blur10[9:2];

    reg [7:0]  s4_blur, s4_Yc;
    reg [23:0] s4_rgb;
    reg        s4_de;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s4_blur <= 8'd0;  s4_Yc <= 8'd0;  s4_rgb <= 24'd0;  s4_de <= 1'b0;
        end else begin
            s4_blur <= blur_c;  s4_Yc <= Yc;  s4_rgb <= rgb_p1;  s4_de <= de_s3;
        end
    end

    //========================================================================
    // S5：高通幅度 diff_a = |Yc - blur| 与符号   （≈3 级）
    //   用「幅度 + 符号」两条无符号线表示，彻底规避 Verilog「部分选择
    //   永远无符号」的陷阱（chroma_denoise v2/v3 两次事故的根因）。
    //========================================================================
    wire [7:0] s5_diff_c = (s4_Yc >= s4_blur) ? (s4_Yc - s4_blur) : (s4_blur - s4_Yc);
    wire       s5_neg_c  = (s4_Yc <  s4_blur);

    reg [7:0]  s5_diff, s5_blur, s5_Yc;
    reg        s5_neg;
    reg [23:0] s5_rgb;
    reg        s5_de;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s5_diff <= 8'd0;  s5_blur <= 8'd0;  s5_Yc <= 8'd0;  s5_neg <= 1'b0;
            s5_rgb  <= 24'd0;  s5_de <= 1'b0;
        end else begin
            s5_diff <= s5_diff_c;  s5_blur <= s4_blur;  s5_Yc <= s4_Yc;
            s5_neg  <= s5_neg_c;   s5_rgb  <= s4_rgb;  s5_de <= s4_de;
        end
    end

    //========================================================================
    // S6：死区归零 ⇒ cored = max(diff_a - dz, 0)   （≈3 级）
    //   ★v6.4：dz 由 AE 增益自适应给出（ADAPT_EN=1）或取常量 CORE_DZ
    //========================================================================
    wire [7:0] s6_cored_c = (s5_diff > dz) ? (s5_diff - dz) : 8'd0;

    reg [7:0]  s6_cored, s6_blur, s6_Yc;
    reg        s6_neg;
    reg [23:0] s6_rgb;
    reg        s6_de;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s6_cored <= 8'd0;  s6_blur <= 8'd0;  s6_Yc <= 8'd0;  s6_neg <= 1'b0;
            s6_rgb   <= 24'd0;  s6_de <= 1'b0;
        end else begin
            s6_cored <= s6_cored_c;  s6_blur <= s5_blur;  s6_Yc <= s5_Yc;
            s6_neg   <= s5_neg;      s6_rgb  <= s5_rgb;  s6_de <= s5_de;
        end
    end

    //========================================================================
    // S7：Y_dn = blur ± cored；inc = cored >>> SHARP_SH   （≈2 级，纯移位不占 LUT）
    //
    //  ★v3.2：**这里不会 8bit 回绕 —— 用位级证明取代了原来的猜测**：
    //     neg 分支（Yc<blur）：cored = (blur-Yc) - dz ⇒ blur - cored = Yc + dz；
    //         coring 有效（cored>0）时必有 blur-Yc > dz ⇒ Yc+dz < blur ≤ 255 ⇒ 不回绕
    //     pos 分支（Yc≥blur）：blur + cored = Yc - dz ≥ 0                ⇒ 不回绕
    //     （cored=0 时两分支都退化成 blur，同样在 0~255 内。）
    //  由同一组关系还可推出 **|delta| = |Y_out - Yc| 恒 ≤ dz** —— 这是 S9 加
    //  DELTA_MAX 上限的依据（正常永不触发，只在上游异常样本时兜底）。
    //========================================================================
    wire [7:0] s7_ydn_c = s6_neg ? (s6_blur - s6_cored) : (s6_blur + s6_cored);
    //  ★v3.2(B2)：高增益档 inc 强制 0 ⇒ 退化为"仅降噪"。SHARP_OFF_AG=3'd7 时永不关。
    wire [7:0] s7_inc_c = sh_off ? 8'd0 : (s6_cored >> SHARP_SH);

    reg [7:0]  s7_ydn, s7_inc, s7_Yc;
    reg        s7_neg;
    reg [23:0] s7_rgb;
    reg        s7_de;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s7_ydn <= 8'd0;  s7_inc <= 8'd0;  s7_Yc <= 8'd0;  s7_neg <= 1'b0;
            s7_rgb <= 24'd0;  s7_de <= 1'b0;
        end else begin
            s7_ydn <= s7_ydn_c;  s7_inc <= s7_inc_c;  s7_Yc <= s6_Yc;
            s7_neg <= s6_neg;    s7_rgb <= s6_rgb;    s7_de <= s6_de;
        end
    end

    //========================================================================
    // S8：Y_out = Y_dn ± inc（限幅）；按 MODE 取锐化或仅降噪结果   （≈4 级）
    //========================================================================
    wire [8:0] s8_up   = s7_ydn + s7_inc;
    wire [7:0] s8_ysh_c = s7_neg ? ((s7_ydn >= s7_inc) ? (s7_ydn - s7_inc) : 8'd0)
                                 : ((s8_up > 9'd255) ? 8'd255 : s8_up[7:0]);
    wire [7:0] s8_yf_c  = (MODE_EFF == 2'd2) ? s8_ysh_c : s7_ydn;

    reg [7:0]  s8_yf, s8_Yc;
    reg [23:0] s8_rgb;
    reg        s8_de;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s8_yf <= 8'd0;  s8_Yc <= 8'd0;  s8_rgb <= 24'd0;  s8_de <= 1'b0;
        end else begin
            s8_yf <= s8_yf_c;  s8_Yc <= s7_Yc;  s8_rgb <= s7_rgb;  s8_de <= s7_de;
        end
    end

    //========================================================================
    // S9：delta 的幅度与符号   （≈3 级 + 钳位 1 级）
    //========================================================================
    wire [7:0] s9_dmag_c = (s8_yf >= s8_Yc) ? (s8_yf - s8_Yc) : (s8_Yc - s8_yf);
    wire       s9_dneg_c = (s8_yf <  s8_Yc);

    //  ★v3.2(B3)：|delta| 安全网。正常恒 ≤ dz（见 S7 证明），仅上游异常样本会超出；
    //    钳位加在**寄存器输入端**，S10 的组合深度不增加。
    wire [7:0] s9_dmag_lim = (s9_dmag_c > DELTA_MAX) ? DELTA_MAX : s9_dmag_c;

    reg [7:0]  s9_dmag;
    reg        s9_dneg;
    reg [23:0] s9_rgb;
    reg        s9_de;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s9_dmag <= 8'd0;  s9_dneg <= 1'b0;  s9_rgb <= 24'd0;  s9_de <= 1'b0;
        end else begin
            s9_dmag <= s9_dmag_lim;  s9_dneg <= s9_dneg_c;  s9_rgb <= s8_rgb;
            s9_de   <= s8_de;
        end
    end

    //========================================================================
    // S10：RGB + delta，限幅 0~255，输出寄存   （≈3 级）
    //   附加式锐化：三通道加同一 delta ⇒ 保持色相/饱和度不变
    //   MODE_EFF=0 时输出中心行 RGB 原值（保留延时与几何，便于严格 A/B）
    //========================================================================
    wire [7:0] s10_r = s9_rgb[23:16];
    wire [7:0] s10_g = s9_rgb[15:8];
    wire [7:0] s10_b = s9_rgb[7:0];

    wire [8:0] r_add = s10_r + s9_dmag;
    wire [8:0] g_add = s10_g + s9_dmag;
    wire [8:0] b_add = s10_b + s9_dmag;

    wire [7:0] r_o = s9_dneg ? ((s10_r > s9_dmag) ? (s10_r - s9_dmag) : 8'd0)
                             : ((r_add > 9'd255) ? 8'd255 : r_add[7:0]);
    wire [7:0] g_o = s9_dneg ? ((s10_g > s9_dmag) ? (s10_g - s9_dmag) : 8'd0)
                             : ((g_add > 9'd255) ? 8'd255 : g_add[7:0]);
    wire [7:0] b_o = s9_dneg ? ((s10_b > s9_dmag) ? (s10_b - s9_dmag) : 8'd0)
                             : ((b_add > 9'd255) ? 8'd255 : b_add[7:0]);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rgb_out <= 24'd0;
            O_de    <= 1'b0;
        end else begin
            O_de <= s9_de;                  // ★v6.5：纯寄存器延时链，与 rgb_out 同拍
            if (MODE_EFF == 2'd0)
                rgb_out <= s9_rgb;          // 直通（不做任何滤波，几何不变）
            else
                rgb_out <= {r_o, g_o, b_o};
        end
    end

endmodule

//============================================================================
// 上板调试提示
//----------------------------------------------------------------------------
// · 画面整体上移 1 行、右移约 10 像素：本模块固有延时（1 行 RAM + 10 拍流水），
//   与 chroma_denoise 同量级，肉眼不可察；灰度/二值/Sobel 分支不受影响。
// · ★v3.2 降噪强度自适应：默认 ADAPT_EN=1，死区随 AE 增益 6/10/16/24/34/44/56 七档；
//   要整体加强 → 把上面 case 表的七个值统一调大（调大前先看"边缘剖面"会不会糊）；
//   要回到固定死区 → ADAPT_EN=0，并改顶层 CORE_DZ。
//   ⚠️ 调大 dz 的代价：|detail| < dz 的**低对比度纹理会被一起清掉**。实测台阶 60→200
//      在 dz=6 时过渡 2 列、dz=56 时过渡 ~5 列（强边缘仍然清晰）；低增益档请务必
//      保持小 dz，否则明亮场景会显得"塑料感/糊"。
// · ★v3.2 高增益自动关锐化：SHARP_OFF_AG（默认 3'd5）表示 ag 档 ≥5（增益 ≥45x）时
//   inc 强制 0，模块退化为"仅降噪"。想让高增益下也保留锐化 → 填 3'd7。
// · 画面偏"软/糊"：档位表整体调小，或 SHARP_SH 由 1 改 2（降低锐化放大）。
// · 想更强锐化：SHARP_SH 改 0（1.0x，易出白边，谨慎）。
// · ⚠️ 周期性竖条纹：line_delay_ram.v 里的 syn_ramstyle 被工具选成 write-first，
//   把该行注释掉回退（详见 line_delay_ram.v 注释）。
// · ⚠️⚠️ **横向色带 / 右侧整片单一颜色（含纯黑）**：先查 O_de 的波形！
//     本模块 O_de 必须是"消隐期为低"的正常 de。若有人再把它改成从行缓存取位，
//     下游 chroma_denoise 的列计数器就会永不复位 ⇒ 每行相位漂移 (行周期-1280) 拍
//     ⇒ 右侧 (行周期-1280)/1280 的比例整片单色 + 其余部分横向色带。
//     自检：vcdc/vlint 查不出这类问题，靠"O_de 与 I_de 的占空比是否相同"判断。
// · ⚠️ **不要再把"满屏噪点"归罪于本模块**：现场照片的定量分析（见文件头 v3.2）
//     证明屏幕噪声是 100% 共模亮度噪声、且 ∝ AE 增益（亮场 σ≈2 / 暗场 σ≈13）。
//     本模块只能把高增益噪声压到 ~0.5 倍；要从根上降噪必须降增益或加曝光时间。
//     复查工具：python tools/img_enh_model.py（模块）、tools/_dbg_lag.py（真实噪声比）。
//============================================================================
