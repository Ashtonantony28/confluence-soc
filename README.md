# Confluence

A heterogeneous ML SoC (Vortex-V RV64 host, NanoXL transformer accelerator, SpikeMesh
neuromorphic mesh, MLACC int8 IP on an AXI4 fabric) and its SystemVerilog/UVM verification
campaign: reusable protocol VIP, block-level environments reused vertically in a SoC
environment, SystemRDL registers, firmware-driven tests, formal on the fabric, performance
checks and coverage closure. Plan: [docs/PLAN.md](docs/PLAN.md). Conventions: [CLAUDE.md](CLAUDE.md).

## Status

| Milestone | State |
|---|---|
| M0 foundations (ADRs, toolchain, pinned IPs) | done |
| M1 VIP library | AXI4 done (26/26 self-tests); AXI-Lite, APB, AXI-Stream in progress |

## Quick start

```
scripts/setup-toolchain.sh                 # Verilator 5.054, UVM, PeakRDL, submodules
python3 sim/regress.py sim/tests_vip.yaml  # VIP self-test regression
sim/run_uvm.sh axi4_selftest axi4_random_test 7
```
