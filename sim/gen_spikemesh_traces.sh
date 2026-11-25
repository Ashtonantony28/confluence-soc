#!/usr/bin/env bash
# Golden traces for the SpikeMesh chip env (M5). Deterministic: same submodule pin -> same traces.
#   sim/gen_spikemesh_traces.sh   -> build/traces/spikemesh/*.trace
# Trained 256-256-10 net: fixture samples 0..31 in chunks of 8 (each chunk reloads the net),
# plus random 64-48-16 nets on random events.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd); cd "$ROOT"
G="python3 scripts/gen_spikemesh_trace.py"
D=build/traces/spikemesh
mkdir -p "$D"
for s in 0 8 16 24; do
  $G --start $s --samples 8 -o $D/trained_${s}_8.trace
done
for seed in 1 2 3; do
  $G --random-net $seed --samples 4 -o $D/rand_${seed}.trace
done
