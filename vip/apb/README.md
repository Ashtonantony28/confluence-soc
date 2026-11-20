# APB4 VIP

`apb_pkg` (classes parameterised by `AW`/`DW`, DW = 8, 16 or 32), `apb_if`, `apb_checker`.
Ports the ideas of the MLACC-UVM APB agent (blocking driver that fills in the item before
`item_done`, monitor on the completing ACCESS cycle, `uvm_reg` adapter) and adds APB4 PPROT /
PSTRB, wait states, error responses, a reactive slave, coverage and a protocol checker.

| Component | What it does |
|---|---|
| `apb_master_driver` | IDLE (`item.idle` cycles) -> SETUP -> ACCESS until PREADY; back-to-back transfers when `idle == 0` (PSEL stays high); read data, PSLVERR and wait-state count written back into the item |
| `apb_slave_driver` | reactive, memory-backed (`vip_mem`); random wait states picked at SETUP (`slave_wait_pct`, `slave_max_wait`); writes honour PSTRB and commit at the completing edge; PSLVERR regions (writes dropped, reads return 0) |
| `apb_monitor` | one item per completed transfer on `ap`, with wait states and back-to-back flag |
| `apb_coverage` | direction x PSLVERR, wait states, back-to-back, PPROT, strobe pattern |
| `apb_reg_adapter` | `uvm_reg` <-> `apb_item` (byte enables -> PSTRB, PSLVERR -> `UVM_NOT_OK`); use with a `uvm_reg_predictor` on `mon.ap` |
| `apb_checker` | protocol rules below; failures go to `vip_checker_db` |

## Checker rules

| Rule | Check | Injection proving it fires |
|---|---|---|
| APB-R01 | ACCESS (PSEL && PENABLE) only after SETUP or a wait-state ACCESS: PENABLE never rises without a SETUP cycle | `APB_INJ_ENABLE_NO_SETUP` |
| APB-R02 | SETUP lasts one cycle and is always followed by ACCESS | `APB_INJ_SETUP_NO_ACCESS` |
| APB-R03 | during a wait state (PREADY low) the transfer stays in ACCESS (PSEL, PENABLE high) with stable PADDR/PWRITE/PPROT (+ PWDATA/PSTRB on writes) | `APB_INJ_ADDR_CHANGE_WAIT`, `APB_INJ_SEL_DROP_WAIT` |
| APB-R04 | PADDR/PWRITE/PPROT (+ PWDATA/PSTRB on writes) unchanged from SETUP to ACCESS | `APB_INJ_SETUP_CHANGE` |
| APB-R05 | PENABLE low in the cycle after the completing ACCESS | `APB_INJ_ENABLE_STUCK` |
| APB-R06 | PENABLE only high while PSEL is high | `APB_INJ_ENABLE_NO_SEL` |
| APB-R07 | PSTRB all zero on reads (APB4) | `APB_INJ_READ_STRB` |
| APB-R08 | no PSEL / PENABLE during reset | `APB_INJ_SEL_IN_RESET` |

Deliberately **not** checked: PSLVERR / PRDATA outside the completing ACCESS cycle (the spec
gives them no meaning there), PWDATA / PSTRB stability on reads, PREADY outside ACCESS.

## Self-test (`vip/apb/test`)

VIP master and VIP slave on one interface, checker on the wires, a memory scoreboard on the
master monitor (APB is sequential, so every read is predicted exactly). `python3
sim/regress.py sim/tests_vip_lite.yaml --filter apb` runs: smoke (incl. byte strobes), random
(5 seeds), PSLVERR regions, a scoreboard sanity test (the slave corrupts read data and the
scoreboard must notice), a `uvm_reg` frontdoor test through `apb_reg_adapter` + predictor
(including a register in a PSLVERR region) and one violation test per injection above.
