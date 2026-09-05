#!/usr/bin/env python3
"""Robustness of number formats and precisions to a single bit flip.

Numbers from model/robustness.py; the containment panel is cross-checked
against tb/tb_damage.v on the RTL.
"""
import sys, pathlib
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "model"))
from robustness import (RNG, Posit, fixed_bits, fixed_value, f16_bits, f16_value,
                        flip_damage, study_partition)
from formats import quantise_fixed

x = RNG.uniform(-1.0, 1.0, size=4000)
pos = Posit(16, 1)
DMG = {
    "fixed Q1.15":   flip_damage(fixed_bits, fixed_value, quantise_fixed(x, 16), 16),
    "IEEE binary16": flip_damage(f16_bits,   f16_value,   x, 16),
    "posit(16,1)":   flip_damage(pos.encode, pos.decode,  x, 16),
}
COL = {"fixed Q1.15": "#3f7f5f", "IEEE binary16": "#4a6fb0", "posit(16,1)": "#b04a4a"}

fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(11.5, 4.6))

# survival curve: P(damage > d)
for name, dmg in DMG.items():
    v = dmg.reshape(-1)
    v = np.sort(v[np.isfinite(v) & (v > 0)])
    surv = 1.0 - np.arange(len(v)) / len(v)
    ax1.plot(v, surv, color=COL[name], lw=1.9, label=name)
ax1.axvline(1.0, color="#333", ls=":", lw=1)
ax1.annotate("full scale", (1.0, 0.55), rotation=90, fontsize=8,
             va="center", ha="right", color="#333")
ax1.set_xscale("log"); ax1.set_yscale("log")
ax1.set_xlabel("damage from one bit flip (units of full scale)")
ax1.set_ylabel("P(damage > x)")
ax1.set_title("Fixed point is bounded; the others are not")
ax1.grid(alpha=.3, which="both")
ax1.legend(fontsize=8)

# containment: lane damage vs vector damage
rows = study_partition()
modes = [r["mode"] for r in rows]
lane = [r["lane_mean"] for r in rows]
vec  = [r["vec_mean"] for r in rows]
xpos = np.arange(len(modes))
ax2.bar(xpos - 0.18, lane, 0.36, label="damage to the lane that was hit", color="#c98a30")
ax2.bar(xpos + 0.18, vec,  0.36, label="damage to the output vector",     color="#3f7f5f")
for i, (l, v) in enumerate(zip(lane, vec)):
    ax2.text(i - 0.18, l + .006, f"{l:.3f}", ha="center", fontsize=8)
    ax2.text(i + 0.18, v + .006, f"{v:.3f}", ha="center", fontsize=8)
ax2.set_xticks(xpos)
ax2.set_xticklabels([f"{m}\n{r['lanes']}x{r['w']}b" for m, r in zip(modes, rows)])
ax2.set_ylabel("mean damage (units of full scale)")
ax2.set_title("Partitioning a fixed 48-bit file changes nothing")
ax2.grid(alpha=.3, axis="y")
ax2.legend(fontsize=8)
ax2.set_ylim(0, max(lane) * 1.25)

fig.suptitle("Does inexactness buy robustness? Not from precision, and not from partitioning",
             fontsize=11)
fig.tight_layout()
fig.savefig("robustness.png", dpi=130)
print("wrote results/robustness.png")
for name, dmg in DMG.items():
    v = dmg.reshape(-1); v = v[np.isfinite(v)]
    print(f"  {name:15s} median {np.median(v):.3e}  p99 {np.percentile(v,99):.3e}  "
          f"worst {v.max():.3e}  P(>full scale) {100*(v>1).mean():.1f}%")
