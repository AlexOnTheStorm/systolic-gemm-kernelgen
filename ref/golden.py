"""
Golden reference для систолического массива: INT8 matmul с INT32-накоплением.
Чистый Python (список списков) — без numpy-зависимости, как в py_env/ex4,
чтобы reference был читаемым и переносимым. Та же семантика, что у RTL:
знаковые INT8 входы, знаковый INT32 аккумулятор.

Используется и в cocotb-TB (tb/test_systolic.py), и в gen-петле (gen/evaluate.py).
"""
from __future__ import annotations
import random


def matmul_ref(A: list[list[int]], B: list[list[int]]) -> list[list[int]]:
    """C[M×N] = A[M×K] · B[K×N], целочисленно (INT8·INT8 -> INT32-суммы)."""
    M, K, N = len(A), len(A[0]), len(B[0])
    C = [[0] * N for _ in range(M)]
    for i in range(M):
        for j in range(N):
            acc = 0
            for k in range(K):
                acc += A[i][k] * B[k][j]      # знаковое MAC, как в pe.sv
            C[i][j] = acc
    return C


def rand_int8_matrix(rows: int, cols: int, rng: random.Random) -> list[list[int]]:
    """Случайная матрица со знаковыми INT8-элементами [-128, 127]."""
    return [[rng.randint(-128, 127) for _ in range(cols)] for _ in range(rows)]


def acc_fits_int32(M: int, N: int, K: int) -> bool:
    """
    Проверка, что INT32-аккумулятор не переполнится в худшем случае.
    Максимум по модулю: K * 128 * 128 = K * 16384. Для INT32 (±2^31)
    безопасно при K < ~131072 — с огромным запасом для наших тайлов.
    """
    worst = K * 128 * 128
    return worst < (1 << 31)
