# 0003. Golden models reach SystemVerilog as pre-computed images plus DPI-C

- **Status:** Accepted
- **Date:** 2026-11-19

## Context

The authorities are Python models (NanoXL funcsim/golden, SpikeMesh golden, Vortex-V Xmlacc model)
and the Vortex-V ISS. Embedding Python in Verilator through DPI is fragile and slow; re-writing
every model in SV duplicates them and risks drift.

## Decision

Heavy Python models produce seeded, committed-generator **golden images** (memory images, spike
rasters, expected result tables) before simulation; SV scoreboards load and compare them. Small,
per-transaction models (memory model, Xmlacc ops, address decode) are written in SV or C via DPI-C.
Generators live in `scripts/golden/` and are deterministic from a seed.

## Consequences

Scenarios must be expressible as "program + input image → expected image". Truly reactive
checking of a Python model (cycle by cycle) is out of scope. Fixture regeneration is a reviewed
change, as in the upstream repos.
