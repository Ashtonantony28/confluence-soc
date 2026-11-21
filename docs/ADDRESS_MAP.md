# Confluence address map

CSR blocks are generated from `regs/confluence_soc.rdl` (ADR 0004); this page adds the memories,
which are not registers. Every CSR block decodes its whole 4 KiB window, so nothing aliases behind
the bridges, and an unmapped word answers SLVERR (NanoXL keeps its documented OKAY / read-0).

| Base | Size | Target | Path |
|---|---|---|---|
| 0x0000_0000 | 64 KiB | boot ROM | crossbar S0 |
| 0x1000_0000 | 256 KiB | SRAM (multi-bank) | crossbar S1 |
| 0x4000_0000 | 4 KiB | NanoXL CSRs (`nanoxl_csr`) | S3, AXI4-Lite |
| 0x4000_1000 | 4 KiB | SpikeMesh control (`cf_spikemesh_ctl`) | S3 |
| 0x4000_2000 | 4 KiB | system control (`cf_sys_ctrl`) | S3 |
| 0x4000_3000 | 4 KiB | interrupt controller (`cf_irq_ctrl`) | S3 |
| 0x4000_4000 | 4 KiB | machine timer (`cf_timer`) | S3 |
| 0x4000_5000 | 4 KiB | system DMA (`cf_dma_csr`) | S3 |
| 0x5000_0000 | 4 KiB | MLACC CSRs (`mlacc_csr`) | S4, APB |
| 0x5000_1000 | 4 KiB | UART (no CSR model yet) | S4 |
| 0x5000_2000 | 4 KiB | testbench mailbox (`cf_mailbox`) | S4 |
| 0x8000_0000 | configurable | DRAM model | crossbar S2 |

Anything else decodes to the crossbar default slave (DECERR).
