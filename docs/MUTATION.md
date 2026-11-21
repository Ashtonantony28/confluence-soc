# Mutation log

Each entry is a deliberate bug compiled in with `DEFINES=+define+MUTANT_<NAME>` and a separate
build directory (`BUILD_TAG=<NAME>`). A mutant is **killed** when at least one test in the
block's list fails. The M11 campaign extends this table to the whole SoC.

Run one: `BUILD_TAG=X DEFINES=+define+MUTANT_X sim/run_uvm.sh bridge bridge_random_test 1`

| Mutant | Block | Bug | Killed by | Status |
|---|---|---|---|---|
| `AXI2AXIL_LANE` | axi2axil | every 32-bit word routed to lane 0 of the wide beat | bridge_random_test s1/s2, bridge_error_test (memory scoreboard: byte mismatch) | killed |
| `AXI2AXIL_WRAP` | axi2axil | WRAP bursts never wrap (treated as INCR) | bridge_random_test s1/s2 (scoreboard mismatch on WRAP reads) | killed |
| `AXI2AXIL_BRESP` | axi2axil | burst response = last word's response, not the worst | bridge_word_err_test only | killed |
| `AXIL2APB_NOERR` | axil2apb | PSLVERR ignored, always OKAY | bridge_error_test, bridge_word_err_test | killed |

`AXI2AXIL_BRESP` survived the first test list: with 4 KiB-aligned error regions every word of
a burst gets the same response, so "last" and "worst" agree. `bridge_word_err_test` (single
32-bit error words at the first, middle and last word of a 16-byte beat) was added to kill it.

## Register flow (M3): MLACC's own seeded CSR bugs vs the RAL tests

MLACC-UVM ships these mutants in `mlacc_csr.sv`; here they are run against `make test-ral`
(`BUILD_TAG=X DEFINES=+define+MUTANT_X sim/run_uvm.sh regs <test> 1`).

| Mutant | Bug | Killed by | Status |
|---|---|---|---|
| `SCRATCH_BIT` | SCRATCH bit 15 stuck at 0 | regs_bit_bash_test, regs_rw_test | killed |
| `W1C_AS_RW` | MLSTAT.SAT plain RW instead of W1C | regs_bit_bash_test, regs_rw_test | killed |
| `ADDR_ALIAS` | only paddr[7:0] decoded (0x100 aliases ID) | regs_unmapped_test | killed |
| `STATUS_LEVEL` | STATUS.fifo_level at [6:3] instead of [7:4] | none | survives: needs FIFO traffic (M7/M8) |

`W1C_AS_RW` first survived: peakrdl-uvm marks every hardware-settable field volatile, and UVM
fixes a field's compare flag at configure time. The register env now re-enables comparison on
W1C fields because their set sources are idle in that bench. `ADDR_ALIAS` needed the new
unmapped-address test (every hole of every 4 KiB window).
