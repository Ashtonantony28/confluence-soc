#!/usr/bin/env bash
# Golden traces for the NanoXL env (M4). Deterministic: same submodule pin -> same traces.
#   sim/gen_nanoxl_traces.sh      -> build/traces/nanoxl/*.trace
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd); cd "$ROOT"
G="python3 scripts/gen_nanoxl_trace.py"
D=build/traces/nanoxl
mkdir -p "$D"
for b in w8a8 w4a8; do
  $G --bundle $b --layers 1 --prompt 2 --decode 1 -o $D/${b}_l1.trace
  $G --bundle $b --layers 2 --prompt 4 --decode 2 --ring-words ${RING_WORDS:-700} -o $D/${b}_l2_wrap.trace
  $G --bundle $b --layers 0 --prompt 16 --decode 8 --pbuf-kb 32 --check-tokens -o $D/${b}_full.trace
done
