# Облачная среда для Vivado/Vitis + F2 (P3–P4)

macOS не запускает Vivado/Vitis. Всё «железное» (синтез, ILA, bitstream, запуск)
делаем в облаке. Прямой путь — **AWS FPGA Developer AMI** (ветка F2): в ней уже
стоят Vivado/Vitis + XRT с лицензией под F2-устройство. Текущая: Ubuntu, Xilinx
**2025.2**, юзер `ubuntu`, репо/доки в `/home/ubuntu/src`.

⚠️ AWS мигрировал с **F1 (VU9P)** на **F2 (VU47P)**. Имена AMI/платформ/версий
быстро меняются — сверяйся с awsdocs-fpga-f2.readthedocs-hosted.com и
`github.com/aws/aws-fpga` (branch f2) + `platforminfo -l` на инстансе.

## Регионы F2 (важно!)
US East (N. Virginia), US West (Oregon), Canada Central, **eu-central-1 (Frankfurt)**,
**eu-west-2 (London)**, AP Sydney/Tokyo/Seoul. **В eu-north-1 (Стокгольм) F2 НЕТ.**
- Синтез/эмуляцию (P3, hw_emu) делай в любом регионе.
- Реальный F2-прогон + AFI — в F2-регионе (ЕС: Frankfurt/London). AFI создаётся
  в том же регионе, что и f2-инстанс.

## Роли инстансов (синтез отдельно от железа)
| Задача | Инстанс | Зачем |
|---|---|---|
| Синтез P3, сборка `.xo`/`.xclbin`, эмуляции | **m7a.2xlarge** (без FPGA) | дёшево, быстрый Zen4 под P&R |
| Запуск на кремнии + ILA | **f2.6xlarge** (1×VU47P) | собственно FPGA; F2-регион |

Сборка (часы) — на дешёвом build-инстансе; на f2 переходишь только ради прогона
и ILA. Битстрим → **AFI** (`aws ec2 create-fpga-image`), затем грузишь на f2.

## Быстрый старт
```bash
# 1) build-инстанс из FPGA Developer AMI (уже с Vitis 2025.2). Настройка env:
source /home/ubuntu/src/aws-fpga/vitis_setup.sh     # XRT + платформы F2 + env
#   (в свежей AMI aws-fpga уже склонирован в ~/src; иначе git clone -b f2 ...)

# 2) синтез-оценка (P3), из корня проекта gemm_kernelgen:
vivado -mode batch -source flow/synth.tcl -tclargs xcvu47p-fsvh2892-3-e 3.0 8 8
#   → results/synth/*.rpt   (разбор: docs/report_analysis.md)

# 3) собрать kernel (P4):
vivado -mode batch -source flow/package_kernel.tcl                    # → results/xo/*.xo
PLATFORM=xilinx_aws-vu47p-f2_202420_2 ./flow/build_hw.sh hw_emu       # RTL-эмуляция
PLATFORM=xilinx_aws-vu47p-f2_202420_2 ./flow/build_hw.sh hw           # битстрим → AFI

# 4) на f2-инстансе (F2-регион) — запуск + сверка:
source /opt/xilinx/xrt/setup.sh
python3 host/run_hw.py results/hw/gemm_kernel.hw.xclbin --M 8 --N 8 --K 8
```

## Дешевле без f2
- **hw_emu** (RTL-эмуляция) НЕ требует f2 — гоняй на build-инстансе, ловит 90%
  интеграционных багов до дорогого битстрима. Начинай ВСЕГДА с hw_emu.
- Логика ядра уже sim-проверена локально (`make kernel`) — эмуляция должна пройти чисто.

## Гигиена расходов
- f2 — по требованию: подними, прогони, **терминируй**. hw-синтез — на build-инстансе.
- Держи `.xo`/`.dcp`/`.xclbin`/AFI-манифест в S3, чтобы не пересобирать.
- VU47P огромен (9024 DSP) — наш массив помещается многократно; можно строить 64×64+.
