# Сквозной флоу: sim → synth → xo → xclbin → железо → ILA

Полный путь одного ядра. Локальное (мак) отмечено 💻, облачное (Vivado/F2) — ☁️.
Это и есть «образец проектирования на будущее»: каждый шаг воспроизводим.

```
 💻 P1  RTL + cocotb + SVA + coverage         → make (scripts/)         [корректность]
 💻 P2  gen-loop: DSE в симуляции             → gen/search.py           [латентность, выбор конфига]
 ☁️ P3  synth/impl, репорты                    → flow/synth.tcl          [f_max, DSP/LUT, power]
 ☁️ P4  package_xo → v++ → xclbin → host+ILA   → flow/*, host/run_hw.py  [замер на кремнии]
```

## Шаг за шагом

### 1. 💻 Симуляция и выбор конфига (P1–P2)
```bash
source /Users/alex/fpga-venv/bin/activate
cd scripts && make                       # self-check + coverage + SVA
cd ../gen && python3 search.py --M 64 --N 64 --K 64 --budget 64
```
Из DSE берёшь конфиг (напр. 8×8) → это `ARRAY_M/ARRAY_N` для синтеза.

### 2. ☁️ Синтез-оценка (P3)
```bash
vivado -mode batch -source flow/synth.tcl -tclargs xcvu47p-fsvh2892-3-e 3.0 8 8
```
Смотри `results/synth/timing_summary.rpt` (WNS≥0?) и `utilization.rpt`
(DSP ≈ 64 = число PE?). Разбор — `docs/report_analysis.md`. Здесь смыкаются
модель (P2) и железо: реальный `throughput = MAC/такт × f_max`.

### 3. ☁️ Упаковка kernel (P4)
```bash
vivado -mode batch -source flow/package_kernel.tcl     # → results/xo/gemm_kernel.xo
```
Практика: интерфейсы удобнее сгенерить Vitis RTL Kernel Wizard, вставив наш
вычислитель (rtl/gemm_kernel.sv — reference интеграции + управляющий FSM).

### 4. ☁️ Линковка с ILA
```bash
PLATFORM=<platform> ./flow/build_hw.sh hw_emu    # СНАЧАЛА эмуляция (минуты)
PLATFORM=<platform> ./flow/build_hw.sh hw        # потом битстрим (часы)
```
`--debug.chipscope gemm_kernel_1` вешает **System ILA** на AXI-интерфейсы ядра.

### 5. ☁️ Запуск на F2 + сверка
```bash
python3 host/run_hw.py results/hw/gemm_kernel.hw.xclbin --M 8 --N 8 --K 8
# PASS — hardware GEMM совпал с golden
```

### 6. ☁️ Отладка на ILA — ПОЛНОСТЬЮ ИЗ ТЕРМИНАЛА (сердце P4)
GUI Vivado НЕ нужен. ILA гоняется headless через batch-Tcl, волна пишется в файл.

```bash
# терминал 1: поднять коннект к железу
#   Alveo — hw_server видит карту сам; F2 — виртуальный JTAG (XVC):
sudo fpga-load-local-image  -S 0 -I <agfi-с-ILA>        # только F2
sudo fpga-start-virtual-jtag -P 10201 -S 0              # только F2 → XVC на :10201

# терминал 2: вооружить ILA (ждёт триггер ap_start), захватить в файл
XVC_URL=localhost:10201 vivado -mode batch -source flow/ila_debug.tcl   # F2
#   (Alveo: без XVC_URL — open_hw_target подключится напрямую)

# терминал 3: запустить хост → сработает триггер
python3 host/run_hw.py results/hw/gemm_kernel.hw.xclbin --M 8 --N 8 --K 8
```
Результат: `results/ila/capture.vcd` (+ `.csv`). Смотришь волну **в терминале**:
```bash
surfer results/ila/capture.vcd        # или gtkwave; или scp на мак и открой там
```
Что искать в захвате: **волновой фронт систолики** (как в `make waves` на P1, но
на кремнии); AXI burst'ы A/B/C; **зависания** = `valid` есть, `ready` нет
(backpressure) — типичный bring-up баг датапата. Нашёл → правишь
`rtl/gemm_kernel.sv` → пересборка (`build_hw.sh hw_emu` сначала!). Цикл эмуляция→ILA.

Триггер меняешь в `flow/ila_debug.tcl` (напр. на `m_axi_arvalid`); список доступных
проб — `get_hw_probes -of_objects $ila` внутри того же batch-Tcl.

## Что где отлаживать (карта багов)
| Симптом | Где | Инструмент |
|---|---|---|
| Неверная математика | логика массива | P1 cocotb + `make waves` 💻 |
| Плохой выбор размера | конфиг | P2 `search.py` 💻 |
| Тайминг не закрыт (WNS<0) | критический путь | P3 `timing_summary.rpt` ☁️ |
| DSP ушли в LUT | синтез умножения | P3 `utilization.rpt` + `use_dsp` ☁️ |
| Зависание/неверные данные на плате | AXI-датапат обёртки | **P4 ILA** ☁️ |

Мораль: чем левее поймал баг (симуляция), тем дешевле. ILA — последний рубеж
для того, что видно только на реальном железе (AXI, тайминг платформы).
