#!/usr/bin/env python3
"""Coverage against overhead: where the knee is.

Numbers come from results/campaign_*.txt (Verilator campaigns, 16000 trials
per design) and fpga/ooc_results.txt (Vivado out-of-context, xc7a100t).
Regenerate those first if the RTL changes.
"""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

# design -> (LUT, reg-to-reg slack ns, SDC escapes out of 16000 trials)
DATA = {
    "unprotected":        (1525,  5.397, 4000 + 3885 + 4000),   # ACC + OPA + PROD
    "residue + SEC-DED":  (1883, -0.078, 1234),                 # OPA only
    "TMR":                (4775,  5.348, 0),                    # single-fault masked
}
BASE_LUT = DATA["unprotected"][0]
TRIALS = 16000

fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(11, 4.4))

names = list(DATA)
over = [100.0 * (DATA[n][0] / BASE_LUT - 1.0) for n in names]
cov = [100.0 * (1.0 - DATA[n][2] / TRIALS) for n in names]
slack = [DATA[n][1] for n in names]
colors = ["#b04a4a", "#3f7f5f", "#4a6fb0"]

ax1.scatter(over, cov, s=110, c=colors, zorder=3)
for n, x, y in zip(names, over, cov):
    ax1.annotate(n, (x, y), textcoords="offset points", xytext=(8, -12), fontsize=9)
ax1.plot(over, cov, "--", color="#999", lw=1, zorder=2)
ax1.set_xlabel("LUT overhead vs unprotected (%)")
ax1.set_ylabel("coverage: 1 - SDC/trials (%)")
ax1.set_title("Coverage vs area overhead")
ax1.grid(alpha=.3)
ax1.set_ylim(20, 105)

ax2.scatter(over, slack, s=110, c=colors, zorder=3)
for n, x, y in zip(names, over, slack):
    ax2.annotate(n, (x, y), textcoords="offset points", xytext=(8, -12), fontsize=9)
ax2.axhline(0, color="#b04a4a", lw=1, ls=":")
ax2.set_xlabel("LUT overhead vs unprotected (%)")
ax2.set_ylabel("reg-to-reg slack (ns, 10 ns clock)")
ax2.set_title("The other axis: timing")
ax2.grid(alpha=.3)

fig.suptitle("Protecting a multi-precision MAC: the knee is timing, not area", fontsize=11)
fig.tight_layout()
fig.savefig("coverage_vs_overhead.png", dpi=130)
print("wrote results/coverage_vs_overhead.png")
for n in names:
    print(f"  {n:20s} LUT +{100.0*(DATA[n][0]/BASE_LUT-1):6.1f}%   "
          f"coverage {100.0*(1-DATA[n][2]/TRIALS):6.2f}%   slack {DATA[n][1]:+.3f} ns")
