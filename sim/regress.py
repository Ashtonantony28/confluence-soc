#!/usr/bin/env python3
"""Run a regression list (sim/tests_*.yaml) in parallel with sim/run_uvm.sh.

    python3 sim/regress.py sim/tests_vip.yaml [-j N] [--filter SUBSTR] [--md reports/X.md]

Builds each bench once first (serially, since a Verilator build already uses every core),
then runs all (test, seed) pairs. Exit status is non-zero if anything fails.
"""
import argparse, concurrent.futures as cf, pathlib, subprocess, sys, time, yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
RUN = str(ROOT / "sim" / "run_uvm.sh")


def run(job):
    bench, test, seed, args = job
    t0 = time.time()
    p = subprocess.run([RUN, bench, test, str(seed)] + args.split(), cwd=ROOT,
                       capture_output=True, text=True)
    return job, p.returncode == 0, time.time() - t0, (p.stdout + p.stderr).strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("lists", nargs="+")
    ap.add_argument("-j", type=int, default=4)
    ap.add_argument("--filter", default="")
    ap.add_argument("--md")
    a = ap.parse_args()
    jobs = []
    for lst in a.lists:
        for e in yaml.safe_load(open(lst)):
            for s in e.get("seeds", [1]):
                j = (e["bench"], e["test"], s, e.get("args", ""))
                if a.filter in " ".join(map(str, j)):
                    jobs.append(j)
    for bench in sorted({j[0] for j in jobs}):          # build each bench once, serially
        first = next(j for j in jobs if j[0] == bench)
        print(run(first)[3].splitlines()[0])
    results = []
    with cf.ThreadPoolExecutor(a.j) as ex:
        for job, ok, dt, out in ex.map(run, jobs):
            results.append((job, ok, dt))
            print(out.splitlines()[0] if ok else out)
    fails = [r for r in results if not r[1]]
    print(f"\n{len(results) - len(fails)}/{len(results)} passed")
    if a.md:
        pathlib.Path(a.md).parent.mkdir(parents=True, exist_ok=True)
        with open(a.md, "w") as f:
            f.write("| bench | test | seed | args | result | s |\n|---|---|---|---|---|---|\n")
            for (b, t, s, ar), ok, dt in results:
                f.write(f"| {b} | {t} | {s} | `{ar}` | {'PASS' if ok else '**FAIL**'} | {dt:.0f} |\n")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
