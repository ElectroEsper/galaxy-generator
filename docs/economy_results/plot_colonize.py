import csv, matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter
D = "docs/economy_results/"
def ld(f):
    r = list(csv.DictReader(open(D + f)))
    return {k: [float(x[k]) for x in r] for k in r[0]}
d = ld("run_colonize.csv")
yrs = [t / 12 for t in d["tick"]]
INK, MUTED, GRID = "#1f2328", "#6b7280", "#e5e7eb"
C = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100"]
panels = [
    ("Population", [("pop", "population", C[0])]),
    ("Colonies settled / planets surveyed (of 100)", [("settled", "settled", C[0]), ("surveyed", "surveyed", C[1])]),
    ("Facilities", [("facilities", "facilities", C[0])]),
    ("Average price (base 10)", [("avg_food", "Food", C[2]), ("avg_parts", "Parts", C[3]), ("avg_ore", "Ore", C[1])]),
]
fig, axs = plt.subplots(2, 2, figsize=(12, 7.2))
for ax, (title, series) in zip(axs.flat, panels):
    ymax = 0
    offs = {"Food": -7, "Ore": 7}
    for k, name, col in series:
        ax.plot(yrs, d[k], color=col, lw=2)
        ymax = max(ymax, max(d[k]))
        if len(series) > 1:
            ax.annotate(name, (yrs[-1], d[k][-1]), xytext=(4, offs.get(name, 0)), textcoords="offset points", va="center", fontsize=9.5, color=INK)
    ax.set_title(title, loc="left", fontsize=11.5, color=INK)
    ax.set_ylim(0, ymax * 1.12)
    ax.set_xlim(0, yrs[-1] * 1.1)
    ax.grid(axis="y", color=GRID, lw=0.8); ax.set_axisbelow(True)
    for s in ["top", "right"]: ax.spines[s].set_visible(False)
    for s in ["left", "bottom"]: ax.spines[s].set_color(GRID)
    ax.tick_params(colors=MUTED, labelsize=9)
    ax.yaxis.set_major_formatter(FuncFormatter(lambda v, _: f"{v:,.0f}"))
    ax.set_xlabel("years", color=MUTED, fontsize=9)
fig.suptitle("Colonization from one Capital World: 100 planets, 50 years", x=0.01, ha="left", fontsize=14, color=INK)
fig.tight_layout(rect=(0, 0, 1, 0.95))
fig.savefig(D + "fig12_colonization.png", dpi=150)
print("ok")
