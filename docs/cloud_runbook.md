# Cloud runbook — точная последовательность команд (P3→P4), всё из терминала

Один линейный сценарий от пустого инстанса до ILA-захвата. GUI не нужен нигде.
Таргет — **AWS F2 (VU47P)** (AWS мигрировал с F1). ⚠️ имена платформ/AMI/AGFI
меняются — сверяй с `platforminfo -l`, awsdocs-fpga-f2 и aws-fpga (branch f2).

## 0. Инстанс + окружение (build-инстанс из FPGA Developer AMI, Vitis 2025.2)
На этом AMI Vivado/Vitis/v++ **уже в PATH** (`/opt/Xilinx/2025.2/…`, settings64.sh
подхватывается профилем) — для СИНТЕЗА (P3) source'ить ничего не надо.
XRT и aws-fpga из коробки **отсутствуют** — нужны только на P4 (упаковка/хост/железо):
```bash
# --- для P3 (synth) достаточно этого: ---
git clone https://github.com/AlexOnTheStorm/systolic-gemm-kernelgen.git
cd systolic-gemm-kernelgen/practice/gemm_kernelgen
which vivado    # sanity: /opt/Xilinx/2025.2/Vivado/bin/vivado

# --- ДОП. только когда дойдёшь до P4 (xo/v++/хост): ---
git clone https://github.com/aws/aws-fpga.git ~/aws-fpga
source ~/aws-fpga/vitis_setup.sh    # ставит/подхватывает XRT + F2-платформы + env
# (если settings64 не в профиле: source /opt/Xilinx/2025.2/Vitis/settings64.sh)
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

## 3. Из .xclbin → AWS-образ (.awsxclbin/AFI). Vitis/XRT-флоу, в F2-регионе!
На F2 грузится НЕ сырой `.xclbin`, а `.awsxclbin` (AWS-обёртка с AFI). Создание
AFI — асинхронное на стороне AWS (~30–60 мин). ⚠️ Bucket и `create-fpga-image`
должны быть в **F2-регионе** (Frankfurt=eu-central-1 или London=eu-west-2), НЕ в
eu-north-1. Билд-бокс может быть где угодно — он просто заливает в S3 и дёргает API.

Нужно: AWS CLI с креденшелами (IAM-права `ec2:CreateFpgaImage`,
`ec2:DescribeFpgaImages`, доступ к S3), и S3-bucket в F2-регионе.
```bash
source ~/aws-fpga/vitis_setup.sh              # даёт create_vitis_afi.sh
aws configure set region eu-central-1         # Frankfurt (F2)
aws s3 mb s3://<bucket-afi> --region eu-central-1   # один раз

# найти скрипт (путь зависит от версии aws-fpga):
AFISH=$(find ~/aws-fpga -name create_vitis_afi.sh | head -1); echo $AFISH

# сгенерить AFI + .awsxclbin из hw.xclbin:
$AFISH -xclbin=results/hw/gemm_kernel.hw.xclbin \
       -o=results/hw/gemm_kernel \
       -s3_bucket=<bucket-afi> -s3_dcp_key=dcp -s3_logs_key=logs
# → results/hw/gemm_kernel.awsxclbin  +  *_afi_id.txt (afi-.../agfi-...)

# дождаться, пока AFI перейдёт в 'available':
afi=$(grep -o 'afi-[0-9a-f]*' *_afi_id.txt | head -1)
aws ec2 describe-fpga-images --fpga-image-ids $afi \
    --query 'FpgaImages[0].State.Code' --region eu-central-1   # ждём "available"
```

## 4. Запуск + сверка с golden (на f2.6xlarge, Frankfurt)
XRT сам программирует FPGA при `load_xclbin(.awsxclbin)` — отдельный
`fpga-load-local-image` в Vitis-флоу НЕ нужен. На f2 XRT/pyxrt уже из коробки.
```bash
# скопировать на f2: .awsxclbin + host/ + ref/ (репо проще склонировать заново)
python3 host/run_hw.py results/hw/gemm_kernel.awsxclbin --M 8 --N 8 --K 8
# PASS — hardware GEMM 8x8x8 совпал с golden   ← ЗАМЕР НА КРЕМНИИ
```

## 5. ILA-отладка на F2 — headless (см. flow/ila_debug.tcl)
Битстрим собран с System ILA (`--debug.chipscope`, только на `hw`). На F2 доступ к
ILA идёт через отладочный мост XRT (XVC). ⚠️ точная механика XVC/порта на F2 зависит
от версии XRT/awsdocs-fpga — сверь с текущей докой AWS перед прогоном.
```bash
# т.1 (f2): открыть XVC-мост к запрограммированному FPGA (XRT/AWS утилита)
#   на F2 это делает XRT debug-bridge; порт/команда — см. awsdocs-fpga (F2 debug).
# т.2: вооружить ILA и захватить волну в файл (headless batch-Tcl):
XVC_URL=localhost:10201 vivado -mode batch -source flow/ila_debug.tcl
# т.3: дёрнуть kernel → триггер на ap_start:
python3 host/run_hw.py results/hw/gemm_kernel.awsxclbin --M 8 --N 8 --K 8
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
