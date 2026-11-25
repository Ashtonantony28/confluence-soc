# NanoXL block environment (M4)

`nanoxl_top` (N=8, L=4, default buffers) runs real compiled programs of the tiny nanoGPT
model. Expected results come from NanoXL's integer golden model (`nanoxl.golden`), not from
the RTL.

**Golden traces** (`scripts/gen_nanoxl_trace.py`, `sim/gen_nanoxl_traces.sh`): NanoXL's own host
driver (`nanoxl.driver.NanoXL`) runs on a recording backend built on its `SimBackend`
(funcsim). The generator asserts that every step's logits equal `Golden.forward`, that the
dumped KV cache equals the golden cache, and, for the full model, that the tokens equal
`golden_ref.json`. It records the driver's view: memory loads, CSR writes, CSR reads (replayed as
"poll until golden value") and every device-written byte.

**Env** (`nanoxl_env_pkg.sv`): an AXI4-Lite VIP master drives the CSRs through the RAL generated
from `regs/nanoxl_csr.rdl` (M3). Three reactive AXI4 VIP slaves (fetch, DMA0, DMA1) share one
memory with per-test latency and backpressure. Protocol checkers sit on all four ports.
Coverage: command opcodes seen on the fetch port, DMA burst shapes, and ring wrap.

| Test | Memory profile |
|---|---|
| `nanoxl_fast_test` | 1-cycle latency, no backpressure |
| `nanoxl_random_test` | random 10-40 % busy, latency up to 8-40 cycles (per seed) |
| `nanoxl_slow_mem_test` | DDR-like 40-80 cycle latency |
| `nanoxl_corrupt_test` | DMA reads flip bits; passes only if the golden compare flags it |

Traces: `{w8a8,w4a8}_l1` (1 layer, 2-token prefill, 1 decode), `_l2_wrap` (2 layers, ring
shrunk to 700 words so programs wrap), `_full` (all 4 layers, 16-token prefill, 8 decodes).

Known coverage holes, for M10: opcodes the compiler never emits for this model (IRQ,
ATTN_TILE, GELU and LUT_LOAD on W8A8), and DMA bursts longer than 128 beats.
