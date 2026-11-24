import csv, matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter
D="docs/economy_results/"
rows=list(csv.DictReader(open(D+"run_upgrades_1200.csv")))
d={k:[float(r[k]) for r in rows] for k in rows[0]}
SURF,INK,INK2,GRID="#fcfcfb","#0b0b0b","#52514e","#e6e5e1"
B,O,A,Y="#2a78d6","#eb6834","#1baf7a","#eda100"
plt.rcParams.update({"font.family":"DejaVu Sans","font.size":10,"axes.edgecolor":GRID,"axes.labelcolor":INK2,"xtick.color":INK2,"ytick.color":INK2,"text.color":INK,"axes.facecolor":SURF,"figure.facecolor":SURF})
fig,axs=plt.subplots(2,3,figsize=(14,7.4),dpi=140)
def base(ax,t,ymax=None,pcap=False):
    ax.set_title(t,loc="left",fontsize=11,fontweight="bold",pad=8); ax.grid(axis="y",color=GRID); ax.set_axisbelow(True)
    for sp in ("top","right","left"): ax.spines[sp].set_visible(False)
    ax.tick_params(length=0); ax.set_xlabel("tick",fontsize=9); ax.set_xlim(0,1400)
    ax.yaxis.set_major_formatter(FuncFormatter(lambda v,_: f"{v:,.0f}"))
    ax.axvline(600,color=INK2,lw=0.8,ls=(0,(3,3))); ax.text(610,0,"600",fontsize=8,color=INK2,va="bottom")
    if pcap: ax.axhline(100,color=INK2,lw=0.8,ls=(0,(3,3)))
def one(ax,k,t,c,ymax=None):
    base(ax,t); ax.plot(d["tick"],d[k],color=c,lw=2); ax.set_ylim(0,ymax or max(d[k])*1.1)
one(axs[0,0],"pop","Total population",B)
one(axs[0,1],"colonies_with_jobs","Colonies with jobs (of 100)",B,105)
one(axs[0,2],"facilities","Facilities",B)
ax=axs[1,0]; base(ax,"Average price per good",pcap=True); ax.set_ylim(0,105)
for k,c,l,ls in (("avg_ore",B,"Ore","-"),("avg_metal",O,"Metal","--"),("avg_parts",A,"Parts","-."),("avg_food",Y,"Food",":")):
    ax.plot(d["tick"],d[k],color=c,lw=2,ls=ls); ax.annotate(l,(1200,d[k][-1]),xytext=(1208,d[k][-1]),fontsize=9,va="center")
ax=axs[1,1]; base(ax,"Corporations by kind")
for k,c,l,ls in (("extractors",B,"Extractors","-"),("producers",O,"Producers","--"),("freight",A,"Freight","-.")):
    ax.plot(d["tick"],d[k],color=c,lw=2,ls=ls); ax.annotate(l,(1200,d[k][-1]),xytext=(1208,d[k][-1]),fontsize=9,va="center")
ax.set_ylim(0,max(d["extractors"])*1.1)
one(axs[1,2],"avg_level","Average facility level",O)
axs[1,2].yaxis.set_major_formatter(FuncFormatter(lambda v,_: f"{v:.1f}"))
fig.suptitle("Latest version (growth + upgrades), 100 planets, 1200 ticks",x=0.01,ha="left",fontsize=13,fontweight="bold")
fig.tight_layout(rect=(0,0,1,0.95)); fig.savefig(D+"fig5_upgrades_1200.png",facecolor=SURF); print("ok")
