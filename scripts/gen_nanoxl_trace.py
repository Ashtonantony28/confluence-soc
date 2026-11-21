#!/usr/bin/env python3
"""Golden image for the NanoXL block env (M4, ADR 0003 / D4: golden images).

Runs NanoXL's own host driver (third_party/nanoxl-accelerator, nanoxl.driver.NanoXL) on a recording
backend built on its SimBackend (nanoxl.funcsim), the way tests/rtl/top_cocotb.py drives the RTL:
prefill a prompt, greedy-decode a few tokens, then dump the on-chip KV cache. Every step's logits are
asserted equal to nanoxl.golden.Golden.forward before anything is written, so the expected values in
the trace are golden values, not just funcsim values.

The UVM env (tb/nanoxl) replays the trace against nanoxl_top. One record per line:
  B base size          DDR buffer: physical base and size (bytes)
  M addr hex           testbench memory load (CPU writes, made visible by a flush)
  W off val            CSR write
  R off val            CSR read; poll until it reads val (completion is not instantaneous on RTL)
  X off                CSR read whose value is timing dependent (perf counters): not compared
  C addr hex           expected DDR contents written by the device (checked byte for byte)
  S name               start of a step (coverage / messages)
  E                    end
Numbers are hex without 0x; "hex" is the bytes in address order.

  scripts/gen_nanoxl_trace.py --bundle w8a8 --layers 1 --prompt 2 --decode 1 -o build/traces/nanoxl/x.trace
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
NXL = ROOT / "third_party" / "nanoxl-accelerator"
sys.path.insert(0, str(NXL))

from nanoxl import isa  # noqa: E402
from nanoxl.driver import NanoXL, SimBackend  # noqa: E402
from nanoxl.driver import csr as R  # noqa: E402
from nanoxl.export import load_bundle  # noqa: E402
from nanoxl.golden import Golden  # noqa: E402
from nanoxl.hwconfig import KV260, KiB  # noqa: E402

PHYS = 0x8000_0000             # Confluence DRAM base (docs/ADDRESS_MAP.md)
LINE = 32                      # bytes per M / C record
NOCMP = {R.PERF_CYCLES, R.PERF_BUSY_DMA, R.PERF_BUSY_ARR, R.PERF_BUSY_VEC, R.PERF_RETIRED,
         R.PERF_BYTES_LO, R.PERF_BYTES_HI}


def top_hw(kv_onchip=True, pbuf_kb=10):
    """The HwConfig nanoxl_top implements with its default parameters (N=8, L=4), as in
    tests/rtl/top_cocotb.py::top_hw; pbuf_kb < 32 makes the PBUF ring wrap inside a program."""
    return KV260.with_(array_n=8, lanes=4, kv_onchip=kv_onchip, abuf=64 * KiB, wbuf=32 * KiB,
                       acc=64 * KiB, pbuf=pbuf_kb * KiB, kvbuf=128 * KiB)


class TraceBackend(SimBackend):
    """SimBackend that records the driver's view of the device (see module docstring)."""

    def __init__(self, hw, out, extra):
        super().__init__(hw, phys_base=PHYS)
        self.out, self.extra = out, extra
        self.shadow = None

    def emit(self, s):
        self.out.write(s + "\n")

    def runs(self, tag, new, old, force=None):
        """Emit tag records for bytes where new != old (or every byte of force=(lo, hi))."""
        diff = new != old
        if force is not None:
            diff[force[0]:force[1]] = True
        idx = np.flatnonzero(diff)
        if idx.size == 0:
            return
        # split into runs of consecutive indices, then into LINE-byte records
        brk = np.flatnonzero(np.diff(idx) != 1) + 1
        for run in np.split(idx, brk):
            for i in range(run[0], run[-1] + 1, LINE):
                j = min(i + LINE, run[-1] + 1)
                self.emit(f"{tag} {PHYS + i:x} {new[i:j].tobytes().hex()}")

    def alloc(self, nbytes):
        mem, phys = super().alloc(nbytes + self.extra)     # room past the image for the KV dump
        self.emit(f"B {phys:x} {len(mem):x}")
        self.shadow = np.zeros_like(mem)
        return mem, phys

    def flush(self, off=0, n=None):
        self.runs("M", self.mem, self.shadow)
        self.shadow[:] = self.mem

    def invalidate(self, off=0, n=None, force=None):
        self.runs("C", self.mem, self.shadow, force)
        self.shadow[:] = self.mem

    def read32(self, off):
        v = super().read32(off)
        self.emit(f"X {off:x}" if off in NOCMP else f"R {off:x} {v:x}")
        return v

    def write32(self, off, val):
        self.emit(f"W {off:x} {int(val) & 0xFFFFFFFF:x}")
        super().write32(off, val)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bundle", default="w8a8", choices=["w8a8", "w4a8"])
    ap.add_argument("--layers", type=int, default=1)
    ap.add_argument("--prompt", type=int, default=2)
    ap.add_argument("--decode", type=int, default=1)
    ap.add_argument("--pbuf-kb", type=int, default=10)
    ap.add_argument("--ring-words", type=int, default=0,
                    help="shrink the command ring (re-reset) so programs wrap around it; 0 = compiler's ring")
    ap.add_argument("--check-tokens", action="store_true",
                    help="full model and full reference prompt: tokens must equal golden_ref.json")
    ap.add_argument("-o", "--out", required=True)
    a = ap.parse_args()

    tiny = NXL / "artifacts" / "models" / "tiny"
    ref = json.loads((tiny / "golden_ref.json").read_text())
    arrays, meta = load_bundle(tiny / f"{a.bundle}.npz")
    meta = dict(meta)
    if a.layers and a.layers < meta["n_layer"]:
        meta["n_layer"] = a.layers
    hw = top_hw(pbuf_kb=a.pbuf_kb)
    out_path = Path(a.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w") as out:
        out.write(f"# NanoXL golden trace: bundle {a.bundle}, layers {meta['n_layer']}, prompt {a.prompt}, "
                  f"decode {a.decode}, N=8 L=4, PBUF {a.pbuf_kb} KiB, KV on chip\n")
        g = Golden(arrays, meta)
        be = TraceBackend(hw, out, extra=hw.kvbuf)        # on-chip KV fits KVBUF by construction
        dev = NanoXL(be, arrays, meta, hw, name=a.bundle)
        if a.ring_words:
            dev.ring_words = a.ring_words
            dev.reset()
        cache = g.new_cache()
        dev.clear_counters()
        toks, tokens = list(ref["prompt"][:a.prompt]), []
        for s in range(a.decode + 1):
            feed = toks if s == 0 else [tokens[-1]]
            out.write(f"S step{s}\n")
            prog = dev.comp.compile_step([(dev.pos[0], len(feed))])
            logits = dev.step([feed])[0]
            gold = g.forward(feed, cache)
            if not np.array_equal(logits, gold):
                sys.exit(f"step {s}: funcsim logits differ from golden; trace not written correctly")
            # the whole logits block is checked, not only the bytes that changed
            off, rows, width, dt = dev._io(prog, "logits")
            nb = rows * width * np.dtype(dt).itemsize
            out.write(f"# logits {rows}x{width} int{np.dtype(dt).itemsize * 8} at {PHYS + off:x}\n")
            for i in range(off, off + nb, LINE):
                be.emit(f"C {PHYS + i:x} {be.mem[i:min(i + LINE, off + nb)].tobytes().hex()}")
            tokens.append(int(np.argmax(logits[-1])))
        if a.check_tokens:
            want = ref["bundles"][a.bundle]["tokens"][:len(tokens)]
            if tokens != want:
                sys.exit(f"tokens {tokens} differ from golden_ref.json {want}")
        # KV cache dump (on-chip KVBUF -> DDR scratch past the image), compared with golden too
        out.write("S kv_dump\n")
        nkv = dev.comp.kv_slot
        img = dev.comp.img
        cmds = []
        for o in range(0, nkv, 65536):
            rb = min(65536, nkv - o)
            cmds.append(isa.C("DMA_STORE", chan=2, sp_buf=isa.KVBUF, sp_addr=o,
                              ddr_addr=img.base + img.size + o, rows=1, row_bytes=rb, ddr_stride=rb))
        cmds.append(isa.C("END"))
        dev.wait(dev.submit(cmds))
        be.invalidate(force=(img.size, img.size + nkv))
        cfg = dev.cfg
        kv = be.mem[img.size:img.size + nkv].view(np.int8).reshape(cfg.n_layer, 2, cfg.n_head, cfg.ctx, cfg.d_head)
        for kind, name in ((0, "k"), (1, "v")):
            gk = cache[name].reshape(cfg.n_layer, cfg.ctx, cfg.n_head, cfg.d_head).transpose(0, 2, 1, 3)
            if not np.array_equal(kv[:, kind], gk):
                sys.exit(f"KV {name}: funcsim differs from golden")
        # end-of-run CSR state: saturation counters, no error, idle
        dev.saturation()
        be.read32(R.ERR_CODE)
        be.read32(R.STATUS)
        out.write(f"# tokens {tokens}\nE\n")
    print(f"{out_path}: tokens {tokens}")


if __name__ == "__main__":
    main()
