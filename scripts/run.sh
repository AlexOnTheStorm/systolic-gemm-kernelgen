#!/usr/bin/env bash
# =====================================================================
#  run.sh — orchestrator for the LOCAL stages (P1–P2, on a laptop in a venv).
#  Cloud stages P3–P4 (synth/ILA) are separate, see docs/cloud_setup.md.
#
#    ./run.sh sim     — P1: self-check + coverage + SVA
#    ./run.sh dse     — P2: DSE config search (grid + hill-climb)
#    ./run.sh all     — sim, then dse
#  Needs an active venv with cocotb/verilator/python.
# =====================================================================
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CMD="${1:-all}"

run_sim() {
  echo "== P1: sim =="
  # clean is required: DSE (P2) leaves a build WITHOUT trace, and this stage needs --trace.
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
