# Synthesis report analysis (P3)

What to read in the reports in `results/synth/` after `flow/synth.tcl`: given a timing and
utilization report, what do you look at and in which order?

⚠️ The numbers depend on the part, the period and the Vivado version — the **method** is what matters.

---

## 0. All from the terminal (no GUI)

Vivado reports are plain TEXT files (written by `report_* -file` in synth.tcl). On a headless
instance you read them with `cat`/`less`/`grep` — no GUI needed. `synth.tcl` also prints WNS/f_max
straight to stdout. Quick extracts:

```bash
# timing: is it met (look for WNS/TNS/WHS)
grep -A4 "Design Timing Summary" results/synth/timing_summary.rpt
# worst path (where the critical path starts/ends)
grep -A20 "Max Delay Paths" results/synth/timing_summary.rpt | head -25
# resources: DSP (should ≈ number of PEs), LUT/FF/BRAM
grep -E "CLB LUTs|CLB Registers|Block RAM Tile|DSPs" results/synth/utilization.rpt
# power
grep -E "Total On-Chip Power|Dynamic|Device Static" results/synth/power.rpt
```
What these numbers mean:

## 1. Timing — `timing_summary.rpt` (the main one)

Find the **Design Timing Summary** block:

| Metric | Meaning | Healthy |
|---|---|---|
| **WNS** (Worst Negative Slack) | worst setup slack | **≥ 0** = timing met |
| **TNS** (Total Negative Slack) | sum of all negative slacks | **0** = no violations |
| **WHS** (Worst Hold Slack) | worst hold slack | **≥ 0** (frequency does not fix hold!) |
| **THS** | sum of hold violations | 0 |

**Achievable f_max** (what synth.tcl prints):
```
f_max = 1 / (T_clk − WNS)      # T_clk — the constrained period
```
If WNS < 0, timing is NOT met: either lower the frequency (↑ period) or cut the critical path
(pipelining/retiming). **A hold violation (WHS<0) is NOT fixed by frequency** — it is about minimum
delay and is fixed with buffers/routing.

**Critical path:** the `Max Delay Paths` section — where the worst path starts and ends
(`Source`/`Destination`), and how much of it is logic vs wire (`logic`/`net %`). In this array the
worst path is usually the MAC accumulator chain or the long INT32 adder carry; it is sped up by
narrowing ACC_WIDTH or adding a register.

## 2. Resources — `utilization.rpt`

The **CLB Logic** and **DSP** sections:

| Resource | What | What to check |
|---|---|---|
| **DSP48/DSP58** | hard multipliers | **should ≈ number of PEs = ARRAY_M·ARRAY_N** — this VALIDATES the P2 resource proxy! One INT8 MAC = 1 DSP |
| **LUT** | combinational logic | adders, control |
| **FF** | registers | a/b pass-through + acc |
| **BRAM/URAM** | memory | ~0 here (data lives outside); appears with on-chip buffers |

Honesty check: if the DSP count ≈ ARRAY_M·ARRAY_N, the "PE≈DSP" model in `gen/search.py` is
confirmed **by synthesis**. If Vivado mapped the INT8 multiply to LUTs (not DSPs), you will see a
LUT spike and few DSPs — a reason to force `(* use_dsp = "yes" *)` on the multiply.

## 3. Power — `power.rpt`

**Total On-Chip Power (W)** + the dynamic/static breakdown. For perf/watt: `throughput / power`.
Dynamic power grows with frequency and activity; static power depends on the part and temperature.
Vivado numbers are an **estimate**, not a board measurement.

## 4. DRC — `drc.rpt`

Design Rule Checks: there should be no **critical** ones. Review the warnings (often incomplete I/O
constraints in OOC — fine for a standalone module).

---

## Worked example: how this design was pushed from 397 to 795 MHz (VU47P-3, 8×8, OOC)

A real "synthesize → read the report → fix" cycle on this array. Four iterations, each driven by the
critical path in `timing_summary.rpt`:

| # | Symptom in the report | Diagnosis | Fix | Result |
|---|---|---|---|---|
| 1 | `place_design`: *IO overutilization*, 2180 ports > 1106 pins | the module is synthesized as a whole chip | `synth_design -mode out_of_context` | synthesis passes |
| 2 | **DSP=0**, LUT=6400 (~100/PE) | INT8×INT8 is small → Vivado puts the multiplier in LUTs | `(* use_dsp="yes" *)` on the product | DSP=64, f_max ~397 MHz |
| 3 | combinational MAC: mult+add in one cycle | multiply and add on one path | MAC pipeline (operands→MREG→acc) | expected ~700, **got 496** |
| 4 | path `b_out_reg`(FDCE) → `prod_r_reg`(FDCE), **7 logic levels** combinationally through the DSP | the **async reset** prevents packing registers into the DSP | synchronous reset in the datapath | **795 MHz** |

Final critical path after fix #4:
```
Source: a_out_reg/C (FDCE)  →  Dest: acc_reg/DSP_A_B_DATA_INST/A (DSP48E2)
Logic Levels: 0     Data Path Delay: route 93% / logic 7%
```
**Sign that it is squeezed out:** the endpoint is INSIDE the DSP (the registers landed in
AREG/BREG/MREG/PREG), 0 logic levels, the path is **route-bound** (93% wire). From here the frequency
is moved by placement/floorplanning, not RTL — the microarchitecture is at the DSP48E2 limit
(-3 speed grade, ~790–890 MHz).

Three pitfalls worth remembering:
1. **An async reset kills packing into the DSP** (and into BRAM/SRL) — put the datapath on a synchronous reset.
2. **A small multiply ends up in LUTs** — `use_dsp` forces a DSP; check DSP≈#PE.
3. **latency↔f_max**: pipelining the MAC buys frequency at the cost of fill cycles; the accumulator
   loop cannot be pipelined, but the multiplier can be moved out of it (MREG).

⚠️ These 795 MHz are the **OOC ceiling of the array itself**. Inside a Vitis kernel on F2 the frequency
is lower (platform: AXI/NoC/HBM, global routing, SLRs). Do not present the OOC f_max as the kernel's
operating frequency.

---

## Summary: reading order
> First WNS/TNS — is timing met; if not, look at the critical path: logic or wire, and cut it with
> pipelining. Separately WHS — frequency does not fix hold. Then DSPs: for an INT8 MAC array their
> count must match the number of PEs — if Vivado went to LUTs, force use_dsp. LUT/FF at a sane level,
> BRAM for on-chip buffers. Power for perf/watt. This is also the model→synthesis link: simulated
> cycles (P2) give latency, synthesis (P3) gives f_max and resources, together = real throughput in
> GMAC/s and GMAC/s/W.

## How the project metrics fit together (labeled by source)
```
tile latency         ← MEASURED in simulation (P2, deterministic)
f_max, DSP/LUT, power ← SYNTHESIS (P3, Vivado)  ← real, not an estimate
real throughput      = MAC/cycle (P2 model) × f_max (P3)   [GMAC/s]
perf/watt            = throughput / power (P3)
```
Never present synthesis numbers as an on-silicon measurement — that measurement will come from F2 (P4).
