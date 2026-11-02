"""
test_eval — measurement cocotb test for the generator loop (P2).

Unlike test_systolic.py, this runs one tile of a given size, where we
(1) check correctness against the golden model and (2) MEASURE in simulation the
array's settle latency (cycles from clear deassertion until every acc == C).
This confirms the DETERMINISTIC latency, the metric used by gen/search.py.

Separate driver (writes in the ReadWrite phase) and monitor (samples in the
ReadOnly phase) — otherwise cocotb complains "write during ReadOnly".

Geometry and K come from the environment (evaluate.py sets them and also passes
-GARRAY_M/-GARRAY_N to Verilator). Prints the line:
    EVAL_JSON {"ok": true, "latency": N, ...}
"""
import os
import sys
import json
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "ref"))
from golden import matmul_ref, rand_int8_matrix  # noqa: E402

M = int(os.environ.get("ARRAY_M", 4))
N = int(os.environ.get("ARRAY_N", 4))
DW = int(os.environ.get("DATA_WIDTH", 8))
ACC = int(os.environ.get("ACC_WIDTH", 32))
K = int(os.environ.get("EVAL_K", 8))


def to_signed(val, bits):
    return val - (1 << bits) if (val & (1 << (bits - 1))) else val


def pack_edge(vals):
    word, mask = 0, (1 << DW) - 1
    for idx, v in enumerate(vals):
        word |= (v & mask) << (idx * DW)
    return word


def read_acc(dut):
    raw = int(dut.c_out_flat.value)
    fmask = (1 << ACC) - 1
    return [[to_signed((raw >> ((i * N + j) * ACC)) & fmask, ACC)
             for j in range(N)] for i in range(M)]


async def driver(dut, A, B, total):
    """Drives the systolic skew every cycle (in the ReadWrite phase after the edge)."""
    for c in range(total):
        a_edge = [A[i][c - i] if 0 <= (c - i) < K else 0 for i in range(M)]
        b_edge = [B[c - j][j] if 0 <= (c - j) < K else 0 for j in range(N)]
        dut.a_in_flat.value = pack_edge(a_edge)
        dut.b_in_flat.value = pack_edge(b_edge)
        await RisingEdge(dut.clk)
    dut.a_in_flat.value = 0
    dut.b_in_flat.value = 0


async def monitor(dut, exp, state):
    """Samples acc in the ReadOnly phase; captures the settle latency."""
    c = 0
    while True:
        await RisingEdge(dut.clk)
        await ReadOnly()
        acc = read_acc(dut)
        state["last"] = acc
        if state["latency"] is None and acc == exp:
            state["latency"] = c + 1
        c += 1


@cocotb.test()
async def measure(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    rng = random.Random(0x1234 + M * 131 + N * 17 + K)
    A = rand_int8_matrix(M, K, rng)
    B = rand_int8_matrix(K, N, rng)
    exp = matmul_ref(A, B)

    # reset
    dut.clear.value = 0
    dut.en.value = 0
    dut.a_in_flat.value = 0
    dut.b_in_flat.value = 0
    dut.rst_n.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst_n.value = 1

    # 1 cycle of clear → start of a new matmul
    await RisingEdge(dut.clk)
    dut.clear.value = 1
    await RisingEdge(dut.clk)
    dut.clear.value = 0
    dut.en.value = 1

    state = {"latency": None, "last": None}
    cocotb.start_soon(monitor(dut, exp, state))
    await driver(dut, A, B, total=K + M + N + 6)
    for _ in range(3):                      # drain
        await RisingEdge(dut.clk)

    ok = (state["last"] == exp) and (state["latency"] is not None)
    result = {
        "ok": bool(ok),
        "latency": state["latency"] if state["latency"] is not None else -1,
        "array_m": M, "array_n": N, "k": K,
        "data_width": DW, "pe_count": M * N,
    }
    dut._log.info("EVAL_JSON " + json.dumps(result))
    assert ok, f"eval failed: settle={state['latency']} last==exp:{state['last'] == exp}"
