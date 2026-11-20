# CLAUDE.md: conventions for Confluence

Confluence is a heterogeneous ML SoC (Vortex-V + NanoXL + SpikeMesh + MLACC on an AXI4 fabric)
and, above all, its SystemVerilog/UVM verification campaign. Plan: `docs/PLAN.md`.

## Prime directives

1. **Every change ships with a Verify command** (a `make` target, a test name, a formal task) in
   its PR description. If something cannot be verified yet, say so and name the milestone.
2. **Reference models are the authority.** IP results are checked bit-exact against the owning
   project's golden model (Vortex-V ISS / Xmlacc model, NanoXL funcsim, SpikeMesh golden). Never
   loosen a comparison to make a test pass; file a KNOWN-ISSUES entry and a waiver instead.
3. **Verification first, design modest.** New RTL (fabric, bridges, peripherals) stays simple;
   extra features sit behind parameters that default off.
4. **Upstream IPs are pinned submodules** in `third_party/`. Do not edit them here. A bug found in
   an IP is fixed in its own repo, then the submodule is bumped with a regression run.

## SystemVerilog

- One module/package per file, filename = module name. Packages in `rtl/pkg/` (RTL) and
  `vip/*/` (verification). Parameterise widths/depths; no magic numbers; `localparam` or package.
- Explicit `logic`, `default_nettype none` in RTL, fully named port connections, synchronous
  active-low reset, no latches. Verilator `-Wall` lint clean (`make lint`).
- CSR blocks are generated from SystemRDL (`regs/*.rdl`); never hand-edit `*/gen/*`.

## UVM

- Accellera UVM 1800.2-2017 (antmicro `uvm-verilator`, pinned in `scripts/setup-toolchain.sh`),
  Verilator 5.054, built with `+define+UVM_NO_DPI` (no DPI backdoor, see ADR 0005).
- VIP (`vip/`) is protocol-generic and has no knowledge of any DUT. Every agent has a config
  object with `is_active`, a monitor that publishes on an analysis port, and an SVA checker
  interface. Envs are reusable passively (vertical reuse, ADR 0002).
- Use the factory (`type_id::create`) and `uvm_config_db`; no hard-coded hierarchical paths in
  components. A test passes only if `UVM_ERROR == 0 && UVM_FATAL == 0` and every scoreboard is
  drained; the testbench prints `*** TEST PASSED ***` exactly then.

## Process

- Never commit to `main` directly; branch per milestone, one logical change per PR.
- PR description: what changed, **Verify command**, ADRs touched, milestone advanced.
- Hard-to-reverse decisions get an ADR in `docs/adr/` (immutable once Accepted; supersede).
- Commit messages explain *why*. Red CI never merges.
