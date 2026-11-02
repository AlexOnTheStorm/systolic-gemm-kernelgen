# End-to-end flow: sim → synth → xo → xclbin → hardware → ILA

The full path of one kernel. Local steps (laptop) are marked 💻, cloud steps (Vivado/F2) ☁️.
Every step is reproducible.

```
 💻 P1  RTL + cocotb + SVA + coverage         → make (scripts/)         [correctness]
 💻 P2  generator loop: DSE in simulation     → gen/search.py           [latency, config choice]
 ☁️ P3  synth/impl, reports                    → flow/synth.tcl          [f_max, DSP/LUT, power]
 ☁️ P4  package_xo → v++ → xclbin → host+ILA   → flow/*, host/run_hw.py  [on-silicon measurement]
```

## Step by step

### 1. 💻 Simulation and config choice (P1–P2)
```bash
source "$FPGA_VENV/bin/activate"         # your venv with cocotb
cd scripts && make                       # self-check + coverage + SVA
cd ../gen && python3 search.py --M 64 --N 64 --K 64 --budget 64
```
Take a config from the DSE (e.g. 8×8) → these are `ARRAY_M/ARRAY_N` for synthesis.

### 2. ☁️ Synthesis estimate (P3)
```bash
vivado -mode batch -source flow/synth.tcl -tclargs xcvu47p-fsvh2892-3-e 3.0 8 8
```
Check `results/synth/timing_summary.rpt` (WNS≥0?) and `utilization.rpt`
(DSP ≈ 64 = number of PEs?). Analysis: `docs/report_analysis.md`. This is where the model (P2)
meets the hardware: real `throughput = MAC/cycle × f_max`.

### 3. ☁️ Kernel packaging (P4)
```bash
vivado -mode batch -source flow/package_kernel.tcl     # → results/xo/gemm_kernel.xo
```
In practice the interfaces are easier to generate with the Vitis RTL Kernel Wizard, dropping in our
compute core (rtl/gemm_kernel.sv is a reference integration + control FSM).

### 4. ☁️ Linking with an ILA
```bash
PLATFORM=<platform> ./flow/build_hw.sh hw_emu    # emulation FIRST (minutes)
PLATFORM=<platform> ./flow/build_hw.sh hw        # then the bitstream (hours)
```
`--debug.chipscope gemm_kernel_1` attaches a **System ILA** to the kernel's AXI interfaces.

### 5. ☁️ Run on F2 + check
```bash
python3 host/run_hw.py results/hw/gemm_kernel.hw.xclbin --M 8 --N 8 --K 8
# PASS — hardware GEMM matches golden
```

### 6. ☁️ ILA debug — ENTIRELY FROM THE TERMINAL (the core of P4)
No Vivado GUI needed. The ILA runs headless via batch Tcl and the waveform is written to a file.

```bash
# terminal 1: bring up the hardware connection
#   Alveo — hw_server sees the card directly; F2 — virtual JTAG (XVC):
sudo fpga-load-local-image  -S 0 -I <agfi-with-ILA>     # F2 only
sudo fpga-start-virtual-jtag -P 10201 -S 0              # F2 only → XVC on :10201

# terminal 2: arm the ILA (waits for the ap_start trigger), capture to a file
XVC_URL=localhost:10201 vivado -mode batch -source flow/ila_debug.tcl   # F2
#   (Alveo: no XVC_URL — open_hw_target connects directly)

# terminal 3: run the host → the trigger fires
python3 host/run_hw.py results/hw/gemm_kernel.hw.xclbin --M 8 --N 8 --K 8
```
Result: `results/ila/capture.vcd` (+ `.csv`). View the waveform **from the terminal**:
```bash
surfer results/ila/capture.vcd        # or gtkwave; or scp to a laptop and open it there
```
What to look for in the capture: the **systolic wavefront** (as in `make waves` in P1, but on
silicon); AXI bursts for A/B/C; **hangs** = `valid` asserted with no `ready` (backpressure) — a
typical datapath bring-up bug. Found one → fix `rtl/gemm_kernel.sv` → rebuild (`build_hw.sh hw_emu`
first!). Iterate emulation → ILA.

Change the trigger in `flow/ila_debug.tcl` (e.g. to `m_axi_arvalid`); list the available probes
with `get_hw_probes -of_objects $ila` inside the same batch Tcl.

## Where to debug what (bug map)
| Symptom | Where | Tool |
|---|---|---|
| Wrong math | array logic | P1 cocotb + `make waves` 💻 |
| Poor size choice | config | P2 `search.py` 💻 |
| Timing not met (WNS<0) | critical path | P3 `timing_summary.rpt` ☁️ |
| DSPs ended up in LUTs | multiplier synthesis | P3 `utilization.rpt` + `use_dsp` ☁️ |
| Hang/wrong data on the board | wrapper AXI datapath | **P4 ILA** ☁️ |

Moral: the further left a bug is caught (simulation), the cheaper it is. The ILA is the last line
of defence for what only shows up on real hardware (AXI, platform timing).
