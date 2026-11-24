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
var shortfall_signal : float = 0.0 # smoothed price premium of pop goods -> corp emergence

func _init(n : String, p : float, rich : Dictionary) -> void:
	name = n; pop = p; richness = rich
	for g in Goods.ALL:
		stock[g] = 40.0; price[g] = BASE_PRICE; use[g] = 1.0

func pop_demand(g : int) -> float:
	match g:
		Goods.FOOD: return pop * 0.05
		Goods.PARTS: return pop * 0.012
	return 0.0

func note_use(g : int, amount : float) -> void:
	use_this_tick[g] = use_this_tick.get(g, 0.0) + amount

func tick() -> void:
	for g in Goods.ALL:
		var take : float = minf(stock[g], pop_demand(g))
		stock[g] -= take
		var used : float = take + use_this_tick.get(g, 0.0)
		use[g] = 0.9 * use[g] + 0.1 * maxf(used, 0.3)
		var cover : float = stock[g] / (use[g] * COVER_TICKS)
		price[g] = BASE_PRICE * clampf(pow(maxf(cover, 0.001), -0.7), 0.1, 10.0)
	use_this_tick.clear()
	var premium : float = (price[Goods.FOOD] + price[Goods.PARTS]) / (2.0 * BASE_PRICE) - 1.0
	shortfall_signal = 0.9 * shortfall_signal + 0.1 * premium
