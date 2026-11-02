#!/usr/bin/env bash
# =====================================================================
#  build_hw.sh — link the .xo into an .xclbin with v++ (P4, in the cloud).
#  Inserts a System ILA on the kernel interfaces (--debug.chipscope) for
#  on-hardware debug via ChipScope/debug-bridge (virtual JTAG on F2).
#
#  Three targets (TARGET):
#    sw_emu — fast check of host+kernel logic (seconds), no RTL accuracy
#    hw_emu — RTL-accurate emulation in QEMU + Verilog sim (minutes), waves/ILA dry run
#    hw     — real bitstream for F2/Alveo (HOURS of synthesis + P&R)
#
#  Usage:
#    ./build_hw.sh sw_emu        # local check on the build instance
#    ./build_hw.sh hw_emu        # RTL emulation
#    ./build_hw.sh hw            # hardware bitstream (slow, for F2)
#
#  Platform: AWS F2 = xilinx_aws-vu47p-f2_202420_2  (VU47P, 9024 DSP)
#            (old AWS F1 = xilinx_aws-vu9p-f1_shell-v04261818_201920_3;
#             Alveo U200 = xilinx_u200_gen3x16_xdma_2_202110_1)
#  (⚠️ the exact platform name depends on the version — see `platforminfo -l`.)
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

# --debug.chipscope <cu> attaches a System ILA to the compute unit's interfaces.
# The ILA only makes sense for a real bitstream (hw) — for sw_emu/hw_emu debugging
# uses simulator waves, and chipscope is redundant there (v++ complains or ignores it).
# So the ILA flag is added for hw only.
ila_args=()
if [[ "$TARGET" == "hw" ]]; then
  ila_args=(--debug.chipscope "${KRNL}_1")
fi

# -g enables a debug build (symbols for emulation/ILA).
v++ -l -t "$TARGET" --platform "$PLATFORM" \
    -g "${ila_args[@]}" \
    --connectivity.nk "${KRNL}:1:${KRNL}_1" \
    -o "$OUT/${KRNL}.${TARGET}.xclbin" \
    "$XO"

echo "→ $OUT/${KRNL}.${TARGET}.xclbin"
echo "Next: host/run_hw.py (see docs/flow_walkthrough.md); ILA in the Vivado hw_manager."
