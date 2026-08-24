"""
run_hw.py — XRT-хост: запустить gemm_kernel на F1/Alveo и сверить с golden (P4).

Поток (pyxrt):
  device → load_xclbin → kernel → выделить BO (A,B,C в global memory) →
  записать A,B → sync TO_DEVICE → run(a,b,c,K).wait() → sync FROM_DEVICE →
  прочитать C → сверить с ref/golden.matmul_ref.

⚠️ Запускается в облаке на F1-инстансе (нужны pyxrt + XRT + xclbin из build_hw.sh).
На маке не идёт (нет XRT) — это финальный «замер на кремнии».

Использование:
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

    import pyxrt  # импорт тут, чтобы файл парсился и без XRT

    # --- устройство + xclbin ---
    dev = pyxrt.device(args.device)
    uuid = dev.load_xclbin(pyxrt.xclbin(args.xclbin))
    krnl = pyxrt.kernel(dev, uuid, "gemm_kernel")

    # --- данные (INT8), C — INT32 ---
    rng = np.random.default_rng(0xBEEF)
    A = rng.integers(-128, 128, size=(args.M, args.K), dtype=np.int8)
    B = rng.integers(-128, 128, size=(args.K, args.N), dtype=np.int8)
    a_bytes = A.tobytes()
    b_bytes = B.tobytes()
    c_nbytes = args.M * args.N * 4  # INT32

    # --- буферы в глобальной памяти (group_id по порядку аргументов kernel) ---
    bo_a = pyxrt.bo(dev, len(a_bytes), pyxrt.bo.normal, krnl.group_id(0))
    bo_b = pyxrt.bo(dev, len(b_bytes), pyxrt.bo.normal, krnl.group_id(1))
    bo_c = pyxrt.bo(dev, c_nbytes,      pyxrt.bo.normal, krnl.group_id(2))

    bo_a.write(a_bytes, 0)
    bo_b.write(b_bytes, 0)
    bo_a.sync(pyxrt.xclBOSyncDirection.XCL_BO_SYNC_BO_TO_DEVICE)
    bo_b.sync(pyxrt.xclBOSyncDirection.XCL_BO_SYNC_BO_TO_DEVICE)

    # --- запуск: аргументы (a_addr, b_addr, c_addr, K) как в реестре kernel'а ---
    run = krnl(bo_a, bo_b, bo_c, args.K)
    run.wait()

    # --- забрать C и сверить с golden ---
    bo_c.sync(pyxrt.xclBOSyncDirection.XCL_BO_SYNC_BO_FROM_DEVICE)
    c_host = np.frombuffer(bo_c.read(c_nbytes, 0), dtype=np.int32).reshape(args.M, args.N)

    exp = np.array(matmul_ref(A.tolist(), B.tolist()), dtype=np.int64)
    if np.array_equal(c_host.astype(np.int64), exp):
        print(f"PASS — hardware GEMM {args.M}x{args.N}x{args.K} совпал с golden")
    else:
        diff = np.abs(c_host.astype(np.int64) - exp)
        print(f"FAIL — max|diff|={diff.max()} (открой ILA: триггер на ap_start/handshake)")
        sys.exit(1)


if __name__ == "__main__":
    main()
