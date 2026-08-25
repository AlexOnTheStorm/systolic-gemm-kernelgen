# Анализ репортов синтеза (P3)

Что читать в отчётах из `results/synth/` после `flow/synth.tcl`. Это тот навык,
который спрашивают на интервью: «дали timing/utilization — что смотришь?».

⚠️ Числа зависят от part/периода/версии Vivado — не заучивать; важен **метод**.

---

## 0. Всё из терминала (без GUI)

Репорты Vivado — обычные ТЕКСТОВЫЕ файлы (их пишет `report_* -file` в synth.tcl).
На headless-инстансе читаешь их `cat`/`less`/`grep` — GUI не нужен. `synth.tcl`
вдобавок печатает WNS/f_max прямо в stdout. Быстрые выжимки:

```bash
# тайминг: закрыт ли (ищем WNS/TNS/WHS)
grep -A4 "Design Timing Summary" results/synth/timing_summary.rpt
# худший путь (откуда/куда критический путь)
grep -A20 "Max Delay Paths" results/synth/timing_summary.rpt | head -25
# ресурсы: DSP (должно ≈ числу PE), LUT/FF/BRAM
grep -E "CLB LUTs|CLB Registers|Block RAM Tile|DSPs" results/synth/utilization.rpt
# питание
grep -E "Total On-Chip Power|Dynamic|Device Static" results/synth/power.rpt
```
Дальше — что эти числа значат:

## 1. Timing — `timing_summary.rpt` (главный)

Ищи блок **Design Timing Summary**:

| Метрика | Что значит | Норма |
|---|---|---|
| **WNS** (Worst Negative Slack) | худший запас по setup | **≥ 0** = тайминг закрыт |
| **TNS** (Total Negative Slack) | сумма всех отрицательных запасов | **0** = ни одного нарушения |
| **WHS** (Worst Hold Slack) | худший запас по hold | **≥ 0** (hold не лечится частотой!) |
| **THS** | сумма hold-нарушений | 0 |

**Достижимый f_max** (что печатает synth.tcl):
```
f_max = 1 / (T_clk − WNS)      # T_clk — заданный период
```
Если WNS < 0 → тайминг НЕ закрыт: либо снизь частоту (↑ период), либо режь
критический путь (pipeline/retiming). **Hold-нарушение (WHS<0) частотой НЕ
лечится** — это про минимальную задержку, чинится буферами/route (тема 01-02).

**Критический путь:** секция `Max Delay Paths` — откуда/куда worst path
(`Source`/`Destination`), сколько в логике vs в проводах (`logic`/`net %`).
В нашем массиве worst path обычно — цепочка MAC-аккумулятора или длинный
carry сумматора INT32; ускоряется сужением ACC_WIDTH или доп. регистром.

## 2. Ресурсы — `utilization.rpt`

Секции **CLB Logic** и **DSP**:

| Ресурс | Что | На что смотреть |
|---|---|---|
| **DSP48/DSP58** | аппаратные умножители | **должно ≈ числу PE = ARRAY_M·ARRAY_N** — это ВАЛИДИРУЕТ ресурс-прокси из P2! Один INT8-MAC = 1 DSP |
| **LUT** | комбинаторика | сумматоры, управление |
| **FF** | регистры | pass-through a/b + acc |
| **BRAM/URAM** | память | у нас ~0 (данные снаружи); появится при on-chip буферах |

Проверка честности: если DSP в отчёте ≈ ARRAY_M·ARRAY_N — модель «PE≈DSP» из
`gen/search.py` подтверждена **синтезом**. Если Vivado разложил INT8-умножение
в LUT (а не DSP) — увидишь всплеск LUT и мало DSP: повод форсировать
`(* use_dsp = "yes" *)` на умножении.

## 3. Питание — `power.rpt`

**Total On-Chip Power (W)** + разбивка (dynamic/static). Для perf/watt-нарратива
(глава 03a-01): `throughput / power`. Динамика растёт с частотой и активностью;
static — от part/температуры. Числа Vivado — **оценка**, не замер на плате.

## 4. DRC — `drc.rpt`

Design Rule Checks: должно быть без **critical**. Warnings разобрать (часто
незаконченные I/O-constraints в OOC — для standalone это ок).

---

## Что говорить на интервью (готовый разбор)
> «Сначала WNS/TNS — тайминг закрыт или нет; если нет, смотрю критический путь:
> логика или провода, и режу его pipeline'ом. Отдельно WHS — hold частотой не
> лечится. Потом DSP: для INT8-MAC-массива их число обязано совпасть с числом
> PE — если Vivado ушёл в LUT, форсирую use_dsp. LUT/FF — на разумном уровне,
> BRAM под on-chip буферы. Power — для perf/watt. Это же и связка модель→синтез:
> симуляционные такты (P2) дают латентность, синтез (P3) — f_max и ресурсы,
> вместе = реальный throughput в GMAC/s и GMAC/s/Вт.»

## Связка метрик проекта (честно по источникам)
```
латентность тайла   ← ИЗМЕРЕНО в симуляции (P2, детерминировано)
f_max, DSP/LUT, power ← СИНТЕЗ (P3, Vivado)  ← реальные, не estimate
реальный throughput  = MAC/такт (P2 модель) × f_max (P3)   [GMAC/s]
perf/watt            = throughput / power (P3)
```
Никогда не подавай synth-числа как «замер на кремнии» — замер будет на F2 (P4).
