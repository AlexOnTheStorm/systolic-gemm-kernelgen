# Cloud runbook — точная последовательность команд (P3→P4), всё из терминала

Один линейный сценарий от пустого инстанса до ILA-захвата. GUI не нужен нигде.
Таргет — **AWS F2 (VU47P)** (AWS мигрировал с F1). ⚠️ имена платформ/AMI/AGFI
меняются — сверяй с `platforminfo -l`, awsdocs-fpga-f2 и aws-fpga (branch f2).

## 0. Инстанс + окружение (build-инстанс из FPGA Developer AMI, Vitis 2025.2)
```bash
source /home/ubuntu/src/aws-fpga/vitis_setup.sh   # XRT + F2-платформы + env
source /opt/xilinx/xrt/setup.sh                   # (если не подтянулось)
git clone https://github.com/AlexOnTheStorm/systolic-gemm-kernelgen.git
cd systolic-gemm-kernelgen
```

## 1. P3 — синтез-оценка (f_max, ресурсы) — регион не важен
```bash
vivado -mode batch -source flow/synth.tcl -tclargs xcvu47p-fsvh2892-3-e 3.0 8 8
# stdout сразу печатает WNS и f_max. Детально:
grep -A4 "Design Timing Summary" results/synth/timing_summary.rpt
grep -E "CLB LUTs|CLB Registers|DSPs|Block RAM Tile" results/synth/utilization.rpt
```
Цель: **WNS ≥ 0** и **DSP ≈ ARRAY_M·ARRAY_N** (валидирует P2-модель). VU47P = 9024
DSP, так что 8×8=64 — капля; можно синтезировать и 64×64.

## 2. P4 — собрать kernel и xclbin
```bash
vivado -mode batch -source flow/package_kernel.tcl          # → results/xo/gemm_kernel.xo
export PLATFORM=xilinx_aws-vu47p-f2_202420_2                # F2-платформа (verify: platforminfo -l)

./flow/build_hw.sh sw_emu    # (сек)  проверка host↔kernel логики
./flow/build_hw.sh hw_emu    # (мин)  RTL-точная эмуляция — ЛОВИТ 90% багов до битстрима
./flow/build_hw.sh hw        # (часы) реальный битстрим с ILA → results/hw/*.xclbin
```
Эмуляции (`sw_emu`/`hw_emu`) НЕ требуют f2 — гоняй на дешёвом build-инстансе.
`hw` — только когда эмуляция чистая (логика ядра уже sim-проверена `make kernel`).

## 3. Залить на F2 (только для реального железа, в F2-регионе: Frankfurt/London)
```bash
# из битстрима создать AFI (один раз), дождаться 'available':
aws ec2 create-fpga-image --input-storage-location Bucket=<s3>,Key=<dcp> ...
# на f2.6xlarge:
sudo fpga-load-local-image -S 0 -I <agfi-id>
```

## 4. Запуск + сверка с golden (на f2)
```bash
python3 host/run_hw.py results/hw/gemm_kernel.hw.xclbin --M 8 --N 8 --K 8
# PASS — hardware GEMM совпал с golden
```

## 5. ILA-отладка — headless, 3 терминала (см. flow/ila_debug.tcl)
```bash
# т.1 (f2): поднять виртуальный JTAG
sudo fpga-start-virtual-jtag -P 10201 -S 0

# т.2: вооружить ILA (ждёт триггер ap_start), захват в файл
XVC_URL=localhost:10201 vivado -mode batch -source flow/ila_debug.tcl

# т.3: дёрнуть kernel → сработает триггер
python3 host/run_hw.py results/hw/gemm_kernel.hw.xclbin --M 8 --N 8 --K 8
```
Волна → `results/ila/capture.vcd`. Смотреть:
```bash
surfer results/ila/capture.vcd        # headless-вьювер; или scp на мак
grep -c "" results/ila/capture.csv    # быстрый sanity по числу сэмплов
```

## Карта «где какой инстанс»
| Шаг | Инстанс | Регион | Стоимость |
|---|---|---|---|
| 0–2 (synth, xo, эмуляции, `hw` битстрим) | m7a.2xlarge (без FPGA) | любой | дёшево |
| 3–5 (load, run, ILA) | f2.6xlarge (1×VU47P) | F2-регион (EU: Frankfurt/London) | подними/прогони/**терминируй** |

Правило: всё, что можно, — на build-инстансе и в эмуляции; f2 только под финал.
