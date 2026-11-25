import csv, matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter
D = "docs/economy_results/"
def ld(f):
    r = list(csv.DictReader(open(D + f)))
    return {k: [float(x[k]) for x in r] for k in r[0]}
INK, MUTED, GRID = "#1f2328", "#6b7280", "#e5e7eb"
runs = [("seed 7", ld("run_booms_s7.csv"), "#2a78d6"), ("seed 23", ld("run_booms_s23.csv"), "#eb6834")]
panels = [("known_systems", "Charted star systems"), ("survey_ships", "Survey ships (ticks = sector discoveries)"),
          ("surveyed", "Bodies surveyed (of 500)"), ("settled", "Colonies settled")]
fig, axs = plt.subplots(2, 2, figsize=(12, 7.2))
for ax, (k, title) in zip(axs.flat, panels):
    ymax = 0
    for name, d, c in runs:
        yrs = [t / 12 for t in d["tick"]]
        ax.plot(yrs, d[k], color=c, lw=2)
        ymax = max(ymax, max(d[k]))
    if k == "survey_ships":
        for i, (name, d, c) in enumerate(runs):
            ev = [d["tick"][j] / 12 for j in range(1, len(d["tick"])) if d["sector_events"][j] > d["sector_events"][j - 1]]
            ax.plot(ev, [ymax * (1.06 + 0.04 * i)] * len(ev), "|", color=c, ms=9, mew=2)
        ymax *= 1.08
    ax.set_title(title, loc="left", fontsize=11.5, color=INK)
    ax.set_ylim(0, ymax * 1.12); ax.set_xlim(0, 100)
    ax.grid(axis="y", color=GRID, lw=0.8); ax.set_axisbelow(True)
    for sp in ["top", "right"]: ax.spines[sp].set_visible(False)
    for sp in ["left", "bottom"]: ax.spines[sp].set_color(GRID)
    ax.tick_params(colors=MUTED, labelsize=9)
    ax.yaxis.set_major_formatter(FuncFormatter(lambda v, _: f"{v:,.0f}"))
    ax.set_xlabel("years", color=MUTED, fontsize=9)
from matplotlib.lines import Line2D
fig.legend([Line2D([], [], color=c, lw=2) for _, _, c in runs], [n for n, _, _ in runs], loc="upper right", ncol=2, frameon=False, fontsize=9.5, bbox_to_anchor=(1.0, 0.995))
fig.suptitle("Exploration booms: known-space horizon + sector discoveries (500 planets, 100 years)", x=0.01, ha="left", fontsize=14, color=INK)
fig.tight_layout(rect=(0, 0, 1, 0.93))
fig.savefig(D + "fig18_exploration_booms.png", dpi=150)
print("ok")
