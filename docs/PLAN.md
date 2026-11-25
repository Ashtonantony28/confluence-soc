# Confluence: a heterogeneous ML SoC and its full UVM verification campaign

*Plan v1 · 2026-11-19 · owner: Ashton Antony · status: awaiting review (plan only, nothing built)*

## 1. The one-paragraph pitch

**Confluence** puts four of your existing hardware blocks onto one chip and verifies the whole thing
the way an industry DV team would. The SoC is a **Vortex-V** RV64 core as the host CPU, the
**NanoXL** transformer accelerator, the **SpikeMesh** neuromorphic mesh and the **MLACC** int8 IP,
all joined by an **AXI4 interconnect** (crossbar, AXI-Lite and APB bridges, interrupt controller,
timer, UART, DMA-able shared memory). The SystemVerilog and UVM work is the main deliverable:
a reusable **protocol VIP library** (AXI4, AXI-Lite, APB, AXI-Stream), **block-level UVM
environments** for each IP, a **SoC-level environment** that reuses them vertically, a
**register model generated from one SystemRDL source**, **firmware-driven tests** where C code on
Vortex-V and UVM sequences cooperate, **formal proofs** of the interconnect, a **performance
verification** layer, and **coverage closure** traced back to a written verification plan.
Everything runs in the cloud container on open tools (Verilator 5.054 with Accellera UVM, cocotb,
Yosys/SymbiYosys, PeakRDL, the RISC-V GCC toolchain).

## 2. Why this project, and how it differs from MLACC-UVM

MLACC-UVM (M0 to M5 done) is an **IP-level** bench: one small DUT you wrapped yourself, three
simple agents, one RAL block, a scoreboard against one golden model. That is the shape of a
junior DV task. Confluence is the shape of a **senior / lead DV task**:

| Dimension | MLACC-UVM (done) | Confluence (this plan) |
|---|---|---|
| DUT | 1 IP, ~500 lines of wrapper | SoC: 4 IPs (tens of thousands of lines, all yours) + new interconnect RTL |
| Protocols | APB3 + valid/ready | AXI4 full (bursts, IDs, outstanding, out-of-order), AXI-Lite, APB, AXI-Stream, 48-bit NoC flits, interrupts |
| VIP | agents inside one env | a standalone, versioned **VIP library** with its own tests and protocol checkers |
| Reuse | none | **horizontal** (same VIP in every env) and **vertical** (block envs run passive inside the SoC env) |
| Registers | hand-written RAL | **SystemRDL single source** → RTL CSRs + UVM RAL + C headers + docs |
| Stimulus | UVM sequences only | UVM sequences **plus C firmware on Vortex-V**, synchronised through a mailbox |
| Reference models | one numpy model | Vortex-V ISS, NanoXL funcsim, SpikeMesh golden model, a memory model, all bridged into SV |
| Formal | SVA simulated | SymbiYosys proofs on the crossbar and bridges, plus reuse of existing NoC/LSQ proofs |
| Closure | 150 bins | code + functional coverage merged across a nightly regression, traced to a vplan |
| Performance | none | latency/bandwidth monitors and checks against NanoXL and SpikeMesh performance models |

It **reuses** MLACC-UVM directly: the APB agent and MLACC RAL become seeds of the VIP library,
and the MLACC env becomes the first block env to be run vertically inside the SoC env.

## 3. What already exists that we build on (checked in the repos today)

| Repo | Relevant state | Interface Confluence connects to |
|---|---|---|
| `vortex-v` (main `6bb7000`) | OoO RV64 core, 2-wide, Xmlacc with 2 units, `vortex_soc` with 16 KiB RAM, MMIO UART/LEDs/cycle, SYNC_MEM block-RAM mode, ISS lockstep co-sim, crv, yosys formal on LSQ | simple instruction/data memory ports. **No standard bus yet**, so Confluence adds an AXI4 master bridge. |
| `nanoxl-accelerator` (`8e1e12a`) | `nanoxl_top`, AXI4-Lite CSR slave (12-bit), 3 AXI4 128-bit masters (command fetch, 2 DMA channels), irq; bit-exact vs golden in Verilator; Vivado shell `nanoxl_axi_wrap.v` | already AXI. Plugs straight into the crossbar. |
| `spikemesh` (`5517a40`) | 2×2 mesh of LIF neurocores, 48-bit flit host in/out, step/step_done, err/drop_cnt; `fpga/rtl/axis_bridge.sv` for AXI-Stream; golden model; formal on router + tick controller | AXI-Stream bridge + a new AXI-Lite control wrapper (step, status, counters). |
| `mlacc-uvm` (`2d90781`) | MLACC IP (APB3 + streams), pyuvm and SV-UVM benches, NanoXL requantizer as second DUT | APB slave behind the AXI→APB bridge; its stream ports get a small AXI-Stream shim. |
| `anvil-compiler` | PyTorch → Vortex-V backend, bit-exact on all 6 RTL core configs | generates the firmware workloads for the SoC scenarios. |
| `neuroflight-fc` | int8 policy whose requantize matches Vortex-V `rqs` bit-for-bit; already a Vortex-V workload (`verif/workloads/neuroflight`) | "flight computer" scenario on the SoC. |
| `macromind` | RL macro placement through OpenROAD; already places SpikeMesh | optional back-end milestone: place Confluence blocks, feed a Yosys netlist back for gate-level sim. |
| `sentinel-cam` | edge camera, models in ST Edge AI / TFLite (MCU, no RTL) | weak link, stated honestly: its frame pipeline shape is used as a "camera frames over AXI-Stream" traffic profile. No shared RTL. |

## 4. Architecture

### 4.1 The SoC (design side, kept deliberately modest)

```
                         +-----------------------------------------------+
   +-----------+  AXI4   |              confluence_xbar (AXI4)          |
   | Vortex-V  |-------->| M0 cpu_i (RO)                                 |
   | OoO core  |-------->| M1 cpu_d                                      |
   | + AXI     |         | M2 nanoxl_mf (RO)   M3 nanoxl_md0  M4 md1     |
   | bridge    |         | M5 sys_dma                                    |
   +-----------+         |                                               |
         ^ irq           | S0 boot ROM      S1 SRAM (multi-bank, 256 KiB)|
   +-----------+         | S2 DRAM model (latency/bw configurable)       |
   | irq ctrl  |         | S3 AXI→AXI-Lite: NanoXL CSR, SpikeMesh ctl,   |
   | (PLIC-lite)|        |    sys_ctrl, irq ctrl, timer, DMA CSR         |
   +-----------+         | S4 AXI→APB: MLACC CSR, UART, mailbox          |
                         +-----------------------------------------------+
   NanoXL <-> crossbar (CSR + 3 masters) · SpikeMesh <-> sys_dma over AXI-Stream (flits in/out)
   MLACC cmd/rsp streams <-> sys_dma channel 2 over AXI-Stream
```

New RTL written in this project (each one module per file, parameterised, Verilator `-Wall` clean,
following the Vortex-V CLAUDE.md conventions):

1. `confluence_xbar`: parameterised N×M AXI4 crossbar, ID-width extension per master, round-robin
   arbitration, decode errors to a default slave (DECERR), configurable outstanding depth.
2. `axi2axil`, `axi2apb` bridges (burst splitting, error mapping).
3. `vortex_axi_bridge`: Vortex-V instruction/data ports → AXI4 masters (single-beat reads, writes
   with strobes; uncached first, line refills later behind a parameter that defaults off).
4. `sys_dma`: 3-channel AXI4 ↔ AXI-Stream DMA (descriptor-based) feeding SpikeMesh and MLACC.
5. `irq_ctrl` (PLIC-lite: priorities, pending, claim/complete), `timer`, `mailbox`
   (test-bench ↔ firmware handshake), `sys_ctrl` (resets, IDs, scratch, sim-exit register).
6. `spikemesh_axil_ctl`: AXI-Lite wrapper for step/step_done/err/drop_cnt/drained.
7. All CSR blocks generated from **SystemRDL** by PeakRDL (`peakrdl-regblock`), never hand-written.

Single clock in the base configuration; a CDC configuration is a user decision (§9, D6).

### 4.2 The verification architecture

```
confluence_soc_test (+ firmware image chosen by the test)
└─ soc_env
   ├─ vip: axi4_agent ×6 (passive monitors on every crossbar master port)
   │       axi4_agent ×5 (passive on every slave port)        ← one VIP, many instances
   ├─ nanoxl_env      (vertical reuse, passive)  ← same env that runs active in block tests
   ├─ spikemesh_env   (vertical reuse, passive)
   ├─ mlacc_env       (vertical reuse, passive)  ← ported from mlacc-uvm
   ├─ xbar_env        (vertical reuse, passive)
   ├─ cpu_monitor     retire trace → Vortex-V ISS lockstep (existing co-sim, wrapped as a UVM component)
   ├─ soc_ral         generated from SystemRDL (whole address map, all IPs)
   ├─ mem_scoreboard  end-to-end coherent view of SRAM/DRAM: every AXI write applied, every read checked
   ├─ irq_monitor     every interrupt edge checked against RAL-predicted pending state
   ├─ perf_monitor    per-port latency histograms, bandwidth, arbitration fairness
   ├─ fw_agent        mailbox + UART monitor; lets a sequence wait on / signal firmware
   ├─ coverage        SoC-level covergroups (concurrency crosses, error responses, irq races)
   └─ virtual_sequencer  owns pointers to every sub-sequencer
```

Block-level environments (each one runs **active** on its own, then **passive** in the SoC):

| Env | DUT | Active stimulus | Checker / reference |
|---|---|---|---|
| `vip_selftest` | VIP master ↔ VIP slave loopback | all AXI/APB/AXI-S features | protocol SVA + transaction compare |
| `xbar_env` | `confluence_xbar` + bridges | N master agents, M reactive slave agents (random latency, OOO responses, errors) | memory-model scoreboard, ID-ordering checker, DECERR checker |
| `nanoxl_env` | `nanoxl_top` | AXI-Lite RAL programming, command-ring sequences, 3 reactive AXI memory slaves with backpressure | NanoXL golden/funcsim results (pre-computed images + DPI-C compare) |
| `spikemesh_env` | `spikemesh_top` (and a router-level sub-env) | config + spike flit sequences, step control, congestion storms | SpikeMesh golden raster; per-flow ordering, no drop/duplicate, routing correctness |
| `mlacc_env` | MLACC (existing) | ported from `mlacc-uvm/sv_uvm` | Vortex-V golden model (existing) |
| `cpu_axi_env` | Vortex-V + `vortex_axi_bridge` | riscv-dv / crv instruction streams, random memory latency | ISS lockstep (existing) + AXI protocol checker |

### 4.3 Supporting infrastructure

- **VIP library (`vip/`)**: SV packages per protocol: config object, sequence item with constraints,
  driver, monitor, sequencer, reactive slave with a pluggable memory backend, coverage, and an
  SVA checker interface bound into every instance. Versioned on its own so other repos
  (NanoXL, SpikeMesh, MLACC-UVM) can pull it as a submodule.
- **Register flow (`regs/`)**: `*.rdl` → PeakRDL → `rtl/gen/*_csr.sv`, `tb/gen/*_ral_pkg.sv`,
  `sw/include/*.h`, `docs/regs.html`. CI fails if generated files are stale. The existing NanoXL
  and MLACC CSR maps are re-described in RDL and checked register-by-register against the RTL
  that already exists (a nice "spec vs RTL" audit in itself).
- **HW/SW co-verification (`sw/`)**: a bare-metal C runtime extended from `vortex-v/sw`; tests are
  pairs (`test_x.c`, `test_x_seq.sv`). Firmware writes the mailbox; the `fw_agent` turns writes
  into UVM events; sequences can wait on firmware, inject traffic, and release it. Pass/fail is
  the `sys_ctrl` exit register plus every scoreboard being empty and clean.
- **Reference-model bridge**: DPI-C to C/C++ where a model is small (memory model, ISS already in
  C++/Python glue), pre-computed golden images for the heavy Python models (NanoXL funcsim,
  SpikeMesh golden), produced by committed, seeded scripts. Choice confirmed in D4.
- **Regression system (`sim/`)**: one Python runner: test list YAML with seeds and weights,
  parallel builds per configuration, log triage (first error signature, auto-bucketing of
  failures), re-run-with-waves on failure, coverage merge, HTML report.
- **Verification plan (`docs/vplan.yaml`)**: every feature → requirement IDs → covergroup bins,
  assertions or tests. The closure report is generated from it, so "what is covered" is always
  traceable to "what was promised".

## 5. Toolchain (cloud only)

| Need | Tool | Status / note |
|---|---|---|
| SV-UVM simulation | Verilator **5.054** + Accellera UVM (antmicro `uvm-verilator`, pinned like MLACC-UVM) + z3 for `randomize` | proven by MLACC-UVM M5. Built from source per fresh container (~15 min), so M0 caches a prebuilt tarball in project files. |
| Python-side models, quick benches | cocotb 2.1 + pyuvm 5.0 | proven |
| Lint | Verilator `-Wall`, plus Verible (pip/GitHub release) for style | Verible is new, low risk |
| Code coverage | Verilator `--coverage` (line, toggle, branch, expression) + `verilator_coverage` merge/annotate | standard |
| Functional coverage | SV `covergroup` (used in MLACC-UVM SV bench); M0 confirms how Verilator 5.054 reports bin hits. Fallback: a small coverage library in SV that writes a JSON database (the pyuvm bench already proved the approach). |
| Formal | SymbiYosys + Yosys + a solver (boolector/yices) via the OSS CAD Suite release tarball | earlier threads had only `yosys sat`; the project now has full network access, so this should install. Fallback: Yosys `sat -tempinduct` as Vortex-V and SpikeMesh already use. |
| Registers | PeakRDL (`peakrdl-regblock`, `peakrdl-uvm`, `peakrdl-cheader`, `peakrdl-html`) | pip, pure Python |
| Firmware | `riscv64-unknown-elf-gcc` (already in Vortex-V's setup script) | proven |
| Random instruction streams | riscv-dv (pip install from GitHub) | new; optional in M6 |
| Gate-level (stretch) | Yosys synth of one block → Verilator netlist sim | Vortex-V hit "yosys can't parse `import pkg::*`"; needs sv2v or yosys-slang (D8) |

No commercial simulators, no Vivado, no board. Nothing in this plan needs your computer.

## 6. Milestones

Each milestone ends with CI green, a merged PR with a **Verify command** (your repo convention),
an updated `STATUS.md`, and a bundle backup in project files. Effort is in "thread-days" of
container work, a rough guide only.

| M | Deliverable | Exit criteria (Verify) | Effort |
|---|---|---|---|
| **M0 Foundations** | Repo, CLAUDE.md, ADRs 0001-0005 (bus, reuse strategy, reference-model bridge, register flow, toolchain); toolchain script + cached Verilator tarball; submodules pinned to vortex-v / nanoxl / spikemesh / mlacc-uvm; Verilator spike: compile all 4 IPs together, confirm covergroup reporting, measure compile time | `make lint` clean; `make smoke-build` compiles all IPs in one Verilator model; ADRs Accepted | 1 |
| **M1 VIP library** | AXI4 full (INCR/WRAP/FIXED, narrow + unaligned, IDs, ≥16 outstanding, OOO read data, interleaved responses, all resp codes), AXI-Lite, APB4 (from MLACC), AXI-Stream (tkeep/tlast/tuser); reactive slaves with memory backend; SVA protocol checkers (ARM AMBA rules); per-VIP coverage | `make vip-test`: loopback tests per protocol, protocol checkers catch ≥10 injected protocol violations each | 3 |
| **M2 Interconnect** | `confluence_xbar`, `axi2axil`, `axi2apb`, default slave; `xbar_env` with N masters × M slaves; SymbiYosys proofs: no lost/duplicate transactions, same-ID ordering, DECERR for unmapped, handshake stability, bounded liveness under fair slaves | `make test-xbar` 50 seeds green; `make formal-xbar` all properties PASS (k-induction) | 3 |
| **M3 Register flow** | SystemRDL for every CSR block; generated RTL CSRs (sys_ctrl, irq_ctrl, timer, mailbox, DMA, SpikeMesh ctl); generated SoC RAL; RDL descriptions of existing NanoXL + MLACC maps audited against their RTL; built-in `uvm_reg_hw_reset_seq`, `bit_bash`, `access`, `mem_walk` | `make regs-check` (generated files up to date); `make test-ral` all built-in sequences pass on every block | 2 |
| **M4 NanoXL block env** | `nanoxl_env`: RAL + command-ring sequences, 3 reactive AXI memories with random latency/backpressure/errors, scoreboard vs NanoXL golden images; covergroups over command types, DMA shapes, ring wrap, semaphore waits | `make test-nanoxl` 30 seeds green on tiny W8A8 and W4A8 models, bit-exact | 3 |
| **M5 SpikeMesh block env** | router-level env (5-port agents, routing/ordering/no-loss scoreboard, congestion and backpressure storms) + chip env (config flits, spike injection, step protocol, golden raster compare); covergroups over XY routes, port contention, FIFO full, quiescence timing | `make test-spikemesh` green; trained-net raster identical to golden on ≥32 samples under random backpressure | 3 |
| **M6 CPU on AXI** | `vortex_axi_bridge`; `cpu_axi_env` running crv/riscv-dv streams with random memory latency, ISS lockstep wrapped as a UVM checker; existing riscv-tests through AXI | `make test-cpu-axi`: riscv-tests + 20 random streams green in lockstep | 2 |
| **M7 SoC integration** | `confluence_soc` top, `sys_dma`, `irq_ctrl`, boot ROM, firmware runtime + mailbox; `soc_env` with vertical reuse of all block envs (passive), `mem_scoreboard`, `irq_monitor`, `fw_agent` | `make test-soc-smoke`: firmware boots, reads every IP ID through the RAL-checked path, each block scoreboard sees and checks traffic | 3 |
| **M8 System scenarios** | Firmware + sequence pairs: (a) anvil-compiled MLP on Vortex-V Xmlacc, (b) a NanoXL transformer layer launched by firmware, (c) SpikeMesh inference fed by `sys_dma`, (d) NeuroFlight policy loop with timer interrupts, (e) all accelerators concurrently with UVM background traffic, (f) error injection (SLVERR/DECERR, DMA faults, NoC overflow) and recovery, (g) reset mid-traffic | `make test-scenarios`: all scenarios bit-exact vs their golden models; error scenarios end with correct status and recovery | 4 |
| **M9 Performance verification** | `perf_monitor`: per-port latency histograms, bandwidth, fairness; perf assertions (e.g. no master starved > N cycles); NanoXL decode tok/s and SpikeMesh cycles/sample measured under SoC contention vs their standalone models | `make perf-report`: numbers within stated tolerance of each model, or a documented, explained gap | 2 |
| **M10 Coverage closure** | vplan.yaml complete; code coverage (line/branch/toggle) on all new RTL; functional coverage on all envs; hole analysis; directed tests and constraint tuning to close; waivers reviewed and justified; generated closure report | `make closure`: ≥95% functional bins, ≥90% line/branch on new RTL, every waiver has a reason; report published | 3 |
| **M11 Bug hunting + sign-off** | SoC mutation campaign (≥30 injected bugs across xbar, bridges, DMA, irq, CSRs); a "found bugs" log of real findings in your existing IPs; nightly regression in CI; README + results dashboard (artifact) + write-up | every mutant killed or explained; CI nightly green; sign-off checklist complete | 2 |
| **S1 stretch: CDC** | SpikeMesh on its own clock; async FIFOs; CDC structural lint + formal on the synchronisers; UVM multi-clock agents | gated on D6 | 2 |
| **S2 stretch: gate-level** | Yosys netlist of `confluence_xbar` (+ optionally a MacroMind-placed block) re-run under the same UVM test list | gated on D8 | 2 |
| **S3 stretch: coverage-directed stimulus** | a bandit/RL agent that tunes sequence knobs to hit coverage holes faster than random seeds (shared ideas with MacroMind) | measured speed-up vs random on M10 holes | 2 |

Core path M0 to M11: about **31 thread-days**. Natural release points to stop at if usage runs
short: after **M2** (a VIP library plus a formally proven interconnect is already a strong
portfolio piece), after **M5** (three block-level envs), after **M8** (working, verified SoC).

## 7. How each piece links back to your projects

- **Vortex-V**: gets an AXI bridge and becomes a real SoC host. Bugs found by AXI timing
  randomisation and ISS lockstep under memory latency go back as Vortex-V PRs (as VTX-RQS-001 did).
  Reuses its ISS co-sim, crv generator, riscv-tests and C runtime. Keep its `CORE_CONFIGS` /
  `cosim_lockstep` APIs stable (anvil depends on them).
- **NanoXL**: first time it runs against a non-ideal memory system (latency, backpressure, slave
  errors, contention). Its command-processor and DMA corners are the most likely place to find
  real bugs. Its modelled 333 tok/s gets an independent SoC-level measurement.
- **SpikeMesh**: its NoC gets a proper transaction-level UVM bench (its tests today are system
  rasters and formal on one router). Audit items in `docs/AUDIT-1.md` (sparse images need zeroed
  SRAM, R-STDP eligibility memory has no reset) become directed tests.
- **MLACC-UVM**: the APB agent, RAL and env are ported into the VIP library and reused
  vertically. Its scoreboard stays the reference for Xmlacc.
- **Anvil**: becomes the firmware generator for scenario (a); a PyTorch model compiled by Anvil
  runs on the SoC and is checked bit-exact.
- **NeuroFlight**: scenario (d) runs the policy loop on Vortex-V with timer interrupts, the
  closest thing to the "flight computer" story without a board. Its requant already matches
  `rqs` bit-for-bit.
- **MacroMind**: optional S2 link (placement of a Confluence block, netlist back into simulation)
  and S3 shares the RL-for-EDA idea.
- **Sentinel-cam**: no shared RTL. Only a traffic profile (camera frames over AXI-Stream into
  NanoXL). Listed for honesty, not as a real dependency.

## 8. Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Verilator UVM gaps (no DPI backdoor with `UVM_NO_DPI`, partial `uvm_reg` features, constraint solver speed, covergroup reporting) | High | Medium | M0 spike confirms each feature before design depends on it; frontdoor-only RAL (backdoor via generated `bind`-ed peek/poke tasks if needed); keep constraints simple and solve heavy ones in `pre_randomize` |
| Compile time / memory of one Verilator model with OoO core + NanoXL + SpikeMesh + UVM | High | Medium | small parameter configs at SoC level (NanoXL N=4, SpikeMesh 2×2 small neuron count, Vortex-V WIDTH=1); separate builds per configuration; `-j` and `--hierarchical` builds; most stimulus at block level |
| Toolchain rebuild every fresh container (~15 min Verilator, OSS CAD Suite download) | Certain | Low | cached tarball in project files, setup script, CI cache |
| Bridging Python golden models into SV | Medium | Medium | pre-computed seeded golden images (committed generators) + DPI-C for small models (D4) |
| Scope creep in the design side (cache, coherence, MMU) | Medium | High | design kept deliberately simple; any extra feature is behind a parameter defaulting off; this is a verification project first |
| Upstream repos change under the pinned submodules | Medium | Low | pin by SHA, bump on purpose with a regression run |
| Real bugs found in existing IPs block SoC progress | Medium | Low (this is the point) | log in KNOWN-ISSUES with a waiver mechanism like MLACC-UVM, fix upstream in the owning repo |
| SymbiYosys install fails | Low | Low | fall back to Yosys `sat -tempinduct` already used in two repos |
| Usage limits / long runs | Medium | Medium | small milestones, bundle after each, release points after M2 / M5 / M8 |

## 9. Decisions for you

Recommended option first. I would proceed on the recommendations unless you say otherwise.

- **D1 Interconnect source.** (a) **Write our own AXI crossbar and bridges** (recommended: more
  SV design experience and real bugs for the bench to find, with formal as the safety net), or
  (b) use the open PULP `axi` library and spend the effort only on verification.
- **D2 SoC scope.** (a) **All four IPs**, SpikeMesh entering at M5/M7 (recommended), (b) Vortex-V +
  NanoXL + MLACC only, SpikeMesh dropped (saves about 4 thread-days).
- **D3 Bench language.** (a) **SV-UVM primary**, pyuvm only for model glue (recommended: the
  project's purpose is SV/UVM, and Verilator 5.054 is proven), or (b) keep both benches in parallel
  like MLACC-UVM (much more work, little extra signal).
- **D4 Golden models.** (a) **Pre-computed seeded golden images + DPI-C for small models**
  (recommended), or (b) embed Python in the simulator through DPI (one language for models,
  but fragile and slow).
- **D5 Repository.** (a) **New repo** `Ashtonantony28/confluence-soc` with the IPs as pinned
  submodules (recommended). Threads cannot create repos from the cloud container, so you would
  create an empty repo with that name, or (b) grow `mlacc-uvm` into it (blurs two projects).
- **D6 Clock domains.** (a) **Single clock for the core path, CDC as stretch S1** (recommended), or
  (b) multi-clock from day one.
- **D7 Pace.** (a) **Milestone by milestone with a short status after each**, stopping at a release
  point if usage runs low (recommended), or (b) run straight through to M11.
- **D8 Gate-level stretch tooling.** if S2 is wanted: allow installing `sv2v` or `yosys-slang`
  (both open source, cloud-installable). Only needed for S2.

## 10. What you need to do to start

1. Review this plan and answer D1-D8 (or just say "go with the recommendations").
2. Create an empty GitHub repo `Ashtonantony28/confluence-soc` (if D5a) so it can be pushed.

Nothing needs your computer, a board, Vivado or a commercial simulator.
