# 0002. Protocol VIP library and vertical reuse of block environments

- **Status:** Accepted
- **Date:** 2026-11-19

## Context

Four IPs plus the fabric each need a bench, and the SoC needs one too. Writing ad-hoc agents per
bench (as MLACC-UVM did) duplicates protocol code and makes SoC-level checking start from zero.

## Decision

We will keep a DUT-agnostic VIP library in `vip/` (one SV package per protocol: AXI4, AXI4-Lite,
APB4, AXI-Stream, plus `vip_common`). Every block environment is built from VIP agents and is
written so that, with all agents `UVM_PASSIVE`, it still checks its block from monitored traffic.
The SoC environment instantiates the block environments passively (vertical reuse) and adds only
system-level checkers. SystemVerilog UVM is the primary language (plan decision D3); pyuvm is used
only for glue around Python golden models.

## Consequences

Block scoreboards must be driven from monitors, never from drivers or sequences. VIP must be
configurable enough (widths, ID widths, outstanding limits) for every instance. Each VIP gets
its own self-test so a VIP bug is not mistaken for a DUT bug.
