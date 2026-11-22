# AXI4 VIP

`axi4_pkg` (classes parameterised by `AW`/`DW`/`IDW`), `axi4_if`, `axi4_checker`.

| Component | What it does |
|---|---|
| `axi4_master_driver` | five independent channel threads; up to `max_outstanding` bursts; W may lead AW; responses matched per ID; `put_response` per burst |
| `axi4_slave_driver` | reactive, memory-backed (`vip_mem`); random latency and ready stalls; out-of-order completion across IDs and read interleaving (per-ID order kept); SLVERR regions |
| `axi4_monitor` | rebuilds bursts: `ap_req` at each address handshake, `ap` at completion; annotates outstanding depth, out-of-order completion, interleaving |
| `axi4_coverage` | burst type x length x direction, narrow/unaligned, 4 KiB boundary, responses, outstanding depth, reordering, interleaving |
| `axi4_mem_scoreboard` | memory consistency for any number of monitors on one address space; handles AXI write reordering with per-byte possible-value sets |
| `axi4_checker` | protocol rules below; failures go to `vip_checker_db` |

## Checker rules

| Rule | Check |
|---|---|
| AXI4-R01..R05 | AW / W / B / AR / R: VALID held with stable payload until READY |
| AXI4-R06 | no VALID during reset |
| AXI4-R07 | burst type 2'b11 reserved |
| AXI4-R08 | size not wider than the data bus |
| AXI4-R09 | WRAP length is 2, 4, 8 or 16 |
| AXI4-R10 | WRAP start address size-aligned |
| AXI4-R11 | FIXED length at most 16 |
| AXI4-R12 | INCR burst does not cross a 4 KiB boundary |
| AXI4-R13 | WLAST exactly on the last beat of the matching AW (W may lead AW) |
| AXI4-R14 | no W beat past the AW length without WLAST (early detection when AW is known) |
| AXI4-R15 | B only for a write whose AW and last W have been seen |
| AXI4-R16 | R only for an ID with an outstanding read |
| AXI4-R17 | RLAST exactly on the last beat of the oldest read of that ID |
| AXI4-R18 | WSTRB only on the byte lanes the beat's address and size make active (narrow / unaligned) |

## Self-test (`vip/axi4/test`)

VIP master and VIP slave on one interface, checker on the wires, memory scoreboard on the
master monitor. `python3 sim/regress.py sim/tests_vip.yaml` runs: smoke, in-order, random
(out-of-order + interleaved, 5 seeds), SLVERR regions, a scoreboard sanity test (the slave
corrupts read data and the scoreboard must notice), and one violation test per injectable
rule (every injected violation must be caught by the named rule).
