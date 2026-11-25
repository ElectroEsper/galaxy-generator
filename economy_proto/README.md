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
