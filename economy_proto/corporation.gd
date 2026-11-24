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
const HEADROOM := 1.3          # build until capacity ~ HEADROOM x use
const CLOSE_AFTER := 20       # consecutive losing ticks before closing a facility
const INSOLVENT_AFTER := 15   # ticks with cash < 0 before dissolving
const IDLE_AFTER := 30        # ticks with no facilities before dissolving (frees a corporation slot)

class Facility:
	var colony : ColonyMarket
	var good : int
	var losing_ticks : int = 0
	func _init(c : ColonyMarket, g : int) -> void:
		colony = c; good = g
	## Units of `good` this facility can add per tick.
	func throughput() -> float:
		if Goods.is_raw(good):
			return colony.richness.get(good, 0.0)
		return Goods.RECIPES[good]["yield"]

var kind : Kind
var cash : float
var facilities : Array[Facility] = []
var ships : int = 0
var broke_ticks : int = 0
var idle_ticks : int = 0
var utilisation : float = 0.0
var moved : float = 0.0

func _init(k : Kind, starting_cash : float) -> void:
	kind = k; cash = starting_cash

## A local business graduating into a corporation: first facility is at home.
func seed_facility(c : ColonyMarket, g : int) -> void:
	var f := Facility.new(c, g)
	facilities.append(f)
	c.capacity[g] += f.throughput()

func is_dead() -> bool:
	return broke_ticks >= INSOLVENT_AFTER or idle_ticks >= IDLE_AFTER

## Called when a corporation dissolves: its capacity leaves the market.
func dissolve() -> void:
	for f in facilities:
		f.colony.capacity[f.good] -= f.throughput()
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
		if Goods.is_raw(f.good):
			# Same discipline as producers: don't extract at a loss; idle until price recovers.
			if _unit_margin(c, f.good) <= 0.0:
				continue
			var q : float = c.richness.get(f.good, 0.0)
			c.stock[f.good] += q
			cash += q * (c.price[f.good] - Goods.RAW_COST[f.good])
		else:
			var r : Dictionary = Goods.RECIPES[f.good]
			# Operating discipline: don't buy inputs at a loss; idle until the margin recovers.
			var idle : bool = _unit_margin(c, f.good) <= 0.0
			var runs : float = 0.0 if idle else 1.0
			for i in r["in"]:
				c.note_use(i, r["in"][i])           # desired input draw, even if the shelf is empty
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
	cash -= UPKEEP * facilities.size()

func _unit_margin(c : ColonyMarket, g : int) -> float:
	if Goods.is_raw(g):
		return c.price[g] - Goods.RAW_COST[g]
	var r : Dictionary = Goods.RECIPES[g]
	var m : float = r["yield"] * c.price[g]
	for i in r["in"]:
		m -= r["in"][i] * c.price[i]
	return m

## 0..1: how well-stocked this colony is with the inputs a recipe needs.
func _input_availability(c : ColonyMarket, g : int) -> float:
	if Goods.is_raw(g):
		return 1.0
	var a : float = 1.0
	for i in Goods.RECIPES[g]["in"]:
		a = minf(a, c.stock[i] / (c.use[i] * ColonyMarket.COVER_TICKS * 0.5))
	return clampf(a, 0.05, 1.0)

func _facility_margin(c : ColonyMarket, g : int) -> float:
	var q : float = c.richness.get(g, 0.0) if Goods.is_raw(g) else 1.0
	return _unit_margin(c, g) * q - UPKEEP

func _review_and_expand(markets : Array[ColonyMarket]) -> void:
	for f in facilities.duplicate():
		f.losing_ticks = f.losing_ticks + 1 if _facility_margin(f.colony, f.good) <= 0.0 else 0
		# Only shed capacity that is genuinely surplus; otherwise a price dip makes every
		# facility close in the same tick and the market swings straight into shortage.
		var surplus : bool = _regional(markets, "capacity", f.good) > _regional(markets, "use", f.good) * HEADROOM
		if f.losing_ticks > CLOSE_AFTER and surplus:
			facilities.erase(f)
			f.colony.capacity[f.good] -= f.throughput()
	if cash < CAPEX * 1.5:
		return
	var best_margin : float = 0.0
	var best_c : ColonyMarket = null
	var best_g : int = -1
	for c in markets:
		for g in Goods.ALL:
			if (kind == Kind.EXTRACTOR) != Goods.is_raw(g):
				continue
			var q : float = c.richness.get(g, 0.0) if Goods.is_raw(g) else 1.0
			if q <= 0.0:
				continue
			# Demand-pull: only build where regional use exceeds regional capacity.
			# (Freight links colonies, so supply/demand is judged region-wide.)
			var unmet : float = _regional(markets, "use", g) * HEADROOM - _regional(markets, "capacity", g)
			if unmet < q * 0.5:
				continue
			var m : float = _unit_margin(c, g) * q * _input_availability(c, g) - UPKEEP
			if m > best_margin:
				best_margin = m; best_c = c; best_g = g
	if best_c != null and CAPEX / best_margin < PAYBACK_HORIZON:
		cash -= CAPEX
		var f := Facility.new(best_c, best_g)
		facilities.append(f)
		best_c.capacity[best_g] += f.throughput()

func _run_freight(markets : Array[ColonyMarket]) -> void:
	var best_m : float = 0.0
	var best : Array = []
	for g in Goods.ALL:
		for a in markets:
			if a.stock[g] < 6.0:
				continue
			for b in markets:
				if a == b:
					continue
				var m : float = b.price[g] - a.price[g] - SHIP_COST * _dist(a, b, markets)
				if m > best_m:
					best_m = m; best = [g, a, b]
	if best_m > 0.3:
		var g : int = best[0]; var a : ColonyMarket = best[1]; var b : ColonyMarket = best[2]
		var cap : float = SHIP_CAPACITY * (1 + ships)
		var q : float = minf(minf(a.stock[g] * 0.5, cap), maxf(0.0, cash / a.price[g]))
		a.stock[g] -= q; b.stock[g] += q
		cash += q * best_m
		moved = q
		utilisation = 0.8 * utilisation + 0.2 * (q / cap)
	else:
		utilisation = 0.8 * utilisation
	cash -= SHIP_UPKEEP * (1 + ships)
	# Fleet grows only while it is actually busy, and shrinks when idle.
	if cash > CAPEX * 3.0 and utilisation > 0.85:
		cash -= CAPEX; ships += 1
	elif utilisation < 0.25 and ships > 0:
		ships -= 1

func _dist(a : ColonyMarket, b : ColonyMarket, markets : Array[ColonyMarket]) -> float:
	return 1.0 + absf(markets.find(a) - markets.find(b)) * 0.5
