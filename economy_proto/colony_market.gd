class_name ColonyMarket
extends RefCounted
## Per-colony market. Price is derived from stock cover (stock / (use * COVER)),
## so it is stateless and cannot run away the way an integrated price can.

const BASE_PRICE := 10.0
const COVER_TICKS := 10.0

var name : String
var pop : float
var richness : Dictionary          # Goods.ID -> float (raw goods only)
var stock : Dictionary = {}
var price : Dictionary = {}
var use : Dictionary = {}          # smoothed consumption rate per good
var use_this_tick : Dictionary = {}
var capacity : Dictionary = {}     # units/tick that facilities here can add, per good
var max_pop : float = 400.0        # habitability ceiling (from the planet in the real game)
var extraction : Dictionary = {}   # raw good -> output of corporate extraction facilities here (capped by richness)
var facility_count : int = 0       # facilities built here (kept in sync by Corporation)
var requests : Array = []          # input requests posted by producers this tick (served by Freight)
var growth_enabled : bool = true   # births + maintenance demand (false = PR #8 baseline behaviour)
var jobs : float = 0.0             # facilities operating here (set by the sim each tick)
var local_cash : float = 0.0       # profit accrued by the colony's informal local business
var planet_label : String = ""       # planet class, shown by the view
var position : Vector2 = Vector2.ZERO  # galaxy-map position (used by the visual layer)
var shortfall_signal : float = 0.0 # smoothed price premium of pop goods -> corp emergence

func _init(n : String, p : float, rich : Dictionary, ceiling : float = 400.0) -> void:
	name = n; pop = p; richness = rich; max_pop = ceiling
	for g in Goods.ALL:
		stock[g] = 40.0; price[g] = BASE_PRICE; use[g] = 0.1; capacity[g] = 0.0
	# Local business: small informal extraction for every raw resource the colony has.
	for g in richness:
		capacity[g] += local_output(g)
	# Subsistence output also counts as capacity, so corporations only build for demand beyond it.
	capacity[Goods.FOOD] += SUBSISTENCE_FOOD
	capacity[Goods.PARTS] += SUBSISTENCE_PARTS

const USE_FLOOR := 0.02            # tiny, so a 100-colony map doesn't invent phantom demand
const BASE_SELF_POP := 30.0
const JOBS_PER_FACILITY := 8.0
const MAINT_METAL_PER_POP := 0.004
const MAINT_PARTS_PER_FACILITY := 0.08
const BIRTH_RATE := 0.008
const DEATH_RATE := 0.02
## Subsistence: every colony feeds and equips its baseline population without any corporation.
const SUBSISTENCE_FOOD := BASE_SELF_POP * 0.05
const SUBSISTENCE_PARTS := BASE_SELF_POP * 0.012

## Workforce caps how many facilities a colony can host (spreads industry across colonies).
func facility_slots_free() -> int:
	return int(floor(max_pop / JOBS_PER_FACILITY)) - facility_count

func local_output(g : int) -> float:
	return richness.get(g, 0.0) * 0.25

## Workforce demand outpacing the population is the emergence signal (0 = balanced).
func workforce_gap() -> float:
	return (target_pop() - pop) / maxf(pop, 1.0)

func target_pop() -> float:
	return minf(BASE_SELF_POP + jobs * JOBS_PER_FACILITY, max_pop)

func pop_demand(g : int) -> float:
	var d : float = 0.0
	match g:
		Goods.FOOD: d = pop * 0.05
		Goods.PARTS: d = pop * 0.012
	if growth_enabled:
		# Maintenance demand: buildings and facilities wear out and need Metal / Parts.
		match g:
			Goods.METAL: d += pop * MAINT_METAL_PER_POP
			Goods.PARTS: d += facility_count * MAINT_PARTS_PER_FACILITY
	return d

func note_use(g : int, amount : float) -> void:
	use_this_tick[g] = use_this_tick.get(g, 0.0) + amount

func tick() -> void:
	stock[Goods.FOOD] += SUBSISTENCE_FOOD
	stock[Goods.PARTS] += SUBSISTENCE_PARTS
	for g in richness:
		var q : float = local_output(g)
		if price[g] > Goods.RAW_COST[g]:
			stock[g] += q
			local_cash += q * (price[g] - Goods.RAW_COST[g])
	# Abstract migration: population drifts toward what the local economy can employ.
	if growth_enabled:
		# Births need food and room; starvation kills; jobs only ever attract migrants (no forced shrink).
		var need : float = maxf(pop_demand(Goods.FOOD), 0.001)
		var fed : float = clampf(stock[Goods.FOOD] / (need * 3.0), 0.0, 1.0)
		pop += pop * BIRTH_RATE * fed * (1.0 - pop / max_pop) - pop * DEATH_RATE * (1.0 - fed)
		pop += maxf(0.0, target_pop() - pop) * 0.02
		pop = clampf(pop, 5.0, max_pop)
	else:
		pop += (target_pop() - pop) * 0.02
	for g in Goods.ALL:
		var take : float = minf(stock[g], pop_demand(g))
		stock[g] -= take
		# Desired consumption (not just what was available) so stock-outs stay visible as demand.
		var used : float = pop_demand(g) + use_this_tick.get(g, 0.0)
		use[g] = 0.9 * use[g] + 0.1 * maxf(used, USE_FLOOR)
		var cover : float = stock[g] / (use[g] * COVER_TICKS)
		price[g] = BASE_PRICE * clampf(pow(maxf(cover, 0.001), -0.7), 0.1, 10.0)
	use_this_tick.clear()
	requests.clear()
	var premium : float = (price[Goods.FOOD] + price[Goods.PARTS]) / (2.0 * BASE_PRICE) - 1.0
	shortfall_signal = 0.9 * shortfall_signal + 0.1 * premium
