"""
generator.py — workload-aware генератор конфигураций систолического массива.

Дано: GEMM (M, N, K) + бюджет ресурсов (макс. число PE ~ число DSP).
Порождает: КАНДИДАТ-конфиги массива (ARRAY_M × ARRAY_N) + расписание тайлинга.

Это «ex6, повзрослевший»: раньше генерили текст спеки, теперь порождаем
реальные RTL-параметры, которые gen/evaluate.py собирает в Verilator и мерит.

Модель тайлинга: массив ARRAY_M×ARRAY_N считает ОДИН выходной тайл за проход
(K — потоковая ось). Полный GEMM = сетка тайлов:
    tiles = ceil(M/ARRAY_M) * ceil(N/ARRAY_N),  каждый стримит K.
Тайлы идут последовательно на одном массиве (консервативно; перекрытие
fill/drain соседних тайлов — возможная оптимизация, см. search.py).
"""
from __future__ import annotations
from dataclasses import dataclass
from math import ceil


@dataclass(frozen=True)
class Config:
    """Одна точка пространства дизайна = размер массива и разрядности."""
    array_m: int
    array_n: int
    data_width: int = 8
    acc_width: int = 32

    @property
    def pe_count(self) -> int:
        return self.array_m * self.array_n

    def key(self) -> str:
        return f"{self.array_m}x{self.array_n}_dw{self.data_width}"


def n_tiles(M: int, N: int, cfg: Config) -> int:
    """Сколько выходных тайлов нужно, чтобы покрыть C[M×N] массивом cfg."""
    return ceil(M / cfg.array_m) * ceil(N / cfg.array_n)


def enumerate_configs(max_pe: int,
                      dims: tuple[int, ...] = (2, 4, 8, 16, 32),
                      data_width: int = 8) -> list[Config]:
    """
    Все квадратные и прямоугольные массивы из `dims`, у которых
    число PE (= число умножителей) влезает в бюджет `max_pe`.
    """
    out = []
    for m in dims:
        for n in dims:
            cfg = Config(array_m=m, array_n=n, data_width=data_width)
            if cfg.pe_count <= max_pe:
                out.append(cfg)
    return out


def neighbours(cfg: Config, dims: tuple[int, ...] = (2, 4, 8, 16, 32)) -> list[Config]:
    """Соседи по сетке `dims` (шаг вверх/вниз по каждой оси) — для hill-climb."""
    idx_m = dims.index(cfg.array_m) if cfg.array_m in dims else None
    idx_n = dims.index(cfg.array_n) if cfg.array_n in dims else None
    res = []
    if idx_m is not None:
        for di in (-1, +1):
            k = idx_m + di
            if 0 <= k < len(dims):
                res.append(Config(dims[k], cfg.array_n, cfg.data_width, cfg.acc_width))
    if idx_n is not None:
        for dj in (-1, +1):
            k = idx_n + dj
            if 0 <= k < len(dims):
                res.append(Config(cfg.array_m, dims[k], cfg.data_width, cfg.acc_width))
    return res
