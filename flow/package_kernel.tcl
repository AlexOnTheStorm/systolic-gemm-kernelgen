# =====================================================================
#  package_kernel.tcl — package the RTL into a Vitis kernel .xo (P4, in the cloud).
#  A COMPLETE headless script (not a skeleton): project → IP → interface tagging →
#  package_xo. Everything from the terminal and version-controlled.
#
#  Flow (UG1393 "Packaging RTL as .xo"):
#    RTL → Vivado IP (ipx) → tag interfaces → package_xo (+kernel.xml) → .xo
#
#  ⚠️ The first run is EXPLORATORY: it prints the interface names that ipx
#     inferred from the ports (s_axil_*/m_axi_*/ap_clk/ap_rst_n). If the inferred
#     names differ from the expected ones, fix the normalization block below from the log.
#  ⚠️ Our s_axil_* is a simplified AXI-Lite (no WSTRB/BRESP/RRESP/PROT). If
#     ipx/linking complains about an incomplete interface, add the signals in the RTL
#     OR wrap it with an adapter (see docs/flow_walkthrough.md, section P4).
#
#  Run:  vivado -mode batch -source flow/package_kernel.tcl
# =====================================================================
set krnl     gemm_kernel
set part     xcvu47p-fsvh2892-3-e
# the array size is "baked" into the .xo at packaging time (a compile-time parameter,
# not runtime). Override via env: ARRAY_M/ARRAY_N. Default 8×8 matches the P3 headline
# (795 MHz, 64 DSP) and the host default (--M 8 --N 8). K stays runtime (k_dim≤K_MAX).
set arr_m    [expr {[info exists ::env(ARRAY_M)] ? $::env(ARRAY_M) : 8}]
set arr_n    [expr {[info exists ::env(ARRAY_N)] ? $::env(ARRAY_N) : 8}]
set here     [file normalize [file dirname [info script]]]
set rtl_dir  $here/../rtl
set out_dir  $here/../results/xo
set ip_dir   $out_dir/ip
file mkdir $out_dir

# --- 0) clean previous artifacts: package_xo does NOT overwrite an existing
#        .xo ("Kernel already exists inside XO container") → delete it ourselves. ---
file delete -force $out_dir/$krnl.xo
file delete -force $ip_dir
file delete -force $out_dir/pack

# --- 1) temporary project for IP packaging ---
create_project -force pack_$krnl $out_dir/pack -part $part
add_files -norecurse [list $rtl_dir/pe.sv $rtl_dir/systolic_array.sv $rtl_dir/$krnl.sv]
set_property top $krnl [current_fileset]
# bake the array size into top via a generic (compile-time)
set_property generic "ARRAY_M=$arr_m ARRAY_N=$arr_n" [current_fileset]
puts "=== packaging gemm_kernel  ARRAY_M=$arr_m  ARRAY_N=$arr_n ==="
update_compile_order -fileset sources_1

# --- 2) package as IP (ipx infers bus interfaces from port names) ---
ipx::package_project -root_dir $ip_dir -vendor user.org -library user \
    -taxonomy /KernelIP -import_files -set_current true
set core [ipx::current_core]

# --- 2a) EXPLORATION: what did ipx infer? (the names feed the normalization below) ---
puts "=================== inferred bus interfaces ==================="
foreach bif [ipx::get_bus_interfaces -of_objects $core] {
  puts "  BUSIF: [get_property name $bif]   ([get_property abstraction_type_vlnv $bif])"
}
puts "=============================================================="

# --- 3) normalize names to what kernel.xml expects -----------------
#   ipx usually names an interface after the common port prefix. We expect
#   something like 's_axil' and 'm_axi'. Rename them to the Vitis convention.
#   (catch so the exploratory run does not fail if a name differs; fix from the log.)
catch { set_property name s_axi_control [ipx::get_bus_interfaces s_axil -of_objects $core] } e1
catch { set_property name m_axi_gmem    [ipx::get_bus_interfaces m_axi  -of_objects $core] } e2
puts "rename s_axil->s_axi_control: ${e1}"
puts "rename m_axi->m_axi_gmem:     ${e2}"

# --- 3a) gmem master: 64-bit address space (XRT needs it for DMA) ---
#   2025.2 syntax: name + component positionally (no -index). range = full
#   64-bit; the master points to its address space via master_address_space_ref.
catch {
  ipx::add_address_space Data_m_axi_gmem $core
  set_property range 0xFFFFFFFFFFFFFFFF \
      [ipx::get_address_spaces Data_m_axi_gmem -of_objects $core]
  set_property width 64 \
      [ipx::get_address_spaces Data_m_axi_gmem -of_objects $core]
  set_property master_address_space_ref Data_m_axi_gmem \
      [ipx::get_bus_interfaces m_axi_gmem -of_objects $core]
} e3
puts "gmem address space: ${e3}"

# --- 3b) associate the clock with both interfaces (ASSOCIATED_BUSIF) ---
catch {
  ipx::associate_bus_interfaces -busif s_axi_control -clock ap_clk $core
  ipx::associate_bus_interfaces -busif m_axi_gmem    -clock ap_clk $core
} e4
puts "clock assoc: ${e4}"

# --- 4) save the component and package it into an .xo ---
set_property core_revision 1 $core
ipx::create_xgui_files $core
ipx::update_checksums   $core
ipx::save_core          $core

package_xo -xo_path $out_dir/$krnl.xo -kernel_name $krnl \
           -ip_directory $ip_dir \
           -kernel_xml $here/kernel.xml

puts "→ $out_dir/$krnl.xo  (ready for v++ linking, see flow/build_hw.sh)"
