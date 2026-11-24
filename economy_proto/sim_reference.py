import random
random.seed(7)
GOODS=["ORE","METAL","PARTS","FOOD"]
RECIPES={"METAL":({"ORE":2},1.0),"PARTS":({"METAL":2},1.0)}   # out:(inputs, yield)
RAW={"ORE":1.5,"FOOD":1.5}   # raw good -> extraction cost per unit
BASE=10.0; K=0.12; COVER=10.0; CAPEX=80.0; UPKEEP=1.0; SHIP_COST=0.4
class Colony:
    def __init__(s,n,pop,rich):
        s.n=n;s.pop=pop;s.rich=rich
        s.stock={g:40.0 for g in GOODS};s.price={g:BASE for g in GOODS}
        s.use={g:1.0 for g in GOODS}; s.fl_use={}
    def pop_demand(s,g): return {"FOOD":s.pop*0.05,"PARTS":s.pop*0.012}.get(g,0.0)
    def tick(s):
        for g in GOODS:
            d=s.pop_demand(g); take=min(s.stock[g],d); s.stock[g]-=take
            used=take+s.fl_use.get(g,0)
            s.use[g]=0.9*s.use[g]+0.1*max(used,0.3)       # smoothed consumption rate
            cover=s.stock[g]/(s.use[g]*COVER)              # 1.0 = exactly target stock
            s.price[g]=BASE*max(0.1,min(10.0,max(cover,1e-3)**-0.7))
        s.fl_use={}
class Facility:
    def __init__(s,col,good): s.col=col;s.good=good;s.cap=1.0;s.bad=0
class Corp:
    def __init__(s,kind,cash): s.kind=kind;s.cash=cash;s.fac=[];ships=0;s.ships=0;s.broke=0
    def margin(s,c,g):
        if g in RAW: return c.price[g]*c.rich.get(g,0)-RAW[g]*c.rich.get(g,0) if c.rich.get(g,0)>0 else -1
        ins,y=RECIPES[g]; return y*c.price[g]-sum(n*c.price[i] for i,n in ins.items())
    def run(s,w):
        if s.kind=="FREIGHT": s.freight(w); return
        for f in s.fac:
            c,g=f.col,f.good
            if g in RAW:
                q=f.cap*c.rich[g]; c.stock[g]+=q; s.cash+=q*(c.price[g]-RAW[g])
            else:
                ins,y=RECIPES[g]; runs=f.cap
                for i,n in ins.items(): runs=min(runs,c.stock[i]/n)
                if runs<=0: continue
                for i,n in ins.items(): c.stock[i]-=runs*n; s.cash-=runs*n*c.price[i]; c.fl_use[i]=c.fl_use.get(i,0)+runs*n
                c.stock[g]+=runs*y; s.cash+=runs*y*c.price[g]
        s.cash-=UPKEEP*len(s.fac)
        s.consider_expansion(w)
    def consider_expansion(s,w):
        # close facilities that have lost money for a while
        for f in list(s.fac):
            m=s.margin(f.col,f.good)*(f.col.rich.get(f.good,1) if f.good in RAW else 1)-UPKEEP
            f.bad=f.bad+1 if m<=0 else 0
            if f.bad>20: s.fac.remove(f)
        if s.cash<CAPEX*1.5: return
        best=None
        for c in w.cols:
            for g in GOODS:
                is_raw=g in RAW
                if (s.kind=="EXTRACTOR")!=is_raw: continue
                if is_raw and c.rich.get(g,0)<=0: continue
                q=c.rich.get(g,1) if is_raw else 1.0
                sat=c.use[g]/(c.use[g]+q*2)          # price pressure from added output
                m=(s.margin(c,g)+0)*(q if is_raw else 1)*sat-UPKEEP
                if m>0 and (best is None or m>best[0]): best=(m,c,g)
        if best and CAPEX/best[0]<25:
            s.cash-=CAPEX; s.fac.append(Facility(best[1],best[2]))
    def freight(s,w):
        best=None
        for g in GOODS:
            for a in w.cols:
                if a.stock[g]<6: continue
                for b in w.cols:
                    if a is b: continue
                    m=b.price[g]-a.price[g]-SHIP_COST*w.dist(a,b)
                    if best is None or m>best[0]: best=(m,g,a,b)
        if best and best[0]>0.3:
            m,g,a,b=best; q=min(a.stock[g]*0.5,6*(1+s.ships),max(0,s.cash/a.price[g]))
            a.stock[g]-=q;b.stock[g]+=q;s.cash+=q*m; a.fl_use[g]=a.fl_use.get(g,0)+q
        s.cash-=0.5*(1+s.ships)
        if s.cash>CAPEX*3: s.cash-=CAPEX; s.ships+=1
class World:
    def __init__(s):
        s.cols=[Colony("A",80,{"ORE":2.0}),Colony("B",60,{"FOOD":2.0}),Colony("C",100,{"ORE":.5,"FOOD":.5}),Colony("D",40,{}),Colony("E",50,{"ORE":1.0})]
        s.corps=[Corp("EXTRACTOR",300),Corp("PRODUCER",300),Corp("FREIGHT",300)]
        s.sig={c.n:0.0 for c in s.cols}
    def dist(s,a,b): return 1+abs(ord(a.n)-ord(b.n))*0.5
    def tick(s,t):
        for k in s.corps: k.run(s)
        for c in s.cols:
            c.tick()
            prem=(c.price["FOOD"]+c.price["PARTS"])/(2*BASE)-1
            s.sig[c.n]=0.9*s.sig[c.n]+0.1*prem
            if t>20 and random.random()<max(0,s.sig[c.n]-0.25)*0.05 and len(s.corps)<12:
                s.corps.append(Corp(random.choice(["EXTRACTOR","PRODUCER"]),200))
        for k in s.corps:
            k.broke=k.broke+1 if k.cash<0 else 0
        s.corps=[k for k in s.corps if k.broke<15]
w=World()
for t in range(400):
    w.tick(t)
    if t%80==79:
        print(t+1,[(k.kind[0],int(k.cash),len(k.fac),k.ships) for k in w.corps])
        print("   ",{c.n:{g:round(c.price[g]) for g in GOODS} for c in w.cols})
