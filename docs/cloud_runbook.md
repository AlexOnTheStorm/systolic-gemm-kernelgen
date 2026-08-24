# Cloud runbook — точная последовательность команд (P3→P4), всё из терминала

Один линейный сценарий от пустого инстанса до ILA-захвата. GUI не нужен нигде.
⚠️ Имена платформ/AMI/AGFI меняются — сверяй с `platforminfo -l` и aws-fpga.

## 0. Инстанс + окружение (build-инстанс из AWS FPGA Developer AMI)
```bash
git clone https://github.com/aws/aws-fpga.git
source aws-fpga/vitis_setup.sh              # XRT + платформы + переменные
source /opt/xilinx/xrt/setup.sh
git clone <твой-репо>/gemm-kernelgen.git && cd gemm-kernelgen
```

## 1. P3 — синтез-оценка (f_max, ресурсы)
```bash
vivado -mode batch -source flow/synth.tcl -tclargs xcvu9p-flgb2104-2-i 3.0 8 8
# stdout сразу печатает WNS и f_max. Детально:
grep -A4 "Design Timing Summary" results/synth/timing_summary.rpt
grep -E "CLB LUTs|CLB Registers|DSPs|Block RAM Tile" results/synth/utilization.rpt
```
Цель: **WNS ≥ 0** и **DSP ≈ ARRAY_M·ARRAY_N** (валидирует P2-модель).

## 2. P4 — собрать kernel и xclbin
```bash
vivado -mode batch -source flow/package_kernel.tcl          # → results/xo/gemm_kernel.xo
export PLATFORM=<f1_или_alveo_platform>

./flow/build_hw.sh sw_emu    # (сек)  проверка host↔kernel логики
./flow/build_hw.sh hw_emu    # (мин)  RTL-точная эмуляция — ЛОВИТ 90% багов до битстрима
./flow/build_hw.sh hw        # (часы) реальный битстрим с ILA → results/hw/*.xclbin
```
Эмуляции (`sw_emu`/`hw_emu`) НЕ требуют F1 — гоняй на дешёвом build-инстансе.
`hw` — только когда эмуляция чистая.

## 3. Залить на F1 (только для реального железа)
```bash
# из битстрима создать AFI (один раз), дождаться 'available':
aws ec2 create-fpga-image --input-storage-location Bucket=<s3>,Key=<dcp> ...
# на f1.2xlarge:
sudo fpga-load-local-image -S 0 -I <agfi-id>
```

## 4. Запуск + сверка с golden (на f1)
```bash
python3 host/run_hw.py results/hw/gemm_kernel.hw.xclbin --M 8 --N 8 --K 8
# PASS — hardware GEMM совпал с golden
```

## 5. ILA-отладка — headless, 3 терминала (см. flow/ila_debug.tcl)
```bash
# т.1 (F1): поднять виртуальный JTAG
sudo fpga-start-virtual-jtag -P 10201 -S 0

# т.2: вооружить ILA (ждёт триггер ap_start), захват в файл
XVC_URL=localhost:10201 vivado -mode batch -source flow/ila_debug.tcl
#   Alveo: без XVC_URL

# т.3: дёрнуть kernel → сработает триггер
python3 host/run_hw.py results/hw/gemm_kernel.hw.xclbin --M 8 --N 8 --K 8
```
Волна → `results/ila/capture.vcd`. Смотреть:
```bash
surfer results/ila/capture.vcd        # headless-вьювер; или scp на мак
grep -c "" results/ila/capture.csv    # быстрый sanity по числу сэмплов
```

## Карта «где какой инстанс»
| Шаг | Инстанс | Стоимость |
|---|---|---|
| 0–2 (synth, xo, эмуляции, `hw` битстрим) | z1d/c5 (без FPGA) | дёшево |
| 3–5 (load, run, ILA) | f1.2xlarge | ~$1.65/ч — подними/прогони/**выключи** |

Правило: всё, что можно, — на build-инстансе и в эмуляции; f1 только под финал.
