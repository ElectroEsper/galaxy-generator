import csv, matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter
D="docs/economy_results/"
def load(f):
    rows=list(csv.DictReader(open(D+f))); return {k:[float(r[k]) for r in rows] for k in rows[0]}
runs=[("Food x1 (2 sites)",load("run_upgrades.csv"),"#2a78d6","-"),("Food x2",load("run_food2.csv"),"#eb6834","--"),("Food x4",load("run_food4.csv"),"#1baf7a","-.")]
SURF,INK,INK2,GRID="#fcfcfb","#0b0b0b","#52514e","#e6e5e1"
plt.rcParams.update({"font.family":"DejaVu Sans","font.size":10,"axes.edgecolor":GRID,"axes.labelcolor":INK2,"xtick.color":INK2,"ytick.color":INK2,"text.color":INK,"axes.facecolor":SURF,"figure.facecolor":SURF})
fig,axs=plt.subplots(1,3,figsize=(14,4.4),dpi=140)
for ax,(k,t,ym) in zip(axs,[("pop","Total population",None),("colonies_with_jobs","Colonies with jobs (of 100)",105),("avg_food","Average Food price",105)]):
    ax.set_title(t,loc="left",fontsize=11,fontweight="bold",pad=8); ax.grid(axis="y",color=GRID); ax.set_axisbelow(True)
    for sp in ("top","right","left"): ax.spines[sp].set_visible(False)
    ax.tick_params(length=0); ax.set_xlabel("tick",fontsize=9); ax.set_xlim(0,600)
    top=0
    for n,d,c,ls in runs:
        ax.plot(d["tick"],d[k],color=c,lw=2,ls=ls,label=n); top=max(top,max(d[k]))
    ax.set_ylim(0,ym or top*1.1); ax.yaxis.set_major_formatter(FuncFormatter(lambda v,_: f"{v:,.0f}"))
    if k=="avg_food": ax.axhline(100,color=INK2,lw=0.8,ls=(0,(3,3))); ax.text(4,101.5,"price cap",fontsize=8,color=INK2)
axs[0].legend(frameon=False,loc="lower right",fontsize=9)
fig.suptitle("Does Food richness fix the shortage? (growth + upgrades, 100 planets) - only 2 of 100 planets can grow Food",x=0.01,ha="left",fontsize=12,fontweight="bold")
fig.tight_layout(rect=(0,0,1,0.93)); fig.savefig(D+"fig6_food_richness.png",facecolor=SURF)

cls=[("Neptunian (ice giant)",26),("Asteroid ring",18),("Dry husk",10),("Venerian",8),("Scorched wasteland",7),("Glacial taiga",4),("Gas giants (Jovian, Pegasean)",3),("Other rocky classes (2 of them bear life)",24)]
fig,ax=plt.subplots(figsize=(9,4.2),dpi=140)
names=[c[0] for c in cls]; vals=[c[1] for c in cls]; cols=["#2a78d6"]*(len(cls)-1)+["#eb6834"]
ax.barh(names[::-1],vals[::-1],color=cols[::-1],height=0.62)
for i,v in enumerate(vals[::-1]): ax.text(v+0.4,i,str(v),va="center",fontsize=9)
for sp in ("top","right","left"): ax.spines[sp].set_visible(False)
ax.tick_params(length=0); ax.set_xlim(0,31); ax.grid(axis="x",color=GRID); ax.set_axisbelow(True)
ax.set_title("What the 100 generated planets are (seed 7)",loc="left",fontsize=11,fontweight="bold")
fig.tight_layout(); fig.savefig(D+"fig7_planet_mix.png",facecolor=SURF); print("ok")
