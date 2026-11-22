#!/usr/bin/env bash
# Golden ISS traces for the CPU-on-AXI env (M6). Deterministic: same submodule pin -> same traces.
#   sim/gen_cpu_traces.sh          -> build/traces/cpu/*.trace
# Every riscv-test Vortex-V's conformance suite runs (needs riscv64-unknown-elf-gcc), 20 default-mix
# and 5 Xmlacc-heavy random streams from verif/crv/rvgen.py.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd); cd "$ROOT"
D=build/traces/cpu
mkdir -p "$D"
python3 - "$D" <<'PY'
import subprocess, sys
from pathlib import Path
D = Path(sys.argv[1])
sys.path[:0] = ["third_party/vortex-v/verif/conformance", "third_party/vortex-v/verif/core", "third_party/vortex-v"]
import test_conformance as tc
jobs = [["--riscv-test", n, "-o", str(D / f"{n}.trace")] for n in tc.RUN_NAMES]
jobs += [["--random", str(s), "-o", str(D / f"rand_{s}.trace")] for s in range(20)]
jobs += [["--random", str(s), "--mix", "xm", "-o", str(D / f"xm_{s}.trace")] for s in range(5)]
procs = []
for j in jobs:
    procs.append(subprocess.Popen([sys.executable, "scripts/gen_cpu_trace.py"] + j, stdout=subprocess.DEVNULL))
    if len(procs) >= 8:
        if procs.pop(0).wait(): sys.exit("trace generation failed")
for p in procs:
    if p.wait(): sys.exit("trace generation failed")
print(f"{len(jobs)} traces in {D}")
PY
