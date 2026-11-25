import csv, matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter
D="docs/economy_results/"
def load(f):
    rows=list(csv.DictReader(open(D+f)))
    return {k:[float(r[k]) for r in rows] for k in rows[0]}
def ld(f):
    d=load(f)
    if "hydro_facilities" not in d: d["hydro_facilities"]=[0.0]*len(d["tick"])
    return d
runs=[("freight capped",ld("run_hydro2.csv"),"#2a78d6","-"),("freight uncapped",ld("run_uncapped.csv"),"#eb6834","--")]
SURF,INK,INK2,GRID="#fcfcfb","#0b0b0b","#52514e","#e6e5e1"
plt.rcParams.update({"font.family":"DejaVu Sans","font.size":10,"axes.edgecolor":GRID,"axes.labelcolor":INK2,"xtick.color":INK2,"ytick.color":INK2,"text.color":INK,"axes.facecolor":SURF,"figure.facecolor":SURF})
panels=[("pop","Total population",None),("colonies_with_jobs","Colonies with jobs (of 100)",105),("ships","Freight ships",None),
        ("avg_water","Average Water price",105),("avg_parts","Average Parts price",105),("avg_food","Average Food price",105)]
fig,axs=plt.subplots(2,3,figsize=(13.5,7.4),dpi=140)
offs=[(5,6),(5,0),(5,-6)]
for ax,(k,t,ym) in zip(axs.flat,panels):
    ax.set_title(t,loc="left",fontsize=11,fontweight="bold",pad=8)
    ax.grid(axis="y",color=GRID,lw=1); ax.set_axisbelow(True)
    for sp in ("top","right","left"): ax.spines[sp].set_visible(False)
    ax.tick_params(length=0); ax.set_xlabel("tick",fontsize=9)
    ymax=0
    for (name,d,c,ls),off in zip(runs,[(5,8),(5,0),(5,-8)]):
        ax.plot(d["tick"],d[k],color=c,lw=2,ls=ls,solid_capstyle="round",label=name)
        ymax=max(ymax,max(d[k]))
    ax.set_xlim(0,780); ax.set_ylim(0,ym if ym else ymax*1.08)
    ax.yaxis.set_major_formatter(FuncFormatter(lambda v,_: f"{v:,.0f}"))
    if k.startswith("avg_"): ax.axhline(100,color=INK2,lw=0.8,ls=(0,(3,3))); ax.text(4,101.5,"price cap",fontsize=8,color=INK2)
    # direct labels, nudged apart
    ends=sorted([(d[k][-1],name,c) for name,d,c,ls in runs])
    last=None
    for v,name,c in ends:
        y=v if last is None or v-last>(ax.get_ylim()[1]*0.07) else last+ax.get_ylim()[1]*0.07
        ax.annotate(name,(600,v),xytext=(606,y),textcoords=("data","data"),fontsize=8.5,va="center",color=INK)
        last=y
h,l=axs[0,0].get_legend_handles_labels()
fig.legend(h,l,loc="upper right",ncol=2,frameon=False,fontsize=9.5,bbox_to_anchor=(1.0,0.995))
fig.suptitle("Freight cap removed, 100 planets",x=0.01,ha="left",fontsize=13,fontweight="bold")
fig.tight_layout(rect=(0,0,1,0.95)); fig.savefig(D+"fig9_freight_uncapped.png",facecolor=SURF)
print('ok')
