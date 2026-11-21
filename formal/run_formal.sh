#!/usr/bin/env bash
# Run the formal proofs. Needs yosys, sby, boolector, sv2v (scripts/setup-toolchain.sh).
#   formal/run_formal.sh [xbar] [bmc|prove]
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WHAT=${1:-xbar}; TASK=${2:-}
case $WHAT in
  xbar)
    cd "$ROOT/formal/xbar"
    sv2v -w xbar_rtl.v "$ROOT"/rtl/lib/cf_fifo.sv "$ROOT"/rtl/lib/cf_rr_arb.sv \
      "$ROOT"/rtl/xbar/axi4_default_slave.sv "$ROOT"/rtl/xbar/confluence_xbar.sv
    sby -f xbar.sby $TASK ;;
  *) echo "unknown target $WHAT"; exit 2 ;;
esac
