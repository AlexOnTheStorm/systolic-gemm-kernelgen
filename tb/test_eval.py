"""
test_eval — измерительный cocotb-тест для gen-петли (P2).

Отличие от test_systolic.py: один тайл заданного размера, где мы
(1) проверяем корректность против golden и (2) ИЗМЕРЯЕМ в симуляции латентность
устаканивания массива (такты от снятия clear до момента, когда все acc == C).
Это подтверждает ДЕТЕРМИНИРОВАННУЮ латентность — метрику, которую использует
gen/search.py.

Идиома как в ex7: раздельные driver (пишет в ReadWrite-фазе) и monitor
(сэмплирует в ReadOnly-фазе) — иначе cocotb ругается «write during ReadOnly».

Геометрия и K берутся из окружения (evaluate.py их выставляет и одновременно
даёт -GARRAY_M/-GARRAY_N в Verilator). Печатает строку:
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
    """Пишет систолический skew каждый такт (в ReadWrite-фазе после фронта)."""
    for c in range(total):
        a_edge = [A[i][c - i] if 0 <= (c - i) < K else 0 for i in range(M)]
        b_edge = [B[c - j][j] if 0 <= (c - j) < K else 0 for j in range(N)]
        dut.a_in_flat.value = pack_edge(a_edge)
        dut.b_in_flat.value = pack_edge(b_edge)
        await RisingEdge(dut.clk)
    dut.a_in_flat.value = 0
    dut.b_in_flat.value = 0


async def monitor(dut, exp, state):
    """Сэмплирует acc в ReadOnly-фазе; ловит латентность устаканивания."""
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

    # clear 1 такт → старт нового matmul
    await RisingEdge(dut.clk)
    dut.clear.value = 1
    await RisingEdge(dut.clk)
    dut.clear.value = 0
    dut.en.value = 1

    state = {"latency": None, "last": None}
    cocotb.start_soon(monitor(dut, exp, state))
    await driver(dut, A, B, total=K + M + N + 6)
    for _ in range(3):                      # дренаж
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
