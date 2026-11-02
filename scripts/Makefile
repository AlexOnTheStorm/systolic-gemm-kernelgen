# =====================================================================
#  Simulation of systolic_array in cocotb + Verilator.
#    make          — build and run the self-checking TB (default)
#    make waves    — same + open the VCD (needs surfer/gtkwave)
#    make clean    — remove build artifacts
#  Idiom: flat include of the cocotb Makefile.sim.
#  Run FROM this directory (scripts/): RTL paths are relative to it.
# =====================================================================
SIM           ?= verilator
TOPLEVEL_LANG ?= verilog

VERILOG_SOURCES += $(CURDIR)/../rtl/pe.sv
VERILOG_SOURCES += $(CURDIR)/../rtl/systolic_array.sv
VERILOG_SOURCES += $(CURDIR)/../tb/systolic_sva.sv     # SVA contract (bound into pe)

TOPLEVEL = systolic_array      # top module = DUT
MODULE   = test_systolic       # .py name without extension

# where cocotb looks for the test module and the golden model
export PYTHONPATH := $(CURDIR)/../tb:$(CURDIR)/../ref:$(PYTHONPATH)

EXTRA_ARGS += --trace --trace-structs   # VCD for waveform debugging
EXTRA_ARGS += --assert                  # enable SVA checking (systolic_sva.sv)

include $(shell cocotb-config --makefiles)/Makefile.sim

# --- P4: simulation of the FULL kernel (AXI-Lite + AXI-master DMA) — verifies
#     the wrapper datapath BEFORE hardware. `make kernel [ARRAY_M=8 ARRAY_N=8 KERNEL_K=8]`
ARRAY_M  ?= 4
ARRAY_N  ?= 4
KERNEL_K ?= 4
.PHONY: kernel
kernel:
	@$(MAKE) clean >/dev/null 2>&1
	@ARRAY_M=$(ARRAY_M) ARRAY_N=$(ARRAY_N) KERNEL_K=$(KERNEL_K) $(MAKE) \
	  TOPLEVEL=gemm_kernel MODULE=test_kernel \
	  VERILOG_SOURCES="$(CURDIR)/../rtl/pe.sv $(CURDIR)/../rtl/systolic_array.sv $(CURDIR)/../rtl/gemm_kernel.sv" \
	  EXTRA_ARGS="--assert -GARRAY_M=$(ARRAY_M) -GARRAY_N=$(ARRAY_N)"

.PHONY: waves
waves:
	@$(MAKE) -s
	@f=$$(find . -name '*.vcd' | head -1); echo "wave: $$f"; \
	 (command -v surfer >/dev/null && surfer $$f) || \
	 (command -v gtkwave >/dev/null && gtkwave $$f) || \
	 echo "no surfer/gtkwave — open $$f manually"
