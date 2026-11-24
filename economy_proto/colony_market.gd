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
var jobs : float = 0.0             # facilities operating here (set by the sim each tick)
var local_cash : float = 0.0       # profit accrued by the colony's informal local business
var position : Vector2 = Vector2.ZERO  # galaxy-map position (used by the visual layer)
var shortfall_signal : float = 0.0 # smoothed price premium of pop goods -> corp emergence

func _init(n : String, p : float, rich : Dictionary, ceiling : float = 400.0) -> void:
	name = n; pop = p; richness = rich; max_pop = ceiling
	for g in Goods.ALL:
		stock[g] = 40.0; price[g] = BASE_PRICE; use[g] = 1.0; capacity[g] = 0.0
	# Local business: small informal extraction for every raw resource the colony has.
	for g in richness:
		capacity[g] += local_output(g)

const JOBS_PER_FACILITY := 8.0
const BASE_SELF_POP := 30.0

func local_output(g : int) -> float:
	return richness.get(g, 0.0) * 0.25

## Workforce demand outpacing the population is the emergence signal (0 = balanced).
func workforce_gap() -> float:
	return (target_pop() - pop) / maxf(pop, 1.0)

func target_pop() -> float:
	return minf(BASE_SELF_POP + jobs * JOBS_PER_FACILITY, max_pop)

func pop_demand(g : int) -> float:
	match g:
		Goods.FOOD: return pop * 0.05
		Goods.PARTS: return pop * 0.012
	return 0.0

func note_use(g : int, amount : float) -> void:
	use_this_tick[g] = use_this_tick.get(g, 0.0) + amount

func tick() -> void:
	for g in richness:
		var q : float = local_output(g)
		if price[g] > Goods.RAW_COST[g]:
			stock[g] += q
			local_cash += q * (price[g] - Goods.RAW_COST[g])
	# Abstract migration: population drifts toward what the local economy can employ.
	pop += (target_pop() - pop) * 0.02
	for g in Goods.ALL:
		var take : float = minf(stock[g], pop_demand(g))
		stock[g] -= take
		# Desired consumption (not just what was available) so stock-outs stay visible as demand.
		var used : float = pop_demand(g) + use_this_tick.get(g, 0.0)
		use[g] = 0.9 * use[g] + 0.1 * maxf(used, 0.3)
		var cover : float = stock[g] / (use[g] * COVER_TICKS)
		price[g] = BASE_PRICE * clampf(pow(maxf(cover, 0.001), -0.7), 0.1, 10.0)
	use_this_tick.clear()
	var premium : float = (price[Goods.FOOD] + price[Goods.PARTS]) / (2.0 * BASE_PRICE) - 1.0
	shortfall_signal = 0.9 * shortfall_signal + 0.1 * premium
