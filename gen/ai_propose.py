"""
ai_propose.py — AI-assisted предложение следующих конфигов для DSE (P5).

Замыкает «AI-assisted generation loop» из JD: по УЖЕ измеренным результатам
LLM предлагает, какие конфиги пробовать дальше (вместо перебора всей сетки).

⚠️ ЧЕСТНО: это НАДСТРОЙКА, не ядро. Поиск (gen/search.py) работает и без LLM.
Здесь: если есть ANTHROPIC_API_KEY + пакет anthropic — спрашиваем модель;
иначе — эвристический fallback (сосед лучшего непройденный конфиг). Так петля
демонстрирует AI-in-the-loop, но не зависит от него.

Использование (в search.py или отдельно):
    from ai_propose import propose_next
    next_cfgs = propose_next(results, budget=64, tried={"8x8_dw8", ...})
"""
from __future__ import annotations
import os
import json

from generator import Config, neighbours, enumerate_configs


def _heuristic(results: list[dict], budget: int, tried: set[str]) -> list[Config]:
    """Fallback без LLM: непройденные соседи текущего лучшего по throughput."""
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
    Вернуть до k конфигов-кандидатов на следующий замер.
    Пытается LLM; при любой проблеме — эвристика (никогда не падает).
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
        "Ты помогаешь искать оптимальный размер систолического INT8 GEMM-массива.\n"
        f"Бюджет: {budget} PE (число PE = ARRAY_M*ARRAY_N).\n"
        f"Допустимые конфиги: {valid}\n"
        f"Уже измерено (throughput_mac_per_cyc — цель максимизировать):\n"
        f"{json.dumps(results, ensure_ascii=False)}\n"
        f"Уже пробовали: {sorted(tried)}\n"
        f"Предложи до {k} НЕ пробованных конфигов, которые стоит измерить следующими, "
        "чтобы быстрее найти максимум throughput. Ответь СТРОГО JSON-массивом строк "
        'вида ["8x8_dw8", "4x8_dw8"], без пояснений.'
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
            # формат "MxN_dwD"
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
    print("предложено:", [c.key() for c in nxt])
