import csv, io, sys, matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter
D = "docs/economy_results/"
F = sys.argv[1] if len(sys.argv) > 1 else "scaling/empires4_200.out"
OUT = sys.argv[2] if len(sys.argv) > 2 else "fig20_empires.png"
rows = [l[4:] for l in open(D + F) if l.startswith("EMP,")]
r = list(csv.DictReader(io.StringIO("".join(rows))))
INK, MUTED, GRID = "#1f2328", "#6b7280", "#e5e7eb"
C = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100"]
emps = sorted(set(x["empire"] for x in r), key=int)
panels = [("colonies", "Colonies", 1), ("systems", "Star systems owned", 1), ("pop", "Population", 1), ("treasury", "Treasury (thousands)", 1000)]
fig, axs = plt.subplots(2, 2, figsize=(12, 7.2))
for ax, (k, title, div) in zip(axs.flat, panels):
    ymax = 0
    for i, e in enumerate(emps):
        xs = [int(x["tick"]) / 12 for x in r if x["empire"] == e]
        ys = [float(x[k]) / div for x in r if x["empire"] == e]
        ax.plot(xs, ys, color=C[i % 4], lw=2)
        ymax = max(ymax, max(ys))
    ax.set_title(title, loc="left", fontsize=11.5, color=INK)
    ax.set_ylim(0, ymax * 1.12); ax.set_xlim(0, 100)
    ax.grid(axis="y", color=GRID, lw=0.8); ax.set_axisbelow(True)
    for sp in ["top", "right"]: ax.spines[sp].set_visible(False)
    for sp in ["left", "bottom"]: ax.spines[sp].set_color(GRID)
    ax.tick_params(colors=MUTED, labelsize=9)
    ax.yaxis.set_major_formatter(FuncFormatter(lambda v, _: f"{v:,.0f}"))
    ax.set_xlabel("years", color=MUTED, fontsize=9)
from matplotlib.lines import Line2D
fig.legend([Line2D([], [], color=C[i % 4], lw=2) for i in range(len(emps))], [f"Empire {int(e) + 1}" for e in emps], loc="upper right", ncol=4, frameon=False, fontsize=9.5, bbox_to_anchor=(1.0, 0.995))
fig.suptitle("Four empires, 200 star systems, 100 years", x=0.01, ha="left", fontsize=14, color=INK)
fig.tight_layout(rect=(0, 0, 1, 0.93))
fig.savefig(D + OUT, dpi=150)
print("ok")
