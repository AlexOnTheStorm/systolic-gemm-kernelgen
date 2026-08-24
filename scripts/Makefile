# =====================================================================
#  Симуляция systolic_array в cocotb + Verilator.
#    make          — собрать и прогнать self-checking TB (дефолт)
#    make waves    — то же + открыть VCD (нужен surfer/gtkwave)
#    make clean    — убрать артефакты сборки
#  Идиома — как в practice/ex7_fifo_cocotb/Makefile (плоский include).
#  Запускать ИЗ этой папки (scripts/): пути к RTL относительны неё.
# =====================================================================
SIM           ?= verilator
TOPLEVEL_LANG ?= verilog

VERILOG_SOURCES += $(CURDIR)/../rtl/pe.sv
VERILOG_SOURCES += $(CURDIR)/../rtl/systolic_array.sv
VERILOG_SOURCES += $(CURDIR)/../tb/systolic_sva.sv     # SVA-контракт (bind в pe)

TOPLEVEL = systolic_array      # верхний модуль = DUT
MODULE   = test_systolic       # имя .py без расширения

# где cocotb ищет test-модуль и golden-модель
export PYTHONPATH := $(CURDIR)/../tb:$(CURDIR)/../ref:$(PYTHONPATH)

EXTRA_ARGS += --trace --trace-structs   # VCD для разбора волн
EXTRA_ARGS += --assert                  # включить проверку SVA (systolic_sva.sv)

include $(shell cocotb-config --makefiles)/Makefile.sim

.PHONY: waves
waves:
	@$(MAKE) -s
	@f=$$(find . -name '*.vcd' | head -1); echo "wave: $$f"; \
	 (command -v surfer >/dev/null && surfer $$f) || \
	 (command -v gtkwave >/dev/null && gtkwave $$f) || \
	 echo "нет surfer/gtkwave — открой $$f вручную"
