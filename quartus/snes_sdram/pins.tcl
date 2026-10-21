# W16 clock input, the HDMI transmitter video/audio pins and controller port 1 as
# quartus/snes/pins.tcl (colour pins as confirmed on the console with vtest: ch1 = red,
# ch2 = green, ch3 = blue, bit 7..0), plus the x8 SDRAM pair.
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
set_location_assignment PIN_L17 -to aud_mclk
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to aud_mclk
set_location_assignment PIN_L19 -to aud_bclk
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to aud_bclk
set_location_assignment PIN_K17 -to aud_lrclk
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to aud_lrclk
set_location_assignment PIN_L18 -to aud_sdata
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to aud_sdata
# Controller port 1 (notes/controllers.md): outputs as spc.cor drives them, T12 without pull-up.
set_location_assignment PIN_P14 -to pad_p14
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to pad_p14
set_location_assignment PIN_J13 -to pad_j13
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to pad_j13
set_location_assignment PIN_K16 -to pad_k16
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to pad_k16
set_location_assignment PIN_T12 -to pad_t12
# x8 SDRAM pair (notes/sdram.md), pins and settings as quartus/hwtest/pins.tcl. DQM candidates:
# held low (DQM_LOW = 1 in snes_sdram_top.sv: constant 0, only the low-side driver is on, the
# same as hwtest's open-drain low; DQM_LOW = 0 releases them); CKE candidate AB10 driven high.
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
set_location_assignment PIN_Y3 -to sd_dqm[0]
set_location_assignment PIN_W9 -to sd_dqm[1]
set_location_assignment PIN_W8 -to sd_dqm[2]
set_location_assignment PIN_Y9 -to sd_dqm[3]
set_location_assignment PIN_Y10 -to sd_dqm[4]
set_location_assignment PIN_R11 -to sd_dqm[5]
set_location_assignment PIN_R10 -to sd_dqm[6]
set_location_assignment PIN_Y11 -to sd_dqm[7]
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to sd_clk
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to sd_cs_n
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to sd_ras_n
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to sd_cas_n
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to sd_we_n
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to sd_a[*]
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to sd_ba[*]
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to sd_dq[*]
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to sd_cke
set_instance_assignment -name OUTPUT_TERMINATION "SERIES 50 OHM WITHOUT CALIBRATION" -to sd_dqm[*]
