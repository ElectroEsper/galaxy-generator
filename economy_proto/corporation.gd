class_name Corporation
extends RefCounted
## Profit-driven agent. Each tick: operate facilities -> maybe close losers ->
## maybe expand into the best opportunity (payback-gated, saturation-aware).

enum Kind {EXTRACTOR, PRODUCER, FREIGHT}

const CAPEX := 80.0
const UPKEEP := 1.0
const SHIP_CAPACITY := 6.0
const SHIP_UPKEEP := 1.5
const SHIP_COST := 0.4        # per unit per distance step
const PAYBACK_HORIZON := 25.0 # ticks; expand only if CAPEX / margin < this
const REQUEST_COVER := 4.0     # producers ask Freight to keep this many ticks of inputs on the shelf
const MAX_LEVEL := 4
const LEVEL_BONUS := 0.6        # each level adds this fraction of base output
const UPKEEP_GROWTH := 0.25     # each level adds this fraction of base upkeep (jobs/slots stay the same)
const EXTRACT_CAP_MULT := 40.0  # a site can't be extracted beyond richness x this per good, however upgraded
const HEADROOM := 1.3          # build until capacity ~ HEADROOM x use
const CLOSE_AFTER := 20       # consecutive losing ticks before closing a facility
const INSOLVENT_AFTER := 15   # ticks with cash < 0 before dissolving

class Facility:
	var colony : ColonyMarket
	var good : int
	var recipe_mode : bool = false   # true: manufactures `good` from inputs; false: extracts it from the ground
	var level : int = 1
	var losing_ticks : int = 0
	func _init(c : ColonyMarket, g : int, recipe : bool = false) -> void:
		colony = c; good = g; recipe_mode = recipe
	func extracts() -> bool:
		return not recipe_mode
	func level_mult() -> float:
		return 1.0 + LEVEL_BONUS * (level - 1)
	## Units of `good` this facility can add per tick at its current level.
	func throughput() -> float:
		var base : float = colony.richness.get(good, 0.0) if extracts() else Goods.RECIPES[good]["yield"]
		return base * level_mult()
	func upkeep() -> float:
		return UPKEEP * (1.0 + UPKEEP_GROWTH * (level - 1))
	## Cost to go from the current level to the next.
	func upgrade_cost() -> float:
		return CAPEX * (0.4 + 0.2 * level)

var kind : Kind
var cash : float
var facilities : Array[Facility] = []
var ships : int = 0
var broke_ticks : int = 0
var idle_ticks : int = 0
var upgrades : int = 0
var utilisation : float = 0.0
var moved : float = 0.0
var last_moves : Array = []       # shipments made this tick (for the visual layer)

func _init(k : Kind, starting_cash : float) -> void:
	kind = k; cash = starting_cash

## A local business graduating into a corporation: first facility is at home.
func seed_facility(c : ColonyMarket, g : int) -> void:
	var f := Facility.new(c, g)
	facilities.append(f)
	_register(f, 1.0)
	c.facility_count += 1

## Keep colony capacity / extraction bookkeeping in sync with a facility's throughput.
func _register(f : Facility, sign : float) -> void:
	f.colony.capacity[f.good] += sign * f.throughput()
	if f.extracts():
		f.colony.extraction[f.good] = f.colony.extraction.get(f.good, 0.0) + sign * f.throughput()

func _site_room(c : ColonyMarket, g : int, recipe : bool = false) -> float:
	if recipe:
		return INF
	return c.richness.get(g, 0.0) * EXTRACT_CAP_MULT - c.extraction.get(g, 0.0)

## Idle and able to act on an opening (used so emergence doesn't found redundant corporations).
func is_idle_funded() -> bool:
	return facilities.is_empty() and cash >= CAPEX * 1.5

func is_dead() -> bool:
	# A corporation only ever dissolves by going bankrupt; idle ones just wait for an opening.
	return broke_ticks >= INSOLVENT_AFTER

## Called when a corporation dissolves: its capacity leaves the market.
func dissolve() -> void:
	for f in facilities:
		_register(f, -1.0)
		f.colony.facility_count -= 1
	facilities.clear()

static func _regional(markets : Array[ColonyMarket], field : String, g : int) -> float:
	var t : float = 0.0
	for m in markets:
		t += m.get(field)[g]
	return t

func run(markets : Array[ColonyMarket]) -> void:
	if kind == Kind.FREIGHT:
		_run_freight(markets)
	else:
		_run_facilities()
		_review_and_expand(markets)
		idle_ticks = idle_ticks + 1 if facilities.is_empty() else 0
	broke_ticks = broke_ticks + 1 if cash < 0.0 else 0

func _run_facilities() -> void:
	for f in facilities:
		var c : ColonyMarket = f.colony
		if f.extracts():
			# Same discipline as producers: don't extract at a loss; idle until price recovers.
			if _unit_margin(c, f.good, false) <= 0.0:
				continue
			var q : float = c.richness.get(f.good, 0.0) * f.level_mult()
			c.stock[f.good] += q
			cash += q * (c.price[f.good] - Goods.RAW_COST[f.good])
		else:
			var r : Dictionary = Goods.RECIPES[f.good]
			# Operating discipline: don't buy inputs at a loss; idle until the margin recovers.
			var idle : bool = _unit_margin(c, f.good, true) <= 0.0
			var runs : float = 0.0 if idle else f.level_mult()
			for i in r["in"]:
				c.note_use(i, r["in"][i] * f.level_mult())           # desired input draw, even if the shelf is empty
				# Ask Freight for a few ticks' worth of inputs when the shelf runs low.
				var want : float = r["in"][i] * f.level_mult() * REQUEST_COVER
				if c.stock[i] < want:
					c.requests.append({"good": i, "qty": want - c.stock[i], "payer": self})
				if not idle:
					runs = minf(runs, c.stock[i] / r["in"][i])
			if runs <= 0.0:
				continue
			for i in r["in"]:
				var n : float = runs * r["in"][i]
				c.stock[i] -= n
				cash -= n * c.price[i]
			var out : float = runs * r["yield"]
			c.stock[f.good] += out
			cash += out * c.price[f.good]
	for f in facilities:
		cash -= f.upkeep()

func _unit_margin(c : ColonyMarket, g : int, recipe : bool = false) -> float:
	if not recipe:
		return c.price[g] - Goods.RAW_COST[g]
	var r : Dictionary = Goods.RECIPES[g]
	var m : float = r["yield"] * c.price[g]
	for i in r["in"]:
		m -= r["in"][i] * c.price[i]
	return m

## 0..1: how well-stocked this colony is with the inputs a recipe needs.
func _input_availability(c : ColonyMarket, g : int, recipe : bool = false) -> float:
	if not recipe:
		return 1.0
	var a : float = 1.0
	for i in Goods.RECIPES[g]["in"]:
		a = minf(a, c.stock[i] / (c.use[i] * ColonyMarket.COVER_TICKS * 0.5))
	return clampf(a, 0.05, 1.0)

func _facility_margin(f : Facility) -> float:
	return _unit_margin(f.colony, f.good, f.recipe_mode) * f.throughput() - f.upkeep()

func _review_and_expand(markets : Array[ColonyMarket]) -> void:
	for f in facilities.duplicate():
		f.losing_ticks = f.losing_ticks + 1 if _facility_margin(f) <= 0.0 else 0
		# Only shed capacity that is genuinely surplus; otherwise a price dip makes every
		# facility close in the same tick and the market swings straight into shortage.
		var surplus : bool = _regional(markets, "capacity", f.good) > _regional(markets, "use", f.good) * HEADROOM
		# Chronic losers close regardless: an idle facility still costs upkeep and maintenance demand.
		if (f.losing_ticks > CLOSE_AFTER and surplus) or f.losing_ticks > CLOSE_AFTER * 4:
			facilities.erase(f)
			_register(f, -1.0)
			f.colony.facility_count -= 1
	if cash < CAPEX * 0.6:
		return
	# Candidate actions: build a new facility, or upgrade one of ours. Pick the best payback.
	var best_payback : float = INF
	var best_new_c : ColonyMarket = null
	var best_new_g : int = -1
	var best_new_recipe : bool = false
	var best_up : Facility = null
	for c in markets:
		for g in Goods.ALL:
			var as_recipe : bool = kind == Kind.PRODUCER
			if (as_recipe and not Goods.RECIPES.has(g)) or (not as_recipe and not Goods.is_raw(g)):
				continue
			var q : float = 1.0 if as_recipe else c.richness.get(g, 0.0)
			if q <= 0.0 or _site_room(c, g, as_recipe) < q:
				continue
			# Demand-pull: only build where regional use exceeds regional capacity.
			var unmet : float = _regional(markets, "use", g) * HEADROOM - _regional(markets, "capacity", g)
			if unmet < q * 0.5:
				continue
			# Local absorption: output beyond what this colony's market can use only sells at crashed prices.
			var absorb : float = minf(1.0, (c.use[g] * HEADROOM) / q)
			var m : float = _unit_margin(c, g, as_recipe) * q * _input_availability(c, g, as_recipe) * absorb - UPKEEP
			if c.facility_slots_free() > 0 and cash >= CAPEX * 1.5 and m > 0.0 and CAPEX / m < best_payback:
				best_payback = CAPEX / m; best_new_c = c; best_new_g = g; best_new_recipe = as_recipe
	for f in facilities:
		if f.level >= MAX_LEVEL:
			continue
		var delta : float = f.throughput() / f.level_mult() * LEVEL_BONUS      # extra output from one more level
		if _site_room(f.colony, f.good, f.recipe_mode) < delta or cash < f.upgrade_cost():
			continue
		var unmet_u : float = _regional(markets, "use", f.good) * HEADROOM - _regional(markets, "capacity", f.good)
		if unmet_u < delta * 0.5:
			continue
		var absorb_u : float = minf(1.0, (f.colony.use[f.good] * HEADROOM) / (f.throughput() + delta))
		var gain : float = _unit_margin(f.colony, f.good, f.recipe_mode) * delta * _input_availability(f.colony, f.good, f.recipe_mode) * absorb_u - UPKEEP * UPKEEP_GROWTH
		if gain > 0.0 and f.upgrade_cost() / gain < best_payback:
			best_payback = f.upgrade_cost() / gain; best_up = f; best_new_c = null
	if best_payback >= PAYBACK_HORIZON:
		return
	if best_up != null:
		cash -= best_up.upgrade_cost()
		_register(best_up, -1.0)
		best_up.level += 1
		_register(best_up, 1.0)
		upgrades += 1
	elif best_new_c != null:
		cash -= CAPEX
		var f := Facility.new(best_new_c, best_new_g, best_new_recipe)
		facilities.append(f)
		_register(f, 1.0)
		best_new_c.facility_count += 1

func _run_freight(markets : Array[ColonyMarket]) -> void:
	last_moves = []
	var voyages : int = 1 + ships          # every ship makes one voyage per tick
	var cap : float = SHIP_CAPACITY
	var done : int = 0
	# Contracts first: deliver inputs that producers have asked for (producer pays the shipping fee).
	for dest in markets:
		if done >= voyages:
			break
		for req in dest.requests:
			if done >= voyages:
				break
			var g : int = req["good"]
			var src : ColonyMarket = null
			for m in markets:
				if m != dest and m.stock[g] >= 8.0 and (src == null or m.stock[g] > src.stock[g]):
					src = m
			if src == null:
				continue
			var q : float = minf(minf(req["qty"], cap), src.stock[g] * 0.5)
			if q <= 0.0:
				continue
			var fee : float = SHIP_COST * _dist(src, dest, markets) * q
			src.stock[g] -= q; dest.stock[g] += q
			req["qty"] -= q
			cash += q * (dest.price[g] - src.price[g]) + fee
			if req["payer"] != null:
				req["payer"].cash -= fee
			moved += q
			done += 1
			last_moves.append({"from": src, "to": dest, "good": g, "qty": q})
	# Candidate lanes: for each good, cheapest sources x dearest destinations (keeps it O(n log n) at 100 colonies).
	var sources : Dictionary = {}
	var dests : Dictionary = {}
	for g in Goods.ALL:
		var by_price : Array = markets.duplicate()
		by_price.sort_custom(func(x, y): return x.price[g] < y.price[g])
		sources[g] = by_price.slice(0, 6)
		by_price.reverse()
		dests[g] = by_price.slice(0, 6)
	for v in range(done, voyages):
		var best_m : float = 0.0
		var best : Array = []
		for g in Goods.ALL:
			for a in sources[g]:
				if a.stock[g] < 6.0:
					continue
				for b in dests[g]:
					if a == b:
						continue
					var m : float = b.price[g] - a.price[g] - SHIP_COST * _dist(a, b, markets)
					if m > best_m:
						best_m = m; best = [g, a, b]
		if best_m <= 0.3:
			break
		var g : int = best[0]; var a : ColonyMarket = best[1]; var b : ColonyMarket = best[2]
		var q : float = minf(minf(a.stock[g] * 0.5, cap), maxf(0.0, cash / a.price[g]))
		if q <= 0.0:
			break
		a.stock[g] -= q; b.stock[g] += q
		cash += q * best_m
		moved += q
		done += 1
		last_moves.append({"from": a, "to": b, "good": g, "qty": q})
	utilisation = 0.8 * utilisation + 0.2 * (float(done) / float(voyages))
	cash -= SHIP_UPKEEP * (1 + ships)
	# Fleet grows only while it is actually busy, and shrinks when idle.
	var fleet_cap : int = maxi(3, markets.size() / 4)   # lanes, not cash, limit how many ships are useful
	if cash > CAPEX * 3.0 and utilisation > 0.85 and ships < fleet_cap:
		cash -= CAPEX; ships += 1
	elif utilisation < 0.25 and ships > 0:
		ships -= 1

func _dist(a : ColonyMarket, b : ColonyMarket, markets : Array[ColonyMarket]) -> float:
	# Map-space distance (px) -> lane cost units; keeps the hand-made map at roughly 1.5-3.
	return 1.0 + a.position.distance_to(b.position) / 200.0
