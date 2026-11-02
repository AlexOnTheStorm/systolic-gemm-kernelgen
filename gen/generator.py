"""
generator.py — workload-aware generator of systolic array configurations.

Given: a GEMM (M, N, K) + a resource budget (max number of PEs ~ number of DSPs).
Produces: CANDIDATE array configs (ARRAY_M × ARRAY_N) + a tiling schedule.

The output is real RTL parameters, which gen/evaluate.py builds in Verilator
and measures.

Tiling model: an ARRAY_M×ARRAY_N array computes ONE output tile per pass
(K is the streaming axis). A full GEMM is a grid of tiles:
    tiles = ceil(M/ARRAY_M) * ceil(N/ARRAY_N),  each streaming K.
Tiles run sequentially on one array (conservative; overlapping fill/drain of
adjacent tiles is a possible optimization, see search.py).
"""
from __future__ import annotations
from dataclasses import dataclass
from math import ceil


@dataclass(frozen=True)
class Config:
    """One point of the design space = array size and bit widths."""
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
    """How many output tiles are needed to cover C[M×N] with array cfg."""
    return ceil(M / cfg.array_m) * ceil(N / cfg.array_n)


def enumerate_configs(max_pe: int,
                      dims: tuple[int, ...] = (2, 4, 8, 16, 32),
                      data_width: int = 8) -> list[Config]:
    """
    All square and rectangular arrays from `dims` whose number of PEs
    (= number of multipliers) fits the `max_pe` budget.
    """
    out = []
    for m in dims:
        for n in dims:
            cfg = Config(array_m=m, array_n=n, data_width=data_width)
            if cfg.pe_count <= max_pe:
                out.append(cfg)
    return out


def neighbours(cfg: Config, dims: tuple[int, ...] = (2, 4, 8, 16, 32)) -> list[Config]:
    """Neighbours on the `dims` grid (one step up/down on each axis), for hill-climb."""
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
