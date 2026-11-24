import csv, matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter
D="docs/economy_results/"
def load(f):
    rows=list(csv.DictReader(open(D+f)))
    return {k:[float(r[k]) for r in rows] for k in rows[0]}
base,grow=load("run_growth0.csv"),load("run_growth1.csv")
SURF,INK,INK2,GRID="#fcfcfb","#0b0b0b","#52514e","#e6e5e1"
BLUE,ORANGE,AQUA,YELLOW="#2a78d6","#eb6834","#1baf7a","#eda100"
plt.rcParams.update({"font.family":"DejaVu Sans","font.size":10,"axes.edgecolor":GRID,"axes.labelcolor":INK2,
  "xtick.color":INK2,"ytick.color":INK2,"text.color":INK,"axes.facecolor":SURF,"figure.facecolor":SURF})
def style(ax,title,ylab=None,ymax=None):
    ax.set_title(title,loc="left",fontsize=11,color=INK,fontweight="bold",pad=8)
    ax.grid(axis="y",color=GRID,lw=1); ax.set_axisbelow(True)
    for s in ("top","right","left"): ax.spines[s].set_visible(False)
    ax.tick_params(length=0); ax.set_xlim(0,640)
    if ymax: ax.set_ylim(0,ymax)
    ax.set_xlabel("tick",fontsize=9)
    ax.yaxis.set_major_formatter(FuncFormatter(lambda v,_: f"{v:,.0f}"))
def line(ax,x,y,c,label,ls="-"):
    ax._ymax=max(getattr(ax,'_ymax',0),max(y))
    ax.plot(x,y,color=c,lw=2,ls=ls,solid_capstyle="round")
    ax.annotate(label,(x[-1],y[-1]),xytext=(5,0),textcoords="offset points",color=INK,fontsize=9,va="center")

# ---- Figure 1: baseline vs growth
fig,axs=plt.subplots(2,3,figsize=(13,7.2),dpi=140)
panels=[("pop","Total population",None),("colonies_with_jobs","Colonies with jobs (of 100)",105),
        ("in_shortage","Colonies in shortage (of 100)",105),("facilities","Facilities",None),
        ("avg_parts","Average Parts price",105),("avg_food","Average Food price",105)]
for ax,(k,t,ym) in zip(axs.flat,panels):
    style(ax,t,ymax=ym)
    line(ax,base["tick"],base[k],BLUE,"no growth")
    line(ax,grow["tick"],grow[k],ORANGE,"growth")
    if not ym: ax.set_ylim(0,ax._ymax*1.08)
    if k.startswith("avg_"): ax.axhline(100,color=INK2,lw=0.8,ls=(0,(3,3))); ax.text(4,101.5,"price cap",fontsize=8,color=INK2)
fig.suptitle("100-planet economy: baseline (PR #8) vs growth drivers (births + maintenance demand)",x=0.01,ha="left",fontsize=13,fontweight="bold",color=INK)
fig.tight_layout(rect=(0,0,1,0.95)); fig.savefig(D+"fig1_baseline_vs_growth.png",facecolor=SURF); plt.close(fig)

# ---- Figure 2: growth run detail
fig,axs=plt.subplots(1,3,figsize=(14,4.6),dpi=140)
ax=axs[0]; style(ax,"Growth run - average price per good",ymax=105)
for k,c,l,ls in (("avg_ore",BLUE,"Ore","-"),("avg_metal",ORANGE,"Metal","--"),("avg_parts",AQUA,"Parts","-."),("avg_food",YELLOW,"Food",":")):
    line(ax,grow["tick"],grow[k],c,l,ls)
ax.axhline(100,color=INK2,lw=0.8,ls=(0,(3,3)))
ax=axs[1]; style(ax,"Growth run - corporations by kind")
for k,c,l,ls in (("extractors",BLUE,"Extractors","-"),("producers",ORANGE,"Producers","--"),("freight",AQUA,"Freight","-.")):
    line(ax,grow["tick"],grow[k],c,l,ls)
ax=axs[2]; style(ax,"Growth run - population and facilities")
line(ax,grow["tick"],grow["pop"],BLUE,"population")
line(ax,grow["tick"],grow["facilities"],ORANGE,"facilities","--")
for a in axs:
    if not a.get_ylim()[1]>1 or a.get_title().startswith(('Growth run - corporations','Growth run - population')): a.set_ylim(0,a._ymax*1.08)
for a in axs: a.set_ylim(bottom=0)
fig.tight_layout(); fig.savefig(D+"fig2_growth_detail.png",facecolor=SURF); plt.close(fig)
print("ok")
