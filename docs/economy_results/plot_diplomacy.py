import csv, io, matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
D = "docs/economy_results/"
F = "scaling/empires4_diplomacy.out"
rows = [l[4:] for l in open(D + F) if l.startswith("REL,")]
r = list(csv.DictReader(io.StringIO("".join(rows))))
INK, MUTED, GRID = "#1f2328", "#6b7280", "#e5e7eb"
pairs = sorted(set((x["a"], x["b"]) for x in r))
fig, axs = plt.subplots(2, 3, figsize=(13, 6.6), sharex=True, sharey=True)
for ax, (a, b) in zip(axs.flat, pairs):
    xs = [x for x in r if x["a"] == a and x["b"] == b]
    yrs = [int(x["tick"]) / 12 for x in xs]
    op = [float(x["opinion"]) if x["met"] == "1" else float("nan") for x in xs]
    for i in range(len(xs) - 1):
        if xs[i]["trade_treaty"] == "1":
            ax.axvspan(yrs[i], yrs[i + 1], color="#1baf7a", alpha=0.18, lw=0)
        if xs[i]["passage"] == "1":
            ax.axvspan(yrs[i], yrs[i + 1], ymin=0.0, ymax=0.05, color="#2a78d6", alpha=0.6, lw=0)
    for y0, y1, c in [(25, 100, "#1baf7a"), (-100, -25, "#eb6834")]:
        ax.axhspan(y0, y1, color=c, alpha=0.04, lw=0)
    ax.plot(yrs, op, color=INK, lw=1.8)
    ax.axhline(0, color=GRID, lw=0.8)
    ax.set_title(f"Empire {int(a) + 1} - Empire {int(b) + 1}", loc="left", fontsize=11, color=INK)
    ax.set_ylim(-100, 100); ax.set_xlim(0, 100)
    for sp in ["top", "right"]: ax.spines[sp].set_visible(False)
    for sp in ["left", "bottom"]: ax.spines[sp].set_color(GRID)
    ax.tick_params(colors=MUTED, labelsize=9)
for ax in axs[1]: ax.set_xlabel("years", color=MUTED, fontsize=9)
for ax in axs[:, 0]: ax.set_ylabel("opinion", color=MUTED, fontsize=9)
from matplotlib.patches import Patch
from matplotlib.lines import Line2D
fig.legend([Line2D([], [], color=INK, lw=1.8), Patch(color="#1baf7a", alpha=0.3), Patch(color="#2a78d6", alpha=0.6)],
           ["opinion (blank = not yet met)", "trade treaty in force", "free passage granted"], loc="upper right", ncol=3, frameon=False, fontsize=9.5, bbox_to_anchor=(1.0, 0.995))
fig.suptitle("Diplomacy between four empires (100 years)", x=0.01, ha="left", fontsize=14, color=INK)
fig.tight_layout(rect=(0, 0, 1, 0.92))
fig.savefig(D + "fig21_diplomacy.png", dpi=150)
print("ok")
