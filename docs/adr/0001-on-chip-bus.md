# 0001. AXI4 fabric written in-house

- **Status:** Accepted
- **Date:** 2026-11-19

## Context

The SoC needs an interconnect joining a CPU (Vortex-V has only simple memory ports), NanoXL
(already AXI4-Lite slave + three AXI4 128-bit masters), SpikeMesh (48-bit flits, AXI-Stream bridge)
and MLACC (APB3). Options: write our own crossbar and bridges, or import the PULP `axi` library.
PULP is battle tested but large and macro heavy; using it would leave the bench little real RTL
to find bugs in. The project goal is SystemVerilog design + UVM verification experience.

## Decision

We will write a parameterised AXI4 crossbar (`confluence_xbar`), AXI4→AXI4-Lite and AXI4→APB
bridges, and a default (DECERR) slave in `rtl/`. Data width of the fabric is 128 bits (NanoXL's
native width); narrower masters/slaves use AXI narrow transfers. The CPU gets a bridge from its
memory ports. Correctness is backed by UVM (`xbar_env`) and SymbiYosys proofs (M2).

## Consequences

More design work and more bugs to find (intended). We own AXI corner cases (WRAP bursts,
4 KiB boundaries, ID ordering), so the VIP must cover them. A later ADR may swap in PULP if the
in-house fabric becomes a time sink; the VIP and envs do not depend on which fabric is used.
