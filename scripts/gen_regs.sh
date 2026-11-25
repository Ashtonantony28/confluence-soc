#!/usr/bin/env bash
# Generate every register artefact from regs/*.rdl (ADR 0004). Never hand-edit regs/gen/.
#   scripts/gen_regs.sh [OUT]     OUT defaults to regs/gen (make regs-check uses a temp dir)
# RTL:  one PeakRDL regblock per new CSR block (AXI4-Lite, the mailbox APB4).
# RAL:  one UVM package for the whole SoC map; block types are reused by the block tests.
# C:    one header for firmware.  HTML (HTML=1, not committed: 8 MB of fonts): browsable docs.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$(realpath -m "${1:-$ROOT/regs/gen}")
cd "$ROOT/regs"
rm -rf "$OUT/rtl" "$OUT/ral" "$OUT/c" "$OUT/html"; mkdir -p "$OUT/rtl" "$OUT/ral" "$OUT/c"
# Every block decodes its whole 4 KiB window (no aliasing behind the bridges) and answers an
# unmapped address with SLVERR, like MLACC (docs/ADDRESS_MAP.md).
RB_OPTS="--default-reset rst_n --addr-width 12 --err-if-bad-addr"
for b in cf_sys_ctrl cf_irq_ctrl cf_timer cf_dma_csr cf_spikemesh_ctl; do
  peakrdl regblock "$b.rdl" -o "$OUT/rtl" --cpuif axi4-lite-flat $RB_OPTS
done
peakrdl regblock cf_mailbox.rdl -o "$OUT/rtl" --cpuif apb4-flat $RB_OPTS
peakrdl uvm confluence_soc.rdl -o "$OUT/ral/confluence_soc_ral_pkg.sv"
# Post-process (ADR 0004 allows this, hand edits are not allowed): peakrdl-uvm creates maps with
# UVM_NO_ENDIAN, which Accellera UVM 1800.2-2017 rejects on every access (MAPNOENDIANESS) even
# when register and bus widths match. AXI4/AXI4-Lite/APB are little-endian.
sed -i 's/UVM_NO_ENDIAN/UVM_LITTLE_ENDIAN/g' "$OUT/ral/confluence_soc_ral_pkg.sv"
peakrdl c-header confluence_soc.rdl -o "$OUT/c/confluence_soc.h"
[ -n "${HTML:-}" ] && peakrdl html confluence_soc.rdl -o "$OUT/html" >/dev/null
true
