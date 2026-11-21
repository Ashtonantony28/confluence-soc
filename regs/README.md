# Register flow (M3, ADR 0004)

`*.rdl` here is the single source for every CSR. `make regs` regenerates `gen/`; never edit it.

| File | What | Generated into |
|---|---|---|
| `cf_sys_ctrl`, `cf_irq_ctrl`, `cf_timer`, `cf_dma_csr`, `cf_spikemesh_ctl` | new AXI4-Lite blocks | `gen/rtl/` (PeakRDL regblock) |
| `cf_mailbox` | new APB block | `gen/rtl/` |
| `nanoxl_csr`, `mlacc_csr` | audit descriptions of the existing IP maps | RAL only |
| `confluence_soc` | SoC address map (all of the above) | `gen/ral/` (UVM), `gen/c/` (C header), HTML via `make regs-html` |

Generator settings (`scripts/gen_regs.sh`): 12-bit address decode, SLVERR on unmapped words,
synchronous active-low reset `rst_n`; the UVM maps are post-processed to little-endian because
peakrdl-uvm emits `UVM_NO_ENDIAN`, which UVM 1800.2-2017 rejects. Lint waivers for generated
RTL live in `sim/lint/peakrdl.vlt`.

Checks: `make regs-check` (generated files up to date), `make test-ral` (hardware reset,
bit-bash, random read/write with mirror checks, and every unmapped word of every 4 KiB window).
`uvm_reg_access_seq` and `uvm_mem_walk_seq` need a backdoor, which `UVM_NO_DPI` removes
(ADR 0005); they arrive with the generated peek/poke binds in M7.
