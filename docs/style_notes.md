# RTL style (lowRISC) as applied in this project

The project follows the lowRISC SystemVerilog Style Guide (IEEE 1800-2017). Below are the
conventions and where they appear in the code.

| Rule | How | Where |
|---|---|---|
| One module per file, file name = module name | `pe.sv`→`pe`, `systolic_array.sv`→`systolic_array` | rtl/ |
| 4-state types, `logic` everywhere | no `reg`/`wire` in synthesizable RTL | rtl/*.sv |
| `lower_snake_case` for signals/modules | `a_in`, `arr_c_out`, `n_tiles` | everywhere |
| `parameter int` + `#(...)`, no magic numbers | `ARRAY_M`, `DATA_WIDTH`, `ACC_WIDTH` | pe.sv, systolic_array.sv |
| Named `generate` blocks | `g_row`, `g_col`, `g_a_edge` | systolic_array.sv |
| Contract in the file header | dataflow/timing/precision before the code | all rtl/*.sv |
| Active-low reset named `rst_n`, `always_ff` | synchronous `always_ff @(posedge clk)` in the PE (lets Vivado pack registers into the DSP48E2); the kernel wrapper keeps an asynchronous `ap_rst_n` | pe.sv, gemm_kernel.sv |
| Explicit signed arithmetic | `logic signed`, `signed'()`, product width `2*DATA_WIDTH` | pe.sv |
| `unique case` + `default` in FSMs | `unique case` for registers, `default:` in the state machine | gemm_kernel.sv |
| SVA contract kept separate, `bind` into the DUT | `pe_sva` + `bind pe pe_sva ... (.*)` | tb/systolic_sva.sv |

## Why it matters
- **Readability/review:** one consistent style → faster code review, fewer conflicts.
- **Synthesizability:** `logic` + `always_ff`/`always_comb`, no latches and no hierarchical
  references in RTL follow directly from the rules.
- **Parameterization instead of copy-paste:** one array covers the whole DSE space (P2),
  because the sizes are parameters, not hard-coded values.

## Deliberate deviations
- `tb/systolic_sva.sv` contains the module `pe_sva` (name ≠ file): it is a tb/bind file, and
  the "file name = module" rule is intentionally relaxed for verification code.
- `rtl/gemm_kernel.sv` uses a simplified AXI-Lite slave (always-ready, no WSTRB/BRESP/RRESP);
  in a production flow this boilerplate would come from the Vitis Kernel Wizard
  (see docs/flow_walkthrough.md).

## Source
lowRISC style guide: github.com/lowRISC/style-guides (VerilogCodingStyle.md).
