#!/usr/bin/env python3
"""ABFT on a PE array: what it costs as the array grows, and what it recovers.

Numbers from sweep_abft.sh and tb/tb_abft.v (results/abft_*.txt).
"""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

P      = np.array([4, 8, 16])
ABFT   = np.array([54, 36, 28])       # measured % over a bare array
PERPE  = np.array([48, 48, 48])       # Phase-1 residue+SEC-DED on every PE
IDEAL  = 200.0 / P                    # two checksum PEs only, 2/P

fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(11.5, 4.6))

ax1.plot(P, ABFT,  "o-", color="#3f7f5f", lw=2, label="ABFT, measured")
ax1.plot(P, IDEAL, "s--", color="#7fae97", lw=1.6, label="ABFT, checksum PEs only (2/P)")
ax1.plot(P, PERPE, "^-", color="#b04a4a", lw=2, label="per-PE residue + SEC-DED")
ax1.fill_between(P, IDEAL, ABFT, color="#c98a30", alpha=.25,
                 label="syndrome tree (the part that scales)")
ax1.set_xscale("log", base=2); ax1.set_xticks(P); ax1.set_xticklabels(P)
ax1.set_xlabel("processing elements, P")
ax1.set_ylabel("area overhead over a bare array (%)")
ax1.set_title("ABFT amortises, but not as 2/P")
ax1.grid(alpha=.3); ax1.legend(fontsize=8)
ax1.annotate("crosses under per-PE\nprotection at P=8", xy=(8, 36), xytext=(8.6, 90),
             fontsize=8, arrowprops=dict(arrowstyle="->", color="#555"))

labels = ["unprotected", "ABFT\ncorrect", "ABFT detect\n+ re-execute"]
vals   = [1.053e-2, 5.500e-3, 0.0]
cols   = ["#b04a4a", "#c98a30", "#3f7f5f"]
bars = ax2.bar(labels, vals, color=cols, width=.6)
for b, v in zip(bars, vals):
    ax2.text(b.get_x() + b.get_width()/2, v + 3e-4,
             "0" if v == 0 else f"{v:.2e}", ha="center", fontsize=9)
ax2.set_ylabel("mean |error| per output (units of full scale)")
ax2.set_title("What correction actually recovers")
ax2.grid(alpha=.3, axis="y")
ax2.set_ylim(0, 1.3e-2)
ax2.annotate("location is ambiguous when the error\nis 2^47 -- and those are the big ones",
             xy=(1, 5.5e-3), xytext=(0.35, 8.3e-3), fontsize=8,
             arrowprops=dict(arrowstyle="->", color="#555"))

fig.suptitle("ABFT on a PE array: detection is free and perfect, location is not",
             fontsize=11)
fig.tight_layout()
fig.savefig("abft.png", dpi=130)
print("wrote results/abft.png")
