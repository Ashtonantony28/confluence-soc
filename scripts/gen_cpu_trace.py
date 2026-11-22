#!/usr/bin/env python3
"""Golden traces for the Vortex-V CPU-on-AXI env (M6, ADR 0003 / D4 golden images, ADR 0006).

A program (a seeded constrained-random stream from Vortex-V's verif/crv/rvgen.py, or one of the
upstream riscv-tests Vortex-V's conformance suite runs) is executed on Vortex-V's golden ISS
(model/iss/rv64i.py). The ISS must halt with tohost PASS before the trace is written. The UVM env
loads the image into the AXI slave's memory and compares every instruction the core retires, in
order, with the ISS (pc, writeback valid, rd, value): lockstep checking against a recorded ISS
run, since the program is deterministic and the env has no DPI (ADR 0005).

Records, one per line (hex without 0x):
  M addr hex          memory image bytes at addr (address order)
  R pc wbv rd data op retired instruction: writeback valid, rd, value, major opcode (coverage)
  X tohost sat        expected tohost value and final mlstat.SAT
  C addr hex          expected final memory contents (data region of random programs)
  E                   end

  scripts/gen_cpu_trace.py --random 3 -o build/traces/cpu/rand_3.trace
  scripts/gen_cpu_trace.py --riscv-test rv64ui-add -o build/traces/cpu/rv64ui-add.trace
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VV = ROOT / "third_party" / "vortex-v"
for p in (VV, VV / "verif" / "core", VV / "verif" / "crv", VV / "verif" / "conformance"):
    sys.path.insert(0, str(p))

from model.iss.rv64i import Hart, Memory  # noqa: E402
from rvasm import DATA_BASE, DATA_SIZE, RESET_PC, TOHOST_ADDR  # noqa: E402

LINE = 32
MASK64 = (1 << 64) - 1
MAX_STEPS = 200_000


def image_random(seed, mix, n_items):
    from rvgen import MIXES, RandomProgram
    asm, data, _ = RandomProgram(seed, n_items=n_items, mix=MIXES[mix]).build()
    img = {}
    for i, w in enumerate(asm.assemble()):
        for b in range(4):
            img[RESET_PC + 4 * i + b] = (w >> (8 * b)) & 0xFF
    for addr, n, v in data:
        for b in range(n):
            img[addr + b] = (v >> (8 * b)) & 0xFF
    return img, (DATA_BASE, DATA_SIZE)


def image_riscv_test(name):
    import test_conformance as tc
    if name not in tc.RUN_NAMES:
        sys.exit(f"{name}: not in Vortex-V's conformance run list (excluded or unknown)")
    blob = tc._build(name).read_bytes()
    return {RESET_PC + i: b for i, b in enumerate(blob)}, None


def emit_bytes(out, tag, img):
    addrs = sorted(img)
    i = 0
    while i < len(addrs):
        start = addrs[i]
        chunk = [img[start]]
        while i + 1 < len(addrs) and addrs[i + 1] == addrs[i] + 1 and len(chunk) < LINE:
            i += 1
            chunk.append(img[addrs[i]])
        out.write(f"{tag} {start:x} {bytes(chunk).hex()}\n")
        i += 1


def main():
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--random", type=int, metavar="SEED")
    g.add_argument("--riscv-test", metavar="NAME")
    ap.add_argument("--mix", default="default")
    ap.add_argument("--items", type=int, default=180)
    ap.add_argument("-o", "--out", required=True)
    a = ap.parse_args()

    if a.random is not None:
        img, check = image_random(a.random, a.mix, a.items)
        what = f"rvgen seed {a.random} mix {a.mix} ({a.items} items)"
    else:
        img, check = image_riscv_test(a.riscv_test)
        what = f"riscv-tests {a.riscv_test}"

    mem = Memory(base=RESET_PC)
    for addr, b in img.items():
        mem.store(addr, 1, b)
    hart = Hart(mem=mem, reset_pc=RESET_PC, tohost_addr=TOHOST_ADDR)
    recs = []
    while not hart.halted and len(recs) < MAX_STEPS:
        recs.append(hart.step())
    if not hart.halted or hart.halt_code != (True, 0):
        sys.exit(f"{what}: ISS did not halt with PASS (halted={hart.halted}, code={hart.halt_code})")

    out_path = Path(a.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w") as out:
        out.write(f"# Vortex-V golden ISS trace: {what}, {len(recs)} retires\n")
        emit_bytes(out, "M", {k: v for k, v in img.items() if v})     # the slave memory reads 0 elsewhere
        for r in recs:
            rd = r.get("rd")
            wbv = int(rd is not None and rd != 0)
            val = (r.get("rd_val", 0) or 0) & MASK64 if wbv else 0
            out.write(f"R {r['pc'] & MASK64:x} {wbv} {rd if wbv else 0:x} {val:x} {r['inst'] & 0x7F:x}\n")
        out.write(f"X 1 {hart.mlstat & 1}\n")
        if check:
            base, n = check
            emit_bytes(out, "C", {base + i: mem.load(base + i, 1) & 0xFF for i in range(n)})
        out.write("E\n")
    print(f"{out_path}: {what}, {len(recs)} retires")


if __name__ == "__main__":
    main()
