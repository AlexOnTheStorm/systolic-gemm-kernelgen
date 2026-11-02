# =====================================================================
#  constraints.xdc — timing constraints for OOC synthesis of systolic_array.
#
#  For STANDALONE synthesis (P3, f_max/resource estimate) we set the clock
#  ourselves. In the Vitis flow (P4) the platform provides the clock — this file
#  is NOT needed there.
#
#  The period is set from synth.tcl through a variable; default 3.0 ns (~333 MHz).
#  Change CLK_PERIOD_NS in synth.tcl and re-check WNS (see docs/report_analysis.md).
# =====================================================================

# create a clock on the clk input port
create_clock -name clk -period 3.000 [get_ports clk]

# inputs/outputs: nominal I/O budget (for OOC a rough frame, not critical)
set_input_delay  -clock clk 0.500 [all_inputs]
set_output_delay -clock clk 0.500 [all_outputs]

# clk itself is not subject to set_input_delay
set_false_path -from [get_ports clk]
