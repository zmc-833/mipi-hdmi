//==============================================================================
//  awb_frame.v —— 全帧统计式自动白平衡（AWB v2，灰度世界）
//------------------------------------------------------------------------------
//  【为什么要重写 AWB】
//    2026-10-07 上板实测（照片量化分析）：彩色模式满屏粉红块 + 椒盐噪点，
//    R 通道有 5.76% 的像素被削顶到 ≥250（G 仅 0.09%、B 0.43%），全屏 R/G=1.25。
//
//    链路定位（有数据支撑）：
//      AWB 输出的通道比例没校准 → sat_enhance 把色度再放大 1.5 倍
//      → 亮部 R 撞 255 被钳位 → 钳位破坏 Y 守恒 → 亮度出现 22.9 的像素级抖动
//      → 肉眼看到"粉红块 + 椒盐"。
//
//    ★ 为什么灰度模式看不出来（重要认知）：
//      灰度要的是 Y，而灰度模式下 R=G=B，AWB 的"通道比例错误"对 Y 完全不可见。
//      所以"灰度正常"既不能证明 AWB 正常，也不能证明 LSC 相位正确 —— 别再用它当判据。
//
//    旧实现（isp/awb/awb.v，实际生效的那份）的结构性问题：
//      1. Σ 在【帧开始】复位为 0，之后**帧内滚动累加**，除法器 start 每拍都发
//         ⇒ 增益是"从帧首累计到当前"的比值，随画面位置一路变化；
//           帧开头样本极少，此时 ΣR 很小甚至为 0，
//           商 = ΣG·65536/ΣR 会撞上"高位非零 ⇒ 限幅 0xFFFFF(≈16x)"那条分支，
//           R 被乘以 16 倍直接削顶。
//      2. 数据经 signal_delay 延迟 53 拍，增益却只延迟 (2+除法器latency) 拍，
//         二者相差约 (49-latency) 拍 ⇒ 画面内容变化时白平衡漂移。
//      3. 增益只做了"防溢出限幅"(16x)，没有合理的物理范围限制，也没有帧间平滑。
//
//  【本模块的做法（标准 ISP 流程）】
//    · 统计：对【整帧】所有像素累加 ΣR/ΣG/ΣB，而不是滚动统计。
//    · 锁存：帧开始(I_tuser)那一刻把上一帧的 Σ 锁存，并清零累加器开新帧。
//    · 计算：用锁存的 Σ 算一次增益  gR = ΣG/ΣR，gB = ΣG/ΣB（G 通道不动）。
//    · 应用：下一帧【整帧统一】使用这一组增益 —— 所以不再需要 50 拍数据延迟，
//            也不再存在"增益与像素错位"的问题。
//    · 保护：增益钳位在 [G_MIN, G_MAX]（默认 0.50x ~ 2.00x）；
//            Σ 异常(为 0)时回退到 1.0x；帧间做 1/4 权重的 IIR 平滑防跳变；
//            统计时跳过饱和像素(Σr+Σg+Σb≥750)，避免高光把白平衡带偏。
//
//  【定点约定】
//    增益为 Q16：20'h10000 = 1.0000x，20'h08000 = 0.5x，20'h20000 = 2.0x。
//    除法器：numerator = {ΣG,16'd0}（48bit），denominator = ΣR（32bit），
//            quotient 低 20 位即 Q16 增益（≥2^20 视为溢出，直接取 G_MAX）。
//    像素乘法：R_new = gR × R（20bit×8bit=28bit），取 [23:16] 为整数部分，
//              若 [27:24] 非零则钳位到 255（与旧实现一致，避免回绕）。
//
//  【★★ 延迟与相位：本模块与 video_in 的硬契约（2026-10-07 踩坑修复）★★】
//    契约：**O_tuser 必须比 O_tdata 早 ≥12 个相机时钟**。
//
//    为什么（这是"画面抖动 + 右侧错位长条"的根因）：
//      video_in.v 拿 I_camera_frame_start 做三件事：
//        ① 复位写侧 FIFO —— 注意 S_fifo_rst = 该脉冲【被拉宽成 8 个相机时钟】的电平
//        ② 推进 4 缓冲区写指针  ③ 重载 DDR 写基地址
//      ⇒ 帧起始脉冲若晚于/贴近本帧第一个数据字，FIFO 的复位窗口就压在帧首数据上，
//        这些数据字被当垃圾丢掉 ⇒ 整帧在 DDR 里整体前移 ⇒ 右侧出现错位条带；
//        又因 S_csi_rx_clk(相机) 与 S_ddr_clk(DDR) 在 SDC 里是【异步时钟组】，
//        两者相位持续漂移 ⇒ 每帧丢的字数不固定 ⇒ 画面持续横向抖动。
//
//    旧实现（工程 .al 实际编译的【根目录 awb.v】）恰好满足契约：
//        assign O_tuser = I_tuser;            // 0 拍，组合直通
//        数据经 signal_delay(DELAY_CYCLE=50)  // 约 53 拍
//      ⇒ 早约 53 拍，所以一直没暴露问题。
//    本模块初版只早 1 拍 ⇒ 上板立刻出现抖动与右侧长条。
//    因此引入 DATA_LEAD：把【数据/valid】多延迟 DATA_LEAD 拍，tuser 不延迟。
//      ⇒ 输出相位：O_tuser = I_tuser + 2
//                  O_tdata = I_tdata + 3 + DATA_LEAD
//        领先量 = 1 + DATA_LEAD（默认 32 ⇒ 领先 33 拍，等于复位窗口的 4 倍）。
//
//    ⚠️ DATA_LEAD 必须 ≥ 12（8 拍复位窗口 + 同步余量），且必须远小于帧消隐宽度
//       （消隐上万拍，32 完全安全）。把它改小到 0/1 会立刻重新引入抖动，勿随意改。
//    ⚠️ 下游 data_96bit_to_128bit 会给 tuser 和数据各 +1 拍，相对领先量不变。
//
//  【v6.2.1 修复（2026-10-07 下午）—— 针对"颜色一直在变"】
//    ① 增益改为【帧边界切换】：原实现除法 done(帧内 ~50 拍)时直接改写增益，
//       每帧前 ~200 像素用旧值、其余用新值 ⇒ 帧内色差台阶 + 台阶位置浮动。
//       现在 done 只算候选值，真正切换推迟到下一帧的 I_tuser。
//    ② 新增【变化死区 G_DEADZONE】：|测量值−当前值| ≤ 死区时不切换，抑制微抖。
//    ③ IIR 权重参数化 IIR_SHIFT（默认 3 ⇒ 时间常数 8 帧，比原来的 4 帧更稳）。
//    O_tlast 沿用旧实现的做法：valid 的上升沿 = 新的一行开始
//      （旧代码 O_tlast = (valid_d1==0)&&(valid_d2==1)），行为完全一致。
//    ⚠️ 本模块不需要旧实现的 signal_delay 行缓存来做"增益对齐"（整帧同一组增益），
//       但【必须】保留 6b 节的 DATA_LEAD 延迟线来满足 tuser 领先契约 —— 两者目的不同。
//
//  【复用工程内 divider IP 的端口定义（★写错位宽会直接编译报错，务必对照）】
//    module divider(clk, denominator, numerator, rst, start, done, quotient, remainder);
//      input  [31:0] denominator;
//      input  [47:0] numerator;
//      input         start;        // 单拍脉冲启动一次
//      output        done;         // 约 50 拍后单拍脉冲
//      output [47:0] quotient;     // ★48bit，不是 80bit
//      output [31:0] remainder;
//    parameter PIPLE = 50;         // 流水线型，无需 start 保持
//
//  【资源】
//    2 个 divider IP（工程中已存在，旧 awb 用了 8 个，这里省 6 个）；
//    无 BRAM；DATA_LEAD 级 FF 延迟线（32 x 97 ≈ 3200 FF）。
//==============================================================================

`timescale 1ns / 1ps

module awb_frame #(
    //---------------------------------------------------------- 图像尺寸（保留参数）
    // 本模块按 AXI-Stream 的 tuser/tlast 工作，不依赖具体分辨率，
    // 保留这两个参数只是为了与旧 awb 的实例化接口完全兼容。
    parameter IMG_HEIGHT = 720,
    parameter IMG_WIDTH  = 1280,

    //-------------------------------------------------------------------- 总开关
    parameter EN = 1'b1,             // 0 = 旁路（增益恒 1.0x，用于上板 A/B 对比）

    //------------------------------------------------------------ 增益物理范围(Q16)
    parameter [19:0] G_MIN = 20'h08000,   // 0.500x —— R/B 增益下限
    parameter [19:0] G_MAX = 20'h20000,   // 2.000x —— R/B 增益上限

    //-------------------------------------------------------------- 帧间 IIR 平滑
    // 新增益 = (1-2^-S)·旧 + 2^-S·新。S=3 ⇒ 时间常数 8 帧（默认，更稳）；
    //         S=2 ⇒ 4 帧（响应快但更容易看到颜色轻微起伏）；S=4 ⇒ 16 帧（很稳很慢）。
    parameter [3:0] IIR_SHIFT = 4'd3,

    //------------------------------------------------------------ 增益变化死区(Q16)
    // |新值 − 当前值| ≤ 该阈值时【不更新】，抑制微小抖动造成的"颜色一直在变"。
    // 20'h00100 = 1/256 ≈ 0.4%；设为 0 可关闭死区。
    parameter [19:0] G_DEADZONE = 20'h00100,

    parameter SKIP_SATURATED = 1'b1,      // 1 = 统计时跳过饱和像素

    //-------------------------------------------------------- 数据延迟拍数（★关键）
    // 只延迟【数据/valid/tlast】，不延迟 tuser ⇒ O_tuser 领先 O_tdata (1+DATA_LEAD) 拍。
    // 下游 video_in.v 用 tuser 复位 DDR 写侧 FIFO，复位窗口宽 8 个相机时钟，
    // 且相机时钟与 DDR 时钟异步 ⇒ 帧起始必须比本帧首个数据字早 ≥12 拍。
    // 取 32 = 复位窗口的 4 倍，留足异步同步余量。
    // 该值必须远小于帧消隐宽度（消隐约上万拍，32 绝对安全）。
    // 详见文件头【延迟与相位】与第 6b 节。必须 ≥ 2（内部要用到 DATA_LEAD-1）。
    parameter DATA_LEAD = 32
) (
    input  wire        I_clk,
    input  wire        I_rst_n,

    input  wire        I_tlast,
    input  wire        I_tuser,      // ★ 帧开始（每帧一个脉冲）
    input  wire [95:0] I_tdata,      // 4 像素 × RGB888（同一个像素的 R,G,B 连续排列）
    input  wire        I_tvalid,
    output wire        I_tready,

    output reg         O_tlast,
    output reg         O_tuser,
    output reg  [95:0] O_tdata,
    output reg         O_tvalid,
    input  wire        O_tready,

    //------------------------------------------ 增益可观测量（供 cwc/ILA 调试，可悬空）
    output wire [19:0] O_gain_r,
    output wire [19:0] O_gain_b
);

  //==========================================================================
  //  1. 输入像素拆分（当拍，不延迟）
  //     I_tdata 布局：像素0 = [23:0]，像素1 = [47:24]，像素2 = [71:48]，像素3 = [95:72]
  //     每像素内：R = [23:16]，G = [15:8]，B = [7:0]
  //==========================================================================
  wire [7:0] p0_r = I_tdata[23:16], p0_g = I_tdata[15:8], p0_b = I_tdata[ 7:0];
  wire [7:0] p1_r = I_tdata[47:40], p1_g = I_tdata[39:32], p1_b = I_tdata[31:24];
  wire [7:0] p2_r = I_tdata[71:64], p2_g = I_tdata[63:56], p2_b = I_tdata[55:48];
  wire [7:0] p3_r = I_tdata[95:88], p3_g = I_tdata[87:80], p3_b = I_tdata[79:72];

  //-------------------------------- 饱和像素判断（跳过过亮像素，避免高光绑架统计）
  wire [9:0] sat_sum0 = p0_r + p0_g + p0_b;
  wire [9:0] sat_sum1 = p1_r + p1_g + p1_b;
  wire [9:0] sat_sum2 = p2_r + p2_g + p2_b;
  wire [9:0] sat_sum3 = p3_r + p3_g + p3_b;

  wire ok0 = (SKIP_SATURATED == 1'b0) || (sat_sum0 < 10'd750);
  wire ok1 = (SKIP_SATURATED == 1'b0) || (sat_sum1 < 10'd750);
  wire ok2 = (SKIP_SATURATED == 1'b0) || (sat_sum2 < 10'd750);
  wire ok3 = (SKIP_SATURATED == 1'b0) || (sat_sum3 < 10'd750);

  wire [7:0] s0_r = ok0 ? p0_r : 8'd0,  s0_g = ok0 ? p0_g : 8'd0,  s0_b = ok0 ? p0_b : 8'd0;
  wire [7:0] s1_r = ok1 ? p1_r : 8'd0,  s1_g = ok1 ? p1_g : 8'd0,  s1_b = ok1 ? p1_b : 8'd0;
  wire [7:0] s2_r = ok2 ? p2_r : 8'd0,  s2_g = ok2 ? p2_g : 8'd0,  s2_b = ok2 ? p2_b : 8'd0;
  wire [7:0] s3_r = ok3 ? p3_r : 8'd0,  s3_g = ok3 ? p3_g : 8'd0,  s3_b = ok3 ? p3_b : 8'd0;

  //==========================================================================
  //  2. 帧内累加（32bit 足够：921600 像素 × 255 ≈ 2.35e8 < 2^32）
  //     帧开始(I_tuser)清零；I_tuser 那一拍的数据不计入（每帧丢 4 个像素，无影响）
  //==========================================================================
  reg [31:0] acc_r, acc_g, acc_b;

  always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
      acc_r <= 32'd0;
      acc_g <= 32'd0;
      acc_b <= 32'd0;
    end else if (I_tuser) begin
      // 帧开始：清零，准备统计新的一帧（复用上一帧统计在下一段的锁存里完成）
      acc_r <= 32'd0;
      acc_g <= 32'd0;
      acc_b <= 32'd0;
    end else if (I_tvalid) begin
      acc_r <= acc_r + s0_r + s1_r + s2_r + s3_r;
      acc_g <= acc_g + s0_g + s1_g + s2_g + s3_g;
      acc_b <= acc_b + s0_b + s1_b + s2_b + s3_b;
    end
  end

  //==========================================================================
  //  3. 帧开始锁存上一帧的 Σ，并发出一拍 start 给除法器
  //     注意：非阻塞赋值 ⇒ I_tuser 当拍读到的 acc_* 就是"上一帧的完整累计值"
  //==========================================================================
  reg [31:0] sum_r_l, sum_g_l, sum_b_l;
  reg        start_div;

  always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
      sum_r_l   <= 32'd0;
      sum_g_l   <= 32'd0;
      sum_b_l   <= 32'd0;
      start_div <= 1'b0;
    end else begin
      start_div <= I_tuser;                 // 1 拍脉冲
      if (I_tuser) begin
        sum_r_l <= acc_r;
        sum_g_l <= acc_g;
        sum_b_l <= acc_b;
      end
    end
  end

  //------------------------------------------- Σ 异常（为 0）保护：本帧回退到 1.0x
  wire invalid_sum = (sum_r_l == 32'd0) || (sum_g_l == 32'd0) || (sum_b_l == 32'd0);

  reg invalid_hold;                          // 与除法器 done 对齐
  always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)          invalid_hold <= 1'b1;
    else if (start_div)    invalid_hold <= invalid_sum;
  end

  //==========================================================================
  //  4. 除法：gR = ΣG·65536 / ΣR ，gB = ΣG·65536 / ΣB
  //     （G 通道为基准，增益恒为 1.0x —— 与旧实现一致，也避免整体亮度被改动）
  //==========================================================================
  // ⚠️ quotient 位宽 = 48bit（与工程里 divider IP 的 numer_width 一致，勿写大）
  wire [47:0] q_r, q_b;
  wire        done_r, done_b;

  divider u_div_r (
      .clk        (I_clk            ),
      .rst        (!I_rst_n         ),
      .start      (start_div        ),
      .denominator(sum_r_l          ),   // 32bit
      .numerator  ({sum_g_l, 16'd0} ),   // 48bit
      .quotient   (q_r              ),   // 80bit（只用低 20 位）
      .done       (done_r           )
  );

  divider u_div_b (
      .clk        (I_clk            ),
      .rst        (!I_rst_n         ),
      .start      (start_div        ),
      .denominator(sum_b_l          ),
      .numerator  ({sum_g_l, 16'd0} ),
      .quotient   (q_b              ),
      .done       (done_b           )
  );

  //------------------------------------- 商 → 增益（Q16），并做物理范围钳位
  function [19:0] clamp_gain;
    input [47:0] q;                                                  // 与 divider.quotient 同宽
    begin
      if (|q[47:20])            clamp_gain = G_MAX;                  // 高位非零 ⇒ 商 ≥16x，视为溢出
      else if (q[19:0] > G_MAX) clamp_gain = G_MAX;                  // 超上限
      else if (q[19:0] < G_MIN) clamp_gain = G_MIN;                  // 超下限
      else                      clamp_gain = q[19:0];                // 正常
    end
  endfunction

  wire [19:0] g_meas_r = clamp_gain(q_r);
  wire [19:0] g_meas_b = clamp_gain(q_b);

  //==========================================================================
  //  5. 帧间 IIR 平滑 + 【帧边界切换】（v6.2.1 修复）
  //--------------------------------------------------------------------------
  //  ⚠️ 原实现（v6.2）在除法 done(帧内约第 50 拍)时【直接改写当前增益】，
  //     于是"每帧的前 ~200 像素用旧增益、其余用新增益" ⇒ 帧内出现色差台阶，
  //     且每帧台阶位置随 done 时刻浮动，肉眼就是"颜色一直在变"。
  //
  //  改为两段式：
  //    ① 除法 done → 只把新值算好存进 gain_nxt（本帧继续用 gain_r，不受影响）
  //    ② 下一帧 I_tuser → 整帧把 gain_r 切到 gain_nxt
  //  ⇒ 整帧严格共用同一组增益，且只在帧边界切换，帧内绝无色差台阶。
  //
  //  另加【变化死区】：|测量值 − 当前值| ≤ G_DEADZONE 时保持现状不切换，
  //  抑制静止场景下 AWB 的微小来回抖动（"颜色一直在变"的另一半原因）。
  //==========================================================================
  reg [19:0] gain_r,     gain_b;        // 当前生效增益（只在帧边界更新）
  reg [19:0] gain_nxt_r, gain_nxt_b;    // 下一帧候选增益（除法完成后算好）
  reg        upd_r,      upd_b;         // 候选增益已就绪

  // 原始误差的绝对值（Q16）：|测量值 − 当前生效值|
  wire [19:0] err_r = (g_meas_r > gain_r) ? (g_meas_r - gain_r) : (gain_r - g_meas_r);
  wire [19:0] err_b = (g_meas_b > gain_b) ? (g_meas_b - gain_b) : (gain_b - g_meas_b);

  always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
      gain_r     <= 20'h10000;  gain_b     <= 20'h10000;
      gain_nxt_r <= 20'h10000;  gain_nxt_b <= 20'h10000;
      upd_r      <= 1'b0;       upd_b      <= 1'b0;
    end else begin
      //---------- ② 帧边界：整帧统一切换到候选增益 ----------
      if (I_tuser) begin
        if (upd_r) gain_r <= gain_nxt_r;
        if (upd_b) gain_b <= gain_nxt_b;
        upd_r <= 1'b0;
        upd_b <= 1'b0;
      end

      //---------- ① 除法完成：只算候选值，绝不动当前值 ----------
      //   （放在 I_tuser 之后 ⇒ 两者同拍时以 done 为准，不会丢一次更新）
      if (done_r) begin
        if (invalid_hold) begin
          gain_nxt_r <= 20'h10000;          // Σ 异常 → 回退 1.0x
          upd_r      <= 1'b1;
        end else if (err_r > G_DEADZONE) begin
          gain_nxt_r <= gain_r    - (gain_r    >>> IIR_SHIFT)
                                 + (g_meas_r >>> IIR_SHIFT);
          upd_r      <= 1'b1;
        end else begin
          upd_r      <= 1'b0;               // 误差在死区内 → 保持现状
        end
      end

      if (done_b) begin
        if (invalid_hold) begin
          gain_nxt_b <= 20'h10000;
          upd_b      <= 1'b1;
        end else if (err_b > G_DEADZONE) begin
          gain_nxt_b <= gain_b    - (gain_b    >>> IIR_SHIFT)
                                 + (g_meas_b >>> IIR_SHIFT);
          upd_b      <= 1'b1;
        end else begin
          upd_b      <= 1'b0;
        end
      end
    end
  end

  wire [19:0] gain_r_use = EN ? gain_r : 20'h10000;
  wire [19:0] gain_b_use = EN ? gain_b : 20'h10000;

  assign O_gain_r = gain_r_use;               // 调试用，可悬空
  assign O_gain_b = gain_b_use;

  //==========================================================================
  //  6. 数据通路：基础延迟 2 拍（d1 收输入、d2 供增益乘法）
  //     注：I_tlast 不作处理 —— 旧 awb 也是用 valid 上升沿当行结束（见第 7 节），
  //         这里保持完全一致，下游不需要改动。
  //==========================================================================
  reg [95:0] d1, d2;
  reg        v1, v2;
  reg        u1;

  always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
      d1 <= 96'd0; d2 <= 96'd0;
      v1 <= 1'b0;  v2 <= 1'b0;
      u1 <= 1'b0;
    end else begin
      d1 <= I_tdata;  v1 <= I_tvalid;
      d2 <= d1;       v2 <= v1;
      u1 <= I_tuser;
    end
  end

  //------------------------------------- 增益应用 + 钳位（与旧实现相同的取位方式）
  wire [7:0] q0_r = d2[23:16], q0_g = d2[15:8], q0_b = d2[ 7:0];
  wire [7:0] q1_r = d2[47:40], q1_g = d2[39:32], q1_b = d2[31:24];
  wire [7:0] q2_r = d2[71:64], q2_g = d2[63:56], q2_b = d2[55:48];
  wire [7:0] q3_r = d2[95:88], q3_g = d2[87:80], q3_b = d2[79:72];

  wire [27:0] nr0 = gain_r_use * q0_r;
  wire [27:0] nr1 = gain_r_use * q1_r;
  wire [27:0] nr2 = gain_r_use * q2_r;
  wire [27:0] nr3 = gain_r_use * q3_r;

  wire [27:0] nb0 = gain_b_use * q0_b;
  wire [27:0] nb1 = gain_b_use * q1_b;
  wire [27:0] nb2 = gain_b_use * q2_b;
  wire [27:0] nb3 = gain_b_use * q3_b;

  wire [7:0] y0_r = (|nr0[27:24]) ? 8'd255 : nr0[23:16];
  wire [7:0] y1_r = (|nr1[27:24]) ? 8'd255 : nr1[23:16];
  wire [7:0] y2_r = (|nr2[27:24]) ? 8'd255 : nr2[23:16];
  wire [7:0] y3_r = (|nr3[27:24]) ? 8'd255 : nr3[23:16];

  wire [7:0] y0_b = (|nb0[27:24]) ? 8'd255 : nb0[23:16];
  wire [7:0] y1_b = (|nb1[27:24]) ? 8'd255 : nb1[23:16];
  wire [7:0] y2_b = (|nb2[27:24]) ? 8'd255 : nb2[23:16];
  wire [7:0] y3_b = (|nb3[27:24]) ? 8'd255 : nb3[23:16];

  wire [95:0] out_data = {y3_r, q3_g, y3_b,
                          y2_r, q2_g, y2_b,
                          y1_r, q1_g, y1_b,
                          y0_r, q0_g, y0_b};

  //==========================================================================
  //  6b. 数据延迟线：DATA_LEAD 级（★让 tuser 领先数据，见文件头硬契约）
  //--------------------------------------------------------------------------
  //  只有【数据 + valid】进延迟线；tuser 走第 7 节的 2 拍寄存器，不经过这里。
  //  输出相位：O_tuser = I_tuser + 2
  //            O_tdata = I_tdata + 3 + DATA_LEAD
  //  领先量 = 1 + DATA_LEAD = 33 拍（DATA_LEAD=32），是 video_in 8 拍复位窗口的 4 倍。
  //  资源：DATA_LEAD x (96 + 1) 个 FF，约 3200 个（PH1P35 当前约用 17K，余量充足）。
  //==========================================================================
  reg [95:0] dl [0:DATA_LEAD];
  reg        vl [0:DATA_LEAD];
  integer    dli;

  always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
      for (dli = 0; dli <= DATA_LEAD; dli = dli + 1) begin
        dl[dli] <= 96'd0;
        vl[dli] <= 1'b0;
      end
    end else begin
      dl[0] <= out_data;                      // 与 d2/v2 同拍（延迟 2 拍）
      vl[0] <= v2;
      for (dli = 1; dli <= DATA_LEAD; dli = dli + 1) begin
        dl[dli] <= dl[dli-1];
        vl[dli] <= vl[dli-1];
      end
    end
  end

  wire [95:0] out_data_ld = dl[DATA_LEAD];    // 数据总延迟 3 + DATA_LEAD 拍
  wire        v_out       = vl[DATA_LEAD];
  wire        v_out_prev  = vl[DATA_LEAD-1];  // 用于生成 O_tlast（valid 上升沿）

  //==========================================================================
  //  7. 输出寄存
  //     ⚠️ 端口名是 O_tdata / O_tvalid（与旧 awb 一致），不是 O_data / O_valid。
  //     O_tlast 沿用旧实现的做法：valid 的上升沿即"新的一行开始"（旧代码里
  //     O_tlast = (valid_d1==0)&&(valid_d2==1)），这样与旧模块行为完全一致，
  //     下游 data_96bit_to_128bit 不需要作任何改动。
  //==========================================================================
  always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
      O_tdata  <= 96'd0;
      O_tvalid <= 1'b0;
      O_tuser  <= 1'b0;
      O_tlast  <= 1'b0;
    end else begin
      O_tdata  <= out_data_ld;              // 数据总延迟 3 + DATA_LEAD 拍
      O_tvalid <= v_out;
      O_tuser  <= u1;                       // 只延迟 2 拍 ⇒ 领先数据 (1+DATA_LEAD) 拍
      O_tlast  <= (v_out_prev == 1'b0) && (v_out == 1'b1);
    end
  end

  assign I_tready = O_tready;

endmodule
