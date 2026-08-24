# =====================================================================
#  ila_debug.tcl — ГОЛОВНОЙ (headless) захват ILA через Vivado batch Tcl.
#  Никакого GUI: коннект к железу, взвод триггера, захват, выгрузка волны
#  в CSV+VCD. Ровно под облачную машину без десктопа.
#
#  Запуск (на build/F1-инстансе):
#    vivado -mode batch -source flow/ila_debug.tcl
#  Волна → results/ila/capture.vcd  (смотри локально в surfer/gtkwave после scp,
#  или headless: `surfer results/ila/capture.vcd`). CSV — для grep/pandas.
#
#  ⚠️ Подключение к FPGA:
#   - Alveo (локально в облаке): hw_server видит карту напрямую (localhost:3121).
#   - AWS F1: нет физического JTAG → Virtual JTAG (XVC) поверх PCIe. Сначала:
#       sudo fpga-load-local-image -S 0 -I <agfi>          # залить AFI с ILA
#       sudo fpga-start-virtual-jtag -P 10201 -S 0         # поднять XVC-сервер
#     затем open_hw_target с -xvc_url (см. ниже). Точные шаги — aws-fpga/Vitis debug.
# =====================================================================
set out_dir [file normalize [file dirname [info script]]/../results/ila]
file mkdir $out_dir

open_hw_manager
connect_hw_server -url localhost:3121

# --- выбрать target: Alveo напрямую ИЛИ F1 через XVC ---
if {[info exists ::env(XVC_URL)]} {
    open_hw_target -xvc_url $::env(XVC_URL)      ;# F1: напр. localhost:10201
} else {
    open_hw_target                               ;# Alveo/локальный JTAG
}
current_hw_device [lindex [get_hw_devices] 0]
refresh_hw_device -update_hw_probes true [current_hw_device]

set ila [lindex [get_hw_ilas -of_objects [current_hw_device]] 0]
puts "ILA: $ila"

# --- триггер: старт GEMM (ap_start=1). Имя пробы зависит от debug-netlist;
#     посмотреть доступные: `get_hw_probes -of_objects $ila` ---
set p [get_hw_probes -of_objects $ila *ap_start*]
if {[llength $p]} {
    set_property TRIGGER_COMPARE_VALUE eq1'b1 $p
}
# позиция триггера в окне захвата (сколько сэмплов ДО триггера)
set_property CONTROL.TRIGGER_POSITION 16 $ila

# --- вооружить, дождаться, выгрузить ---
run_hw_ila $ila
puts "ILA вооружён — запусти host/run_hw.py в другом терминале..."
wait_on_hw_ila -timeout 120 $ila
upload_hw_ila_data $ila

set data [current_hw_ila_data]
write_hw_ila_data -force -csv_file $out_dir/capture.csv $data
write_hw_ila_data -force -vsim_tcl_file $out_dir/capture.tcl $data
# VCD для волновых вьюверов (surfer/gtkwave):
write_hw_ila_data -force -vcd_file $out_dir/capture.vcd $data

puts "→ $out_dir/capture.{vcd,csv}  (открой vcd в surfer/gtkwave)"
close_hw_manager
