"""
Golden reference for the systolic array: INT8 matmul with INT32 accumulation.
Pure Python (lists of lists), no numpy dependency, so the reference stays readable
and portable. Same semantics as the RTL: signed INT8 inputs, signed INT32 accumulator.

Used both by the cocotb TB (tb/test_systolic.py) and by the generator loop (gen/evaluate.py).
"""
from __future__ import annotations
import random


def matmul_ref(A: list[list[int]], B: list[list[int]]) -> list[list[int]]:
    """C[M×N] = A[M×K] · B[K×N], integer (INT8·INT8 -> INT32 sums)."""
    M, K, N = len(A), len(A[0]), len(B[0])
    C = [[0] * N for _ in range(M)]
    for i in range(M):
        for j in range(N):
            acc = 0
            for k in range(K):
                acc += A[i][k] * B[k][j]      # signed MAC, as in pe.sv
            C[i][j] = acc
    return C


def rand_int8_matrix(rows: int, cols: int, rng: random.Random) -> list[list[int]]:
    """Random matrix with signed INT8 elements [-128, 127]."""
    return [[rng.randint(-128, 127) for _ in range(cols)] for _ in range(rows)]


def acc_fits_int32(M: int, N: int, K: int) -> bool:
    """
    Check that the INT32 accumulator cannot overflow in the worst case.
    Max magnitude: K * 128 * 128 = K * 16384. For INT32 (±2^31) this is
    safe for K < ~131072, a huge margin for our tiles.
    """
    worst = K * 128 * 128
    return worst < (1 << 31)
