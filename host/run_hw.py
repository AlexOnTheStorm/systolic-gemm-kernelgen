"""
run_hw.py — XRT host: run gemm_kernel on F2/Alveo and compare with golden (P4).

Flow (pyxrt):
  device → load_xclbin → kernel → allocate BOs (A,B,C in global memory) →
  write A,B → sync TO_DEVICE → run(a,b,c,K).wait() → sync FROM_DEVICE →
  read C → compare with ref/golden.matmul_ref.

⚠️ Runs in the cloud on an F2 instance (needs pyxrt + XRT + the xclbin from build_hw.sh).
It does not run on a laptop (no XRT) — this is the final on-silicon measurement.

Usage:
  python3 run_hw.py results/hw/gemm_kernel.hw.xclbin --M 8 --N 8 --K 8
"""
from __future__ import annotations
import os
import sys
import argparse
import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "ref"))
from golden import matmul_ref  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("xclbin")
    ap.add_argument("--M", type=int, default=8)
    ap.add_argument("--N", type=int, default=8)
    ap.add_argument("--K", type=int, default=8)
    ap.add_argument("--device", type=int, default=0)
    args = ap.parse_args()

    import pyxrt  # imported here so the file parses without XRT

    # --- device + xclbin ---
    dev = pyxrt.device(args.device)
    uuid = dev.load_xclbin(pyxrt.xclbin(args.xclbin))
    krnl = pyxrt.kernel(dev, uuid, "gemm_kernel")

    # --- data (INT8), C is INT32 ---
    # Memory layout = as in rtl/gemm_kernel.sv: one 32-bit word PER ELEMENT
    # (INT8 sign-extended to INT32). Dense INT8 packing is an optimization.
    rng = np.random.default_rng(0xBEEF)
    A = rng.integers(-128, 128, size=(args.M, args.K), dtype=np.int8)
    B = rng.integers(-128, 128, size=(args.K, args.N), dtype=np.int8)
    a_bytes = A.astype(np.int32).tobytes()   # 4 bytes/element
    b_bytes = B.astype(np.int32).tobytes()
    c_nbytes = args.M * args.N * 4  # INT32

    # --- global-memory buffers (group_id in kernel argument order) ---
    bo_a = pyxrt.bo(dev, len(a_bytes), pyxrt.bo.normal, krnl.group_id(0))
    bo_b = pyxrt.bo(dev, len(b_bytes), pyxrt.bo.normal, krnl.group_id(1))
    bo_c = pyxrt.bo(dev, c_nbytes,      pyxrt.bo.normal, krnl.group_id(2))

    bo_a.write(a_bytes, 0)
    bo_b.write(b_bytes, 0)
    bo_a.sync(pyxrt.xclBOSyncDirection.XCL_BO_SYNC_BO_TO_DEVICE)
    bo_b.sync(pyxrt.xclBOSyncDirection.XCL_BO_SYNC_BO_TO_DEVICE)

    # --- launch: arguments (a_addr, b_addr, c_addr, K) as in the kernel register map ---
    run = krnl(bo_a, bo_b, bo_c, args.K)
    run.wait()

    # --- fetch C and compare with golden ---
    bo_c.sync(pyxrt.xclBOSyncDirection.XCL_BO_SYNC_BO_FROM_DEVICE)
    c_host = np.frombuffer(bo_c.read(c_nbytes, 0), dtype=np.int32).reshape(args.M, args.N)

    exp = np.array(matmul_ref(A.tolist(), B.tolist()), dtype=np.int64)
    if np.array_equal(c_host.astype(np.int64), exp):
        print(f"PASS — hardware GEMM {args.M}x{args.N}x{args.K} matches golden")
    else:
        diff = np.abs(c_host.astype(np.int64) - exp)
        print(f"FAIL — max|diff|={diff.max()} (open the ILA: trigger on ap_start/handshake)")
        sys.exit(1)


if __name__ == "__main__":
    main()
