"""Render the README demo media into docs/media/ from a real crossbar simulation.

    scripts/media.py            # builds the xbar bench with WAVES, runs xbar_random_test seed 1, renders

  xbar-traffic.{gif,mp4,png}  every read-data and write-data beat at the three slave ports of confluence_xbar
                              (3 masters x 3 slaves, 128-bit AXI4), coloured by the master it belongs to, from the
                              port-level FST of the UVM random test (all checkers and scoreboards passing)
  xbar-matrix.png             beats per master/slave pair over the whole test

Needs the Confluence toolchain (scripts/setup-toolchain.sh), fst2vcd (gtkwave), matplotlib and ffmpeg.
RTL SIMULATION (Verilator 5.054), not hardware.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "docs" / "media"

import matplotlib  # noqa: E402

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

BG, PANEL, GRID, TXT, DIM = "#0d1117", "#161b22", "#30363d", "#e6edf3", "#8b949e"
MCOL = ["#58a6ff", "#ffa657", "#3fb950"]
NM = NS = 3
MIDW = 4                     # xbar_env_pkg: master ID width; slave-side IDs carry the master index above it
TEST, SEED = "xbar_random_test", 1
SIGS = ["clk", "s_rvalid", "s_rready", "s_rid", "s_rlast", "s_wvalid", "s_wready", "s_wlast", "s_awvalid", "s_awready",
        "s_awid", "s_arvalid", "s_arready", "s_arid", "s_bvalid", "s_bready", "s_bid"]


def simulate():
    env = dict(os.environ, BUILD_TAG="waves", DEFINES="+define+WAVES --trace-fst")
    r = subprocess.run([str(ROOT / "sim" / "run_uvm.sh"), "xbar", TEST, str(SEED)], cwd=ROOT, env=env,
                       capture_output=True, text=True)
    assert r.returncode == 0 and r.stdout.startswith("PASS"), r.stdout + r.stderr
    vcd = ROOT / "build" / "xbar_waves.vcd"
    with open(vcd, "w") as fh:
        subprocess.run(["fst2vcd", str(ROOT / "build" / "xbar_waves.fst")], stdout=fh, stderr=subprocess.DEVNULL, check=True)
    return vcd


def parse(vcd):
    """Per-cycle samples (value just before each rising clk edge) of SIGS in scope xbar_tb_top."""
    ids, cur, scope = {}, {}, []
    rows, t, header = [], 0, True
    clk_code = None
    prev_clk = "0"
    with open(vcd) as fh:
        for line in fh:
            s = line.strip()
            if header:
                if s.startswith("$scope"):
                    scope.append(s.split()[2])
                elif s.startswith("$upscope"):
                    scope.pop()
                elif s.startswith("$var") and scope and scope[-1] == "xbar_tb_top":
                    p = s.split()
                    if p[4] in SIGS and p[3] not in ids and p[4] not in ids.values():
                        ids[p[3]] = p[4]
                        if p[4] == "clk":
                            clk_code = p[3]
                elif s.startswith("$enddefinitions"):
                    header = False
                continue
            if not s:
                continue
            c = s[0]
            if c == "#":
                t = int(s[1:])
                continue
            if c in "01xzXZ":
                v, code = c, s[1:]
            elif c in "bB":
                v, code = s[1:].split()
            else:
                continue
            if code == clk_code:
                if prev_clk == "0" and v == "1":
                    rows.append(dict(cur))               # values before this edge's updates
                prev_clk = v
            elif code in ids:
                cur[ids[code]] = v
    return rows


def bit(v, i):
    if v is None or any(ch not in "01" for ch in v):
        return 0
    return (int(v, 2) >> i) & 1


def field(v, i, w):
    if v is None or any(ch not in "01" for ch in v):
        return -1
    return (int(v, 2) >> (i * w)) & ((1 << w) - 1)


def beats(rows):
    """(cycle, slave, kind, master, last) for every R/W beat and AR/AW/B handshake at the slave ports."""
    sidw = MIDW + max(1, (NM - 1).bit_length())
    out = []
    w_owner = [[] for _ in range(NS)]                    # AW order gives the owner of the following W bursts
    for c, r in enumerate(rows):
        for s in range(NS):
            if bit(r.get("s_awvalid"), s) and bit(r.get("s_awready"), s):
                m = field(r.get("s_awid"), s, sidw) >> MIDW
                w_owner[s].append(m)
                out.append((c, s, "AW", m, 0))
            if bit(r.get("s_arvalid"), s) and bit(r.get("s_arready"), s):
                out.append((c, s, "AR", field(r.get("s_arid"), s, sidw) >> MIDW, 0))
            if bit(r.get("s_rvalid"), s) and bit(r.get("s_rready"), s):
                out.append((c, s, "R", field(r.get("s_rid"), s, sidw) >> MIDW, bit(r.get("s_rlast"), s)))
            if bit(r.get("s_wvalid"), s) and bit(r.get("s_wready"), s):
                m = w_owner[s][0] if w_owner[s] else -1
                last = bit(r.get("s_wlast"), s)
                out.append((c, s, "W", m, last))
                if last and w_owner[s]:
                    w_owner[s].pop(0)
            if bit(r.get("s_bvalid"), s) and bit(r.get("s_bready"), s):
                out.append((c, s, "B", field(r.get("s_bid"), s, sidw) >> MIDW, 0))
    return out


def draw_window(fig, ev, c0, width, total_cycles):
    fig.clf()
    fig.text(0.035, 0.935, "Confluence: AXI4 crossbar traffic under the UVM random test", fontsize=17, weight="bold",
             color=TXT)
    fig.text(0.035, 0.895, f"RTL SIMULATION (Verilator 5.054)  ·  confluence_xbar, 3 masters × 3 slaves, 128-bit  ·  "
             f"{TEST} seed {SEED}, every protocol checker and scoreboard passing  ·  one square = one data beat",
             fontsize=9.2, color=DIM)
    ax = fig.add_axes([0.10, 0.17, 0.87, 0.68])
    ax.set_facecolor(PANEL)
    lanes = []
    for s in range(NS):
        lanes += [(s, "R"), (s, "W")]
    ypos = {ln: len(lanes) - 1 - k for k, ln in enumerate(lanes)}
    for (c, s, kind, m, last) in ev:
        if not (c0 <= c < c0 + width):
            continue
        if kind in ("R", "W"):
            y = ypos[(s, kind)]
            col = MCOL[m] if 0 <= m < NM else DIM
            ax.add_patch(plt.Rectangle((c - 0.45, y - 0.32), 0.9, 0.64, color=col, alpha=0.95))
            if last:
                ax.plot([c + 0.45, c + 0.45], [y - 0.42, y + 0.42], color=TXT, lw=0.9)
        else:
            lane = (s, "R") if kind in ("AR",) else (s, "W")
            y = ypos[lane] + 0.47
            mk = {"AR": "v", "AW": "v", "B": "^"}[kind]
            ax.plot(c, y if kind != "B" else ypos[lane] - 0.47, mk, ms=3.5, color=MCOL[m] if 0 <= m < NM else DIM)
    for k in range(NS):
        ax.axhline(ypos[(k, "W")] - 0.6, color=GRID, lw=0.8)
    ax.set_yticks([ypos[ln] for ln in lanes])
    ax.set_yticklabels([f"slave {s}  {'read data' if k == 'R' else 'write data'}" for s, k in lanes], color=TXT, fontsize=9.5)
    ax.set_xlim(c0 - 0.5, c0 + width - 0.5); ax.set_ylim(-0.75, len(lanes) - 0.25)
    ax.tick_params(colors=DIM, labelsize=8)
    ax.set_xlabel(f"clock cycle (of {total_cycles:,})", color=DIM, fontsize=9)
    for sp in ax.spines.values():
        sp.set_color(GRID)
    x = 0.10
    for m in range(NM):
        fig.text(x, 0.075, f"■ master {m}", color=MCOL[m], fontsize=10.5)
        x += 0.11
    fig.text(x + 0.01, 0.075, "▼ address handshake   ▲ write response   | last beat of a burst", color=DIM, fontsize=9.5)
    fig.text(0.10, 0.035, "Read data from different masters interleaves beat by beat on one slave port: the per-beat R "
             "arbitration that fixed deadlock CF-XBAR-001 (docs/BUGS.md).", color=DIM, fontsize=9)


def matrix(ev):
    M = np.zeros((NM, NS), int)
    for (c, s, kind, m, last) in ev:
        if kind in ("R", "W") and 0 <= m < NM:
            M[m, s] += 1
    fig, ax = plt.subplots(figsize=(6.4, 5.0), dpi=100, facecolor=BG)
    ax.imshow(M, cmap=matplotlib.colors.LinearSegmentedColormap.from_list("m", [PANEL, "#1f6feb", "#79c0ff"]))
    for i in range(NM):
        for j in range(NS):
            ax.text(j, i, f"{M[i, j]:,}", ha="center", va="center", color=TXT, fontsize=13, weight="bold")
    ax.set_xticks(range(NS)); ax.set_xticklabels([f"slave {j}" for j in range(NS)], color=TXT)
    ax.set_yticks(range(NM)); ax.set_yticklabels([f"master {i}" for i in range(NM)], color=TXT)
    ax.tick_params(colors=DIM)
    for sp in ax.spines.values():
        sp.set_color(GRID)
    ax.set_title(f"data beats per master/slave pair\n{TEST} seed {SEED} (RTL simulation)", color=TXT, fontsize=11)
    fig.tight_layout()
    fig.savefig(OUT / "xbar-matrix.png", facecolor=BG)
    plt.close(fig)
    return M


def main(width=120, step=4, fps=15):
    OUT.mkdir(parents=True, exist_ok=True)
    rows = parse(simulate())
    ev = beats(rows)
    matrix(ev)
    n = len(rows)
    dens = np.zeros(n)
    for (c, s, kind, m, last) in ev:
        if kind in ("R", "W"):
            dens[c] += 1
    win = np.convolve(dens, np.ones(width), "valid")
    best = int(np.argmax(win))
    fig = plt.figure(figsize=(12.8, 7.2), dpi=100, facecolor=BG)
    draw_window(fig, ev, best, width, n)
    fig.savefig(OUT / "xbar-traffic.png", facecolor=BG)
    # animation: the window scrolls across the busiest stretch of the test
    start = max(0, best - 3 * width)
    stop = min(n - width, best + 3 * width)
    tmp = Path(tempfile.mkdtemp())
    for k, c0 in enumerate(range(start, stop, step)):
        draw_window(fig, ev, c0, width, n)
        fig.savefig(tmp / f"f{k:04d}.png", facecolor=BG)
    plt.close(fig)
    ff = ["ffmpeg", "-loglevel", "error", "-y", "-framerate", str(fps), "-i", str(tmp / "f%04d.png")]
    subprocess.run(ff + ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "23", str(OUT / "xbar-traffic.mp4")], check=True)
    subprocess.run(ff + ["-vf", "scale=960:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=32[p];"
                         "[b][p]paletteuse=dither=none", str(OUT / "xbar-traffic.gif")], check=True)
    shutil.rmtree(tmp)
    print(f"{n} cycles, {sum(1 for e in ev if e[2] in 'RW')} data beats")


if __name__ == "__main__":
    main()
