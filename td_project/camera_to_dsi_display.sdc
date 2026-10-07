create_clock -name {sys_clk_50m} -period 20.000 -waveform {0.000 10.000} [get_ports {I_sys_clk}]
create_clock -name {mipi_rx_ck_pad} -period 2.415 -waveform {0.000 1.208} [get_nets {IO_rx_clk_pad_p}]

derive_clocks

rename_clock -name {pll_clk_100m} [get_clocks {u_PLL/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[0]}]
rename_clock -name {pll_clk_24m} [get_clocks {u_PLL/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[1]}]
rename_clock -name {HDMI_PIXEL_CLK} [get_clocks {u_PLL/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[4]}]
rename_clock -name {HDMI_SERIAL_CLK} [get_clocks {u_PLL/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[5]}]

rename_clock -name {MIPI_RX_BYTE_CLK} [get_clocks {u_mipi_dphy_rx_ph1p_mipiio_wrapper/u_ph1p_mipiio_rx_wrapper/u_PH1P_LOGIC_DPHY_MIPI_RX.o_fabric_div4_8_clk}]


set_clock_groups -asynchronous \
    -group [get_clocks {mipi_rx_ck_pad MIPI_RX_BYTE_CLK}] \
    -group [get_clocks {sys_clk_50m pll_clk_100m pll_clk_24m HDMI_PIXEL_CLK HDMI_SERIAL_CLK}] \
    -group [get_clocks {u_ph1p35_324_ddr_wrapper/u_ddr2/ddr_clk u_ph1p35_324_ddr_wrapper/u_ddr2/usr_clk}]

#-----------------------------------------------------------------------------
# AE 测光跨时钟域（74.25M → 24M） false path
#   跨域信号：u_ae_meter 的 O_Y_avg[7:0] + O_frame_toggle（共 9 个端点）。
#   协议保证安全：Y_avg 每帧更新一次后整帧保持静态，O_frame_toggle 为翻转
#   电平，接收端 ae_set 用两级同步 + 异或取边沿，在数据稳定期采样。
#   两时钟同源于 u_PLL，本被 set_clock_groups 归入同组（按同步路径检查），
#   故需显式 false path；方向单一（仅 74.25M → 24M），按方向约束，最小影响面。
#-----------------------------------------------------------------------------
set_false_path -from [get_clocks {HDMI_PIXEL_CLK}] -to [get_clocks {pll_clk_24m}]

#-----------------------------------------------------------------------------
# v6.4 图像增强跨时钟域（24M → 74.25M） false path —— 与上一条对称
#   跨域信号：u_ae_set 的 O_ag[15:0]（AE 增益控制字）→ u_image_enhance.I_ag。
#   现象：3 个失败端点 r_ag_reg[0]/[5]/[6] → ag_s0_reg[...]，WNS = -0.213ns。
#   成因：两时钟同源于 u_PLL，被 set_clock_groups 归入同组（按同步路径检查）。
#         74.25MHz : 24MHz = 99 : 32（32 个 24M 周期 = 99 个 74.25M 周期），
#         两者存在固定相位关系，会出现几乎重合的时钟沿 ——
#         报告实测该路径 setup 预算只剩 0.653ns（Clock-Skew 0.024ns）；
#         而该路径 Logic-Level = 0（纯走线），插流水线也无法收敛，只能按 CDC 约束。
#   协议保证安全：ag 是慢变控制字（AE 每约 3 帧才调整一次，调整后整帧保持静态），
#         接收端 image_enhance 三级同步（ag_s0→ag_s1→ag_s2）后取用，
#         且只译码 ag_s2[7:5]（32 的倍数分档），data 稳定期内采样。
#   加了这条之后，24M ↔ 74.25M 双向均已按 CDC 解耦；
#   今后在这两个时钟域之间再传慢变控制信号，无需重复添加约束
#   （但跨域信号仍需在接收端做 ≥2 级同步）。
#-----------------------------------------------------------------------------
set_false_path -from [get_clocks {pll_clk_24m}] -to [get_clocks {HDMI_PIXEL_CLK}]
