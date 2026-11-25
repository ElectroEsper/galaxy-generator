# Corporation logic prototype

GDScript: `goods.gd`, `colony_market.gd`, `corporation.gd`, `economy_sim.gd` (headless driver).
`sim_reference.py` is a Python mirror used to sanity-check dynamics (`python3 sim_reference.py`);
tested headless on Godot 4.7:
`godot --headless --path . --script res://economy_proto/run_headless.gd`

## What it models
- Price derived from stock cover (stateless, bounded) rather than an integrated price.
- Demand is *desired* consumption (pop + recipe input draws), so stock-outs stay visible.
- Demand-pull expansion: Extractors/Producers only build while regional capacity < HEADROOM x regional use.
- Producers favour sites whose inputs are actually stocked; losing facilities close; insolvent or idle corporations dissolve.
- Freight: best lane per tick, capped by stock/cash/fleet; fleet grows only when busy, shrinks when idle; per-ship upkeep.
- Emergence: shortage premium raises founding chance; derived demand picks Extractor vs Producer.

## Known problems
1. Steady state reached by ~tick 160 in the seed-7 run (capacity settles ~1.25x use, prices flat); needs testing with other seeds, shocks (pop jumps, a colony losing its resource) and larger maps.
2. Freight cash still grows slowly with no lane capacity / congestion model.
3. Emergence is global, not tied to a specific colony; local-business layer, Surveyors, acquisitions and Workforce are not implemented.

## Visual layer
Open `res://economy_proto/economy_view.tscn` and run it. Colonies are circles sized by population and tinted green→red by Food/Parts shortage;
ships are triangles coloured by cargo travelling along lanes (lane thickness = recent traffic). Keys: space = pause, up/down = sim speed.
`economy_sim.gd` exposes `setup()`, `step()` and a `shipment_made` signal, so the view only listens and draws.

## Local-business layer
Every colony with a raw resource runs a small informal extractor (`ColonyMarket.local_output`). Emergence is local:
1. Promotion - banked local profit passes `PROMOTE_CASH` and the business incorporates as an Extractor at home.
2. Attraction - workforce demand (jobs) outpaces population (`workforce_gap`) and an outside corporation is founded.
Population drifts toward what jobs support, capped by `max_pop` (habitability ceiling).

## Galaxy link
`economy_view.tscn` now builds its colonies from the star generator (`galaxy_colonies.gd`): it generates stars, takes the best planet per star
(scored by Ore + 1.5 x Edibles richness, +3 if temperate), converts Tier 0 richness (0-10) to extraction units (/5), sets the population ceiling from
mass and life stage, and places colonies at the star's map position. `PlanetResources.generate_richness()` fills richness during planet generation.
The headless runner (`run_headless.gd`) still uses the hand-made 5-colony map unless `use_galaxy` is set.

Findings from the first galaxy run:
- Typical metallicity gives low Ore richness (x0.2-0.4) and rich Food, so Producers starve and Parts sit at the price cap -> most colonies show red.
- Planet generation marks some Steam Worlds as having life (life stage uses water but not the final greenhouse temperature) - worth gating.

## 100-planet test (`run_headless_100.gd`)
Every generated planet (rocky, giant, belt) is a colony (`GalaxyColonies.generate_all`). Result after the scale fixes below: it runs
without crashing in a few seconds, but the economy does NOT hold up at this scale yet.

Fixes it forced (also applied to the 5-colony map, which still stabilises):
- demand floor was 0.3/colony -> 30 units of phantom demand over 100 colonies (now 0.02); founding only counts raw demand that has a site with richness + a free slot.
- workforce slots per colony (`max_pop / JOBS_PER_FACILITY`) so industry can't stack without limit.
- Freight: one voyage per ship per tick, candidate lanes = cheapest sources x dearest destinations (keeps it fast), fleet capped by colony count, max 4 Freight corporations.
- funded idle corporations wait 150 ticks instead of 30 (every colony starts with 40 of each good, so Parts look cheap at first).
- site choice discounts output the colony's own market can't absorb.

Still broken at 100 colonies:
1. Only ~2 colonies host all extraction (the only sites with meaningful richness); 90+ colonies have no local economy and no jobs.
2. No Producer survives: the Ore -> Metal -> Parts chain starts from the initial 40-unit stock, and Freight only moves inputs once a price spread opens, which is too slow, so the Producer bleeds upkeep and goes insolvent. Parts then sit at the price cap everywhere.
3. 'in_shortage' is dominated by Parts being unavailable, so ~100% of colonies read as short.
Next ideas: input contracts / producer-triggered Freight, per-colony local subsistence (so barren colonies still have a baseline economy), and richer Ore on more planets.

## Subsistence + producer input requests (follow-up to the 100-planet test)
- Corporations now dissolve ONLY by bankruptcy. Idle ones wait for an opening; emergence won't found a redundant corporation while a funded idle one of that kind exists.
- Every colony has subsistence output (Food and Parts for `BASE_SELF_POP`), counted as capacity, so barren colonies keep a baseline economy and corporations only build for demand beyond it.
- Producers post input requests when their shelf runs low; Freight serves those contracts first (producer pays the shipping fee), then falls back to price-spread arbitrage.

100-planet result: shortage falls from ~100% to 0% of colonies by tick 320, Parts settle at 3-8, Food at ~8, 6-11 Producers persist, corporation count stays bounded.
Side effect: with subsistence covering baseline demand there is little unmet demand, so population and industry stagnate (the 5-colony map shrinks to a few facilities).
That matches the design note that an economy without an export driver stagnates - but it means growth needs an explicit demand source (empire/player consumption, ship and building upkeep, natural population growth).

## Growth drivers + graphs (docs/economy_results/)
Added natural population growth (births need food and room, starvation kills, jobs only attract migrants), maintenance demand (Metal per
population, Parts per facility), and chronic-loser facility closure. `run_headless_csv.gd` writes a CSV time series
(`godot --headless --path . --script res://economy_proto/run_headless_csv.gd -- growth=1 ticks=600`); `docs/economy_results/plot.py` draws the figures.

Result (100 planets, 600 ticks, seed 7): growth lifts population ~3,000 -> ~8,400 and spreads industry to ~90 of 100 colonies (1,700 facilities)
versus 2 colonies and a collapse to zero facilities without growth. But all colonies end in shortage with Food ~93 and Parts ~78 (cap 100), and Ore/Metal ~45-50:
supply, not demand, is now the ceiling. Suspects: few planets can grow Food and Ore richness is low; Producers compete with Extractors for the same
per-colony workforce slots; Freight is capped at 25 ships.

## Facility upgrades
Corporations can now upgrade a facility (level 1-4) instead of building a new one. Each level adds 60% of base output, 25% of base upkeep, and no extra
workforce slot; cost = CAPEX x (0.4 + 0.2 x level). Each decision picks the best payback across "new facility" and "upgrade". An extractor site is capped at
richness x 40 per good regardless of upgrades (`EXTRACT_CAP_MULT`). Figures: `docs/economy_results/fig3_upgrades.png`, `fig4_upgrade_detail.png`.

100 planets, 600 ticks, seed 7 (growth vs growth + upgrades): facilities 1,700 -> 620; average level 2.0 (~2,000 upgrades); Ore price 46 -> 12, Parts 78 -> 42, Food 93 -> 67.
But population ends lower (8,400 -> 5,900) and, after about tick 380, colonies with jobs fall from 84 to 48 while population declines: Food is still short, so starvation caps
population, and the late decline is unexplained (suspect: chronic-loser closure interacting with upgraded, fewer, larger facilities).

### 1200-tick run (growth + upgrades)
`docs/economy_results/fig5_upgrades_1200.png`. The decline seen around tick 380 is a one-off contraction, not a collapse: from tick ~600 to 1200 it holds steady
(population ~6,000; 37-45 colonies with jobs; ~620-640 facilities; average level ~2.1; Food ~55-60, Parts ~42, Ore ~10, Metal 10-55; ~99 colonies still read as in shortage because of Food).

## Is Food richness the ceiling? (no - the number of Food worlds is)
`run_headless_csv.gd ... food=N` multiplies Edibles richness (`GalaxyColonies.food_mult`). Doubling or quadrupling it barely moves anything
(Food price 67 -> 53, population ~5,600-5,900): only **2 of the 100 planets** have any Food at all.
`diag_planets.gd` shows the mix (seed 7): 26 Neptunian, 18 asteroid rings, 10 Dry Husk, 8 Venerian, 7 Scorched Wasteland, 3 gas giants, and 54 planets with Ore.
Figures: `docs/economy_results/fig6_food_richness.png`, `fig7_planet_mix.png`.
Implication: life-bearing worlds are rare by design of the generator, so Food must be traded in from a few garden worlds or made synthetically
(e.g. a Hydroponics recipe from Water/Volatiles), otherwise most colonies cap out at the subsistence population.
Also noted: life stage is decided from water + age + geology before the final greenhouse temperature, so some hot or frozen worlds can count as living.

## Hydroponics (synthetic Food) and Water
New good `WATER` (raw, extracted from planets with Water richness) and a Producer recipe `FOOD <- 2 WATER + 0.1 PARTS`, so any colony can make Food that
has Water delivered by Freight. Food can now be extracted (farming, rare life-bearing worlds) or manufactured (hydroponics, anywhere); `Facility.recipe_mode`
tells them apart. Ice giants now carry Water richness (water/ammonia ices); 45 of the 100 test planets have Water.
`run_headless_csv.gd` also logs `hydro_facilities`, `food_extractors`, `avg_water`, `water_sites`. Figure: `docs/economy_results/fig8_hydroponics.png`.

600 ticks, 100 planets, growth + upgrades: population ~5,900 -> ~7,800 (rocky water only) -> ~8,800 (with ice-giant water), peak ~9,300;
colonies with jobs 48 -> 62 -> 80; 90-250 hydroponics facilities. Food stays expensive (~75-80) and Parts/Ore/Water rise too (Water ~59): the economy is now
broadly supply-limited (worker slots, Freight, Water), not short of one good.

## Freight cap removed
The per-corporation fleet cap and `MAX_FREIGHT_CORPS` are gone; fleets now grow only on cash and utilisation (>0.85). Figure: `docs/economy_results/fig9_freight_uncapped.png`.
600 ticks, 100 planets: population ~8,800 -> ~10,700, colonies with jobs 80 -> 99, Water price ~59 -> ~18 (water now reaches the hydroponics),
Parts ~65 -> ~83 (more facilities to maintain), Food unchanged ~78. Still one Freight corporation, but its fleet grows by one ship every tick
(591 by tick 600) without utilisation ever dropping: ship growth has no natural brake yet.

## Long run (6,000 ticks, 100 planets)
Figure: `docs/economy_results/fig10_long_run.png`; data `run_6000_capped.csv`, `run_6000_uncapped.csv`.
Both settle by tick ~600 and stay flat for 5,400 more ticks: no collapse, no drift. Uncapped: pop ~11,000, 100/100 colonies with jobs, Water ~18.
Capped (old main): pop ~8,500, 80 colonies with jobs after a dip to ~62 around tick 1,500, Water ~60 (shipping-limited).
Parts and Food converge to ~75 in both runs. Uncapped fleet grows linearly to ~6,000 ships (needs a brake).

## Ship classes (experiment)
Freight fleets now have a hull class (cargo x2, upkeep x1.4 per class, max 6); the corporation either buys a ship or refits the whole fleet, whichever is cheaper per unit of cargo.
Growth requires >85% of voyages finding a lane AND average hold fill > 50%.
Result (600 ticks, 100 planets): the fleet jumps to class 4 (48 units) within ~40 ticks and then stops at 4-16 ships; Water stays ~57, pop ~7,400-8,000 (about the old capped result, worse than uncapped ~10,700).
Finding: hold size is not the bottleneck. A voyage is one delivery per tick and each pickup is limited to half the source stock, so what matters is deliveries per tick,
and bigger hulls just run half-empty. Next: let a ship serve several lanes per tick (or voyages take multiple ticks by distance), then add the cost brake.
Data: `docs/economy_results/run_ship_classes.csv`.

## Sailing-time budget for Freight
A ship no longer makes exactly one delivery per tick: the fleet has `(1+ships) * SHIP_TIME` sailing time per tick and each delivery costs its lane distance + `LOAD_TIME`, so short lanes allow several deliveries per ship.
Growth needs busy sailing time (>85%), hold fill > `GROW_FILL` (0.15) and a payback check on the *marginal* delivery's profit. Data: `docs/economy_results/run_time_budget.csv`.
Result (600 ticks, 100 planets): matches the uncapped run (pop ~10,800, 97-100 colonies with jobs, Water ~12) but ships still grow ~1 per tick to ~590.
The payback brake never bites: a marginal delivery earns (price spread x up to 48 units) against ~4 upkeep, so every extra ship pays back in a few ticks. Persistent price spreads
(Parts ~80 everywhere) keep Freight hugely profitable, so a rising per-ship cost or fleet-size friction (ports, crews, congestion) is needed.

## Port congestion (bounds the Freight fleet)
Each colony can load/unload only `PORT_BASE (2) + pop/100` deliveries per tick, whoever's ships they are. Ships that find every useful port full earn nothing, so the fleet stops growing on its own.
Figure: `docs/economy_results/fig11_port_congestion.png`; data `run_6000_ports.csv` (new column `port_use`).
6,000 ticks, 100 planets: fleet settles at 66 ships (uncapped: ~6,000), 100/100 colonies with jobs, pop ~10,400-11,300 (uncapped ~11,000, old capped ~8,500),
Water ~18-40 (uncapped ~18, capped ~60), Parts ~70, port use ~65%. Fleet growth is slow (53 at tick 600, 63 at 3,000, 66 from tick ~4,500) and stable.

## Parts supply diagnosis (tick 400, 100 planets) - `economy_proto/diag_goods.gd`
Parts is not short of *capacity* (capacity 311 vs use 240, cover 1.3) yet 77 of 100 colonies are stocked out and the price sits at ~80. Findings:
- **Ore is the real shortage**: cover 0.49 (use 1,024 vs capacity 500). Metal (2 Ore each) and so Parts are input-starved; nominal producer capacity overstates real output.
- Ore is **not richness-limited**: 46 Ore sites could yield 1,597, only ~490 is extracted, 31 sites have headroom.
- Expansion at those sites was blocked by the *local absorption* factor (output only counted against the colony's own Ore use). Fixed with `EXPORT_SHARE`: a site also counts the regional deficit Freight can carry.
  Effect: Ore stockouts 10 -> 1, Ore/Metal/Parts facilities +20%, but Parts price unchanged (~85) and Parts stockouts 77 -> 68.
- The next wall is **workforce slots at the Ore sites**: 35 sites have headroom but only 1 has a free slot (avg pop ~100 -> ~12 slots, taken by Water/Food extractors and producers). Overall 1,689 of 2,229 slots are used.
- Corporations are rich (millions in cash) and the corp cap is filled by 53 Extractor corps vs only 6 Producers: capital is not the constraint.
Candidates: let big extractor sites take more workers per slot-level (upgrades already do), let producers locate where inputs arrive, or raise slots for resource colonies.

## Extractors take half a worker slot; max facility level 8
Mines are capital-heavy, so `EXTRACTOR_SLOT = 0.5`: a raw-extraction facility uses half a workforce slot (`ColonyMarket.extractor_count`). `MAX_LEVEL` raised 4 -> 8 (almost unused; level 4 is still the practical top).
Diagnostic at tick 400 (`diag_goods.gd`): Ore extracted 498 -> 913, Ore cover 0.49 -> 0.55 with 0 stockouts (was 10), Metal stockouts 27 -> 1, Water price 25 -> 10.
1200-tick run (`run_halfslot_1200.csv`): pop ~11,200, 98-100 colonies with jobs, Ore ~30, Metal ~36-40, Water ~32-38, Food ~63-75, **Parts still ~74**.
Parts capacity now exceeds use (414 vs 343) but 63 of 100 colonies are still out of stock: Parts is a *distribution* problem (a few producer colonies, many consumers, port slots / voyage size),
not production. Next: look at where Parts is made vs consumed and at producer-colony port load.

## Parts distribution diagnosis (`economy_proto/diag_parts.gd`)
Parts capacity is spread over all 100 colonies (~4 each), not concentrated, and Metal is plentiful (0 stockouts), yet 63 colonies are out of Parts. Findings:
- **The Parts chain is Ore-limited by arithmetic.** 1 Parts = 2 Metal = 4 Ore. Parts use ~340/tick would need ~1,360 Ore for Parts alone, plus Metal for maintenance; the whole economy extracts ~900 Ore.
  The Parts price therefore pins at ~2x the Metal price (84 vs 42): producers sit at ~zero margin and idle, which looks like "capacity exists but no stock".
- Every good has the same `BASE_PRICE` (10) although recipes multiply inputs, so chain goods need scarcity pricing just to break even. Tried per-good base prices (Ore 10, Metal 28, Parts 70, Food 20, Water 6):
  Parts stockouts 63 -> 23, but Ore stockouts 10 -> 43, Food 70, Water 62 and prices in the hundreds: the Ore wall just moves. Reverted; not a fix on its own.
- Freight contract order now rotates each tick (no low-index bias) and contract deliveries count toward the fleet's marginal-profit growth check. No visible change in Parts, kept as correctness fixes.
Real levers: more Ore (mining slots/colonies, richer or more numerous Ore sites, recycling), or less Parts demand (maintenance per facility 0.08, hydroponics Parts 0.1, yield 1 Parts per 2 Metal).

## Salvage / recycling
`SALVAGE_RATE = 0.5`: half of what maintenance consumes (Metal per pop, Parts per facility) is recovered as scrap and returns to the colony's stock. Maintenance was over half of Parts demand, so this cuts net Parts (and thus Ore) demand directly.
Tick 400 diagnostic: Parts stockouts 63 -> 31 colonies, Parts price 84 -> 66, Food stockouts 57 -> 47, Metal stockouts 4.
1200-tick run (`run_salvage_1200.csv`) vs the half-slot run: pop 11,181 -> 11,708, 100/100 colonies with jobs, Parts ~74 -> ~62, Food ~63 -> ~61, Ore/Metal/Water about the same (~32/38/35).
Everything still reads "in shortage" by the metric (price > 2x base for Food+Parts), but the gap is closing slowly; the remaining Ore wall (46 Ore sites, workforce slots) is the structural limit.

## Asteroid belts hold the Ore; ports were the choke (`diag_belts.gd`)
Belts are already colonies with Ore, but at tick 400 the 18 belts (990 of the 1,600 Ore site capacity) extracted only 136 (14%) and sat on **400-2,400 unsold Ore each at price 1-5**, so their mines idled while Metal producers elsewhere starved.
The Freight fleet was the bottleneck, not richness: ships at class 4 (48 units) ran 15% full with 21% of sailing time unused, because small belt colonies (pop ~65) had only 2 port slots each.
`PORT_BASE` 2 -> 4. Tick 400: Ore extracted 590 -> 853 (belts 136 -> 280), Food stockouts 47 -> 37. 1200 ticks (`run_ports4_1200.csv`), vs previous (salvage) run:
pop 11,708 -> 13,575, Ore 32 -> 21, Metal 38 -> 26, Parts 62 -> 55, Food 61 -> 45, Water 35 -> 12, fleet 58 -> 76 ships, all 100 colonies with jobs.
Remaining oddity: class-4 hulls are mostly empty (fill 0.15-0.3) because the class refit happens in the first ~40 ticks, before real flows exist; gate refits on hold fill.

## Time scale: one tick = one month
`EconomySim.MONTHS_PER_TICK = 1.0`, with `years_elapsed()` / `date_label()` (shown in the HUD as "year Y, month M"). Rates are now tuned against that:
- births 0.3%/tick (~3.7%/year with food and room; was 0.8%, ~10%/year), starvation 2%/tick (~21%/year), payback horizon 25 ticks (~2 years), a freight run ~ a month.
- 6,000 ticks = 500 years; 600 ticks = 50 years.
Effect (`run_birth003_1200.csv` vs `run_ports4_1200.csv`): slower early growth (pop at tick 100: 5,500 vs 6,200; tick 300: 8,500 vs 9,800), converging by tick ~1000 (12,400 vs 13,600 at 1,200; all 100 colonies with jobs, Parts ~58, Food ~55).
Use this scale when picking new constants (facility build times, ship speed, tech/upgrade durations).

## Colonization from a Capital World, Surveyors and outposts (`colonize = true`)
Run: `run_headless_csv.gd -- growth=1 ticks=600 colonize=1` (the 2D view now starts in this mode). The old all-planets-settled mode is unchanged (`colonize` off).
- **Capital World**: the best-scoring planet that can feed and equip itself (needs Ore, plus Food or Water). It starts with 600 people (ceiling 3,000), an established
  economy sized to them (Extractor + Producer founding firms, shelves at normal cover) and fully known deposits. Its home star system is charted from the start.
  A capital without Ore can't run Metal/Parts; 1,500 people need ~150 Ore/month, far more than one planet's deposit (~16), so the capital must colonize for Ore.
- **Frontier**: every other planet is unsettled, pop 0, deposits hidden (`hidden_richness`). `richness` now means *known* richness.
- **Surveyor** corporation (`Kind.SURVEYOR`, one state-chartered at start, re-chartered if it goes bankrupt): survey ships spend 6 months on site plus travel.
  A survey reveals part of each deposit's true richness, decaying as more is found and more slowly on rich worlds (resurveys keep finding more on rich planets).
  Surveyors can't see true richness: unsurveyed planets have a flat prior, resurveys are worth less each time; they pick the best value per month of ship time.
  Income: a state contract per first survey (20) and **claims**: each find becomes a claim the first extractor to work that deposit must buy (150 per richness unit).
  They buy more ships only while fewer than 6 finds are unsold.
- **Outposts**: an Extractor can found an outpost on a surveyed, unsettled planet (cost 160 + facility + claim), judged on the nearest colony's price minus shipping.
  20 settlers are recruited from a colony of 100+ people (well-staffed and close preferred).
- **Migration is now zero-sum** in this mode: people move from better-staffed colonies (pop vs. jobs target above average) toward worse-staffed ones; births add people.
Result, 600 ticks (50 years), seed 7 (`run_colonize.csv`, `fig12_colonization.png`, `view_colonize.png`):
first outposts in years 5-8, 9 colonies by year 28 (all in or near the home system), all 99 other planets surveyed by year 28 with 2 survey ships,
population 600 -> 2,010, facilities 142 -> 386, prices low after the first years (Parts ~30, Food/Ore ~5). An early Parts crunch (years 2-5) clears once the first Ore outposts open.
Open: expansion stalls after year 28 because demand is met and outposts are judged only on current shortages (no speculative or long-distance colonization);
32 Extractor corporations exist but most are idle; claims sell slowly (4 of dozens of finds).

## Taxes and a state treasury
`EconomySim.taxes` (default on; `taxes=0` on the CSV runner to disable): every corporation pays 25% of its monthly profit plus 0.5%/month (~6%/year) on cash above 800.
It goes to `treasury`, which now pays the survey contracts and Surveyor charters. New metrics: `treasury`, `corp_cash`, `tax_collected`. Runs now take `seed=N`.
Colonization runs, 50 years, seeds 7/11/23/31 (`fig13_taxes.png`, `run_col_s<seed>_t<0|1>.csv`):
- Corporate cash falls about 3x (seed 7: 13.8M -> 4.6M; range 1.6-5.8M taxed vs 6.8-15.3M untaxed), but it is still millions against an 80-cash facility.
- The treasury reaches 4.8-10.4M with almost nothing to spend it on.
- Expansion barely changes: colonies 9/6/12/11 untaxed vs 15/6/10/14 taxed, facilities mixed, population the same. The differences are within seed-to-seed noise.
Why: corporations decide on payback (cost vs. monthly margin), not on cash, and a facility (80) earns its cost back in a few months, so profits dwarf every investment.
A cash drain can't bind until building costs scale with what facilities earn (e.g. capex paid in Metal/Parts as construction materials, or capex tied to output value).

## Construction materials
New facilities and upgrades are now construction projects: Metal and Parts must be delivered to the site (taken from the colony's shelf at local prices, the rest requested from Freight)
and they take at least 6 months. A new facility produces nothing until finished; an upgrading one keeps running at its old level. Materials count as demand.
Amounts: new facility 10 Metal + 4 Parts; upgrades x(0.4 + 0.2 x level); an outpost adds 15 Metal + 6 Parts (habitat). The payback test includes materials at today's prices.
Outposts are judged on a 60-month horizon instead of 25 (a new colony is a long-term investment). Metric: `under_construction`.
First try (20+10 per facility, 30+15 per outpost, 25-month horizon for outposts): no outpost in 50 years on seeds 7 and 23. The Ore-poor capital's Parts sit at the price cap,
an outpost then costs ~3,600 instead of ~390, and without Ore outposts Parts never get cheaper: a poverty trap. Hence the lighter amounts and the longer outpost horizon.
Result, 4 seeds, 50 years, vs taxes-only (`fig14_construction.png`, `run_build_s<seed>_t1.csv`):
- Slow start, then acceleration: 1-2 colonies for the first 10-35 years, then 12/13/18/21 colonies by year 50 (taxes-only: 15/6/10/14). Note this also includes the longer outpost horizon.
- Fewer facilities on 3 of 4 seeds (434->325, 222->198, 677->465; 374->393), population a bit lower (2,013->1,352, 2,069->1,816, 2,081->1,790; seed 11 879->1,041).
- Corporate cash 3-6x lower (4.6M -> 0.8M on seed 7), treasury 1.7-3.8M: capital now binds.
- Parts is the scarce good again (~55-65 vs ~16-24), because construction competes with consumers and maintenance for it.

## State-funded colonization (`state_colonization`, default on; `state=0` on the CSV runner to disable)
Once a year the colonial office picks the surveyed, unsettled planet that best fills the economy's gaps: known deposits weighted by how scarce each good is (average price / base),
plus room to grow (max_pop), divided by distance from the nearest colony. It pays from the treasury (only if it holds 2x the cost): passage for 40 settlers
(from a colony of 100+), habitat materials (30 Metal + 12 Parts from the nearest colony's shelf, at its prices), a 60 grant to the new colony's local business
(promotion to a corporation happens at 80) and any surveyor claims. Metrics: `state_colonies`, `state_spent`.
Two fixes found on the way (both also apply without the state):
- A corporation in trouble (cash < 0) now closes its worst loss-maker each month instead of carrying idle plants into bankruptcy.
- No new capacity or upgrades for a good while more than 30% of the corporation's own plants making it are losing money (inputs too dear, not demand too low).
  Before this, the only Producer kept building Metal plants while ~200 of its 218 sat idle for lack of Ore, went bankrupt and took the whole Metal/Parts chain with it (seed 31, year 41).
Result, 4 seeds, 50 years, vs companies only (`fig15_state_colonization.png`, `run_state_s<seed>_t1.csv`):
- ~1 state colony a year (46-49), 50-58 colonies by year 50 vs 12-21; the first 10 colonies by year ~10 instead of years 10-45.
- Population higher on every seed (2,180/1,960/2,400/2,450 vs 1,350/1,040/1,820/1,790); facilities similar.
- Cheap: 40-80k spent of a treasury that still ends at 2.5-3.4M (more colonies -> more tax).
Open: seed 11 loses most of its industry between years 30 and 40 without going bankrupt: Metal gluts in some colonies while Parts plants elsewhere idle on dear local Metal
(a distribution problem). New 200-cash founders can't afford construction at Parts ~50-100 and go bankrupt quickly. The state's pace is fixed at one colony a year.

## 500 planets (`planets=500`, seed 7, 50 years; `fig16_500_planets.png`, `run_500_state.csv`, `run_500_nostate.csv`)
Almost identical to 100 planets: with the state, 50 colonies (vs 53), pop 2,430 (vs 2,180); companies only, 16 colonies and pop 1,660.
Only 94 of 500 planets get surveyed in 50 years, the same ~2 a year as on the 100-planet map: survey capacity, not galaxy size, sets the pace.
Surveyors stay at 1-2 ships because they stop buying ships while 6 finds are unsold, and claims sell slowly (the state's colonies void them without paying).
Companies-only shows a population dip around year 24 (Parts shortage) that the state's colonies avoid.

## State survey orders and paid claims
- State colonies now pay the surveyors' claims at the going price (they used to void them).
- Once a year the state orders first surveys of unexplored planets, committing up to 5% of the treasury, at 80 per survey (paid on completion, instead of the flat 20).
  A Surveyor buys ships while the order backlog is bigger than its fleet can clear in a year, and sells ships when it runs short of cash with no orders left.
Result, seed 7 (`fig17_survey_orders.png`, `run_500_surveys.csv`, `run_100_surveys.csv`):
- 500 planets: all surveyed by year ~17 (was 94 by year 50); the fleet peaks at 50 ships, then sells down to 12. Claims sold 1 -> 111. Colonies 50 -> 64, pop 2,430 -> 2,700, Parts ~44 -> ~28.
- 100 planets: map surveyed by year ~10; claims sold 1 -> 61; colonies 53 -> 54, pop 2,180 -> 2,390.
Open: the survey boom may be too fast (5%/year of a growing treasury = 485 orders on the 500 map); on 100 planets facilities fall from ~275 (year 20) to ~150 (year 50) while population keeps rising - to investigate.

## Star systems on the map; survey time by body size; survey ship losses
- The map's nodes are now **star systems** (`SystemNode`: name, position, star class, bodies). Planets, giants and belts are colonies/frontier *inside* a system:
  they share the system's map position, and travel between bodies of one system is a short hop (`INTRA_SYSTEM_DIST` 0.4 vs 1 + distance/200 between systems).
  The 2D view draws one node per system: grey star = unsurveyed, gold ring = known deposits, disc = settled (size = population, "n/m" = colonies/bodies,
  colour = Food/Parts supply), the Capital system outlined in gold; trade lanes only between systems (`view_systems.png`).
- **Survey time scales with the body**: 2 + 4 x radius^0.6 months, capped at 24 (Earth-sized ~6 months, giants ~19, belts by their ring size).
- **Surveying is dangerous**: a ship is lost on 3% of surveys (+4% around giants, +3% in belts), with its findings; the last vessel is replaced at a cost.
- A Surveyor can commission at most one new ship every 6 months.
Result, seed 7 (`run_500_systems.csv`, `run_100_systems.csv`): 500 planets surveyed 74 by year 10, 299 by year 20, all by ~year 35 (was all by year 17);
fleet peaks at ~19 ships (was 50); 45 ships lost in 50 years. 53 colonies in 20 systems, pop 2,600. 100 planets: 51 colonies in 7 systems, pop 2,550.
Open (now the main problem): facilities fall after year ~20 (500: 193 -> 113; 100: 190 -> 88) while population rises, and Parts climbs to 50-60.
Traced on seed 7 / 100 planets: the Producer closes 39 of its 54 Metal plants around year 22 (chronic losers: Ore too dear for the Metal price), Parts follows,
it goes bankrupt at year ~27, and the 200-cash founders that replace it can't afford construction materials, so the Metal/Parts chain never rebuilds.

## Known space and sector discoveries (exploration booms)
Only systems within 160 px of the Capital are charted at the start; each newly settled system charts systems within 110 px; uncharted systems can't be surveyed,
settled or ordered surveys. A random **sector discovery** (probe report, breakthrough, signal) charts every system within 140 px of a random dark one; its monthly chance is
0.2% plus up to 4% as known space gets fully surveyed (cubic), so booms arrive when surveyors run out of work. Metrics: `known_systems`, `sector_events`.
Result, 500 planets (= only ~46 star systems, ~11 bodies each), 100 years, seeds 7/23 (`fig18_exploration_booms.png`, `run_booms_s*.csv`):
- One long boom, not several: 6-7 discoveries in years 12-29 chart the whole map by year ~30; survey fleets rise to ~27 ships, then fall to 1 by year ~55.
- The map is too small for repeated booms: each discovery charts ~5-15 of 46 systems. A bigger galaxy (the scaling test) or smaller sectors should give distinct waves.
- Colonies keep growing for the whole century (113 / 151 by year 100, pop 6,400 / 7,300).
The old all-planets-settled mode still runs after the star-system change (checked 120 ticks).

## Scaling test and profiling (`systems=N`; output `TIME,` and `PROFILE,` lines)
`systems=N` generates exactly N star systems with all their bodies, on a map scaled so star density stays the same. The runner prints ms per tick each decade
and cumulative time per tick phase. Runs: 25 / 50 / 100 / 200 systems (290 / 547 / 1,053 / 2,150 bodies), 50 years, colonize + state (`fig19_scaling.png`, `docs/economy_results/scaling/`).
- **Cost follows colonies, not galaxy size.** Every size ends with ~50-53 colonies (the state's one-a-year pace dominates), and ms/tick climbs with them:
  ~4 at 10 colonies, ~30 at 20, ~85 at 30, ~170 at 40, ~490-590 at ~52 (faster than quadratic). 25 systems is cheaper only late (225 ms).
- **Extractors are 90-95% of the time** (98 s of 106 s at 100 systems): ~56 Extractor corporations (most idle) each re-evaluate every colony x good and every
  outpost candidate each month, and each evaluation summed every market (regional use/capacity) and searched for the nearest colony and a settler donor.
- Surveyors scale with body count (1 s at 25 systems -> 7 s at 200); freight, producers, markets and the state are small.
- **Fix 1 (done):** cache regional sums (invalidated when a facility registers / markets tick), nearest-colony and settler-donor lookups per tick, and the outpost-candidate
  list. Results are bit-identical; 100 systems: 106 s -> 27 s, 588 -> 120 ms/tick at 53 colonies.
- **Next:** the evaluation is still repeated per corporation although it's the same for all of them except cash. A shared per-tick "opportunity board"
  (rank options once, corporations take the best they can afford) should remove most of the rest, and suits the idle-Extractor problem too.
- Exploration at 100-200 systems over 50 years is still one rising boom (fleet 1 -> 30-35 ships, 9-14 sector discoveries); waves would need a longer run.

## Opportunity board (shared evaluation)
New-facility and outpost options are the same for every corporation of a kind, so they're now ranked once into an "opportunity board" (per kind, rebuilt whenever
capacity, claims or the set of colonies change; cached with the regional sums). Each corporation walks the board best-payback-first and takes the first option it can
afford that isn't a good its own plants are idling on, then compares it with its own upgrade options. The scan helpers became static functions.
- Output is **identical** to the original uncached run (full CSV diff). 100 systems, 50 years: 106 s -> 27 s (caches) -> **9 s** (board); ~31 ms per month at 53 colonies.
- 200 systems, 100 years: 69 s total; ms per month grows roughly linearly with colonies now (~1 ms per colony: 4 ms at 10, 58 at 63, 126 at 120).
  Remaining time: Extractors 39 s (own upgrades + facility runs), Surveyors 19 s (target scan over every body), Freight 4 s, Producers 3 s.
- Exploration on that run: survey fleet 2 -> ~37 ships by year 70, then 11 by year 100; 31 sector discoveries spread over years 11-97, so it is one long boom
  rather than waves (discoveries keep coming as each new sector is surveyed fast). Waves would need discoveries to wait for a sector to be finished, or rarer events.

## 1,000 star systems (10,752 bodies), 100 years
- First run (opportunity board): 130 s total. Surveyors had become the biggest cost (74 s, 57%) because each free ship scanned all 10,752 bodies, charted or not.
- Surveyors now scan only bodies in charted systems (`known_frontier()`, rebuilt when space is charted; same order, so output is **identical**): **80 s** total,
  surveyors 74 s -> 25 s. Extractors (40 s) are the main cost again.
- ms per month: 14 at 10 colonies, 52 at 51, 82 at 76, 178 at 101 (vs 126 at 120 colonies on 200 systems).
- Outcome: 101 colonies in 58 systems, pop 5,750; only 267 of 1,000 systems charted and 2,754 bodies surveyed by year 100, so exploration
  would carry on for centuries; survey fleet 2 -> ~40 ships, 22 sector discoveries; treasury 9.2M; Parts ~90 and Food ~33 (supply strained at this pace).

## Survey board; deterministic tie-breaks
- Survey targets are ranked once into a **survey board** (value per month of ship time for every charted body), rebuilt only when a survey completes, space is
  charted, a colony is founded or a month starts. Each free ship takes the best body nobody is surveying.
- Both boards now break ties explicitly by scan order. Godot's `sort_custom` isn't stable, and equal paybacks are common (prices pinned at the cap), so the
  old order could depend on the sort's internals. With the old unstable sort the survey board reproduces the previous output exactly (100 and 1,000 systems);
  with the tie-break, 100 systems is still identical and 1,000 systems diverges (101 -> 117 colonies by year 100) purely through tie order.
- 1,000 systems, 100 years: 80 s -> **73 s**; surveyors 25 s -> 14 s. Extractors (45 s, running and upgrading their own facilities) are now ~60% of the time.

## Extractor review profiling
`PROFILE,<kind>_operate/_review` and `board_builds/board_build_time` lines split the corporations' time. Extractors spend ~95% deciding what to build, almost all of it
rebuilding the opportunity board (~2.6 rebuilds a month, each time any facility registers). Outpost options' fixed parts (price at the nearest colony after shipping,
materials, cost) are now precomputed monthly (`outpost_base()`), and the board sorts natively on [payback, index]; output stays identical.
1,000 systems x 100 years: 73 s -> 68 s. What's left is volume: ~3,000 outpost options re-scored per rebuild by year 100. Next step if needed: rebuild only
the good whose capacity changed, or keep a per-good shortlist (may change results slightly).

## Multiple empires (`num_empires`, CSV runner `empires=N`; per-empire `EMP,` rows yearly)
- `Empire` (empire.gd): capital, treasury and taxes, colonial office, survey orders, sector discoveries, settlements, and its own **known space** and caches.
- **Capitals**: the first is chosen as before; each further empire takes the good homeworld (>= half the best score, self-sufficient) farthest from existing capitals.
  Each capital gets its own founding Extractor/Producer/Freight corporations and a state Surveyor.
- **Knowledge is per empire**: `ColonyMarket.intel[empire id]` holds that empire's known deposits, survey count and surveyors' claims. A settled body's `richness`
  is its owner's knowledge (same dictionary), so the owner's resurveys feed extraction. Other empires must survey a planet themselves.
- **Territory**: the first empire to settle any body in a star system owns the whole system (`SystemNode.owner`); others can't survey or settle there.
- **Corporations are national** (`Corporation.empire`, taxed there) but trade and build in any colony. Founding firms and emergence use the colony's owner.
- Migration and settlers stay inside an empire; freight and regional demand are galaxy-wide.
- **Fair turn order**: each month a different empire's corporations act first (they compete for the same lanes, ports and opportunities). Without it,
  the first empire's freighters always took the best lanes and its treasury reached 37M while the others stayed near zero.
- With one empire the output is identical to the single-state version (full CSV diff).
Result: 4 empires, 200 systems, 100 years (`fig20_empires.png`, `scaling/empires4_200.out`): Empires 1/3/4 reach 122-126 colonies in 27-42 systems, pop 6,750-7,400;
Empire 2, hemmed in by its neighbours, holds 20 systems, 95 colonies and stalls near 4,200 people from year ~75. Treasuries 2-22M (Empire 1 still richest).
Cost: 390 s (vs ~70 s for one empire on the same map): extractors 234 s, mostly re-scoring each empire's thousands of outpost options whenever any facility registers.
Tried splitting the board into a shared market part and per-empire outposts: no speed-up (the outposts are the volume) and slightly different results
(the market options were evaluated at a different moment in the month), so it was reverted.

## Multi-empire speed-ups (identical output)
- Outpost options are cached per (empire, good) and re-scored only when that good's supply changes (a facility of that good registers) or a claim on it
  changes; ordinary build options are still rebuilt whenever any facility registers (they read stock levels that move during the month). The corporations walk
  the lists merged by (payback, scan index), exactly as one combined list. On its own: no gain (the scoring wasn't the cost).
- The real cost was the monthly outpost-candidate rebuild: for every surveyed deposit it searched all the empire's colonies for a settler source and for the
  nearest colony. Now "can send settlers" is one check a month (any colony of 100+ people; the donor is only picked when an outpost is founded), and
  nearest-colony / donor lookups are cached per star system (its bodies share one map position).
- 4 empires, 200 systems, 100 years: 402 s -> **207 s**, output identical (full CSV + EMP diff); 1 empire, 100 systems, 50 years: 10.3 s -> 8.0 s, identical.
  Remaining: extractors 94 s (outpost base 35 s, ordinary board 33 s), freight 45 s, surveyors 27 s, producers 23 s.

## Territory on the map
The 2D view now starts with 4 empires on a 46-system galaxy (one screen). Each empire's systems claim the space within 70 px (nearest claimed system wins),
drawn as a tinted area with a border in the empire's colour; settled systems use their empire's colour (reddened when short of Food/Parts). The layer is
rendered to a small image and rebuilt only when a system changes hands. A legend lists each empire's colonies, systems, population and treasury.
`docs/economy_results/view_territory.png`: year 40 - empires 2 (blue) and 4 (green) hold the flanks, 1 (gold) and 3 (red) are squeezed into the centre,
where borders interleave system by system.

## Relations, closed borders and goal-oriented diplomacy
**Relations** (per pair of empires, monthly): first contact when one has charted space the other owns; opinion drifts toward
`8 x log(1 + trade) - 3 x shared border segments - 15 x incidents + goodwill` (incidents = settling a system the other had surveyed; incidents
and goodwill decay 2%/month). Stances: friendly >= 25, hostile <= -25, embargo <= -60; turning hostile cancels treaties. Customs on cross-border
deliveries go to the destination's treasury: 0% friendly, 10% neutral, 35% hostile, halved under a trade treaty. Runner: `REL,` rows yearly, `EVENT,` lines.
**Closed borders**: an empire's territory (nearest claimed system within 70 px, the same rule the map shader draws) is closed to foreigners. A freighter of
empire F may only use a route if F has a *trade treaty* with each foreign empire at either end and a *passage treaty* with every other empire whose
territory the route crosses (sampled every 20 px; cached per month). Enclaves stay enclaves; even an empire's own colonies can be cut off by a neighbour.
**Diplomacy as GOAP** (`diplomacy.gd`, once a year per empire): goals - secure a good it's short of (avg price >= 1.8x base) from the met empire that has it
cheapest; reach a trade partner whose capital is behind a third empire's territory; ease tension with a hostile neighbour; open trade with a friendly one.
Actions with preconditions/effects - propose a trade treaty (needs opinion >= -10), propose passage (needs >= 10, pays a 5k fee), send aid (20k, +20 goodwill).
A uniform-cost search (depth 4) finds the cheapest plan; the empire carries out its first step. Partners decide by their own interests: a trade treaty is
accepted when opinion/20 + benefit >= 1 (benefit grows with goods they're short of that the proposer has cheap); passage when opinion >= 10.
Refusals put a 5-year cooldown on re-proposing.
Result, 4 empires, 200 systems, 100 years (`fig21_diplomacy.png`, `scaling/empires4_diplomacy.out`): first contacts in years 18-40; Empire 3 is
refused a trade treaty 15 times over 25 years and keeps sending aid, then is accepted everywhere in years 58-62 once others need its Water;
passage treaties let Empires 1 and 2 reach each other through Empire 4; Empires 1 and 4, with a 30-segment border, fall out twice (year 69: treaties
cancelled; reconciled by aid in years 77-79; hostile again near year 97). One empire: output unchanged. Cost: 306 s (route checks), vs 207 s.
