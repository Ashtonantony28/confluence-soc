# SpikeMesh router environment (M5)

Two routers of a 3x3 mesh run at once, each in its own `router_env` (vertical reuse of one env
class): the centre router (1,1), where all five ports carry traffic, and the corner router
(0,0), whose W port is the host link.

**Harness** (`router_harness.sv`): N/E/S/W inputs are driven by credit-link VIP senders
(`vip/credit`), N/E/S/W outputs drain into credit-link VIP receivers that model the neighbour
FIFO and return credits at a random rate, and the local port uses the AXI4-Stream VIP. A credit
checker sits on all eight mesh links and an AXI4-Stream checker on both local links.

**Stimulus** obeys the mesh contract of the router's own formal environment: a flit arriving on
a mesh port has a destination XY routing upstream could send there. The local port and the host
port may carry any destination; `router_drop_test` adds out-of-mesh destinations on the local
port.

**Scoreboard** (`router_sb`): an independent SPEC §4 model gives each flit's output port.
Checks: routing (misrouted flits named with the expected port), ordering per (input, output)
pair, no loss after drain, no corrupted or duplicated flits, `drop_cnt` and `err` equal to the
predicted drops, and every input accepted all its flits (a stimulus watchdog turns a starved
sender into an error). Coverage: legal XY routes hit (17/17 centre, 12/12 corner) and output
contention (1, 2, 3+ inputs waiting for the same output).

| Test | Profile |
|---|---|
| `router_random_test` | random gaps and backpressure per seed |
| `router_storm_test` | every input back to back, 60-90 % busy receivers on every output |
| `router_hotspot_test` | almost all traffic to the local port (or the host link on the corner) |
| `router_drop_test` | 15 % of local flits addressed outside the mesh |

`make mutate-router` (`scripts/mutate_router.py`) runs the env against mutated copies of the
router (the submodule is never edited); docs/MUTATION.md lists them.

Structural coverage holes: the corner router has no S neighbour, so contention bins for its S
output can never be hit.
