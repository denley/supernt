# Pins of quartus/memtest. Video: as quartus/hwtest (confirmed on the console). U4 bus and
# spc.cor's constant pins: as quartus/hwtest (sd_dqm open-drain group left unused = released,
# as stock). U5/U16 bus: notes/sdram.md, "Controller 2"; every pin is one spc.cor drives, used
# the way it does (group 2 data and C13/C15 only low or released).
set_location_assignment PIN_W16 -to clk
set_location_assignment PIN_M22 -to pclk
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to pclk
set_location_assignment PIN_P16 -to s0
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to s0
set_location_assignment PIN_M16 -to s1
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to s1
set_location_assignment PIN_M18 -to s2
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to s2
set_location_assignment PIN_K21 -to ch1[7]
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to ch1[7]
set_location_assignment PIN_K22 -to ch1[6]
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to ch1[6]
set_location_assignment PIN_M20 -to ch1[5]
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to ch1[5]
set_location_assignment PIN_L22 -to ch1[4]
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to ch1[4]
set_location_assignment PIN_T17 -to ch1[3]
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to ch1[3]
set_location_assignment PIN_T18 -to ch1[2]
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to ch1[2]
set_location_assignment PIN_R15 -to ch1[1]
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to ch1[1]
set_location_assignment PIN_T22 -to ch1[0]
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to ch1[0]
set_location_assignment PIN_N20 -to ch2[7]
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to ch2[7]
set_location_assignment PIN_P22 -to ch2[6]
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to ch2[6]
set_location_assignment PIN_R22 -to ch2[5]
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to ch2[5]
set_location_assignment PIN_R21 -to ch2[4]
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to ch2[4]
set_location_assignment PIN_P19 -to ch2[3]
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to ch2[3]
set_location_assignment PIN_P18 -to ch2[2]
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to ch2[2]
set_location_assignment PIN_N16 -to ch2[1]
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to ch2[1]
set_location_assignment PIN_N19 -to ch2[0]
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to ch2[0]
set_location_assignment PIN_T20 -to ch3[7]
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to ch3[7]
set_location_assignment PIN_T15 -to ch3[6]
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to ch3[6]
set_location_assignment PIN_T19 -to ch3[5]
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to ch3[5]
set_location_assignment PIN_R16 -to ch3[4]
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to ch3[4]
set_location_assignment PIN_M21 -to ch3[3]
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to ch3[3]
set_location_assignment PIN_N21 -to ch3[2]
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to ch3[2]
set_location_assignment PIN_P17 -to ch3[1]
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to ch3[1]
set_location_assignment PIN_R17 -to ch3[0]
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to ch3[0]
# U4 (AS4C8M16SA x16, the bottom-bank bus; notes/sdram.md). AB10 = DQM of the 3B byte, low.
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to sd_clk
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to sd_cs_n
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to sd_ras_n
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to sd_cas_n
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to sd_we_n
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to sd_a[*]
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to sd_ba[*]
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to sd_dq[*]
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to sd_cke
# x8 SDRAM pair (notes/sdram.md). DQM candidates: driven low or released (0/Z in the HDL, an
# open-drain buffer; spc.cor: constant open-drain outputs, released); AB10 a constant output
# (spc.cor: low), driven low or high per pass (sdram_test.sv hypotheses).
set_location_assignment PIN_AB11 -to sd_clk
set_location_assignment PIN_AB17 -to sd_cs_n
set_location_assignment PIN_AA17 -to sd_ras_n
set_location_assignment PIN_AB18 -to sd_cas_n
set_location_assignment PIN_AA18 -to sd_we_n
set_location_assignment PIN_AB13 -to sd_a[0]
set_location_assignment PIN_AA13 -to sd_a[1]
set_location_assignment PIN_AB12 -to sd_a[2]
set_location_assignment PIN_AA12 -to sd_a[3]
set_location_assignment PIN_U2 -to sd_a[4]
set_location_assignment PIN_U1 -to sd_a[5]
set_location_assignment PIN_W2 -to sd_a[6]
set_location_assignment PIN_AA2 -to sd_a[7]
set_location_assignment PIN_AA1 -to sd_a[8]
set_location_assignment PIN_N1 -to sd_a[9]
set_location_assignment PIN_AA14 -to sd_a[10]
set_location_assignment PIN_N2 -to sd_a[11]
set_location_assignment PIN_AA15 -to sd_ba[0]
set_location_assignment PIN_AB15 -to sd_ba[1]
set_location_assignment PIN_D3 -to sd_dq[7]
set_location_assignment PIN_E2 -to sd_dq[6]
set_location_assignment PIN_L2 -to sd_dq[5]
set_location_assignment PIN_L1 -to sd_dq[4]
set_location_assignment PIN_G2 -to sd_dq[3]
set_location_assignment PIN_G1 -to sd_dq[2]
set_location_assignment PIN_C2 -to sd_dq[1]
set_location_assignment PIN_C1 -to sd_dq[0]
set_location_assignment PIN_AB5 -to sd_dq[15]
set_location_assignment PIN_AB6 -to sd_dq[14]
set_location_assignment PIN_AB7 -to sd_dq[13]
set_location_assignment PIN_AA7 -to sd_dq[12]
set_location_assignment PIN_AB8 -to sd_dq[11]
set_location_assignment PIN_AA8 -to sd_dq[10]
set_location_assignment PIN_AA9 -to sd_dq[9]
set_location_assignment PIN_AA10 -to sd_dq[8]
set_location_assignment PIN_AB10 -to sd_cke
# spc.cor constant outputs (notes/sdram.md, "Constant pins"): OE always on, DATAOUT unrouted,
# inverter set = 0 / not set = 1. tie3 (3A/3B) is at that level or released per SDRAM pass;
# released = weak pull-up, as these pins were in v1/v2 (unused). tie_hold always at the level.
# All at the weakest drive (4 mA, no series termination): their board roles are unknown, so if
# one of them meets another driver at the opposite level, the contention current stays small.
set_location_assignment PIN_R5 -to tie3[0]
set_instance_assignment -name CURRENT_STRENGTH_NEW 4MA -to tie3[0]
set_instance_assignment -name WEAK_PULL_UP_RESISTOR ON -to tie3[0]
set_location_assignment PIN_R6 -to tie3[1]
set_instance_assignment -name CURRENT_STRENGTH_NEW 4MA -to tie3[1]
set_instance_assignment -name WEAK_PULL_UP_RESISTOR ON -to tie3[1]
set_location_assignment PIN_U7 -to tie3[2]
set_instance_assignment -name CURRENT_STRENGTH_NEW 4MA -to tie3[2]
set_instance_assignment -name WEAK_PULL_UP_RESISTOR ON -to tie3[2]
set_location_assignment PIN_U8 -to tie3[3]
set_instance_assignment -name CURRENT_STRENGTH_NEW 4MA -to tie3[3]
set_instance_assignment -name WEAK_PULL_UP_RESISTOR ON -to tie3[3]
set_location_assignment PIN_T7 -to tie3[4]
set_instance_assignment -name CURRENT_STRENGTH_NEW 4MA -to tie3[4]
set_instance_assignment -name WEAK_PULL_UP_RESISTOR ON -to tie3[4]
set_location_assignment PIN_T8 -to tie3[5]
set_instance_assignment -name CURRENT_STRENGTH_NEW 4MA -to tie3[5]
set_instance_assignment -name WEAK_PULL_UP_RESISTOR ON -to tie3[5]
set_location_assignment PIN_V6 -to tie3[6]
set_instance_assignment -name CURRENT_STRENGTH_NEW 4MA -to tie3[6]
set_instance_assignment -name WEAK_PULL_UP_RESISTOR ON -to tie3[6]
set_location_assignment PIN_U6 -to tie3[7]
set_instance_assignment -name CURRENT_STRENGTH_NEW 4MA -to tie3[7]
set_instance_assignment -name WEAK_PULL_UP_RESISTOR ON -to tie3[7]
set_location_assignment PIN_V9 -to tie3[8]
set_instance_assignment -name CURRENT_STRENGTH_NEW 4MA -to tie3[8]
set_instance_assignment -name WEAK_PULL_UP_RESISTOR ON -to tie3[8]
set_location_assignment PIN_V10 -to tie3[9]
set_instance_assignment -name CURRENT_STRENGTH_NEW 4MA -to tie3[9]
set_instance_assignment -name WEAK_PULL_UP_RESISTOR ON -to tie3[9]
set_location_assignment PIN_U10 -to tie3[10]
set_instance_assignment -name CURRENT_STRENGTH_NEW 4MA -to tie3[10]
set_instance_assignment -name WEAK_PULL_UP_RESISTOR ON -to tie3[10]
set_location_assignment PIN_T10 -to tie3[11]
set_instance_assignment -name CURRENT_STRENGTH_NEW 4MA -to tie3[11]
set_instance_assignment -name WEAK_PULL_UP_RESISTOR ON -to tie3[11]
set_location_assignment PIN_P12 -to tie3[12]
set_instance_assignment -name CURRENT_STRENGTH_NEW 4MA -to tie3[12]
set_instance_assignment -name WEAK_PULL_UP_RESISTOR ON -to tie3[12]
set_location_assignment PIN_R12 -to tie3[13]
set_instance_assignment -name CURRENT_STRENGTH_NEW 4MA -to tie3[13]
set_instance_assignment -name WEAK_PULL_UP_RESISTOR ON -to tie3[13]
set_location_assignment PIN_N9 -to tie3[14]
set_instance_assignment -name CURRENT_STRENGTH_NEW 4MA -to tie3[14]
set_instance_assignment -name WEAK_PULL_UP_RESISTOR ON -to tie3[14]
set_location_assignment PIN_P9 -to tie3[15]
set_instance_assignment -name CURRENT_STRENGTH_NEW 4MA -to tie3[15]
set_instance_assignment -name WEAK_PULL_UP_RESISTOR ON -to tie3[15]
set_location_assignment PIN_M9 -to tie3[16]
set_instance_assignment -name CURRENT_STRENGTH_NEW 4MA -to tie3[16]
set_instance_assignment -name WEAK_PULL_UP_RESISTOR ON -to tie3[16]
set_location_assignment PIN_T9 -to tie3[17]
set_instance_assignment -name CURRENT_STRENGTH_NEW 4MA -to tie3[17]
set_instance_assignment -name WEAK_PULL_UP_RESISTOR ON -to tie3[17]
set_location_assignment PIN_U11 -to tie3[18]
set_instance_assignment -name CURRENT_STRENGTH_NEW 4MA -to tie3[18]
set_instance_assignment -name WEAK_PULL_UP_RESISTOR ON -to tie3[18]
set_location_assignment PIN_T13 -to tie_hold[0]
set_instance_assignment -name CURRENT_STRENGTH_NEW 4MA -to tie_hold[0]
set_location_assignment PIN_T14 -to tie_hold[1]
set_instance_assignment -name CURRENT_STRENGTH_NEW 4MA -to tie_hold[1]
set_location_assignment PIN_U16 -to tie_hold[2]
set_instance_assignment -name CURRENT_STRENGTH_NEW 4MA -to tie_hold[2]
set_location_assignment PIN_V14 -to tie_hold[3]
set_instance_assignment -name CURRENT_STRENGTH_NEW 4MA -to tie_hold[3]
set_location_assignment PIN_V15 -to tie_hold[4]
set_instance_assignment -name CURRENT_STRENGTH_NEW 4MA -to tie_hold[4]
set_location_assignment PIN_V16 -to tie_hold[5]
set_instance_assignment -name CURRENT_STRENGTH_NEW 4MA -to tie_hold[5]
set_location_assignment PIN_V19 -to tie_hold[6]
set_instance_assignment -name CURRENT_STRENGTH_NEW 4MA -to tie_hold[6]
set_location_assignment PIN_W19 -to tie_hold[7]
set_instance_assignment -name CURRENT_STRENGTH_NEW 4MA -to tie_hold[7]
set_location_assignment PIN_Y14 -to tie_hold[8]
set_instance_assignment -name CURRENT_STRENGTH_NEW 4MA -to tie_hold[8]
set_location_assignment PIN_Y15 -to tie_hold[9]
set_instance_assignment -name CURRENT_STRENGTH_NEW 4MA -to tie_hold[9]
set_location_assignment PIN_Y16 -to tie_hold[10]
set_instance_assignment -name CURRENT_STRENGTH_NEW 4MA -to tie_hold[10]
set_location_assignment PIN_Y17 -to tie_hold[11]
set_instance_assignment -name CURRENT_STRENGTH_NEW 4MA -to tie_hold[11]
set_location_assignment PIN_Y19 -to tie_hold[12]
set_instance_assignment -name CURRENT_STRENGTH_NEW 4MA -to tie_hold[12]
set_location_assignment PIN_R14 -to tie_hold[13]
set_instance_assignment -name CURRENT_STRENGTH_NEW 4MA -to tie_hold[13]
set_location_assignment PIN_U15 -to tie_hold[14]
set_instance_assignment -name CURRENT_STRENGTH_NEW 4MA -to tie_hold[14]
set_location_assignment PIN_U17 -to tie_hold[15]
set_instance_assignment -name CURRENT_STRENGTH_NEW 4MA -to tie_hold[15]
set_location_assignment PIN_U20 -to tie_hold[16]
set_instance_assignment -name CURRENT_STRENGTH_NEW 4MA -to tie_hold[16]
set_location_assignment PIN_V13 -to tie_hold[17]
set_instance_assignment -name CURRENT_STRENGTH_NEW 4MA -to tie_hold[17]
set_location_assignment PIN_V18 -to tie_hold[18]
set_instance_assignment -name CURRENT_STRENGTH_NEW 4MA -to tie_hold[18]
set_location_assignment PIN_V20 -to tie_hold[19]
set_instance_assignment -name CURRENT_STRENGTH_NEW 4MA -to tie_hold[19]
set_location_assignment PIN_Y20 -to tie_hold[20]
set_instance_assignment -name CURRENT_STRENGTH_NEW 4MA -to tie_hold[20]
set_location_assignment PIN_K19 -to tie_hold[21]
set_instance_assignment -name CURRENT_STRENGTH_NEW 4MA -to tie_hold[21]
set_location_assignment PIN_K20 -to tie_hold[22]
set_instance_assignment -name CURRENT_STRENGTH_NEW 4MA -to tie_hold[22]
set_location_assignment PIN_J17 -to tie_hold[23]
set_instance_assignment -name CURRENT_STRENGTH_NEW 4MA -to tie_hold[23]
# U5 + U16 (IS42S81600F x8 pair, top-bank bus; notes/sdram.md, "Controller 2"). Shared address,
# bank and clock; per chip command lines, A10 and data. 50 ohm series like every spc.cor pin.
set_location_assignment PIN_H8 -to m_clk
set_location_assignment PIN_N6 -to m_a[0]
set_location_assignment PIN_P6 -to m_a[1]
set_location_assignment PIN_P7 -to m_a[2]
set_location_assignment PIN_R7 -to m_a[3]
set_location_assignment PIN_P8 -to m_a[4]
set_location_assignment PIN_R9 -to m_a[5]
set_location_assignment PIN_H6 -to m_a[6]
set_location_assignment PIN_F7 -to m_a[7]
set_location_assignment PIN_D7 -to m_a[8]
set_location_assignment PIN_C8 -to m_a[9]
set_location_assignment PIN_M6 -to m_a11
set_location_assignment PIN_E9 -to m_ba[0]
set_location_assignment PIN_C9 -to m_ba[1]
set_location_assignment PIN_D12 -to g1_cs_n
set_location_assignment PIN_D13 -to g1_ras_n
set_location_assignment PIN_G13 -to g1_cas_n
set_location_assignment PIN_E12 -to g1_we_n
set_location_assignment PIN_H9 -to g1_a10
set_location_assignment PIN_B6 -to g2_cs_n
set_location_assignment PIN_C6 -to g2_ras_n
set_location_assignment PIN_A7 -to g2_cas_n
set_location_assignment PIN_B7 -to g2_we_n
set_location_assignment PIN_D17 -to g2_a10
set_location_assignment PIN_N8 -to g1_dq[0]
set_location_assignment PIN_J7 -to g1_dq[1]
set_location_assignment PIN_J9 -to g1_dq[2]
set_location_assignment PIN_K7 -to g1_dq[3]
set_location_assignment PIN_H11 -to g1_dq[4]
set_location_assignment PIN_G12 -to g1_dq[5]
set_location_assignment PIN_F12 -to g1_dq[6]
set_location_assignment PIN_J11 -to g1_dq[7]
# group 2 data: open drain in spc.cor (0 or released); released lines rise on the weak pull-up
set_location_assignment PIN_A8 -to g2_dq[0]
set_location_assignment PIN_A9 -to g2_dq[1]
set_location_assignment PIN_A10 -to g2_dq[2]
set_location_assignment PIN_A12 -to g2_dq[3]
set_location_assignment PIN_B10 -to g2_dq[4]
set_location_assignment PIN_B11 -to g2_dq[5]
set_location_assignment PIN_B12 -to g2_dq[6]
set_location_assignment PIN_C16 -to g2_dq[7]
set_instance_assignment -name WEAK_PULL_UP_RESISTOR ON -to g2_dq[*]
# C13/C15: one FF in spc.cor, low except during controller 2's MRS; per hypothesis low or
# released (weak pull-up, what every earlier core left them at)
set_location_assignment PIN_C13 -to m_c13
set_location_assignment PIN_C15 -to m_c15
set_instance_assignment -name WEAK_PULL_UP_RESISTOR ON -to m_c13
set_instance_assignment -name WEAK_PULL_UP_RESISTOR ON -to m_c15
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to m_clk
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to m_a[*]
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to m_a11
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to m_ba[*]
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to g1_cs_n
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to g1_ras_n
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to g1_cas_n
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to g1_we_n
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to g1_a10
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to g2_cs_n
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to g2_ras_n
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to g2_cas_n
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to g2_we_n
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to g2_a10
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to g1_dq[*]
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to g2_dq[*]
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to m_c13
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to m_c15
