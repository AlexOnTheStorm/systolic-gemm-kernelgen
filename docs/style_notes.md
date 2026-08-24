# Стиль RTL (lowRISC), применённый в проекте

Проект следует lowRISC SystemVerilog Style Guide (IEEE 1800-2017). Ниже —
конвенции и где они в коде. Это шпаргалка «как писать RTL, чтобы не стыдно».

| Правило | Как | Где |
|---|---|---|
| Один модуль на файл, имя файла = модуль | `pe.sv`→`pe`, `systolic_array.sv`→`systolic_array` | rtl/ |
| 4-state типы, `logic` везде | ни одного `reg`/`wire` в синтезируемом RTL | rtl/*.sv |
| `lower_snake_case` для сигналов/модулей | `a_in`, `arr_c_out`, `n_tiles` | всюду |
| `parameter int` + `#(...)`, без magic numbers | `ARRAY_M`, `DATA_WIDTH`, `ACC_WIDTH` | pe.sv, systolic_array.sv |
| Именованные `generate`-блоки | `g_row`, `g_col`, `g_a_edge` | systolic_array.sv |
| Контракт в шапке файла | dataflow/тайминг/точность до кода | все rtl/*.sv |
| Синхронный сброс по имени `rst_n`, `always_ff` | `always_ff @(posedge clk or negedge rst_n)` | pe.sv |
| Знаковая арифметика явно | `logic signed`, `signed'()`, ширина произведения `2*DATA_WIDTH` | pe.sv |
| `unique case` + `default` в FSM | `unique case` регистров, `default:` в state-машине | gemm_kernel.sv |
| SVA-контракт отдельно, `bind` в DUT | `pe_sva` + `bind pe pe_sva ... (.*)` | tb/systolic_sva.sv |

## Почему это важно (для интервью)
- **Читаемость/ревью:** единый стиль → быстрее код-ревью, меньше конфликтов.
- **Синтезируемость:** `logic`+`always_ff`/`always_comb`, без латчей и hierarchical
  refs в RTL — прямое следствие правил.
- **Параметризация вместо копипасты:** один массив покрывает всё DSE-пространство
  (P2), потому что размеры — параметры, а не хардкод.

## Сознательные отступления (честно)
- `tb/systolic_sva.sv` содержит модуль `pe_sva` (имя ≠ файл): это tb/bind-файл,
  правило «имя файла = модуль» для верификации ослаблено намеренно.
- `rtl/gemm_kernel.sv` — reference-скелет Vitis-обёртки: AXI-boilerplate в
  реальном потоке из Kernel Wizard (см. docs/flow_walkthrough.md).

## Источник
lowRISC style guide: github.com/lowRISC/style-guides (VerilogCodingStyle.md).
