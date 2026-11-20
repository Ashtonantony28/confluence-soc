#!/usr/bin/env bash
# Build (once, cached) and run one SV-UVM bench under Verilator 5.054.
#   sim/run_uvm.sh BENCH TEST [SEED] [+plusargs...]
# BENCH names sim/flists/BENCH.f; its last file is the top module (same name as the file).
# Env: VERILATOR, UVM_HOME (default .tools/uvm-verilator/src), REBUILD=1, COVERAGE=1, DEFINES.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd); cd "$ROOT"
BENCH=$1; TEST=$2; SEED=${3:-1}; shift $(( $# < 3 ? $# : 3 ))
VERILATOR=${VERILATOR:-$(command -v verilator || echo /opt/verilator-5.054/bin/verilator)}
UVM_HOME=${UVM_HOME:-$ROOT/.tools/uvm-verilator/src}
FL=sim/flists/$BENCH.f
TOP=$(basename "$(grep -v '^\s*[#+-]' "$FL" | grep -v '^\s*$' | tail -1)" .sv)
OBJ=build/$BENCH${COVERAGE:+_cov}
INC=$(grep -v '^\s*[#+-]' "$FL" | grep -v '^\s*$' | xargs -n1 dirname | sort -u | sed 's/^/-I/' | tr '\n' ' ')
if [ ! -x "$OBJ/V$TOP" ] || [ -n "${REBUILD:-}" ] || [ -n "$(find $(grep -v '^\s*[#+-]' "$FL" | grep -v '^\s*$' | xargs -n1 dirname | sort -u) -newer "$OBJ/V$TOP" -name '*.sv*' 2>/dev/null | head -1)" ]; then
  mkdir -p "$OBJ"
  "$VERILATOR" --binary --timing --assert -j "$(nproc)" -Wno-fatal -Wno-lint -Wno-style \
    --error-limit 50 +define+UVM_NO_DPI ${DEFINES:-} ${COVERAGE:+--coverage} \
    +incdir+"$UVM_HOME" $INC "$UVM_HOME/uvm_pkg.sv" -f "$FL" \
    --top-module "$TOP" -Mdir "$OBJ" > "$OBJ/build.log" 2>&1 || { tail -60 "$OBJ/build.log"; exit 2; }
fi
TAG=$( [ $# -gt 0 ] && echo "$*" | md5sum | cut -c1-6 | sed "s/^/./" || true)
LOG=$OBJ/$TEST.s$SEED$TAG.log
timeout "${SIM_TIMEOUT:-900}" "$OBJ/V$TOP" +UVM_TESTNAME="$TEST" +verilator+seed+"$SEED" +verilator+rand+reset+2 "$@" > "$LOG" 2>&1 || true
grep -q '\*\*\* TEST PASSED \*\*\*' "$LOG" && { echo "PASS $BENCH $TEST s$SEED $*"; exit 0; }
echo "FAIL $BENCH $TEST s$SEED $*  (log: $LOG)"; grep -m5 -E 'UVM_(ERROR|FATAL) ' "$LOG" || tail -20 "$LOG"; exit 1
