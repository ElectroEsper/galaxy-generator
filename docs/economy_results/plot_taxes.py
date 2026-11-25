import csv, matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter
D = "docs/economy_results/"
def ld(f):
    r = list(csv.DictReader(open(D + f)))
    return {k: [float(x[k]) for x in r] for k in r[0]}
INK, MUTED, GRID = "#1f2328", "#6b7280", "#e5e7eb"
COL = {0: "#2a78d6", 1: "#eb6834"}
NAME = {0: "no taxes", 1: "25% profit + 0.5%/month wealth tax"}
seeds = [7, 11, 23, 31]
runs = {(s, t): ld(f"run_col_s{s}_t{t}.csv") for s in seeds for t in (0, 1)}
panels = [("corp_cash", "Corporate cash, all corporations (millions)", 1e6),
          ("treasury", "State treasury (millions)", 1e6),
          ("settled", "Colonies settled", 1),
          ("facilities", "Facilities", 1)]
fig, axs = plt.subplots(2, 2, figsize=(12, 7.2))
for ax, (k, title, div) in zip(axs.flat, panels):
    ymax = 0
    for t in (0, 1):
        for s in seeds:
            d = runs[(s, t)]
            ys = [v / div for v in d[k]]
            ax.plot([x / 12 for x in d["tick"]], ys, color=COL[t], lw=2.2 if s == 7 else 1.0, alpha=1.0 if s == 7 else 0.45)
            ymax = max(ymax, max(ys))
    ax.set_title(title, loc="left", fontsize=11.5, color=INK)
    ax.set_ylim(min(0, ax.get_ylim()[0]), ymax * 1.12)
    ax.set_xlim(0, 50)
    ax.grid(axis="y", color=GRID, lw=0.8); ax.set_axisbelow(True)
    for sp in ["top", "right"]: ax.spines[sp].set_visible(False)
    for sp in ["left", "bottom"]: ax.spines[sp].set_color(GRID)
    ax.tick_params(colors=MUTED, labelsize=9)
    ax.yaxis.set_major_formatter(FuncFormatter(lambda v, _: f"{v:,.0f}" if abs(v) >= 10 or v == 0 else f"{v:,.1f}"))
    ax.set_xlabel("years", color=MUTED, fontsize=9)
from matplotlib.lines import Line2D
h = [Line2D([], [], color=COL[t], lw=2.2) for t in (0, 1)]
fig.legend(h, [NAME[0], NAME[1]], loc="upper right", ncol=2, frameon=False, fontsize=9.5, bbox_to_anchor=(1.0, 0.995))
fig.suptitle("Taxes: colonization runs, 4 seeds (thick = seed 7)", x=0.01, ha="left", fontsize=14, color=INK)
fig.tight_layout(rect=(0, 0, 1, 0.93))
fig.savefig(D + "fig13_taxes.png", dpi=150)
print("ok")
