import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
D = "docs/economy_results/scaling/"
INK, MUTED, GRID = "#1f2328", "#6b7280", "#e5e7eb"
def parse(f):
    t, p = [], {}
    for l in open(D + f):
        if l.startswith("TIME,decade="):
            parts = dict(x.split("=") for x in l.strip().split(",")[1:])
            t.append((int(parts["decade"]) * 10, float(parts["ms_per_tick"]), int(parts["colonies"])))
        elif l.startswith("PROFILE,"):
            _, k, v = l.strip().split(","); p[k] = float(v) / 1000
    return t, p
C = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100"]
fig, (a1, a2) = plt.subplots(1, 2, figsize=(12, 4.8))
for (n, c) in zip(["25", "50", "100", "200"], C):
    t, _ = parse(f"scale_{n}.out")
    a1.plot([x[0] for x in t], [x[1] for x in t], color=c, lw=2, marker="o", ms=5)
    a1.annotate(f"{n} systems", (t[-1][0], t[-1][1]), xytext=(5, {"50": 8, "200": -8}.get(n, 0)), textcoords="offset points", va="center", fontsize=9, color=INK)
t, _ = parse("scale_100_cached2.out")
a1.plot([x[0] for x in t], [x[1] for x in t], color=C[2], lw=2, ls="--", marker="o", ms=5)
a1.annotate("100, cached", (t[-1][0], t[-1][1]), xytext=(5, 0), textcoords="offset points", va="center", fontsize=9, color=INK)
a1.set_title("Milliseconds per month simulated (colonies: 10, 20, 30, 40, ~52)", loc="left", fontsize=11, color=INK)
a1.set_xlabel("years", color=MUTED, fontsize=9); a1.set_xlim(0, 58); a1.set_ylim(0, 650)
_, pb = parse("scale_100.out"); _, pa = parse("scale_100_cached2.out")
keys = ["corp_extractor", "corp_surveyor", "corp_producer", "corp_freight", "markets_emergence", "sector_events", "state", "other"]
def g(p, k):
    return p.get(k, 0) if k != "other" else sum(v for kk, v in p.items() if kk not in keys)
names = ["Extractors", "Surveyors", "Producers", "Freight", "Markets + emergence", "Sector events", "State", "Other"]
y = range(len(keys))
a2.barh([i + 0.2 for i in y], [g(pb, k) for k in keys], height=0.38, color="#2a78d6", label="before")
a2.barh([i - 0.2 for i in y], [g(pa, k) for k in keys], height=0.38, color="#eb6834", label="cached")
a2.set_yticks(list(y)); a2.set_yticklabels(names, fontsize=9, color=INK); a2.invert_yaxis()
a2.set_title("Where the time goes: 100 systems, 50 years (seconds)", loc="left", fontsize=11, color=INK)
a2.legend(frameon=False, fontsize=9, loc="lower right")
for ax in (a1, a2):
    ax.grid(axis="x" if ax is a2 else "y", color=GRID, lw=0.8); ax.set_axisbelow(True)
    for sp in ["top", "right"]: ax.spines[sp].set_visible(False)
    for sp in ["left", "bottom"]: ax.spines[sp].set_color(GRID)
    ax.tick_params(colors=MUTED, labelsize=9)
fig.suptitle("Scaling test: cost follows colonies, not galaxy size", x=0.01, ha="left", fontsize=14, color=INK)
fig.tight_layout(rect=(0, 0, 1, 0.92))
fig.savefig("docs/economy_results/fig19_scaling.png", dpi=150)
print("ok")
