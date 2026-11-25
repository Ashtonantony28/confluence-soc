# Credit-link VIP

A protocol-generic agent for credit-based flit links (one flit per cycle while `valid` is high, no
ready; one credit per cycle that `credit` is high). Used on the SpikeMesh router's N/E/S/W ports
(M5), and usable on any link with the same shape (ADR 0002).

| Piece | File | What it does |
|---|---|---|
| interface | `credit_if.sv` | `valid`, `data[DW]`, `credit` |
| sender | `credit_tx_driver.svh` | gap, then wait for a credit, then one flit; publishes sent flits on `ap_sent` |
| receiver | `credit_rx_driver.svh` | `depth`-entry buffer, pops after a random delay (`rx_busy_pct`, `rx_delay_max`), one credit per pop; publishes pops on `ap_rcvd` |
| monitor | `credit_monitor.svh` | every flit, with buffer occupancy and spacing |
| coverage | `credit_coverage.svh` | occupancy (one / partial / full) x spacing |
| checker | `credit_checker.sv` | rules below |

## Checker rules

| Rule | Meaning | Self-test injection |
|---|---|---|
| CREDIT-R01 | flit sent while the sender held no credit (receiver overflow) | `CREDIT_INJ_NO_CREDIT` |
| CREDIT-R02 | more credits returned than flits sent | `CREDIT_INJ_EXTRA_CREDIT` |
| CREDIT-R03 | `valid` or `credit` high during reset | `CREDIT_INJ_VALID_IN_RESET` |

## Self-test

`vip/credit/test`: sender to receiver on one link, scoreboard on the wire and consumer views,
checker silent; each injected violation must be caught by its rule. Part of `make vip-test`
(`sim/tests_vip_lite.yaml`).
