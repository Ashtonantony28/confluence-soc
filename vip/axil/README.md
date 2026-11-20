# AXI4-Lite VIP

`axil_pkg` (classes parameterised by `AW`/`DW`, DW = 32 or 64), `axil_if`, `axil_checker`.

| Component | What it does |
|---|---|
| `axil_master_driver` | five independent channel threads; up to `max_outstanding` accesses; W may lead AW (independent `addr_delay` / `data_delay`); responses matched in order per direction; `put_response` per access |
| `axil_slave_driver` | reactive, memory-backed (`vip_mem`); random latency and AW/W/AR ready stalls; up to `slave_max_accept` requests per direction; in-order responses (AXI4-Lite has no IDs); SLVERR regions (writes dropped, reads return 0) |
| `axil_monitor` | rebuilds accesses: `ap_req` at each address handshake, `ap` at the response; annotates outstanding depth, latency and W-before-AW |
| `axil_coverage` | direction x response, outstanding depth, latency, AxPROT, strobe pattern (none / partial / full), W before AW |
| `axil_checker` | protocol rules below; failures go to `vip_checker_db` |

## Checker rules

| Rule | Check | Injection proving it fires |
|---|---|---|
| AXIL-R01 | AW: AWVALID held with stable AWADDR/AWPROT until AWREADY | `AXIL_INJ_AW_VALID_DROP`, `AXIL_INJ_AW_PAYLOAD_CHANGE` |
| AXIL-R02 | W: WVALID held with stable WDATA/WSTRB until WREADY | `AXIL_INJ_W_VALID_DROP`, `AXIL_INJ_W_PAYLOAD_CHANGE` |
| AXIL-R03 | B: BVALID held with stable BRESP until BREADY | `AXIL_INJ_B_VALID_DROP`, `AXIL_INJ_B_PAYLOAD_CHANGE` |
| AXIL-R04 | AR: ARVALID held with stable ARADDR/ARPROT until ARREADY | `AXIL_INJ_AR_VALID_DROP`, `AXIL_INJ_AR_PAYLOAD_CHANGE` |
| AXIL-R05 | R: RVALID held with stable RDATA/RRESP until RREADY | `AXIL_INJ_R_VALID_DROP`, `AXIL_INJ_R_PAYLOAD_CHANGE` |
| AXIL-R06 | no VALID during reset | `AXIL_INJ_VALID_IN_RESET` |
| AXIL-R07 | B only while a write whose AW and W were both accepted is unanswered | `AXIL_INJ_B_UNSOLICITED` |
| AXIL-R08 | R only while a read is unanswered | `AXIL_INJ_R_UNSOLICITED` |
| AXIL-R09 | no EXOKAY response (AXI4-Lite has no exclusive access) | `AXIL_INJ_EXOKAY` |

Deliberately **not** checked, because the specification allows it: an all-zero WSTRB, an
address that is not aligned to the bus width, READY waiting for VALID or not.

## Self-test (`vip/axil/test`)

VIP master and VIP slave on one interface, checker on the wires, an in-order memory
scoreboard on the master monitor (a read is data-checked when no write to its word was in
flight during its lifetime; the tests keep reads and writes in disjoint halves of the window,
so every read is checked). Two benches share the sources: `axil_selftest` (32-bit data) and
`axil64_selftest` (64-bit, `+define+AXIL_SELFTEST_DW=64`). `python3 sim/regress.py
sim/tests_vip_lite.yaml --filter axil` runs: smoke (incl. byte strobes), serial (one access at
a time), random (5 seeds; 3 for 64-bit), SLVERR regions, a scoreboard sanity test (the slave
corrupts read data and the scoreboard must notice) and one violation test per injection above
(the test passes only if the named rule fires).
