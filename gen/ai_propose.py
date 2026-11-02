"""
ai_propose.py — AI-assisted proposal of the next configs for the DSE (P5).

Closes an AI-assisted generation loop: from ALREADY measured results an LLM
proposes which configs to try next (instead of sweeping the whole grid).

⚠️ To be clear: this is an ADD-ON, not the core. The search (gen/search.py) works
without an LLM. Here: if ANTHROPIC_API_KEY and the anthropic package are present,
we ask the model; otherwise a heuristic fallback (an untried neighbour of the best
config). The loop demonstrates AI-in-the-loop without depending on it.

Usage (from search.py or standalone):
    from ai_propose import propose_next
    next_cfgs = propose_next(results, budget=64, tried={"8x8_dw8", ...})
"""
from __future__ import annotations
import os
import json

from generator import Config, neighbours, enumerate_configs


def _heuristic(results: list[dict], budget: int, tried: set[str]) -> list[Config]:
    """LLM-free fallback: untried neighbours of the current best by throughput."""
    if not results:
        return [Config(2, 2)]
    best = max(results, key=lambda r: r.get("throughput_mac_per_cyc", 0))
    out = []
    for nb in neighbours(Config(best["array_m"], best["array_n"])):
        if nb.pe_count <= budget and nb.key() not in tried:
            out.append(nb)
    return out


def propose_next(results: list[dict], budget: int, tried: set[str],
                 k: int = 2) -> list[Config]:
    """
    Return up to k candidate configs for the next measurement.
    Tries the LLM; on any problem falls back to the heuristic (never raises).
    """
    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        return _heuristic(results, budget, tried)[:k]
    try:
        import anthropic
    except ImportError:
        return _heuristic(results, budget, tried)[:k]

    valid = [c.key() for c in enumerate_configs(budget)]
    prompt = (
        "You are helping to find the optimal size of a systolic INT8 GEMM array.\n"
        f"Budget: {budget} PEs (number of PEs = ARRAY_M*ARRAY_N).\n"
        f"Valid configs: {valid}\n"
        f"Already measured (throughput_mac_per_cyc is the objective to maximize):\n"
        f"{json.dumps(results, ensure_ascii=False)}\n"
        f"Already tried: {sorted(tried)}\n"
        f"Propose up to {k} UNTRIED configs worth measuring next "
        "to reach the throughput maximum faster. Reply STRICTLY with a JSON array of strings "
        'like ["8x8_dw8", "4x8_dw8"], with no explanation.'
    )
    try:
        client = anthropic.Anthropic(api_key=api_key)
        msg = client.messages.create(
            model="claude-sonnet-5",
            max_tokens=200,
            messages=[{"role": "user", "content": prompt}],
        )
        text = msg.content[0].text.strip()
        keys = json.loads(text)
        out = []
        for key in keys:
            # format "MxN_dwD"
            dims, dw = key.split("_dw")
            m, n = dims.split("x")
            cfg = Config(int(m), int(n), int(dw))
            if cfg.pe_count <= budget and cfg.key() not in tried:
                out.append(cfg)
        return out[:k] or _heuristic(results, budget, tried)[:k]
    except Exception:
        return _heuristic(results, budget, tried)[:k]


if __name__ == "__main__":
    demo = [
        {"cfg": "2x2_dw8", "array_m": 2, "array_n": 2, "throughput_mac_per_cyc": 25.6},
        {"cfg": "4x4_dw8", "array_m": 4, "array_n": 4, "throughput_mac_per_cyc": 73.1},
    ]
    nxt = propose_next(demo, budget=64, tried={"2x2_dw8", "4x4_dw8"})
    print("proposed:", [c.key() for c in nxt])
