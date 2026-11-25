# 0005. Open-source cloud toolchain

- **Status:** Accepted
- **Date:** 2026-11-19

## Context

All work runs in an ephemeral cloud container without commercial simulators. MLACC-UVM proved
Verilator 5.054 + antmicro's Verilator-compatible Accellera UVM tree runs SV-UVM (with z3 for
`randomize`).

## Decision

Simulation: Verilator 5.054 (`--binary --timing`), UVM from antmicro/uvm-verilator @795b5f2, built
with `UVM_NO_DPI`. Formal: Yosys + SymbiYosys where installable, otherwise Yosys `sat -tempinduct`.
Registers: PeakRDL. Firmware: riscv64-unknown-elf-gcc. Coverage: Verilator `--coverage` +
`verilator_coverage`, SV covergroups. `scripts/setup-toolchain.sh` installs all of it.

## Consequences

`UVM_NO_DPI` means no `uvm_hdl_*` backdoor: RAL is frontdoor-only; any backdoor access goes
through bound peek/poke interfaces. Verilator builds must be cached (about 15 minutes from
source). Features that Verilator does not support (some covergroup options, `uvm_reg` backdoor,
4-state X checking) are recorded in `docs/VERILATOR-NOTES.md` as they are found.
