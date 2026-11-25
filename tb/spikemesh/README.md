# SpikeMesh chip environment (M5)

`spikemesh_top` (2x2 mesh, 256 neurons and 256 axons per core, W=8, LANES=8) runs the trained
256-256-10 N-MNIST network and random 64-48-16 networks. Expected results come from SpikeMesh's
golden chip model, not from the RTL.

**Golden traces** (`scripts/gen_spikemesh_trace.py`, `sim/gen_spikemesh_traces.sh`): SpikeMesh's
own host API (`host.api.SpikeMeshHost`) runs on a recording backend built on its `GoldenBackend`,
which drives the golden chip purely through 48-bit flits. Before a trace is written, every
sample's hidden and output rasters must equal `compiler.netir.reference_run`. The trace holds
every host-to-chip flit, every STEP and sync point, and the raw chip-to-host flits of each step
(compared as a multiset, since arrival order between sources is not part of the contract).

**Env** (`spikemesh_env_pkg.sv`): an AXI4-Stream VIP master sends flits into `host_in`; an
AXI4-Stream VIP slave with random `tready` takes `host_out`. The step protocol (pulse `step`,
wait `step_done`, then `drained` with the host FIFO empty) is driven through
`spikemesh_ctrl_if`. Protocol checkers sit on both streams; `err` and `drop_cnt` must stay 0.
Coverage: host spikes by source core and parity, step length and spike count, input flit types.

| Test | Profile |
|---|---|
| `spikemesh_fast_test` | host always ready, flits back to back |
| `spikemesh_backpressure_test` | random 20-70 % host backpressure, 0-30 % input gaps (per seed) |
| `spikemesh_corrupt_test` | one weight bit flipped in every 97th weight write; passes only if the golden compare flags it |

Traces: `trained_{0,8,16,24}_8` (fixture samples 0-31, 8 per trace, net reloaded per trace) and
`rand_{1,2,3}` (random networks on random events). `make test-spikemesh` builds them.

This env found CF-SPIKE-001 (docs/BUGS.md): the golden model tagged host-bound spikes with the
wrong parity, which SpikeMesh's own tests could not see because they compared decoded rasters.
