# =====================================================================
#  constraints.xdc — тайминговые ограничения для OOC-синтеза systolic_array.
#
#  Для STANDALONE-синтеза (P3, оценка f_max/ресурсов) задаём тактовую частоту
#  сами. В Vitis-флоу (P4) тактовую даёт платформа — этот файл там НЕ нужен.
#
#  Период задаётся из synth.tcl через переменную; дефолт 3.0 нс (~333 МГц).
#  Меняй CLK_PERIOD_NS в synth.tcl и пересматривай WNS (см. docs/report_analysis.md).
# =====================================================================

# создаём виртуальную тактовую на входном порту clk
create_clock -name clk -period 3.000 [get_ports clk]

# входы/выходы: условный I/O-бюджет (для OOC — грубая рамка, не критично)
set_input_delay  -clock clk 0.500 [all_inputs]
set_output_delay -clock clk 0.500 [all_outputs]

# clk сам под set_input_delay не попадает
set_false_path -from [get_ports clk]
