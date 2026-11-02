"""
search.py — workload-aware DSE (design-space exploration) of the systolic array.

Given: a GEMM (M, N, K) + a PE budget (~ number of DSPs). We search for the array size
ARRAY_M×ARRAY_N that maximizes throughput, CHECKING every candidate in REAL
simulation (gen/evaluate.py → Verilator). This is a reusable workload-aware generation
mechanism that uses measured feedback to guide the next iterations.

Metrics (labeled by source):
  latency_tile  — MEASURED in simulation (deterministic tile latency);
  total_cycles  — MODEL: n_tiles * latency_tile (tiles run sequentially;
                  overlapping fill/drain of adjacent tiles is a possible optimization);
  throughput    — MAC/cycle = (M*N*K) / total_cycles;
  pe_count      — resource proxy (number of multipliers ≈ DSPs); f_max/LUT come from P3 (synth).

Two modes: grid (exhaustive) and hillclimb (greedy neighbour search — fewer
simulation runs). Writes results/dse.json (+ a png if matplotlib is available).
"""
from __future__ import annotations
import os
import json
import argparse
from pathlib import Path

from generator import Config, enumerate_configs, neighbours, n_tiles
from evaluate import run_sim, EvalResult

RESULTS_DIR = Path(__file__).resolve().parent / "results"
DIMS = (2, 4, 8)


def score(res: EvalResult, M: int, N: int, K: int) -> dict:
    """Build full-GEMM metrics from the measured tile latency."""
    tiles = n_tiles(M, N, res.cfg)
    total_cycles = tiles * res.latency
    macs = M * N * K
    throughput = macs / total_cycles if total_cycles else 0.0
    return {
        "cfg": res.cfg.key(),
        "array_m": res.cfg.array_m, "array_n": res.cfg.array_n,
        "pe_count": res.cfg.pe_count,
        "latency_tile": res.latency,      # measured in simulation
        "n_tiles": tiles,
        "total_cycles": total_cycles,     # model (sequential tiles)
        "throughput_mac_per_cyc": round(throughput, 3),
        "util_per_pe": round(throughput / res.cfg.pe_count, 4),  # MAC/cycle/PE
        "ok": res.ok,
    }


class Evaluator:
    """Caching wrapper around the simulation (never run the same config twice)."""
    def __init__(self, M, N, K, eval_k):
        self.M, self.N, self.K, self.eval_k = M, N, K, eval_k
        self.cache: dict[str, dict] = {}
        self.n_sims = 0

    def eval(self, cfg: Config) -> dict:
        if cfg.key() in self.cache:
            return self.cache[cfg.key()]
        self.n_sims += 1
        print(f"  [sim {self.n_sims:2d}] {cfg.key():12s} ...", end="", flush=True)
        res = run_sim(cfg, k=self.eval_k)
        m = score(res, self.M, self.N, self.K)
        print(f" lat={res.latency:3d}  thr={m['throughput_mac_per_cyc']:8.2f} MAC/cycle"
              f"  ({'ok' if res.ok else 'FAIL'})")
        self.cache[cfg.key()] = m
        return m


def grid(ev: Evaluator, max_pe: int) -> list[dict]:
    cfgs = enumerate_configs(max_pe, dims=DIMS)
    return [ev.eval(c) for c in cfgs]


def hillclimb(ev: Evaluator, max_pe: int, seed: Config) -> dict:
    """Greedy ascent: move to the best neighbour while throughput keeps growing."""
    cur = ev.eval(seed)
    improved = True
    while improved:
        improved = False
        for nb in neighbours(Config(cur["array_m"], cur["array_n"]), dims=DIMS):
            if nb.pe_count > max_pe:
                continue
            cand = ev.eval(nb)
            if cand["ok"] and cand["throughput_mac_per_cyc"] > cur["throughput_mac_per_cyc"]:
                cur, improved = cand, True
    return cur


def main():
    ap = argparse.ArgumentParser(description="DSE of the systolic array for a GEMM")
    ap.add_argument("--M", type=int, default=64)
    ap.add_argument("--N", type=int, default=64)
    ap.add_argument("--K", type=int, default=64)
    ap.add_argument("--budget", type=int, default=64, help="max number of PEs (~DSP)")
    ap.add_argument("--eval-k", type=int, default=8, help="K of one tile in the sim measurement")
    ap.add_argument("--mode", choices=["grid", "hillclimb", "both"], default="both")
    args = ap.parse_args()

    print(f"\nDSE: GEMM {args.M}x{args.N}x{args.K}, budget {args.budget} PE, "
          f"candidates from {DIMS}\n")
    ev = Evaluator(args.M, args.N, args.K, args.eval_k)

    all_results = []
    best = None

    if args.mode in ("grid", "both"):
        print("== GRID ==")
        rows = [r for r in grid(ev, args.budget) if r["ok"]]
        rows.sort(key=lambda r: -r["throughput_mac_per_cyc"])
        all_results = rows
        best = rows[0] if rows else None
        print("\n  config       PE  lat  tiles   total_cyc  MAC/cycle MAC/cycle/PE")
        for r in rows:
            print(f"  {r['cfg']:12s} {r['pe_count']:3d} {r['latency_tile']:4d} "
                  f"{r['n_tiles']:5d} {r['total_cycles']:10d} "
                  f"{r['throughput_mac_per_cyc']:9.2f} {r['util_per_pe']:11.4f}")

    if args.mode in ("hillclimb", "both"):
        print("\n== HILLCLIMB (seed 2x2) ==")
        hc = hillclimb(ev, args.budget, Config(2, 2))
        print(f"  hillclimb picked {hc['cfg']} "
              f"({hc['throughput_mac_per_cyc']:.2f} MAC/cycle) in {ev.n_sims} runs")
        if best is None:
            best = hc

    print(f"\nBEST: {best['cfg']}  "
          f"{best['throughput_mac_per_cyc']:.2f} MAC/cycle  "
          f"({best['pe_count']} PE, util {best['util_per_pe']:.3f} MAC/cycle/PE)")
    print(f"Total simulations: {ev.n_sims}")

    # --- save the artifact ---
    RESULTS_DIR.mkdir(exist_ok=True)
    payload = {
        "workload": {"M": args.M, "N": args.N, "K": args.K},
        "budget_pe": args.budget,
        "best": best,
        "grid": all_results or list(ev.cache.values()),
        "n_simulations": ev.n_sims,
    }
    (RESULTS_DIR / "dse.json").write_text(json.dumps(payload, indent=2, ensure_ascii=False))
    print(f"\n→ results/dse.json")
    _maybe_plot(payload)


def _maybe_plot(payload: dict):
    """Optional throughput vs PE plot (if matplotlib is installed)."""
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        print("  (no matplotlib — plot skipped, data is in dse.json)")
        return
    rows = payload["grid"]
    if not rows:
        return
    xs = [r["pe_count"] for r in rows]
    ys = [r["throughput_mac_per_cyc"] for r in rows]
    labels = [r["cfg"] for r in rows]
    plt.figure(figsize=(7, 5))
    plt.scatter(xs, ys, c="tab:blue")
    for x, y, lab in zip(xs, ys, labels):
        plt.annotate(lab, (x, y), fontsize=7, xytext=(4, 3), textcoords="offset points")
    b = payload["best"]
    plt.scatter([b["pe_count"]], [b["throughput_mac_per_cyc"]], c="tab:red", s=120,
                marker="*", label=f"best {b['cfg']}")
    w = payload["workload"]
    plt.title(f"DSE: GEMM {w['M']}x{w['N']}x{w['K']} — throughput vs PE")
    plt.xlabel("PE count (~DSP)"); plt.ylabel("MAC/cycle (model)")
    plt.legend(); plt.grid(True, alpha=0.3); plt.tight_layout()
    out = RESULTS_DIR / "dse_throughput.png"
    plt.savefig(out, dpi=110)
    print(f"→ results/dse_throughput.png")


if __name__ == "__main__":
    main()
