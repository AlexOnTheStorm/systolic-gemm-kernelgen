"""
cocotb self-checking TB for systolic_array (output-stationary, INT8·INT8->INT32).

Idiom: cocotb + Verilator, driver/scoreboard, coverage bins, final asserts.
Here we check the NUMERIC result of a whole matmul against the golden model
(ref/golden.py), not a streaming protocol.

The key mechanism is the systolic feed SKEW (see systolic_array.sv):
  on cycle t row i gets A[i][t-i], column j gets B[t-j][j]
  (zeros outside the window). After the drain every acc(i,j) = C[i][j].

The array parameters default to the RTL defaults (ARRAY_M=ARRAY_N=4). The Makefile
can override them via -G and the environment; v1 keeps 4×4.
"""
import os
import sys
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly

# pull in the golden model from the sibling ref/ directory
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "ref"))
from golden import matmul_ref, rand_int8_matrix, acc_fits_int32  # noqa: E402

# --- array geometry (must match the RTL parameters) ---
M = int(os.environ.get("ARRAY_M", 4))
N = int(os.environ.get("ARRAY_N", 4))
DW = int(os.environ.get("DATA_WIDTH", 8))
ACC = int(os.environ.get("ACC_WIDTH", 32))


def to_signed(val: int, bits: int) -> int:
    """Two's complement -> signed int."""
    return val - (1 << bits) if (val & (1 << (bits - 1))) else val


def pack_edge(vals: list[int]) -> int:
    """List of signed values -> flat bus (DW bits per element)."""
    word = 0
    mask = (1 << DW) - 1
    for idx, v in enumerate(vals):
        word |= (v & mask) << (idx * DW)
    return word


async def reset_dut(dut):
    dut.clear.value = 0
    dut.en.value = 0
    dut.a_in_flat.value = 0
    dut.b_in_flat.value = 0
    dut.rst_n.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst_n.value = 1


async def run_matmul(dut, A: list[list[int]], B: list[list[int]]) -> list[list[int]]:
    """
    Run one matmul A[M×K]·B[K×N] through the array with the systolic skew.
    Returns the read-back acc(i,j) as a list of lists (signed ints).
    """
    K = len(A[0])

    # start a new matmul: 1 cycle of clear (zero acc), inputs = 0
    await RisingEdge(dut.clk)
    dut.clear.value = 1
    dut.en.value = 0
    dut.a_in_flat.value = 0
    dut.b_in_flat.value = 0
    await RisingEdge(dut.clk)
    dut.clear.value = 0
    dut.en.value = 1

    # skewed feed + drain with zeros (en stays 1; zero products are harmless).
    # the +6 margin covers the wavefront AND the MAC pipeline latency in the PE (+2 cycles,
    # see pe.sv): the last product must reach acc while en=1.
    total = K + M + N + 6
    for t in range(total):
        a_edge = [A[i][t - i] if 0 <= (t - i) < K else 0 for i in range(M)]
        b_edge = [B[t - j][j] if 0 <= (t - j) < K else 0 for j in range(N)]
        dut.a_in_flat.value = pack_edge(a_edge)
        dut.b_in_flat.value = pack_edge(b_edge)
        await RisingEdge(dut.clk)

    # a few more cycles to flush the last MAC through the pipeline, inputs 0
    dut.a_in_flat.value = 0
    dut.b_in_flat.value = 0
    for _ in range(4):
        await RisingEdge(dut.clk)
    await ReadOnly()

    raw = int(dut.c_out_flat.value)
    C = [[0] * N for _ in range(M)]
    field_mask = (1 << ACC) - 1
    for i in range(M):
        for j in range(N):
            field = (raw >> ((i * N + j) * ACC)) & field_mask
            C[i][j] = to_signed(field, ACC)
    return C


@cocotb.test()
async def test_systolic_matmul(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset_dut(dut)
    rng = random.Random(0xC0FFEE)

    stats = {"checks": 0, "errors": 0}
    cov = {
        "k_small": 0,          # K <= M
        "k_large": 0,          # K >  M
        "result_positive": 0,  # at least one C[i][j] > 0
        "result_negative": 0,  # at least one C[i][j] < 0
        "result_zero_cell": 0, # at least one C[i][j] == 0
        "extreme_operand": 0,  # ±128/127 seen in the inputs
        "all_zero_matmul": 0,  # all-zero matrices (corner case)
    }

    # scenario set: several K + one all-zero + one extreme
    scenarios = []
    for K in (1, 3, 4, 6, 8):
        scenarios.append((rand_int8_matrix(M, K, rng), rand_int8_matrix(K, N, rng)))
    # all-zero matmul
    scenarios.append(([[0] * 4 for _ in range(M)], [[0] * N for _ in range(4)]))
    # extreme operands
    scenarios.append(([[127 if k % 2 else -128 for k in range(5)] for _ in range(M)],
                      [[-128 if j % 2 else 127 for j in range(N)] for _ in range(5)]))

    for A, B in scenarios:
        K = len(A[0])
        assert acc_fits_int32(M, N, K), "K too large for the INT32 accumulator"

        got = await run_matmul(dut, A, B)
        exp = matmul_ref(A, B)

        stats["checks"] += 1
        if got != exp:
            stats["errors"] += 1
            dut._log.error(f"MISMATCH K={K}\n got={got}\n exp={exp}")
        else:
            dut._log.info(f"ok  K={K}  C[0][0]={exp[0][0]}")

        # --- coverage ---
        cov["k_small"] += int(K <= M)
        cov["k_large"] += int(K > M)
        flat = [x for row in exp for x in row]
        cov["result_positive"] += int(any(x > 0 for x in flat))
        cov["result_negative"] += int(any(x < 0 for x in flat))
        cov["result_zero_cell"] += int(any(x == 0 for x in flat))
        cov["extreme_operand"] += int(any(v in (-128, 127) for r in A for v in r) or
                                      any(v in (-128, 127) for r in B for v in r))
        cov["all_zero_matmul"] += int(all(x == 0 for x in flat))

    # --- coverage report ---
    total = len(cov)
    hit = sum(1 for v in cov.values() if v > 0)
    dut._log.info(f"COVERAGE {hit}/{total} bins = {100 * hit // total}%")
    for name, v in cov.items():
        mark = "ok " if v > 0 else "HOLE"
        dut._log.info(f"  [{mark}] {name:18s} = {v}")

    assert stats["errors"] == 0, f"{stats['errors']} mismatch(es) of {stats['checks']}"
    holes = [n for n, v in cov.items() if v == 0]
    assert not holes, f"coverage holes: {holes}"
    dut._log.info(f"PASS — {stats['checks']} matmuls verified vs golden")
