#!/usr/bin/env bash
# =====================================================================
#  run.sh — оркестратор ЛОКАЛЬНЫХ стадий (P1–P2, на маке в fpga-venv).
#  Облачные P3–P4 (synth/ILA) — отдельно, см. docs/cloud_setup.md.
#
#    ./run.sh sim     — P1: self-check + coverage + SVA
#    ./run.sh dse     — P2: DSE-поиск конфига (grid+hillclimb)
#    ./run.sh all     — sim, затем dse
#  Требует активного fpga-venv (cocotb/verilator/python).
# =====================================================================
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CMD="${1:-all}"

run_sim() {
  echo "== P1: sim =="
  # clean обязателен: DSE (P2) оставляет сборку БЕЗ trace, а тут нужен --trace.
  ( cd "$HERE" && make clean >/dev/null 2>&1; make )
}
run_dse() {
  echo "== P2: DSE =="
  ( cd "$HERE/../gen" && python3 search.py --M 64 --N 64 --K 64 --budget 64 )
}

case "$CMD" in
  sim) run_sim ;;
  dse) run_dse ;;
  all) run_sim; run_dse ;;
  *)   echo "usage: run.sh [sim|dse|all]"; exit 1 ;;
esac
