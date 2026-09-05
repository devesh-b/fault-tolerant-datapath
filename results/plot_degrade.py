#!/usr/bin/env python3
"""Graceful degradation: silent corruption and throughput against fault density.

Numbers from results/degrade_L*.txt (Verilator, 50,000 operations per point per
scheme). Regenerate those before redrawing.
"""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

RATE = [3000, 1000, 300, 100, 30]          # 1 fault per N cycles
DENS = [1.0 / r for r in RATE]             # faults per cycle

# scheme -> (SDC events per 1000 ops, cycles per op)
SDC = {
    "L0  commit always":        [0.220, 0.620, 1.700, 4.680, 16.960],
    "L1  retry on detect":      [0.060, 0.080, 0.240, 0.540,  2.700],
    "L2  always double-check":  [0.000, 0.000, 0.000, 0.000,  0.000],
    "adaptive (on demand)":     [0.060, 0.100, 0.260, 0.520,  0.880],
}
CYC = {
    "L0  commit always":        [2.000, 2.000, 2.000, 2.000, 2.000],
    "L1  retry on detect":      [2.000, 2.001, 2.001, 2.004, 2.015],
    "L2  always double-check":  [3.001, 3.002, 3.006, 3.020, 3.068],
    "adaptive (on demand)":     [2.016, 2.039, 2.099, 2.288, 2.780],
}
STYLE = {
    "L0  commit always":       ("#b04a4a", "o", "-"),
    "L1  retry on detect":     ("#c98a30", "s", "-"),
    "L2  always double-check": ("#4a6fb0", "^", "-"),
    "adaptive (on demand)":    ("#3f7f5f", "D", "--"),
}

fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(11.5, 4.6))

for k in SDC:
    c, m, ls = STYLE[k]
    ax1.plot(DENS, [v + 1e-3 for v in SDC[k]], ls, color=c, marker=m, label=k, lw=1.8)
ax1.set_xscale("log"); ax1.set_yscale("log")
ax1.set_xlabel("fault density (faults per cycle)")
ax1.set_ylabel("silent corruptions per 1000 ops")
ax1.set_title("Coverage")
ax1.grid(alpha=.3, which="both")
ax1.legend(fontsize=8)
ax1.annotate("L2 records zero at every density",
             xy=(DENS[-1], 1e-3), xytext=(DENS[0]*1.2, 4e-3), fontsize=8, color="#4a6fb0")

for k in CYC:
    c, m, ls = STYLE[k]
    ax2.plot(DENS, CYC[k], ls, color=c, marker=m, label=k, lw=1.8)
ax2.set_xscale("log")
ax2.set_xlabel("fault density (faults per cycle)")
ax2.set_ylabel("cycles per operation")
ax2.set_title("What it costs")
ax2.grid(alpha=.3)
ax2.legend(fontsize=8)

fig.suptitle("On-demand reliability: adaptivity interpolates between always-cheap and always-safe",
             fontsize=11)
fig.tight_layout()
fig.savefig("degradation.png", dpi=130)
print("wrote results/degradation.png")

lo, hi = 0, -1
A, L1, L2 = "adaptive (on demand)", "L1  retry on detect", "L2  always double-check"
print(f"  low density  1/{RATE[lo]}: adaptive {CYC[A][lo]:.3f} cyc/op vs L2 {CYC[L2][lo]:.3f} "
      f"-> {100*(1-CYC[A][lo]/CYC[L2][lo]):.0f}% cheaper, SDC {SDC[A][lo]:.2f} vs {SDC[L2][lo]:.2f}")
print(f"  high density 1/{RATE[hi]}: adaptive SDC {SDC[A][hi]:.2f} vs L1 {SDC[L1][hi]:.2f} and L2 {SDC[L2][hi]:.2f} "
      f"-> {100*(1-SDC[A][hi]/SDC[L1][hi]):.0f}% of the way from L1 to L2")
print(f"                    cost {CYC[A][hi]:.3f} cyc/op vs L1 {CYC[L1][hi]:.3f} and L2 {CYC[L2][hi]:.3f} "
      f"-> {100*(CYC[A][hi]-CYC[L1][hi])/(CYC[L2][hi]-CYC[L1][hi]):.0f}% of the way in cost")
