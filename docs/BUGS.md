# Bugs found by the Confluence benches

| ID | Block | Found by | Symptom | Root cause | Fix |
|---|---|---|---|---|---|
| CF-XBAR-001 | `confluence_xbar` (new RTL) | `xbar_random_test` seeds 1,2,3,5,6 (timeout) | crossbar deadlock under mixed traffic | the R return path locked a master to one slave until RLAST; two slaves interleaving read data for two masters each held a beat the other master's locked arbiter would never take | per-beat R arbitration (AXI4 allows interleaving of different IDs; same-ID-one-slave keeps per-ID order) |
