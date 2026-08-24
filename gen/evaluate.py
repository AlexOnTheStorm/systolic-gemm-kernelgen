"""
evaluate.py — прогнать ОДИН конфиг массива через реальную симуляцию и снять метрики.

Это «evaluate performance in simulation» из петли: для конфига (ARRAY_M×ARRAY_N)
пересобираем Verilator с -GARRAY_M/-GARRAY_N и гоняем tb/test_eval.py, который
меряет латентность устаканивания и проверяет корректность против golden.

Требует активного fpga-venv (cocotb-config/verilator на PATH). search.py вызывает
это в цикле. Пересборка на конфиг — секунды; для DSE в десятки точек приемлемо.
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
    latency: int          # такты устаканивания ОДНОГО тайла (детерминированы)
    raw: str = ""         # хвост лога при ошибке


def run_sim(cfg: Config, k: int, timeout: int = 240) -> EvalResult:
    """Собрать конфиг в Verilator и измерить латентность/корректность тайла."""
    env = os.environ.copy()
    env.update({
        "ARRAY_M": str(cfg.array_m),
        "ARRAY_N": str(cfg.array_n),
        "DATA_WIDTH": str(cfg.data_width),
        "ACC_WIDTH": str(cfg.acc_width),
        "EVAL_K": str(k),
    })
    # -G параметры идут в EXTRA_ARGS (ДОБАВляются к verilator), а не в
    # COMPILE_ARGS — иначе затрём обязательные флаги cocotb (--prefix/-o/--vpi).
    # --assert включаем; --trace НЕ включаем (быстрее пересборка в DSE).
    gargs = (f"-GARRAY_M={cfg.array_m} -GARRAY_N={cfg.array_n} "
             f"-GDATA_WIDTH={cfg.data_width} -GACC_WIDTH={cfg.acc_width} --assert")

    # чистая пересборка под новые параметры
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
    # быстрый ручной прогон одного конфига
    r = run_sim(Config(array_m=4, array_n=4), k=8)
    print(f"cfg={r.cfg.key()} k={r.k} ok={r.ok} latency={r.latency} такт(ов)")
