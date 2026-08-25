# =====================================================================
#  synth.tcl — НЕПРОЕКТНЫЙ (non-project) синтез+имплементация systolic_array
#  для оценки f_max и ресурсов (P3). Даёт РЕАЛЬНЫЕ synth-числа (в отличие от
#  симуляционных тактов из P2). Best practice: non-project Tcl = воспроизводимо,
#  версионируется, детерминированно (UG892/UG904).
#
#  Запуск в облаке (Vivado на Linux):
#    vivado -mode batch -source flow/synth.tcl -tclargs \
#           <part> <clk_period_ns> <ARRAY_M> <ARRAY_N>
#  Пример:
#    vivado -mode batch -source flow/synth.tcl -tclargs xcvu47p-fsvh2892-3-e 3.0 8 8
#
#  Дефолты (если без -tclargs): AWS F2 VU47P, 3 нс, массив 8x8.
#  (Старый AWS F1 VU9P = xcvu9p-flgb2104-2-i; Alveo U200 = xcu200-fsgd2104-2-e.)
# =====================================================================

# --- аргументы / дефолты ---
set part      [expr {$argc > 0 ? [lindex $argv 0] : "xcvu47p-fsvh2892-3-e"}]
set clk_ns    [expr {$argc > 1 ? [lindex $argv 1] : 3.0}]
set arr_m     [expr {$argc > 2 ? [lindex $argv 2] : 8}]
set arr_n     [expr {$argc > 3 ? [lindex $argv 3] : 8}]

set rtl_dir   [file normalize [file dirname [info script]]/../rtl]
set out_dir   [file normalize [file dirname [info script]]/../results/synth]
file mkdir $out_dir

puts "=== synth: part=$part  clk=${clk_ns}ns  array=${arr_m}x${arr_n} ==="

# --- чтение RTL (SVA не синтезируем — только pe.sv + systolic_array.sv) ---
read_verilog -sv [list $rtl_dir/pe.sv $rtl_dir/systolic_array.sv]

# --- синтез OUT-OF-CONTEXT (-mode out_of_context) ---
# systolic_array — НЕ самостоятельный чип, а ядро: данные придут по AXI из HBM,
# а не с физических пинов. Плоские шины a/b/c_flat = 2180 портов, у VU47P только
# 1106 I/O → без OOC place_design падает 'IO overutilization'. OOC отключает
# вставку I/O-буферов и посадку портов на пины → получаем чистые f_max/ресурсы
# ЛОГИКИ модуля (именно это и нужно на P3; обёртку синтезирует уже Vitis).
synth_design -top systolic_array -part $part -mode out_of_context \
             -generic ARRAY_M=$arr_m -generic ARRAY_N=$arr_n

# тактовая: создаём здесь (XDC read_xdc тоже можно, но период параметризуем)
create_clock -name clk -period $clk_ns [get_ports clk]

# --- имплементация ---
opt_design
place_design
route_design

# --- РЕПОРТЫ (это и есть предмет анализа в docs/report_analysis.md) ---
report_timing_summary -file $out_dir/timing_summary.rpt
report_utilization    -file $out_dir/utilization.rpt
report_power          -file $out_dir/power.rpt
report_drc            -file $out_dir/drc.rpt

# --- краткая сводка в stdout: WNS и достижимый f_max ---
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set achieved_ns [expr {$clk_ns - $wns}]
set fmax_mhz [expr {1000.0 / $achieved_ns}]
puts "----------------------------------------------------------------"
puts [format "WNS = %.3f ns   (>=0 => тайминг закрыт)" $wns]
puts [format "f_max ~ %.1f МГц  (при периоде %.2f нс, WNS %.3f)" $fmax_mhz $clk_ns $wns]
puts "Ресурсы/питание — в $out_dir/*.rpt (DSP ~ число PE = [expr {$arr_m*$arr_n}])"
puts "----------------------------------------------------------------"

# опционально: чекпойнт для hardware manager / повторного открытия
write_checkpoint -force $out_dir/systolic_routed.dcp
