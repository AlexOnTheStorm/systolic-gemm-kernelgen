# P3 synthesis results (AWS F2 / VU47P-3, 8×8, out-of-context)

Extract from `results/synth/*.rpt` (the raw reports are not version-controlled — large and noisy;
the key numbers are recorded here as evidence). Run: Vivado 2025.2,
part `xcvu47p-fsvh2892-3-e`, period 1.5 ns, 8×8 array, `synth_design -mode out_of_context`.

## Timing (`timing_summary.rpt`) — MET

| Metric | Value | Meaning |
|---|---|---|
| **WNS** | **+0.242 ns** | setup met (≥0) |
| **WHS** | **+0.052 ns** | hold met (frequency does not fix hold — also fine) |
| TNS / THS | 0 / 0 | 0 violations out of **11088** endpoints |
| **f_max** | **~795 MHz** | = 1 / (1.5 − 0.242) ns |

**Critical path** — route-bound (the microarchitecture is at the DSP limit):
```
Source:  g_row[7].g_col[5].u_pe/a_out_reg[7]/C          (fabric FDCE)
Dest:    g_row[7].g_col[7].u_pe/acc_reg/DSP_A_B_DATA_INST/A[21]   (INSIDE the DSP48E2)
Logic Levels: 0     Data Path Delay: 0.989 ns  (logic 6.9% / route 93.1%)
```
The endpoint is a DSP input: the MAC registers landed in AREG/BREG/MREG/PREG. There is no logic
between the registers (0 levels) and 93% of the delay is wire → only placement is left to improve.

## Resources (`utilization.rpt`)

| Resource | Used | Available | % |
|---|---|---|---|
| **DSP48** | **64** | 9024 | 0.71 |
| **CLB LUT** | **16** | 1 303 680 | <0.01 |
| **CLB FF** | **384** | 2 607 360 | 0.01 |
| BRAM / URAM | 0 / 0 | 2016 / 960 | 0 |

**DSP = 64 = number of PEs** (8×8) → the P2 resource proxy "1 MAC = 1 DSP" is confirmed by synthesis.
An almost empty fabric (16 LUT / 384 FF) means **the whole MAC datapath is packed into DSPs** (the
effect of the synchronous reset — see [report_analysis.md](report_analysis.md), worked example).

## Power (`power.rpt`) — why this is NOT perf/watt

| | W |
|---|---|
| Total On-Chip | 3.565 |
| **Dynamic (logic)** | **0.152** |
| **Device Static** | **3.413** (**96%**) |
| Confidence | Medium |

**96% is the static power of the whole VU47P** at 0.7% utilization. The dynamic power of our logic is
only 0.15 W. Dividing throughput by 3.565 W is meaningless: you would get the "efficiency" of an idle
die, not of the accelerator. An honest perf/watt needs a loaded chip and a measurement under load.

## Sources (honesty)
Everything above is **Vivado synthesis (P3)**, not an on-silicon measurement. Tile latency is measured
in simulation (P2). The on-silicon `PASS` on F2 (P4) is deferred (needs AWS FPGA access).
⚠️ This is the OOC ceiling of the array; inside a Vitis kernel on F2 the kernel clock is limited by the platform.
