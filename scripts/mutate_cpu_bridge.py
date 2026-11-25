#!/usr/bin/env python3
"""vortex_axi_bridge mutation check (M6). Each mutant is compiled in with +define+MUTANT_<NAME>
into its own build directory and run against a short kill list; it is killed when any run fails.

  scripts/mutate_cpu_bridge.py [NAME ...]      # default: every mutant (needs sim/gen_cpu_traces.sh)
"""
import subprocess, sys, os, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
T = "+TRACE=build/traces/cpu/"
KILL = [("cpu_random_test", 1, T + "rand_0.trace"), ("cpu_random_test", 2, T + "rv64ui-sb.trace"),
        ("cpu_random_test", 3, T + "rv64ui-lbu.trace"), ("cpu_random_test", 4, T + "rand_5.trace"),
        ("cpu_slow_test", 1, T + "rand_1.trace")]
MUTANTS = {   # name: (bench, description)
    "VXB_WSTRB_FULL":    ("cpu_axi",    "every byte lane written on a narrow store"),
    "VXB_NO_LANE_SHIFT": ("cpu_axi",    "load data not shifted down from its byte lane"),
    "VXB_POSTED_WRITE":  ("cpu_axi",    "core steps before the write response"),
    "VXB_DOUBLE_STEP":   ("cpu_axi",    "every 16th step gives the core two edges"),
    "VXB_STALE_REQ":     ("cpu_axi",    "data request taken from the previous core cycle"),
    "VXB_FETCH1_STALE":  ("cpu_axi_w2", "second fetch port returns the first port's word"),
}


def main():
    names = sys.argv[1:] or list(MUTANTS)
    killed = 0
    for n in names:
        bench, desc = MUTANTS[n]
        env = dict(os.environ, BUILD_TAG=n, DEFINES=f"+define+MUTANT_{n}", SIM_TIMEOUT="600")
        why = None
        for test, seed, arg in KILL:
            p = subprocess.run([str(ROOT / "sim/run_uvm.sh"), bench, test, str(seed), arg], cwd=ROOT,
                               env=env, capture_output=True, text=True)
            if p.returncode != 0:
                err = next((l for l in p.stdout.splitlines() if "UVM_ERROR" in l or "UVM_FATAL" in l), "timeout")
                why = f"{test} s{seed} {arg.split('/')[-1]}: " + err.split("] ", 1)[-1][:120]
                break
        killed += why is not None
        print(f"{'KILLED  ' if why else 'SURVIVED'} {n:18s} {desc}")
        if why:
            print("         " + why)
    print(f"\n{killed}/{len(names)} bridge mutants killed")
    sys.exit(0 if killed == len(names) else 1)


if __name__ == "__main__":
    main()
