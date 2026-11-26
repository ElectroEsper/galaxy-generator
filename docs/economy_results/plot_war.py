import csv,io,sys,matplotlib; matplotlib.use("Agg"); import matplotlib.pyplot as plt
src=sys.argv[1]; L=open(src).read().splitlines()
emp=list(csv.DictReader(io.StringIO("\n".join(l[4:] for l in L if l.startswith("EMP,")))))
ev=[l.split(",",2) for l in L if l.startswith("EVENT,") and ("WAR:" in l or "PEACE" in l)]
cols=["#2a6fdb","#d9822b","#3b9a57","#9b59b6"]
fig,ax=plt.subplots(3,1,figsize=(10,9),sharex=True)
for i,(k,t) in enumerate([("strength","Military strength"),("exhaustion","War exhaustion"),("systems","Star systems owned")]):
  for e in range(4):
    r=[x for x in emp if int(x["empire"])==e]
    ax[i].plot([int(x["tick"])/12 for x in r],[float(x[k]) for x in r],color=cols[e],lw=2,label=f"Empire {e+1}")
  ax[i].set_title(t,loc="left"); ax[i].grid(alpha=.25)
  for _,tk,txt in ev: ax[i].axvline(int(tk)/12,color="#c0392b" if "WAR" in txt else "#7f8c8d",ls="--",lw=1)
ax[0].legend(); ax[2].set_xlabel("Year (dashed: red = war declared, grey = peace)")
fig.tight_layout(); fig.savefig(sys.argv[2],dpi=130)
