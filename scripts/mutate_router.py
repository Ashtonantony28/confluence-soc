#!/usr/bin/env python3
"""Router-env mutation check (M5). Writes mutated copies of SpikeMesh's rtl/noc/router.sv into
build/mutants/router/<NAME>/router.sv (the submodule is never touched), builds the router env
against each copy and runs the test named for it. A mutant is killed when that test fails.

  scripts/mutate_router.py [NAME ...]        # default: every mutant
"""
import pathlib, subprocess, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "third_party/spikemesh/rtl/noc/router.sv"

# name: (description, test, [(old, new), ...]); every old string must occur exactly once
MUTANTS = {
    "YX_ROUTE": ("route Y before X (dimension order swapped)", "router_random_test",
                 [("end else if ({28'd0, dx} > X) route = 3'(PE);\n        else if ({28'd0, dx} < X)     route = 3'(PW);\n"
                   "        else if ({28'd0, dy} > Y)     route = 3'(PN);\n        else if ({28'd0, dy} < Y)     route = 3'(PS);",
                   "end else if ({28'd0, dy} > Y) route = 3'(PN);\n        else if ({28'd0, dy} < Y)     route = 3'(PS);\n"
                   "        else if ({28'd0, dx} > X)     route = 3'(PE);\n        else if ({28'd0, dx} < X)     route = 3'(PW);")]),
    "HOST_EAST": ("host-bound flits leave on E instead of W", "router_random_test",
                  [("if (X > 0)      route = 3'(PW);", "if (X > 0)      route = 3'(PE);")]),
    "CREDIT_INIT": ("output credit counters start one above the neighbour FIFO depth", "router_storm_test",
                    [("for (int o = 0; o < 4; o++) credits[o] <= CW'(FIFO_DEPTH);",
                      "for (int o = 0; o < 4; o++) credits[o] <= CW'(FIFO_DEPTH) + CW'(1);")]),
    "NO_CREDIT_RET": ("credit return for input W is lost", "router_storm_test",
                      [("credit_out <= pop[3:0];", "credit_out <= pop[3:0] & 4'b0111;")]),
    "WRONG_HEAD": ("link register takes the flit of input 0 instead of the granted input", "router_random_test",
                   [("if (send[o]) oreg_f[o] <= head[gsel[o]];", "if (send[o]) oreg_f[o] <= head[0];")]),
    "LOCAL_NO_HOLD": ("local output valid drops without ready (flit lost)", "router_random_test",
                      [("else if (l_out_ready) oreg_v[PL] <= 1'b0;", "else oreg_v[PL] <= 1'b0;")]),
    "DROP_UNCOUNTED": ("dropped flits are not counted", "router_drop_test",
                       [("if (|drop)\n                drop_cnt <=", "if (1'b0)\n                drop_cnt <=")]),
    "NO_DROP": ("out-of-mesh flits are routed east instead of dropped", "router_drop_test",
                [("route = 3'(PDROP);\n        end else if", "route = 3'(PE);\n        end else if")]),
}


def main():
    names = sys.argv[1:] or list(MUTANTS)
    fl = (ROOT / "sim/flists/router.f").read_text()
    killed = 0
    for n in names:
        desc, test, edits = MUTANTS[n]
        src = SRC.read_text()
        for old, new in edits:
            if src.count(old) != 1:
                sys.exit(f"{n}: edit does not apply exactly once: {old[:60]!r}")
            src = src.replace(old, new)
        d = ROOT / "build/mutants/router" / n
        d.mkdir(parents=True, exist_ok=True)
        (d / "router.sv").write_text(src)
        (ROOT / f"sim/flists/router_mut_{n}.f").write_text(
            fl.replace("third_party/spikemesh/rtl/noc/router.sv", str((d / "router.sv").relative_to(ROOT))))
        p = subprocess.run([str(ROOT / "sim/run_uvm.sh"), f"router_mut_{n}", test, "1"], cwd=ROOT,
                           capture_output=True, text=True)
        first = (p.stdout.strip().splitlines() or ["?"])[0]
        why = next((l for l in p.stdout.splitlines() if "UVM_ERROR" in l or "UVM_FATAL" in l), "")
        ok = p.returncode != 0
        killed += ok
        print(f"{'KILLED  ' if ok else 'SURVIVED'} {n:15s} {desc}  [{test}]")
        if why:
            print("         " + why.split("] ", 1)[-1][:150])
        (ROOT / f"sim/flists/router_mut_{n}.f").unlink()
    print(f"\n{killed}/{len(names)} router mutants killed")
    sys.exit(0 if killed == len(names) else 1)


if __name__ == "__main__":
    main()
