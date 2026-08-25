"""
cocotb self-checking TB для systolic_array (output-stationary, INT8·INT8->INT32).

Идиома — как в practice/ex7_fifo_cocotb: cocotb + Verilator, driver/scoreboard,
coverage-bins, финальные assert'ы. Отличие: тут проверяем ЧИСЛЕННЫЙ результат
целого matmul против golden (ref/golden.py), а не потоковый протокол.

Ключевая механика — систолический SKEW подачи (см. systolic_array.sv):
  на такте t в строку i подаём A[i][t-i], в столбец j подаём B[t-j][j]
  (нули вне окна). После дренажа все acc(i,j) = C[i][j].

Параметры массива фиксированы под дефолты RTL (ARRAY_M=ARRAY_N=4). Makefile
может переопределить их через -G и здесь; для v1 держим 4×4.
"""
import os
import sys
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly

# подключаем golden из соседней папки ref/
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "ref"))
from golden import matmul_ref, rand_int8_matrix, acc_fits_int32  # noqa: E402

# --- геометрия массива (должна совпадать с параметрами RTL) ---
M = int(os.environ.get("ARRAY_M", 4))
N = int(os.environ.get("ARRAY_N", 4))
DW = int(os.environ.get("DATA_WIDTH", 8))
ACC = int(os.environ.get("ACC_WIDTH", 32))


def to_signed(val: int, bits: int) -> int:
    """Двоичное дополнение -> знаковое int."""
    return val - (1 << bits) if (val & (1 << (bits - 1))) else val


def pack_edge(vals: list[int]) -> int:
    """Список знаковых значений -> плоская шина (по DW бит на элемент)."""
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
    Прогнать один matmul A[M×K]·B[K×N] через массив с систолическим skew.
    Возвращает считанные acc(i,j) как список списков (знаковые int).
    """
    K = len(A[0])

    # старт нового matmul: 1 такт clear (обнулить acc), входы = 0
    await RisingEdge(dut.clk)
    dut.clear.value = 1
    dut.en.value = 0
    dut.a_in_flat.value = 0
    dut.b_in_flat.value = 0
    await RisingEdge(dut.clk)
    dut.clear.value = 0
    dut.en.value = 1

    # подача со skew + дренаж нулями (en держим 1; нулевые произведения безвредны).
    # запас +6 покрывает волновой фронт И латентность конвейера MAC в PE (+2 такта,
    # см. pe.sv): последнее произведение должно дойти до acc, пока en=1.
    total = K + M + N + 6
    for t in range(total):
        a_edge = [A[i][t - i] if 0 <= (t - i) < K else 0 for i in range(M)]
        b_edge = [B[t - j][j] if 0 <= (t - j) < K else 0 for j in range(N)]
        dut.a_in_flat.value = pack_edge(a_edge)
        dut.b_in_flat.value = pack_edge(b_edge)
        await RisingEdge(dut.clk)

    # ещё несколько тактов на прокачку конвейера последнего MAC, входы 0
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
        "result_positive": 0,  # хоть один C[i][j] > 0
        "result_negative": 0,  # хоть один C[i][j] < 0
        "result_zero_cell": 0, # хоть один C[i][j] == 0
        "extreme_operand": 0,  # встречался ±128/127 во входах
        "all_zero_matmul": 0,  # нулевые матрицы (граничный)
    }

    # набор сценариев: разные K + один нулевой + один экстремальный
    scenarios = []
    for K in (1, 3, 4, 6, 8):
        scenarios.append((rand_int8_matrix(M, K, rng), rand_int8_matrix(K, N, rng)))
    # нулевой matmul
    scenarios.append(([[0] * 4 for _ in range(M)], [[0] * N for _ in range(4)]))
    # экстремальные операнды
    scenarios.append(([[127 if k % 2 else -128 for k in range(5)] for _ in range(M)],
                      [[-128 if j % 2 else 127 for j in range(N)] for _ in range(5)]))

    for A, B in scenarios:
        K = len(A[0])
        assert acc_fits_int32(M, N, K), "K слишком большой для INT32-аккумулятора"

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

    # --- отчёт по покрытию (формат как в ex7) ---
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
