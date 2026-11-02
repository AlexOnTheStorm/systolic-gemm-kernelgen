"""
test_kernel — simulation verification of the FULL gemm_kernel (AXI-Lite + AXI-master DMA).

A memory model (AXI slave) answers the kernel's master requests: reads of A/B and writes of C.
The AXI-Lite driver writes the arguments (addresses, K), pulses ap_start, waits for ap_done,
then reads C from the memory model and compares it with the golden model. This is
"hw_emu on a laptop": it catches datapath bugs BEFORE an expensive F2 run
("shift bugs left", see docs/flow_walkthrough).

Memory layout = as in rtl/gemm_kernel.sv: one 32-bit word per element.
"""
import os
import sys
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "ref"))
from golden import matmul_ref, rand_int8_matrix  # noqa: E402

M = int(os.environ.get("ARRAY_M", 4))
N = int(os.environ.get("ARRAY_N", 4))
ACC = int(os.environ.get("ACC_WIDTH", 32))
K = int(os.environ.get("KERNEL_K", 4))

A_ADDR, B_ADDR, C_ADDR = 0x1000, 0x2000, 0x3000
MASK32 = (1 << 32) - 1


def to_signed(v, bits):
    return v - (1 << bits) if (v & (1 << (bits - 1))) else v


async def axi_mem_slave(dut, mem: dict):
    """AXI slave model of global memory: single-beat read/write."""
    dut.m_axi_arready.value = 1
    dut.m_axi_awready.value = 1
    dut.m_axi_wready.value = 1
    dut.m_axi_rvalid.value = 0
    dut.m_axi_rlast.value = 0
    dut.m_axi_bvalid.value = 0
    r_busy = False
    b_busy = False
    aw_addr = 0
    while True:
        await RisingEdge(dut.ap_clk)
        # --- read data handshake done? ---
        if r_busy and int(dut.m_axi_rvalid.value) and int(dut.m_axi_rready.value):
            dut.m_axi_rvalid.value = 0
            dut.m_axi_rlast.value = 0
            r_busy = False
        # --- accept AR, return R (arready is always 1) ---
        if not r_busy and int(dut.m_axi_arvalid.value):
            addr = int(dut.m_axi_araddr.value) & ~0x3
            dut.m_axi_rdata.value = mem.get(addr, 0) & MASK32
            dut.m_axi_rvalid.value = 1
            dut.m_axi_rlast.value = 1
            r_busy = True
        # --- write: latch the AW address ---
        if int(dut.m_axi_awvalid.value):
            aw_addr = int(dut.m_axi_awaddr.value) & ~0x3
        # --- accept W, store it, raise B ---
        if int(dut.m_axi_wvalid.value) and int(dut.m_axi_wready.value):
            mem[aw_addr] = int(dut.m_axi_wdata.value) & MASK32
            dut.m_axi_bvalid.value = 1
            b_busy = True
        # --- B handshake done? ---
        if b_busy and int(dut.m_axi_bvalid.value) and int(dut.m_axi_bready.value):
            dut.m_axi_bvalid.value = 0
            b_busy = False


async def axil_write(dut, addr, data):
    """One AXI-Lite write (awready/wready are always 1)."""
    await RisingEdge(dut.ap_clk)
    dut.s_axil_awaddr.value = addr
    dut.s_axil_awvalid.value = 1
    dut.s_axil_wdata.value = data & MASK32
    dut.s_axil_wvalid.value = 1
    dut.s_axil_bready.value = 1
    await RisingEdge(dut.ap_clk)
    dut.s_axil_awvalid.value = 0
    dut.s_axil_wvalid.value = 0


async def axil_read(dut, addr) -> int:
    await RisingEdge(dut.ap_clk)
    dut.s_axil_araddr.value = addr
    dut.s_axil_arvalid.value = 1
    dut.s_axil_rready.value = 1
    await RisingEdge(dut.ap_clk)
    dut.s_axil_arvalid.value = 0
    await RisingEdge(dut.ap_clk)
    return int(dut.s_axil_rdata.value)


@cocotb.test()
async def test_kernel_gemm(dut):
    cocotb.start_soon(Clock(dut.ap_clk, 10, unit="ns").start())
    rng = random.Random(0xA11CE)
    A = rand_int8_matrix(M, K, rng)
    B = rand_int8_matrix(K, N, rng)
    exp = matmul_ref(A, B)

    # --- memory model: load A, B (one 32-bit word per element) ---
    mem = {}
    for m in range(M):
        for k in range(K):
            mem[A_ADDR + (m * K + k) * 4] = A[m][k] & MASK32
    for k in range(K):
        for n in range(N):
            mem[B_ADDR + (k * N + n) * 4] = B[k][n] & MASK32

    # --- reset ---
    for sig in ["s_axil_awvalid", "s_axil_wvalid", "s_axil_arvalid",
                "s_axil_bready", "s_axil_rready"]:
        getattr(dut, sig).value = 0
    dut.ap_rst_n.value = 0
    cocotb.start_soon(axi_mem_slave(dut, mem))
    await RisingEdge(dut.ap_clk)
    await RisingEdge(dut.ap_clk)
    dut.ap_rst_n.value = 1

    # --- program the arguments ---
    await axil_write(dut, 0x10, A_ADDR)
    await axil_write(dut, 0x1C, B_ADDR)
    await axil_write(dut, 0x28, C_ADDR)
    await axil_write(dut, 0x34, K)
    # --- start ---
    await axil_write(dut, 0x00, 1)

    # --- wait for ap_done (poll 0x00 bit1) ---
    for _ in range(2000):
        status = await axil_read(dut, 0x00)
        if status & 0x2:
            break
    else:
        assert False, "timeout: ap_done never rose (check the FSM/AXI handshake)"

    # --- read C from memory and compare ---
    got = [[to_signed(mem.get(C_ADDR + (m * N + n) * 4, 0), 32) for n in range(N)]
           for m in range(M)]
    if got != exp:
        dut._log.error(f"MISMATCH\n got={got}\n exp={exp}")
    assert got == exp, "kernel hardware path does not match golden"
    dut._log.info(f"PASS — kernel GEMM {M}x{N}x{K} via AXI DMA == golden")
