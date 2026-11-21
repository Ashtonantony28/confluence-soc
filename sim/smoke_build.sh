#!/usr/bin/env bash
# M0 smoke build: all four upstream IPs in one Verilator model, simulated for a few thousand
# cycles on idle buses. Prints the compile time (the number the plan asked M0 to measure).
#   sim/smoke_build.sh        (make smoke-build)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd); cd "$ROOT"
VERILATOR=${VERILATOR:-$(command -v verilator || echo /opt/verilator-5.054/bin/verilator)}
OBJ=build/smoke
python3 scripts/gen_smoke_top.py
mkdir -p "$OBJ"
t0=$(date +%s)
"$VERILATOR" --binary --timing -j "$(nproc)" -Wno-fatal -Wno-lint -Wno-style \
  -Ithird_party/spikemesh/rtl/core -Ithird_party/spikemesh/rtl/noc -Ithird_party/nanoxl-accelerator/rtl \
  -f sim/flists/smoke_ips.f tb/smoke/cf_smoke_top.sv --top-module cf_smoke_top -Mdir "$OBJ" \
  > "$OBJ/build.log" 2>&1 || { tail -40 "$OBJ/build.log"; exit 2; }
t1=$(date +%s)
echo "smoke-build: compiled in $((t1 - t0)) s on $(nproc) cores"
"$OBJ/Vcf_smoke_top" | tee "$OBJ/run.log" | tail -3
grep -q '\*\*\* SMOKE PASSED \*\*\*' "$OBJ/run.log"
