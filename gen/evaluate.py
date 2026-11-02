"""
evaluate.py — run ONE array config through a real simulation and collect metrics.

This is the "evaluate performance in simulation" step of the loop: for a config
(ARRAY_M×ARRAY_N) we rebuild Verilator with -GARRAY_M/-GARRAY_N and run
tb/test_eval.py, which measures the settle latency and checks correctness against golden.

Needs an active venv (cocotb-config/verilator on PATH). search.py calls this in a loop.
A rebuild per config takes seconds, which is fine for a DSE of tens of points.
"""
from __future__ import annotations
import os
import re
import json
import subprocess
from dataclasses import dataclass
from pathlib import Path

from generator import Config

SCRIPTS_DIR = (Path(__file__).resolve().parent / ".." / "scripts").resolve()
_EVAL_RE = re.compile(r"EVAL_JSON\s+(\{.*\})")


@dataclass
class EvalResult:
    cfg: Config
    k: int
    ok: bool
    latency: int          # settle cycles of ONE tile (deterministic)
    raw: str = ""         # log tail on error


def run_sim(cfg: Config, k: int, timeout: int = 240) -> EvalResult:
    """Build a config in Verilator and measure the tile latency/correctness."""
    env = os.environ.copy()
    env.update({
        "ARRAY_M": str(cfg.array_m),
        "ARRAY_N": str(cfg.array_n),
        "DATA_WIDTH": str(cfg.data_width),
        "ACC_WIDTH": str(cfg.acc_width),
        "EVAL_K": str(k),
    })
    # -G parameters go into EXTRA_ARGS (APPENDED to the verilator call), not into
    # COMPILE_ARGS — otherwise we would clobber cocotb's mandatory flags (--prefix/-o/--vpi).
    # --assert is on; --trace is NOT (faster rebuilds during DSE).
    gargs = (f"-GARRAY_M={cfg.array_m} -GARRAY_N={cfg.array_n} "
             f"-GDATA_WIDTH={cfg.data_width} -GACC_WIDTH={cfg.acc_width} --assert")

    # clean rebuild for the new parameters
    subprocess.run(["make", "clean"], cwd=SCRIPTS_DIR, env=env,
                   capture_output=True, text=True)
    try:
        p = subprocess.run(
            ["make", "MODULE=test_eval", f"EXTRA_ARGS={gargs}"],
            cwd=SCRIPTS_DIR, env=env, capture_output=True, text=True, timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return EvalResult(cfg, k, ok=False, latency=-1, raw="TIMEOUT")

    out = p.stdout + p.stderr
    m = _EVAL_RE.search(out)
    if not m:
        return EvalResult(cfg, k, ok=False, latency=-1, raw=out[-600:])
    data = json.loads(m.group(1))
    return EvalResult(cfg, k, ok=bool(data["ok"]) and p.returncode == 0,
                      latency=int(data["latency"]))


if __name__ == "__main__":
    # quick manual run of one config
    r = run_sim(Config(array_m=4, array_n=4), k=8)
    print(f"cfg={r.cfg.key()} k={r.k} ok={r.ok} latency={r.latency} cycle(s)")
