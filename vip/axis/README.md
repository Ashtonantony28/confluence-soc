# AXI4-Stream VIP

`axis_pkg` (classes parameterised by `DW`/`IDW`/`DESTW`/`UW`), `axis_if`, `axis_checker`.
TID, TDEST and TUSER are optional: a width of 0 means the signal is absent (the wire is one
bit, driven 0 and ignored). TUSER is `UW` bits per transfer. TSTRB and TWAKEUP are not
modelled: every byte is a data byte or a null byte, per TKEEP.

| Component | What it does |
|---|---|
| `axis_item` | one packet: transfers as on the wires (TDATA, TKEEP, TUSER per transfer) plus TID/TDEST; `len` data bytes; PACKED (continuous aligned) or SPARSE (null bytes and null transfers anywhere) TKEEP; `diff()` compares packets on kept lanes |
| `axis_master_driver` | sends packets with random gaps before (`gap_before`) and inside (`beat_gap_pct`) a packet, back-to-back otherwise; publishes each packet on `ap_sent` when its TLAST is accepted |
| `axis_slave_driver` | random TREADY backpressure (`slave_ready_busy_pct`, independent of TVALID); rebuilds accepted packets and publishes them on `ap_rcvd` (consumer view) |
| `axis_packer` | packet rebuilder shared by monitor and slave; one open packet per TID/TDEST stream, so interleaved streams are handled |
| `axis_monitor` | one item per packet on `ap` at TLAST, annotated with stall cycles, idle gaps and interleaving |
| `axis_coverage` | transfers per packet x stalls, whole / partial last transfer, null bytes, gaps, TUSER, TID / TDEST |
| `axis_checker` | protocol rules below; failures go to `vip_checker_db` |

## Checker rules

| Rule | Check | Injection proving it fires |
|---|---|---|
| AXIS-R01 | TVALID held until TREADY | `AXIS_INJ_VALID_DROP` |
| AXIS-R02 | TDATA, TKEEP, TLAST, TUSER, TID, TDEST stable while TVALID && !TREADY | `AXIS_INJ_DATA_CHANGE`, `AXIS_INJ_LAST_CHANGE`, `AXIS_INJ_ID_CHANGE` |
| AXIS-R03 | no TVALID during reset | `AXIS_INJ_VALID_IN_RESET` |
| AXIS-R04 | *optional profile, input `check_packed`*: continuous aligned stream, TKEEP all ones except on the last transfer, where it is a non-empty run of ones from lane 0 | `AXIS_INJ_KEEP_HOLE`, `AXIS_INJ_KEEP_SHORT_MID` |

The base protocol constrains nothing else: TKEEP may mark null bytes anywhere (also whole
null transfers), TID / TDEST may change between transfers (streams interleave), and TREADY
may wait for TVALID or not. Tie `check_packed` low for a sparse stream.

## Self-test (`vip/axis/test`)

VIP master -> VIP slave on one interface, checker on the wires; a scoreboard compares every
packet the master sent (`ap_sent`) with the packet rebuilt by the monitor (wire view) and by
the slave (consumer view), in order, and checks that all three counts agree. Two benches
share the sources: `axis_selftest` (64-bit TDATA, 4-bit TID, 2-bit TDEST, 4-bit TUSER) and
`axis_min_selftest` (8-bit TDATA, no TID / TDEST / TUSER, `+define+AXIS_SELFTEST_MIN`).
`python3 sim/regress.py sim/tests_vip_lite.yaml --filter axis` runs: smoke (every length from
1 byte to 3 transfers + 1, with and without gaps), random (packed TKEEP), sparse (`+AXIS_SPARSE`
turns R04 off in the top and the master into SPARSE mode), heavy backpressure then free flow, a
scoreboard sanity test (the slave corrupts received data and the scoreboard must notice) and
one violation test per injection above.
