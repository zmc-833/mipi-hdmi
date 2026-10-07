//==============================================================================
//  lsc_shading.v —— 镜头色彩阴影校正（Lens Shading Correction, 彩色分量）
//------------------------------------------------------------------------------
//  【为什么需要这个模块】
//    2026-10-07 白墙实测：HDMI 画面**中间偏绿、四周发紫**（肉眼确认，非拍摄伪影）。
//    色彩误差随**空间位置**变化 —— 这正是镜头色彩阴影（Lens Color Shading）的特征：
//    镜头边缘入射角大，微透镜汇聚效率沿半径变化，且 R/G/B 三个通道的变化斜率不同，
//    表现为"中心与边缘的 R:G:B 比例不一致"。
//
//    关键点：**AWB 与 CCM 都治不了它**。
//      · AWB（灰度世界）= 全局通道增益，只能把"整幅画面的平均色调"校中性；
//        本例中"中心绿 + 边缘紫"平均下来正好是中性，AWB 会认为画面没问题。
//      · CCM（3×3 矩阵）= 全局线性变换，对全画面用同一组系数，
//        绿的还是绿、紫的还是紫。
//    所以必须在**像素级、随半径变化**地校正 —— 这就是本模块。
//
//  【放在哪一级：RAW10 域，BLC 之后、demosaic 之前】
//    sensor 的物理模型：raw = 信号(r)·shading_ch(r) + pedestal
//    本工程 BLC 已在 raw10_unpacket_2lane.v 里扣除（10bit 域扣 64），
//    之后再做径向增益：out = (raw - BL) · gain_ch(r)，
//    这样**黑电平不会被增益缩放**，角落依然是纯黑（否则角落会重新泛灰）。
//    同时它排在 demosaic 之前，避免插值把不同增益的邻域像素混在一起。
//
//  【时钟域与时序】
//    本模块跑在 S_csi_rx_clk（MIPI 字节时钟，720p60/2lane 下约 34.5 MHz，
//    周期约 29 ns），比 HDMI 像素时钟 74.25 MHz 宽裕一倍以上。
//    每拍只做：1 次常量乘法（求增益）+ 1 次像素乘法，中间一级寄存，时序非常安全。
//
//  【像素顺序（重要，改错会出现 2×2 棋盘伪影）】
//    上游 raw10_unpacket_2lane.v 输出 40bit = 4 个 10bit 像素：
//        I_data[ 9: 0] = P0 = 本组最左像素（x = 4n + 0，x 为偶数）
//        I_data[19:10] = P1 （x = 4n + 1，奇数）
//        I_data[29:20] = P2 （x = 4n + 2，偶数）
//        I_data[39:30] = P3 （x = 4n + 3，奇数）
//    已通过 mipi_to_raw_converter.v 核对：下游把 [9:2]/[19:12]/[29:22]/[39:32]
//    按此顺序打成 32bit（MSB = P0），且 demosaic 的 bayer_ypos = !v_cnt[0]
//    （偶数行 ypos=1，且偶数行首个像素取 B 为直接分量）—— 与 BGGR 定义一致。
//    ⇒ 偶数列( k=0/2 )：偶数行=B，奇数行=G
//      奇数列( k=1/3 )：偶数行=G，奇数行=R
//    若上板出现细密 2×2 彩色棋盘格，说明相位反了，改 BAYER_PHASE 参数。
//
//  【增益模型】
//    gain_ch(x,y) = 1 + P_ch/256 · ( r² / r²max )，  r² = dx² + dy²
//      dx = 2x - (W-1)，dy = 2y - (H-1)      （用 2 倍坐标，避免 0.5 中心误差）
//      r²max = (W-1)² + (H-1)²               （角落值）
//    ⇒ 中心增益恒为 1.0，角落增益 = (256 + P_ch)/256。
//    P_ch 为带符号 Q8 参数：256 = +1.0，即
//        P = -38  →  角落 ×(256-38)/256 = 0.85（角落衰减 15%）
//        P =  38  →  角落 ×1.15
//    物理上"边缘发紫"= 边缘 R、B 相对过量 ⇒ 取 P_R、P_B 为**负值**衰减边缘 R/B；
//    以 G 为基准（P_G = 0），这样只改颜色比例、不动整体亮度趋势。
//
//  【位宽与定点化】
//    r² 最大 2152802（22bit），为省乘法器位宽先 >>>8 得 r2s（≤8409，14bit），
//    再乘合并常数 M_ch = P_ch·65536 / (r²max>>8)，结果 >>>16 得增益增量。
//    ⚠️ 坑：Verilog 中 `>>> ` 只有在**两侧都是有符号数**时才做算术右移；
//       本模块所有参与 `>>> ` 的信号都显式声明为 signed（见 r2s_* / M_*）。
//
//  【延迟】
//    固定 2 拍：第 1 拍寄存像素与 r²，第 2 拍算增益并输出。
//    I_frame_start / I_frame_end / I_valid 同步延迟 2 拍，保证下游对齐。
//==============================================================================

`timescale 1ns / 1ps

module lsc_shading #(
    //---------------------------------------------------------------- 图像尺寸
    parameter IMG_WIDTH   = 1280,
    parameter IMG_HEIGHT  = 720,

    //---------------------------------------------------------------- Bayer 相位
    // 2'd0 = BGGR（本项目实际值） 2'd1 = GBRG  2'd2 = GRBG  2'd3 = RGGB
    parameter       [1:0] BAYER_PHASE = 2'd0,

    //------------------------------------------------------- 角落增益增量（Q8）
    // 256 = +1.0；负值 = 角落衰减，正值 = 角落提升。建议先只调 P_R / P_B。
    parameter signed [15:0] P_R = -38,      // 角落 R ×0.85（治"边缘发紫"）
    parameter signed [15:0] P_G =   0,      // G 作为基准通道，一般保持 0
    parameter signed [15:0] P_B = -38,      // 角落 B ×0.85

    //---------------------------------------------------------------- 使能
    parameter EN = 1                        // 0 = 纯直通（仍保持 2 拍延迟）
) (
    input  wire        I_clk,
    input  wire        I_rst_n,

    input  wire        I_valid,             // 像素有效（每个时钟 4 像素）
    input  wire        I_frame_start,       // 帧开始
    input  wire        I_frame_end,         // 帧结束
    input  wire [39:0] I_data,              // 4 × 10bit RAW（已扣黑电平）

    output reg         O_valid,
    output reg         O_frame_start,
    output reg         O_frame_end,
    output reg  [39:0] O_data
);

  //==========================================================================
  //  1. 常数推导
  //==========================================================================
  localparam integer WPL      = IMG_WIDTH  >> 2;              // 每行字数 = 320
  localparam [ 8:0]  WPL_M1   = WPL - 1;                      // 319
  localparam [ 9:0]  H_M1     = IMG_HEIGHT - 1;               // 719

  // 中心用"2 倍坐标"表示：dx = 2x - (W-1)，保证中心落在 0 附近且对称
  localparam signed [12:0] CX2_S = IMG_WIDTH  - 1;            // 1279
  localparam signed [11:0] CY2_S = IMG_HEIGHT - 1;            // 719

  // r²max 先 >>8（省乘法位宽），用于把 P_ch 折算成单乘法常数
  localparam integer R2MAX_S = (((IMG_WIDTH - 1) * (IMG_WIDTH - 1)) +
                                ((IMG_HEIGHT - 1) * (IMG_HEIGHT - 1))) >> 8;   // 8409

  // M_ch：一个乘法就能算出增益增量 —— delta = (r2s * M_ch) >>> 16
  localparam signed [15:0] M_R = (P_R * 65536) / R2MAX_S;
  localparam signed [15:0] M_G = (P_G * 65536) / R2MAX_S;
  localparam signed [15:0] M_B = (P_B * 65536) / R2MAX_S;

  localparam [1:0] CH_R = 2'd0, CH_G = 2'd1, CH_B = 2'd2;

  //==========================================================================
  //  2. 坐标计数器
  //     复位与 uial2axis 完全同构（I_frame_start 复位、满行归零、满帧归零），
  //     保证本模块算出的 (x,y) 与下游统计到的位置一致。
  //     注意：所有 RHS 都用"当前拍"的 I_valid，配合非阻塞赋值，
  //     hcnt/vcnt 在沿后的值 = 当前正在输入的那一个字的坐标。
  //==========================================================================
  reg [8:0] hcnt;      // 0 ~ 319
  reg [9:0] vcnt;      // 0 ~ 719

  always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
      hcnt <= 9'd0;
      vcnt <= 10'd0;
    end else if (I_frame_start) begin
      hcnt <= 9'd0;
      vcnt <= 10'd0;
    end else if (I_valid) begin
      if (hcnt == WPL_M1) begin
        hcnt <= 9'd0;
        vcnt <= (vcnt == H_M1) ? 10'd0 : (vcnt + 10'd1);
      end else begin
        hcnt <= hcnt + 9'd1;
      end
    end
  end

  //==========================================================================
  //  3. 第 1 拍：算 r²（dx² + dy²）
  //     一组 4 个像素 x 连续，dx 每次 +2，用"平方展开"省乘法器：
  //       dx_k = dx0 + 2k  ⇒  dx_k² = dx0² + 4k·dx0 + 4k²
  //==========================================================================
  wire signed [12:0] dx0 = $signed({1'b0, hcnt, 3'b000}) - CX2_S;   // 8·hcnt - 1279
  wire signed [11:0] dy  = $signed({1'b0, vcnt, 1'b0})   - CY2_S;   // 2·vcnt - 719

  wire signed [23:0] dx0sq = dx0 * dx0;                       // ≤ 1635841
  wire signed [23:0] dysq  = dy  * dy;                        // ≤  516961

  wire signed [23:0] dx1sq = dx0sq + (dx0 * 4)  +  4;         // (dx0+2)²
  wire signed [23:0] dx2sq = dx0sq + (dx0 * 8)  + 16;         // (dx0+4)²
  wire signed [23:0] dx3sq = dx0sq + (dx0 * 12) + 36;         // (dx0+6)²

  wire signed [23:0] r2_0 = dx0sq + dysq;                     // ≤ 2152802（22bit 够）
  wire signed [23:0] r2_1 = dx1sq + dysq;
  wire signed [23:0] r2_2 = dx2sq + dysq;
  wire signed [23:0] r2_3 = dx3sq + dysq;

  //==========================================================================
  //  4. 第 1 拍寄存器：像素 + r2s + 行奇偶
  //==========================================================================
  reg        [39:0] d1;
  reg               v1, yp_r, fs1, fe1;
  reg signed [15:0] r2s_r0, r2s_r1, r2s_r2, r2s_r3;          // r² >>> 8，恒为正

  always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
      d1     <= 40'd0;
      v1     <= 1'b0;
      yp_r   <= 1'b0;
      fs1    <= 1'b0;
      fe1    <= 1'b0;
      r2s_r0 <= 16'sd0;
      r2s_r1 <= 16'sd0;
      r2s_r2 <= 16'sd0;
      r2s_r3 <= 16'sd0;
    end else begin
      d1     <= I_data;
      v1     <= I_valid;
      yp_r   <= vcnt[0];          // 行奇偶（0 = 偶数行）
      fs1    <= I_frame_start;
      fe1    <= I_frame_end;
      r2s_r0 <= r2_0 >>> 8;
      r2s_r1 <= r2_1 >>> 8;
      r2s_r2 <= r2_2 >>> 8;
      r2s_r3 <= r2_3 >>> 8;
    end
  end

  //==========================================================================
  //  5. 通道判定（Bayer 相位）
  //==========================================================================
  function [1:0] bayer_ch;
    input yp;                     // 行奇偶：0 = 偶数行
    input xp;                     // 列奇偶：0 = 偶数列
    begin
      case (BAYER_PHASE)
        2'd0: bayer_ch = (!yp && !xp) ? CH_B : ((yp && xp) ? CH_R : CH_G);   // BGGR
        2'd1: bayer_ch = (!yp &&  xp) ? CH_B : ((yp && !xp) ? CH_R : CH_G);  // GBRG
        2'd2: bayer_ch = ( yp && !xp) ? CH_B : ((!yp && xp) ? CH_R : CH_G);  // GRBG
        2'd3: bayer_ch = (!yp && !xp) ? CH_R : ((yp && xp) ? CH_B : CH_G);   // RGGB
        default: bayer_ch = CH_G;
      endcase
    end
  endfunction

  // k=0/2 → 偶数列(xp=0)；k=1/3 → 奇数列(xp=1)
  wire [1:0] ch0 = bayer_ch(yp_r, 1'b0);
  wire [1:0] ch1 = bayer_ch(yp_r, 1'b1);
  wire [1:0] ch2 = bayer_ch(yp_r, 1'b0);
  wire [1:0] ch3 = bayer_ch(yp_r, 1'b1);

  wire signed [15:0] m0 = (ch0 == CH_R) ? M_R : (ch0 == CH_G ? M_G : M_B);
  wire signed [15:0] m1 = (ch1 == CH_R) ? M_R : (ch1 == CH_G ? M_G : M_B);
  wire signed [15:0] m2 = (ch2 == CH_R) ? M_R : (ch2 == CH_G ? M_G : M_B);
  wire signed [15:0] m3 = (ch3 == CH_R) ? M_R : (ch3 == CH_G ? M_G : M_B);

  //==========================================================================
  //  6. 第 2 拍：增益 → 像素乘法 → 限幅
  //==========================================================================
  // 增益增量：delta = (r2s * M) >>> 16   （两侧均 signed ⇒ 算术右移）
  wire signed [11:0] dlt0 = (r2s_r0 * m0) >>> 16;
  wire signed [11:0] dlt1 = (r2s_r1 * m1) >>> 16;
  wire signed [11:0] dlt2 = (r2s_r2 * m2) >>> 16;
  wire signed [11:0] dlt3 = (r2s_r3 * m3) >>> 16;

  // 增益 Q8：256 = 1.0；限幅到 0 ~ 1023（0 ~ 4.0 倍），防极端参数下溢出
  wire signed [11:0] gp0 = dlt0 + 256;
  wire signed [11:0] gp1 = dlt1 + 256;
  wire signed [11:0] gp2 = dlt2 + 256;
  wire signed [11:0] gp3 = dlt3 + 256;

  wire [9:0] g0 = (gp0 < 0) ? 10'd0 : (gp0 > 1023) ? 10'd1023 : gp0[9:0];
  wire [9:0] g1 = (gp1 < 0) ? 10'd0 : (gp1 > 1023) ? 10'd1023 : gp1[9:0];
  wire [9:0] g2 = (gp2 < 0) ? 10'd0 : (gp2 > 1023) ? 10'd1023 : gp2[9:0];
  wire [9:0] g3 = (gp3 < 0) ? 10'd0 : (gp3 > 1023) ? 10'd1023 : gp3[9:0];

  // 像素乘法（带四舍五入），再限幅到 10bit 量程
  wire [19:0] p0 = d1[ 9: 0] * g0;
  wire [19:0] p1 = d1[19:10] * g1;
  wire [19:0] p2 = d1[29:20] * g2;
  wire [19:0] p3 = d1[39:30] * g3;

  wire [11:0] o0p = (p0 + 20'd128) >> 8;
  wire [11:0] o1p = (p1 + 20'd128) >> 8;
  wire [11:0] o2p = (p2 + 20'd128) >> 8;
  wire [11:0] o3p = (p3 + 20'd128) >> 8;

  wire [9:0] o0 = (o0p > 12'd1023) ? 10'd1023 : o0p[9:0];
  wire [9:0] o1 = (o1p > 12'd1023) ? 10'd1023 : o1p[9:0];
  wire [9:0] o2 = (o2p > 12'd1023) ? 10'd1023 : o2p[9:0];
  wire [9:0] o3 = (o3p > 12'd1023) ? 10'd1023 : o3p[9:0];

  //==========================================================================
  //  7. 输出寄存（固定 2 拍延迟；EN=0 时直通，延迟不变）
  //==========================================================================
  wire [39:0] out_word = EN ? {o3, o2, o1, o0} : d1;

  always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
      O_data        <= 40'd0;
      O_valid       <= 1'b0;
      O_frame_start <= 1'b0;
      O_frame_end   <= 1'b0;
    end else begin
      O_data        <= out_word;
      O_valid       <= v1;
      O_frame_start <= fs1;
      O_frame_end   <= fe1;
    end
  end

endmodule
