# Confluence top-level targets (docs/PLAN.md milestones). Toolchain: scripts/setup-toolchain.sh.
VERILATOR ?= $(shell command -v verilator || echo /opt/verilator-5.054/bin/verilator)
J ?= 4
RTL_LIB := rtl/lib/cf_fifo.sv rtl/lib/cf_rr_arb.sv

.PHONY: lint smoke-build vip-test test-xbar test-bridge formal-xbar formal-xbar-bmc \
        regs regs-check regs-html test-ral nanoxl-traces test-nanoxl spikemesh-traces test-spikemesh mutate-router \
        test-xbar-50 regress clean
GEN_BLOCKS := cf_sys_ctrl cf_irq_ctrl cf_timer cf_dma_csr cf_spikemesh_ctl cf_mailbox

# Verilator -Wall on every new RTL block (upstream IPs are linted in their own repos).
lint:
	$(VERILATOR) --lint-only -Wall -f rtl/xbar/files.f --top-module confluence_xbar
	$(VERILATOR) --lint-only -Wall $(RTL_LIB) rtl/bridge/axi2axil.sv --top-module axi2axil
	$(VERILATOR) --lint-only -Wall $(RTL_LIB) rtl/bridge/axil2apb.sv --top-module axil2apb
	for b in $(GEN_BLOCKS); do $(VERILATOR) --lint-only -Wall sim/lint/peakrdl.vlt \
	  regs/gen/rtl/$${b}_pkg.sv regs/gen/rtl/$$b.sv --top-module $$b || exit 1; done
	@echo "lint clean"

# M0: Vortex-V SoC + MLACC + NanoXL + SpikeMesh in one Verilator model.
smoke-build:
	sim/smoke_build.sh

# M1: VIP self-tests (AXI4, AXI-Lite, APB, AXI-Stream; loopback + violation injection).
vip-test:
	python3 sim/regress.py sim/tests_vip.yaml sim/tests_vip_lite.yaml -j $(J)

# M2: crossbar and bridges.
test-xbar:
	python3 sim/regress.py sim/tests_xbar.yaml -j $(J)
test-xbar-50:
	python3 sim/regress.py sim/tests_xbar_50.yaml -j $(J)
test-bridge:
	python3 sim/regress.py sim/tests_bridge.yaml -j $(J)
formal-xbar:
	formal/run_formal.sh xbar pdr
formal-xbar-bmc:
	formal/run_formal.sh xbar bmc

# M3: register flow (ADR 0004). regs regenerates; regs-check fails if regs/gen is stale.
regs:
	scripts/gen_regs.sh
regs-check:
	scripts/gen_regs.sh build/regs-check
	diff -r regs/gen build/regs-check && echo "regs/gen up to date"
regs-html:
	HTML=1 scripts/gen_regs.sh
test-ral:
	python3 sim/regress.py sim/tests_regs.yaml -j $(J)

# M4: NanoXL block env against golden traces recorded from NanoXL's driver + funcsim.
nanoxl-traces:
	sim/gen_nanoxl_traces.sh
test-nanoxl: nanoxl-traces
	python3 sim/regress.py sim/tests_nanoxl.yaml -j $(J)

# M5: SpikeMesh chip env against golden traces recorded from SpikeMesh's host API + golden chip.
spikemesh-traces:
	sim/gen_spikemesh_traces.sh
test-spikemesh: spikemesh-traces
	python3 sim/regress.py sim/tests_spikemesh.yaml -j $(J)
# router env vs mutated copies of SpikeMesh's router (submodule untouched); every mutant must die
mutate-router:
	python3 scripts/mutate_router.py

regress: lint regs-check vip-test test-xbar test-bridge test-ral test-nanoxl test-spikemesh

clean:
	rm -rf build reports formal/xbar/xbar_bmc formal/xbar/xbar_prove formal/xbar/xbar_pdr
