#!/usr/bin/env python3
"""Golden trace for the SpikeMesh chip env (M5, ADR 0003 / D4 golden images).

SpikeMesh's own host API (host/api.py SpikeMeshHost) runs the trained 256-256-10 network on
emulated N-MNIST samples over a recording backend built on its GoldenBackend (golden/spikemesh.py
driven purely through 48-bit flits). Each sample's hidden and output rasters are asserted equal
to compiler.netir.reference_run before the trace is used, so the expected flits are golden.

Records, one per line (hex without 0x):
  P name=value ...   RTL parameters the program needs (checked against the bench)
  F flit             host -> chip flit, in order
  T                  STEP: wait until every sent flit was taken, pulse step, wait step_done and
                     until the chip is drained with the host output FIFO empty
  Y                  sync: wait until every sent flit was taken and the chip is drained
  O n flit...        chip -> host flits since the last O (compared as a multiset: arrival order
                     between different sources is not part of the contract)
  S name             sample marker
  E                  end

  scripts/gen_spikemesh_trace.py --samples 4 -o build/traces/spikemesh/trained_0_4.trace
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
SM = ROOT / "third_party" / "spikemesh"
sys.path.insert(0, str(SM))
sys.path.insert(0, str(SM / "tests" / "system"))

from compiler.compile import compile_net  # noqa: E402
from compiler.netir import NetIR, reference_run  # noqa: E402
from host.api import GoldenBackend, SpikeMeshHost  # noqa: E402
from sysutil import FIXTURE, fixture_inputs, rand_net  # noqa: E402


class TraceBackend(GoldenBackend):
    """GoldenBackend that records the host's flit traffic with RtlBackend's sync semantics."""

    def __init__(self, out, *a, **kw):
        super().__init__(*a, **kw)
        self.out = out
        self.dirty = False

    def send_flits(self, flits):
        for f in flits:
            self.out.write(f"F {int(f):012x}\n")
        if len(flits):
            self.dirty = True
        super().send_flits(flits)

    def step(self):
        self.out.write("T\n")
        self.dirty = False
        super().step()

    def recv_flits(self):
        if self.dirty:                       # RtlBackend.recv_flits syncs after unsynced sends
            self.out.write("Y\n")
            self.dirty = False
        got = super().recv_flits()
        if got:
            self.out.write(f"O {len(got)} " + " ".join(f"{int(f):012x}" for f in sorted(got)) + "\n")
        return got


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--start", type=int, default=0, help="first fixture sample")
    ap.add_argument("--samples", type=int, default=4)
    ap.add_argument("--random-net", type=int, default=None, metavar="SEED",
                    help="random 64-48-16 network on random events instead of the trained net")
    ap.add_argument("-o", "--out", required=True)
    a = ap.parse_args()

    if a.random_net is None:
        net = NetIR.load(FIXTURE)
        x, y, _ = fixture_inputs()
        x, y = x[a.start:a.start + a.samples], y[a.start:a.start + a.samples]
        what = f"trained 256-256-10 net, fixture samples {a.start}..{a.start + len(x) - 1}"
    else:
        rng = np.random.default_rng(a.random_net)
        net = rand_net(rng, [64, 48, 16])
        x = rng.random((a.samples, 16, 64)) < 0.15
        y = np.zeros(a.samples, int)
        what = f"random 64-48-16 net seed {a.random_net}, {a.samples} random samples"
    prog = compile_net(net, 2, 2, probe_layers=(0,))
    out_path = Path(a.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w") as out:
        out.write(f"# SpikeMesh golden trace: {what}\n")
        out.write(f"P MESH_X={prog.mesh_x} MESH_Y={prog.mesh_y} N_NEURONS={prog.n_neurons} "
                  f"N_AXONS={prog.n_axons} W_BITS={prog.w_bits} FANOUT_DEPTH={prog.fanout_depth}\n")
        be = TraceBackend(out, prog.mesh_x, prog.mesh_y, prog.n_neurons, prog.n_axons, prog.w_bits)
        h = SpikeMeshHost(be)
        out.write("S load\n")
        h.load(prog)
        preds = []
        for i in range(len(x)):
            out.write(f"S sample{a.start + i}\n")
            if i:
                h.reset_state()
            o, ras = h.run(x[i], probes=True)
            ref = reference_run(net, x[i])
            if not (np.array_equal(ras[0], ref[0]) and np.array_equal(o, ref[-1])):
                sys.exit(f"sample {i}: golden chip differs from reference_run; trace not trustworthy")
            preds.append(int(o.sum(0).argmax()))
        out.write(f"# predictions {preds} labels {[int(v) for v in y]}\nE\n")
    print(f"{out_path}: {what}, predictions {preds}")


if __name__ == "__main__":
    main()
