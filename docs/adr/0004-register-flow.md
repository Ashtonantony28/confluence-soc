# 0004. SystemRDL is the single source for registers

- **Status:** Accepted
- **Date:** 2026-11-19

## Context

Register maps must agree in RTL, UVM RAL, firmware headers and documentation. Hand-written copies
drift (MLACC-UVM hand-wrote all three).

## Decision

All new CSR blocks are described in `regs/*.rdl` and generated with PeakRDL: `peakrdl-regblock`
(RTL), `peakrdl-uvm` (RAL), `peakrdl-cheader` (C), `peakrdl-html` (docs). Existing NanoXL and
MLACC maps are described in RDL too and audited against their RTL (RAL tests on the real IP).
Generated files are committed and CI fails if they are stale.

## Consequences

PeakRDL output must compile under Verilator; any incompatibility is handled by generator options
or a post-processing script, never hand edits. Pinned PeakRDL versions in `requirements.txt`.
