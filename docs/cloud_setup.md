# Облачная среда для Vivado/Vitis + F1 (P3–P4)

macOS не запускает Vivado/Vitis. Всё «железное» (синтез, ILA, bitstream, запуск)
делаем в облаке. Самый прямой путь — **AWS FPGA Developer AMI**: в ней уже стоят
Vivado + Vitis + XRT с лицензией, валидной для F1-устройства (решает вопрос лицензии).

⚠️ Имена AMI/платформ/версий инструментов быстро меняются — сверяйся с
`github.com/aws/aws-fpga` и AWS Marketplace на момент работы.

## Роли инстансов (экономия: синтез отдельно от железа)
| Задача | Инстанс | Зачем |
|---|---|---|
| Синтез P3, сборка `.xo`/`.xclbin` P4 | **z1d/c5.4xlarge** (без FPGA) | дёшево, много CPU/RAM для P&R |
| Запуск на кремнии + ILA | **f1.2xlarge** (1×VU9P) | собственно FPGA; ~$1.65/ч |

Сборка (часы) — на дешёвом build-инстансе; на дорогой f1 переходишь только ради
прогона и ILA. Битстрим → **AFI** (`aws ec2 create-fpga-image`), затем грузишь на f1.

## Быстрый старт (эскиз)
```bash
# 1) build-инстанс из FPGA Developer AMI:
git clone https://github.com/aws/aws-fpga.git
source aws-fpga/vitis_setup.sh          # ставит XRT + платформы + env

# 2) синтез-оценка (P3), из корня проекта gemm_kernelgen:
vivado -mode batch -source flow/synth.tcl -tclargs xcvu9p-flgb2104-2-i 3.0 8 8
#   → results/synth/*.rpt   (разбор: docs/report_analysis.md)

# 3) собрать kernel (P4):
vivado -mode batch -source flow/package_kernel.tcl      # → results/xo/gemm_kernel.xo
PLATFORM=<f1_platform> ./flow/build_hw.sh hw_emu        # RTL-эмуляция (проверка)
PLATFORM=<f1_platform> ./flow/build_hw.sh hw            # битстрим (часы) → AFI

# 4) на f1-инстансе — запуск + сверка:
source /opt/xilinx/xrt/setup.sh
python3 host/run_hw.py results/hw/gemm_kernel.hw.xclbin --M 8 --N 8 --K 8
```

## Дешевле без AWS
- **hw_emu** (RTL-эмуляция) не требует f1 — гоняй на build-инстансе, ловит 90%
  интеграционных багов до дорогого битстрима. Начинай ВСЕГДА с hw_emu.
- Alveo U200 у облачных провайдеров (Nimbix и пр.) — альтернатива F1; тот же
  Vitis-поток, меняется только `--platform` (Alveo U200 ↔ F1 миграция бесшовна).

## Гигиена расходов
- f1 — по требованию: подними, прогони, **выключи**. hw-синтез — на build-инстансе.
- Держи `.xo`/`.dcp`/`.xclbin` в S3, чтобы не пересобирать.
