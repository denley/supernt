# W16 clock input and the HDMI transmitter video pins as outputs. Colour pins as confirmed on
# the console with vtest (notes/spc-core.md, "Video pins"): ch1 = red, ch2 = green, ch3 = blue,
# bit 7..0. (quartus/vtest/pins.tcl keeps the order vtest was tested with.)
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
