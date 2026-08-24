# =====================================================================
#  package_kernel.tcl — упаковать RTL в Vitis-kernel .xo (P4, в облаке).
#
#  Поток (UG1393 «Packaging RTL as .xo»):
#    RTL → Vivado IP (с описанием интерфейсов) → package_xo → gemm_kernel.xo
#
#  ⚠️ ПРАКТИКА: интерфейсный boilerplate (kernel.xml + IP-упаковка + AXI-Lite
#  адаптер) удобнее генерить Vitis RTL Kernel Wizard:
#      vitis -new_kernel  ИЛИ  Tools > Create RTL Kernel в Vitis IDE
#  Он даёт заготовку gemm_kernel с готовыми s_axi_control/m_axi_gmem, куда
#  вставляется наш вычислитель (rtl/gemm_kernel.sv как reference интеграции).
#  Этот tcl — минимальный «ручной» референс того, что делает мастер.
#
#  Запуск:  vivado -mode batch -source flow/package_kernel.tcl
# =====================================================================
set krnl   gemm_kernel
set rtl_dir [file normalize [file dirname [info script]]/../rtl]
set out_dir [file normalize [file dirname [info script]]/../results/xo]
file mkdir $out_dir

# 1) временный проект для упаковки IP
create_project -force pack_$krnl $out_dir/pack -part xcvu9p-flgb2104-2-i
add_files -norecurse [list $rtl_dir/pe.sv $rtl_dir/systolic_array.sv $rtl_dir/$krnl.sv]
set_property top $krnl [current_fileset]
update_compile_order -fileset sources_1

# 2) упаковать как IP + пометить интерфейсы (AXI-Lite control, AXI master gmem)
#    Здесь — ключевые вызовы; полную разметку интерфейсов делает Wizard.
ipx::package_project -root_dir $out_dir/ip -vendor user.org -library user \
    -taxonomy /KernelIP -import_files -set_current true
#   ↳ дальше: ipx::add_bus_interface / associate_bus_interfaces для
#     s_axi_control (aximm/AXI4LITE) и m_axi_gmem (aximm/AXI4) + ap_clk/ap_rst_n.
#     (см. UG1393; в этом референсе опущено ради краткости — берётся из Wizard.)
ipx::save_core

# 3) упаковать IP в .xo
package_xo -xo_path $out_dir/$krnl.xo -kernel_name $krnl \
           -ip_directory $out_dir/ip \
           -kernel_xml $rtl_dir/../flow/kernel.xml

puts "→ $out_dir/$krnl.xo  (готово к линковке v++, см. build_hw.sh)"
