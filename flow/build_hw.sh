#!/usr/bin/env bash
# =====================================================================
#  build_hw.sh — линковка .xo в .xclbin через v++ (P4, в облаке).
#  Вставляет System ILA на интерфейсы kernel'а (--debug.chipscope) для
#  отладки на железе через ChipScope/debug-bridge (виртуальный JTAG на F2).
#
#  Три цели (TARGET):
#    sw_emu — быстрая проверка host+kernel логики (секунды), без RTL-точности
#    hw_emu — RTL-точная эмуляция в QEMU+Verilog-sim (минуты), волны/ILA-препрув
#    hw     — реальный битстрим для F2/Alveo (ЧАСЫ синтеза+P&R)
#
#  Использование:
#    ./build_hw.sh sw_emu        # локальная проверка на build-инстансе
#    ./build_hw.sh hw_emu        # RTL-эмуляция
#    ./build_hw.sh hw            # железный битстрим (долго, для F2)
#
#  Платформа: AWS F2 = xilinx_aws-vu47p-f2_202420_2  (VU47P, 9024 DSP)
#             (старый AWS F1 = xilinx_aws-vu9p-f1_shell-v04261818_201920_3;
#              Alveo U200 = xilinx_u200_gen3x16_xdma_2_202110_1)
#  (⚠️ точное имя платформы зависит от версии — см. `platforminfo -l`.)
# =====================================================================
set -euo pipefail

TARGET="${1:-hw_emu}"
KRNL=gemm_kernel
PLATFORM="${PLATFORM:-xilinx_aws-vu47p-f2_202420_2}"

HERE="$(cd "$(dirname "$0")" && pwd)"
XO="$HERE/../results/xo/${KRNL}.xo"
OUT="$HERE/../results/hw"
mkdir -p "$OUT"

echo "=== v++ link: target=$TARGET platform=$PLATFORM ==="

# --debug.chipscope <cu> вешает System ILA на интерфейсы вычислительного юнита;
# -g включает отладочную сборку. На hw это добавляет ILA в битстрим.
v++ -l -t "$TARGET" --platform "$PLATFORM" \
    -g --debug.chipscope "${KRNL}_1" \
    --connectivity.nk "${KRNL}:1:${KRNL}_1" \
    -o "$OUT/${KRNL}.${TARGET}.xclbin" \
    "$XO"

echo "→ $OUT/${KRNL}.${TARGET}.xclbin"
echo "Дальше: host/run_hw.py (см. docs/flow_walkthrough.md), ILA — в Vivado hw_manager."
