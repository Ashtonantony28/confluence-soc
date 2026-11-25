# Formal results

## confluence_xbar (M2), `make formal-xbar`

Harness: `formal/xbar/xbar_formal.sv`, 2 masters x 2 slaves, 8-bit address and data, 1-bit
master ID, at most 2 outstanding per master. The RTL goes through sv2v (yosys 0.33 cannot parse
SystemVerilog) and SymbiYosys checks it.

| Property | Statement |
|---|---|
| P1 | AW/AR/W toward a slave keep valid and payload until accepted |
| P2 | a request reaches only the slave its address decodes to |
| P3 | an AW/AR accepted by a slave was accepted from the master named in its ID upper bits |
| P4 | B/R toward a master stay stable until accepted |
| P5 | a master only gets responses for IDs it has outstanding |
| P6 | same-ID rule: outstanding transactions of one (master, ID) sit at one target |
| P7 | W at a slave belongs to the oldest AW it accepted (same master, same beat) |

Environment assumptions: masters and slaves follow the handshake rules; at most one write per
(master, ID) in flight with len <= 1; reads are single-beat. Multi-beat and deeper outstanding
behaviour is covered by simulation (`make test-xbar`), not by this proof.

| Task | Engine | Result | Time |
|---|---|---|---|
| `pdr` | abc pdr | **PASS (unbounded)** | 21 min (2026-11-21) |
| `bmc` | smtbmc yices, depth 12 | clean to step 8 before slowing; superseded by the PDR proof | |

Toolchain notes: boolector 1.5 (apt) breaks sby's pipe and z3 is too slow, so the SMT engine is
yices (`pip install yices-solver`); sby is pinned to tag `yosys-0.33` because sby master needs a
newer yosys.
