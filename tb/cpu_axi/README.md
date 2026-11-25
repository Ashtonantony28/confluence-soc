# Vortex-V CPU-on-AXI environment (M6)

Vortex-V's out-of-order core (`vortex_ooo_core`, default parameters, and the two-wide build
`cpu_axi_w2`) fetches and loads over AXI4 through `vortex_axi_bridge` (ADR 0006: the core runs on a
gated clock and gets one edge per completed set of bus accesses, so it sees exactly the
zero-latency memory it was verified against). The memory is a reactive AXI4 VIP slave with
random latency and backpressure; an AXI4 protocol checker watches the bus.

**Golden traces** (`scripts/gen_cpu_trace.py`, `sim/gen_cpu_traces.sh`): each program runs on
Vortex-V's golden ISS (`model/iss/rv64i.py`), which must halt with tohost PASS. The trace holds
the memory image, every ISS retire (pc, writeback valid, rd, value), the expected tohost and
mlstat.SAT, and for random programs the final data region. Programs: all 65 riscv-tests that
Vortex-V's conformance suite runs (rv64ui + rv64um, built with riscv64-unknown-elf-gcc) and
25 constrained-random RV64IM + Xmlacc streams from Vortex-V's `verif/crv/rvgen.py` (20 default
mix, 5 Xmlacc-heavy).

**Checking**: `cpu_retire_mon` samples the core's registered retire ports once per core edge
(both slots on the two-wide core); `cpu_lockstep_checker` compares each retire, in order, with the
ISS. A retire after the ISS halted (before the first idle core cycle) is an error, as in
Vortex-V's own cocotb co-sim. At the end: tohost, mlstat.SAT, the data region byte for byte, and
the bridge's `err` flag. This is lockstep against a recorded ISS run; with `UVM_NO_DPI` (ADR 0005)
the env cannot call the Python ISS live, and the programs are deterministic.

| Test | Memory profile |
|---|---|
| `cpu_fast_test` | 1-cycle latency, always ready |
| `cpu_random_test` | 0-40 % busy, latency 1-4 up to +16 (per seed) |
| `cpu_slow_test` | 20 % busy, 20-60 cycle latency |
| `cpu_corrupt_test` | read beats flip bits; passes only if the lockstep compare flags it |

`make test-cpu-axi` runs 133 runs (riscv-tests, 20 random streams at two timings, Xmlacc
streams, slow memory, the two-wide core, the corruption check). `scripts/mutate_cpu_bridge.py`
runs the bridge mutants (docs/MUTATION.md).

riscv-dv (plan section 5, optional for M6) is not used: Vortex-V's own generator already covers
every instruction class the core implements, and its programs are known to terminate on the ISS.
