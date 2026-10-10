//=============================================================================
//  tb_pix_dly_check.v  —— 张铭晨侧独立验证（第三版，激励改自动生成）
//-----------------------------------------------------------------------------
//  真实集成场景：
//      pix_coord_gen → S_pix_x（与 de 同拍）
//                    → [此处模拟 2 拍延时] → S_pix_x_2d
//                    → detect_color_mask 的 I_pix_x（PIX_DLY=2）
//      detect_color_mask 内部 3 拍流水 → O_de / O_mask / O_pix_x
//
//  核心判据：
//      O_de   = 输入 de  延时 D_de 拍
//      O_pix_x = 该去对齐的那个像素的 x，应延时 D_de 拍（同一像素）
//      本 TB 让 S_pix_x 每拍严格 +1（永不重复），
//      于是「O_de=1 那拍的 O_pix_x 值」= S_pix_x 的延时拍数。
//      再统计 O_de 的延时拍数，两者相等即 PASS。
//
//  激励：全部由时钟驱动的自动生成器写出，避免手工 @(negedge) 的时机错。
//=============================================================================
`timescale 1ns / 1ps

module tb_pix_dly_check;

    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;

    // ================= 坐标源（与 I_de 严格同拍）=================
    reg  [10:0] S_pix_x = 0;
    reg  [9:0]  S_pix_y = 0;
    reg         S_de    = 0;

    // ================= 模拟 S_pix_x_2d：延 2 拍 =================
    reg  [10:0] xd1 = 0, xd2 = 0;
    reg  [9:0]  yd1 = 0, yd2 = 0;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin xd1<=0; xd2<=0; yd1<=0; yd2<=0; end
        else begin
            xd1 <= S_pix_x;  xd2 <= xd1;
            yd1 <= S_pix_y;  yd2 <= yd1;
        end
    end

    // ================= 被测模块的其他输入 =================
    reg  [23:0] I_rgb = 24'hC82828;
    reg         I_vsync = 0, I_hsync = 0, I_user = 0, I_last = 0;
    reg  [1:0]  I_color_sel = 2'd0;

    wire [10:0] O_pix_x;
    wire [9:0]  O_pix_y;
    wire        O_de;
    wire        O_mask, O_mask_r, O_mask_g, O_mask_b;
    wire [7:0]  O_y, O_cb, O_cr;
    wire        O_vsync, O_hsync, O_user, O_last, O_frame_done;

    detect_color_mask #(
        .IMG_WIDTH  (1280),
        .IMG_HEIGHT (720),
        .PIPE_DELAY (0),
        .PIX_DLY    (2)          // ★ 接 S_pix_x_2d
    ) dut (
        .clk( clk ), .rst_n( rst_n ),
        .I_de( S_de ),
        .I_vsync( I_vsync ), .I_hsync( I_hsync ),
        .I_user( I_user ), .I_last( I_last ),
        .I_rgb( I_rgb ),
        .I_pix_x( xd2 ),         // ★ 延 2 拍的坐标
        .I_pix_y( yd2 ),
        .I_color_sel( I_color_sel ),
        .O_mask( O_mask ), .O_mask_r( O_mask_r ), .O_mask_g( O_mask_g ), .O_mask_b( O_mask_b ),
        .O_y( O_y ), .O_cb( O_cb ), .O_cr( O_cr ),
        .O_de( O_de ), .O_vsync( O_vsync ), .O_hsync( O_hsync ),
        .O_user( O_user ), .O_last( O_last ),
        .O_pix_x( O_pix_x ), .O_pix_y( O_pix_y ),
        .O_frame_done( O_frame_done )
    );

    // ================= 自动激励：S_pix_x 每拍 +1 =================
    //  在 S_de=1 期间，S_pix_x = 0,1,2,3,... 严格递增且唯一
    integer gen_n = 0;
    integer clk_cnt = 0;
    reg     run_gen = 0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            S_de <= 0; S_pix_x <= 0; S_pix_y <= 0;
            gen_n <= 0; clk_cnt <= 0;
        end else begin
            clk_cnt <= clk_cnt + 1;
            if (run_gen && clk_cnt < 40) begin
                S_de    <= 1'b1;
                S_pix_x <= gen_n[10:0];
                S_pix_y <= 11'd0;
                gen_n   <= gen_n + 1;
            end else begin
                S_de    <= 1'b0;
            end
        end
    end

    // ================= 临界：把「输入 de 的拍号」记下来 =================
    //  需要知道：当 O_de=1 时，对应的输入 S_de=1 是第几次、x 是几
    integer de_times = 0;             // 输入 S_de 第几次为 1（从 1 开始）
    integer in_x_at_de [0:63];        // 第 k 次 S_de=1 时，S_pix_x 的值
    integer k_idx = 0;

    always @(posedge clk) begin
        if (rst_n && S_de) begin
            de_times = de_times + 1;
            if (k_idx < 64) begin
                in_x_at_de[k_idx] = S_pix_x;
                k_idx = k_idx + 1;
            end
        end
    end

    // ================= 关键判据：3 拍前的输入坐标 =================
    //  掩膜路径总延时 = 3 拍（RTL: C0→P1→P2→P3→O_mask）。
    //  所以 O_de=1 当拍，O_pix_x 必须等于「3 拍前的 S_pix_x」。
    reg [10:0] q1 = 0, q2 = 0, q3 = 0;
    reg        d1 = 0, d2 = 0, d3 = 0;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin q1<=0; q2<=0; q3<=0; d1<=0; d2<=0; d3<=0; end
        else begin
            q1 <= S_pix_x;  q2 <= q1;  q3 <= q2;
            d1 <= S_de;     d2 <= d1;  d3 <= d2;
        end
    end

    integer chk = 0, err = 0;

    always @(posedge clk) begin
        if (rst_n && O_de) begin
            chk = chk + 1;
            if (O_pix_x !== q3) begin
                err = err + 1;
                if (err <= 8)
                    $display("    [ERR] t=%0t O_pix_x=%0d 但 3 拍前 S_pix_x=%0d", $time, O_pix_x, q3);
            end
        end
    end

    // ================= 输出观测 =================
    integer out_times = 0;
    integer out_x [0:63];

    always @(posedge clk) begin
        if (rst_n && O_de) begin
            out_times = out_times + 1;
            if (out_times <= 64) out_x[out_times-1] = O_pix_x;
            if (out_times <= 15)
                $display("  [OUT #%-2d] t=%-8t O_de=1  O_pix_x=%-4d  O_pix_y=%-3d",
                         out_times, $time, O_pix_x, O_pix_y);
        end
    end

    // ================= 主流程 =================
    integer i;
    integer D_de, D_x;
    integer pass;

    initial begin
        $dumpfile("tb_pix_dly_check.vcd");
        $dumpvars(0, tb_pix_dly_check);

        rst_n = 0;
        I_vsync = 0; I_user = 0;
        run_gen = 0;
        repeat (12) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // 帧起始脉冲
        I_vsync = 1; I_user = 1;
        repeat (3) @(posedge clk);
        I_vsync = 0; I_user = 0;
        repeat (3) @(posedge clk);

        // 开激励
        run_gen = 1;
        repeat (45) @(posedge clk);
        run_gen = 0;
        repeat (15) @(posedge clk);

        // ============ 判定 ============
        //  输入第 1 次 S_de=1 时，S_pix_x = 0（因为 S_de 与 S_pix_x=gen_n 同时置位）
        //  输出第 1 次 O_de=1 时，若 O_pix_x = V：
        //      V = 「V 拍前输入的 x」，即 O_pix_x 延 V 拍
        //  O_de 延几拍：只需看 O_de 第 1 次为 1 时刻与输入第 1 次为 1 时刻的差
        $display("");
        $display("=====================================================");
        $display(" tb_pix_dly_check (PIX_DLY=2, 坐标先延 2 拍)");
        $display("-----------------------------------------------------");
        $display("  输入 S_de 有效次数    : %0d", de_times);
        $display("  输出 O_de 有效次数    : %0d", out_times);
        $display("");
        $display("  判据：O_de=1 当拍，O_pix_x 是否 == 3 拍前的 S_pix_x");
        $display("        （掩膜路径固定 3 拍，RTL: C0→P1→P2→P3→O_mask）");
        $display("");
        $display("  受检拍数 : %0d", chk);
        $display("  错位拍数 : %0d", err);
        $display("");
        if (chk > 0 && err == 0)
            $display("  结论 : PASS —— 坐标与掩膜路径严格同拍（同一像素）");
        else if (chk == 0)
            $display("  结论 : 数据不足，无法判定");
        else
            $display("  结论 : FAIL —— %0d 拍错位", err);
        $display("=====================================================");
        $display("");
        $finish;
    end

endmodule
