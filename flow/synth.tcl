# =====================================================================
#  synth.tcl — NON-PROJECT synthesis + implementation of systolic_array
#  to estimate f_max and resources (P3). Produces REAL synthesis numbers (unlike
#  the simulated cycle counts of P2). Best practice: non-project Tcl is reproducible,
#  version-controlled and deterministic (UG892/UG904).
#
#  Run in the cloud (Vivado on Linux):
#    vivado -mode batch -source flow/synth.tcl -tclargs \
#           <part> <clk_period_ns> <ARRAY_M> <ARRAY_N>
#  Example:
#    vivado -mode batch -source flow/synth.tcl -tclargs xcvu47p-fsvh2892-3-e 3.0 8 8
#
#  Defaults (without -tclargs): AWS F2 VU47P, 3 ns, 8x8 array.
#  (Old AWS F1 VU9P = xcvu9p-flgb2104-2-i; Alveo U200 = xcu200-fsgd2104-2-e.)
# =====================================================================

# --- arguments / defaults ---
set part      [expr {$argc > 0 ? [lindex $argv 0] : "xcvu47p-fsvh2892-3-e"}]
set clk_ns    [expr {$argc > 1 ? [lindex $argv 1] : 3.0}]
set arr_m     [expr {$argc > 2 ? [lindex $argv 2] : 8}]
set arr_n     [expr {$argc > 3 ? [lindex $argv 3] : 8}]

set rtl_dir   [file normalize [file dirname [info script]]/../rtl]
set out_dir   [file normalize [file dirname [info script]]/../results/synth]
file mkdir $out_dir

puts "=== synth: part=$part  clk=${clk_ns}ns  array=${arr_m}x${arr_n} ==="

# --- read the RTL (SVA is not synthesized — only pe.sv + systolic_array.sv) ---
read_verilog -sv [list $rtl_dir/pe.sv $rtl_dir/systolic_array.sv]

# --- OUT-OF-CONTEXT synthesis (-mode out_of_context) ---
# systolic_array is NOT a standalone chip but a core: data arrives over AXI from HBM,
# not from physical pins. The flat a/b/c_flat buses are 2180 ports, the VU47P has only
# 1106 I/Os → without OOC place_design fails with 'IO overutilization'. OOC disables
# I/O buffer insertion and pin placement → we get clean f_max/resources of the module
# LOGIC (exactly what P3 needs; the wrapper is synthesized later by Vitis).
synth_design -top systolic_array -part $part -mode out_of_context \
             -generic ARRAY_M=$arr_m -generic ARRAY_N=$arr_n

# clock: created here (read_xdc would also work, but the period is parameterized)
create_clock -name clk -period $clk_ns [get_ports clk]

# --- implementation ---
opt_design
place_design
route_design

# --- REPORTS (these are what docs/report_analysis.md analyzes) ---
report_timing_summary -file $out_dir/timing_summary.rpt
report_utilization    -file $out_dir/utilization.rpt
report_power          -file $out_dir/power.rpt
report_drc            -file $out_dir/drc.rpt

# --- short summary on stdout: WNS and achievable f_max ---
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set achieved_ns [expr {$clk_ns - $wns}]
set fmax_mhz [expr {1000.0 / $achieved_ns}]
puts "----------------------------------------------------------------"
puts [format "WNS = %.3f ns   (>=0 => timing met)" $wns]
puts [format "f_max ~ %.1f MHz  (period %.2f ns, WNS %.3f)" $fmax_mhz $clk_ns $wns]
puts "Resources/power in $out_dir/*.rpt (DSP ~ number of PEs = [expr {$arr_m*$arr_n}])"
puts "----------------------------------------------------------------"

# optional: checkpoint for the hardware manager / reopening later
write_checkpoint -force $out_dir/systolic_routed.dcp
