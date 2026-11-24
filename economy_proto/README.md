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
