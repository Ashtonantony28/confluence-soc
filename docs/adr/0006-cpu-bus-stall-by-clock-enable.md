# 0006. Vortex-V on AXI: stall the core with a clock enable

- **Status:** Accepted
- **Date:** 2026-11-22

## Context

Vortex-V's core ports (docs/M1-INTERFACE-v1.md in that repo) have no ready or stall input: with
`SYNC_MEM=0` instruction and data reads answer combinationally in the same cycle, and stores
take effect at the clock edge. An AXI4 fabric answers after a variable, unbounded latency. The
core cannot be edited here (CLAUDE.md: upstream IPs are pinned submodules), and adding a stall
to an out-of-order core touches every pipeline register, which is a design change for the
Vortex-V project itself.

## Decision

`vortex_axi_bridge` freezes the core between its clock edges. The core runs on a gated clock
(`cf_clk_gate`, a latch-based enable cell, the one place in the RTL with a latch). For every core
cycle the bridge:

1. reads the instruction word(s) at `imem_addr` (and `imem_addr1` with two fetch ports) over AXI,
2. holds them on `imem_rdata*` and waits one cycle for the core's combinational data request,
3. performs the data access over AXI if `dmem_req` is high (a store waits for its write
   response, so a following load can never overtake it),
4. enables exactly one core clock edge with all read data held stable.

The core therefore sees exactly the behaviour of the zero-latency memory it was verified against,
whatever the fabric latency. Every access is single-beat, uncached, one outstanding transaction.
Error responses read as 0 (as unmapped addresses do in `vortex_soc`) and set a sticky `err`.

## Consequences

- Correct by construction for any latency, and the core is untouched.
- Slow: at least about six bus cycles per core cycle. Acceptable for verification and firmware
  bring-up; a cached, stalling interface is Vortex-V work and would supersede this ADR.
- The gated clock is a second clock domain in name only (same source, enable latched while the
  clock is low); it must be declared as a generated clock for any FPGA build.
- Speculative wrong-path fetches and loads reach the fabric as real reads. The SoC's slaves must
  have side-effect-free reads (already true of Vortex-V's MMIO, KNOWN-ISSUES I12 there).
