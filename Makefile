# Confluence top-level targets (docs/PLAN.md milestones). Toolchain: scripts/setup-toolchain.sh.
VERILATOR ?= $(shell command -v verilator || echo /opt/verilator-5.054/bin/verilator)
J ?= 4
RTL_LIB := rtl/lib/cf_fifo.sv rtl/lib/cf_rr_arb.sv

.PHONY: lint smoke-build vip-test test-xbar test-bridge formal-xbar formal-xbar-bmc regress clean

# Verilator -Wall on every new RTL block (upstream IPs are linted in their own repos).
lint:
	$(VERILATOR) --lint-only -Wall -f rtl/xbar/files.f --top-module confluence_xbar
	$(VERILATOR) --lint-only -Wall $(RTL_LIB) rtl/bridge/axi2axil.sv --top-module axi2axil
	$(VERILATOR) --lint-only -Wall $(RTL_LIB) rtl/bridge/axil2apb.sv --top-module axil2apb
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
test-bridge:
	python3 sim/regress.py sim/tests_bridge.yaml -j $(J)
formal-xbar:
	formal/run_formal.sh xbar pdr
formal-xbar-bmc:
	formal/run_formal.sh xbar bmc

regress: lint vip-test test-xbar test-bridge

clean:
	rm -rf build reports formal/xbar/xbar_bmc formal/xbar/xbar_prove formal/xbar/xbar_pdr
