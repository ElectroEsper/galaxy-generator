# Corporation logic prototype

GDScript: `goods.gd`, `colony_market.gd`, `corporation.gd`, `economy_sim.gd` (headless driver).
`sim_reference.py` is a Python mirror used to sanity-check dynamics (`python3 sim_reference.py`);
the GDScript has NOT been run in Godot yet.

## What it models
- Price derived from stock cover (stateless, bounded) rather than an integrated price.
- Extractor / Producer: payback-gated, saturation-aware expansion; closure of facilities losing money; insolvency.
- Freight: best arbitrage lane per tick, capped by stock, cash and fleet size.
- Emergence: smoothed shortage premium per colony raises the chance a new corporation is founded.

## Known problems (observed in the Python mirror, not yet solved)
1. Producers starve/die: ore/food oversupply drives raw prices to the floor, so METAL/PARTS margins stay thin.
2. Freight profit is unbounded (no congestion / lane capacity / ship upkeep scaling).
3. Producers need inputs locally; nothing yet places producers where Freight delivers inputs.
4. Local-business layer, Surveyors, acquisitions and Workforce are not implemented.
