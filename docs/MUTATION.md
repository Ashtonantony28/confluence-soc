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
