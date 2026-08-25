# =====================================================================
#  package_kernel.tcl — упаковать RTL в Vitis-kernel .xo (P4, в облаке).
#  ПОЛНЫЙ headless-скрипт (не скелет): проект → IP → разметка интерфейсов →
#  package_xo. Всё из терминала, версионируется (в духе проекта).
#
#  Поток (UG1393 «Packaging RTL as .xo»):
#    RTL → Vivado IP (ipx) → tag интерфейсов → package_xo (+kernel.xml) → .xo
#
#  ⚠️ Первый прогон РАЗВЕДОЧНЫЙ: печатает имена интерфейсов, которые ipx
#     вывел из портов (s_axil_*/m_axi_*/ap_clk/ap_rst_n). Если авто-имена не
#     совпали с ожидаемыми — правим блок нормализации ниже по факту вывода.
#  ⚠️ Наш s_axil_* — упрощённый AXI-Lite (нет WSTRB/BRESP/RRESP/PROT). Если
#     ipx/линковка ругнётся на неполный интерфейс — дополняем сигналы в RTL
#     ИЛИ оборачиваем адаптером (см. docs/flow_walkthrough.md, раздел P4).
#
#  Запуск:  vivado -mode batch -source flow/package_kernel.tcl
# =====================================================================
set krnl     gemm_kernel
set part     xcvu47p-fsvh2892-3-e
set here     [file normalize [file dirname [info script]]]
set rtl_dir  $here/../rtl
set out_dir  $here/../results/xo
set ip_dir   $out_dir/ip
file mkdir $out_dir

# --- 0) чистим прошлые артефакты: package_xo НЕ перезаписывает существующий
#        .xo («Kernel already exists inside XO container») → удаляем сами. ---
file delete -force $out_dir/$krnl.xo
file delete -force $ip_dir
file delete -force $out_dir/pack

# --- 1) временный проект для упаковки IP ---
create_project -force pack_$krnl $out_dir/pack -part $part
add_files -norecurse [list $rtl_dir/pe.sv $rtl_dir/systolic_array.sv $rtl_dir/$krnl.sv]
set_property top $krnl [current_fileset]
update_compile_order -fileset sources_1

# --- 2) упаковать как IP (ipx авто-выводит bus-интерфейсы из имён портов) ---
ipx::package_project -root_dir $ip_dir -vendor user.org -library user \
    -taxonomy /KernelIP -import_files -set_current true
set core [ipx::current_core]

# --- 2a) РАЗВЕДКА: что ipx вывел? (имена — вход для нормализации ниже) ---
puts "=================== inferred bus interfaces ==================="
foreach bif [ipx::get_bus_interfaces -of_objects $core] {
  puts "  BUSIF: [get_property name $bif]   ([get_property abstraction_type_vlnv $bif])"
}
puts "=============================================================="

# --- 3) нормализация имён под то, что ждёт kernel.xml -----------------
#   ipx обычно называет интерфейс по общему префиксу портов. Ожидаем найти
#   что-то вроде 's_axil' и 'm_axi'. Переименовываем в Vitis-конвенцию.
#   (catch — чтобы разведочный прогон не падал, если имя иное; правим по логу.)
catch { set_property name s_axi_control [ipx::get_bus_interfaces s_axil -of_objects $core] } e1
catch { set_property name m_axi_gmem    [ipx::get_bus_interfaces m_axi  -of_objects $core] } e2
puts "rename s_axil->s_axi_control: ${e1}"
puts "rename m_axi->m_axi_gmem:     ${e2}"

# --- 3a) master gmem: адресное пространство 64-бит (нужно XRT для DMA) ---
#   Синтаксис 2025.2: имя + компонент позиционно (без -index). range = полный
#   64-бит; ссылка мастера на своё адресное пространство — master_address_space_ref.
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

# --- 3b) привязать тактовую к обоим интерфейсам (ASSOCIATED_BUSIF) ---
catch {
  ipx::associate_bus_interfaces -busif s_axi_control -clock ap_clk $core
  ipx::associate_bus_interfaces -busif m_axi_gmem    -clock ap_clk $core
} e4
puts "clock assoc: ${e4}"

# --- 4) сохранить компонент и упаковать в .xo ---
set_property core_revision 1 $core
ipx::create_xgui_files $core
ipx::update_checksums   $core
ipx::save_core          $core

package_xo -xo_path $out_dir/$krnl.xo -kernel_name $krnl \
           -ip_directory $ip_dir \
           -kernel_xml $here/kernel.xml

puts "→ $out_dir/$krnl.xo  (готово к линковке v++, см. flow/build_hw.sh)"
