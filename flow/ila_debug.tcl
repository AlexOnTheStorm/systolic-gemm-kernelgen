# =====================================================================
#  ila_debug.tcl — HEADLESS ILA capture via Vivado batch Tcl.
#  No GUI: connect to the hardware, arm the trigger, capture, dump the waveform
#  to CSV+VCD. Made for a cloud machine without a desktop.
#
#  Run (on the build/F2 instance):
#    vivado -mode batch -source flow/ila_debug.tcl
#  Waveform → results/ila/capture.vcd  (view locally in surfer/gtkwave after scp,
#  or headless: `surfer results/ila/capture.vcd`). The CSV is for grep/pandas.
#
#  ⚠️ Connecting to the FPGA:
#   - Alveo (local in the cloud): hw_server sees the card directly (localhost:3121).
#   - AWS F2: no physical JTAG → Virtual JTAG (XVC) over PCIe. First:
#       sudo fpga-load-local-image -S 0 -I <agfi>          # load the AFI with the ILA
#       sudo fpga-start-virtual-jtag -P 10201 -S 0         # start the XVC server
#     then open_hw_target with -xvc_url (see below). Exact steps: aws-fpga / Vitis debug docs.
# =====================================================================
set out_dir [file normalize [file dirname [info script]]/../results/ila]
file mkdir $out_dir

open_hw_manager
connect_hw_server -url localhost:3121

# --- pick the target: Alveo directly OR F2 via XVC ---
if {[info exists ::env(XVC_URL)]} {
    open_hw_target -xvc_url $::env(XVC_URL)      ;# F2: e.g. localhost:10201
} else {
    open_hw_target                               ;# Alveo/local JTAG
}
current_hw_device [lindex [get_hw_devices] 0]
refresh_hw_device -update_hw_probes true [current_hw_device]

set ila [lindex [get_hw_ilas -of_objects [current_hw_device]] 0]
puts "ILA: $ila"

# --- trigger: GEMM start (ap_start=1). The probe name depends on the debug netlist;
#     list the available ones with `get_hw_probes -of_objects $ila` ---
set p [get_hw_probes -of_objects $ila *ap_start*]
if {[llength $p]} {
    set_property TRIGGER_COMPARE_VALUE eq1'b1 $p
}
# trigger position in the capture window (how many samples BEFORE the trigger)
set_property CONTROL.TRIGGER_POSITION 16 $ila

# --- arm, wait, upload ---
run_hw_ila $ila
puts "ILA armed — run host/run_hw.py in another terminal..."
wait_on_hw_ila -timeout 120 $ila
upload_hw_ila_data $ila

set data [current_hw_ila_data]
write_hw_ila_data -force -csv_file $out_dir/capture.csv $data
write_hw_ila_data -force -vsim_tcl_file $out_dir/capture.tcl $data
# VCD for waveform viewers (surfer/gtkwave):
write_hw_ila_data -force -vcd_file $out_dir/capture.vcd $data

puts "→ $out_dir/capture.{vcd,csv}  (open the vcd in surfer/gtkwave)"
close_hw_manager
