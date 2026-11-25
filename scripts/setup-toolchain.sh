#!/usr/bin/env bash
# Installs the Confluence toolchain into a fresh Ubuntu container (ADR 0005).
#   scripts/setup-toolchain.sh            -> /opt/verilator-5.054, ./.tools/uvm-verilator
# Set VL_TARBALL=/path/verilator-5.054.tgz to skip the ~15 minute source build.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
VL_PREFIX=${VL_PREFIX:-/opt/verilator-5.054}
UVM_SHA=795b5f263c5d440c26e6d3598b406d44dd23fbd9
SUDO=$([ "$(id -u)" = 0 ] && echo "" || echo sudo)
$SUDO apt-get update -qq
$SUDO apt-get install -y -qq z3 libz3-dev help2man flex bison libfl-dev autoconf ccache make g++ \
  iverilog yosys gcc-riscv64-unknown-elf python3-pip >/dev/null
if [ ! -x "$VL_PREFIX/bin/verilator" ]; then
  if [ -n "${VL_TARBALL:-}" ] && [ -f "$VL_TARBALL" ]; then
    $SUDO tar -C / -xzf "$VL_TARBALL"
  else
    tmp=$(mktemp -d); git clone -q --depth 1 -b v5.054 https://github.com/verilator/verilator "$tmp/vl"
    (cd "$tmp/vl" && autoconf && ./configure -q --prefix="$VL_PREFIX" && make -j"$(nproc)" >/dev/null && $SUDO make install >/dev/null)
  fi
fi
mkdir -p "$ROOT/.tools"
if [ ! -d "$ROOT/.tools/uvm-verilator" ]; then
  git clone -q https://github.com/antmicro/uvm-verilator "$ROOT/.tools/uvm-verilator"
fi
git -C "$ROOT/.tools/uvm-verilator" checkout -q "$UVM_SHA"
pip install -q -r "$ROOT/requirements.txt"
# Formal (M2+): sv2v (SV -> Verilog for yosys 0.33), yices (SMT engine), sby pinned to the
# yosys-0.33 tag (sby master needs a newer yosys).
pip install -q yices-solver
if ! command -v sv2v >/dev/null; then
  tmp=$(mktemp -d)
  curl -sSL -o "$tmp/sv2v.zip" https://github.com/zachjs/sv2v/releases/download/v0.0.13/sv2v-Linux.zip
  (cd "$tmp" && unzip -q sv2v.zip && $SUDO install -m755 sv2v-Linux/sv2v /usr/local/bin/sv2v)
fi
if ! command -v sby >/dev/null; then
  tmp=$(mktemp -d); git clone -q -b yosys-0.33 --depth 1 https://github.com/YosysHQ/sby "$tmp/sby"
  (cd "$tmp/sby" && $SUDO make -s install PREFIX=/usr/local)
fi
git -C "$ROOT" submodule update --init --recursive -q
echo "toolchain ready: $("$VL_PREFIX/bin/verilator" --version)"
