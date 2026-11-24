class_name Corporation
extends RefCounted
## Profit-driven agent. Each tick: operate facilities -> maybe close losers ->
## maybe expand into the best opportunity (payback-gated, saturation-aware).

enum Kind {EXTRACTOR, PRODUCER, FREIGHT}

const CAPEX := 80.0
const UPKEEP := 1.0
const SHIP_COST := 0.4        # per unit per distance step
const PAYBACK_HORIZON := 25.0 # ticks; expand only if CAPEX / margin < this
const CLOSE_AFTER := 20       # consecutive losing ticks before closing a facility
const INSOLVENT_AFTER := 15   # ticks with cash < 0 before dissolving

class Facility:
	var colony : ColonyMarket
	var good : int
	var losing_ticks : int = 0
	func _init(c : ColonyMarket, g : int) -> void:
		colony = c; good = g

var kind : Kind
var cash : float
var facilities : Array[Facility] = []
var ships : int = 0
var broke_ticks : int = 0

func _init(k : Kind, starting_cash : float) -> void:
	kind = k; cash = starting_cash

func is_dead() -> bool:
	return broke_ticks >= INSOLVENT_AFTER

func run(markets : Array[ColonyMarket]) -> void:
	if kind == Kind.FREIGHT:
		_run_freight(markets)
	else:
		_run_facilities()
		_review_and_expand(markets)
	broke_ticks = broke_ticks + 1 if cash < 0.0 else 0

func _run_facilities() -> void:
	for f in facilities:
		var c : ColonyMarket = f.colony
		if Goods.is_raw(f.good):
			var q : float = c.richness.get(f.good, 0.0)
			c.stock[f.good] += q
			cash += q * (c.price[f.good] - Goods.RAW_COST[f.good])
		else:
			var r : Dictionary = Goods.RECIPES[f.good]
			var runs : float = 1.0
			for i in r["in"]:
				runs = minf(runs, c.stock[i] / r["in"][i])
			if runs <= 0.0:
				continue
			for i in r["in"]:
				var n : float = runs * r["in"][i]
				c.stock[i] -= n
				c.note_use(i, n)
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

func _facility_margin(c : ColonyMarket, g : int) -> float:
	var q : float = c.richness.get(g, 0.0) if Goods.is_raw(g) else 1.0
	return _unit_margin(c, g) * q - UPKEEP

func _review_and_expand(markets : Array[ColonyMarket]) -> void:
	for f in facilities.duplicate():
		f.losing_ticks = f.losing_ticks + 1 if _facility_margin(f.colony, f.good) <= 0.0 else 0
		if f.losing_ticks > CLOSE_AFTER:
			facilities.erase(f)
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
			# Saturation: adding q units of supply depresses the price we're counting on.
			var sat : float = c.use[g] / (c.use[g] + q * 2.0)
			var m : float = _unit_margin(c, g) * q * sat - UPKEEP
			if m > best_margin:
				best_margin = m; best_c = c; best_g = g
	if best_c != null and CAPEX / best_margin < PAYBACK_HORIZON:
		cash -= CAPEX
		facilities.append(Facility.new(best_c, best_g))

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
		var q : float = minf(minf(a.stock[g] * 0.5, 6.0 * (1 + ships)), maxf(0.0, cash / a.price[g]))
		a.stock[g] -= q; b.stock[g] += q
		a.note_use(g, q)
		cash += q * best_m
	cash -= 0.5 * (1 + ships)
	if cash > CAPEX * 3.0:
		cash -= CAPEX; ships += 1

func _dist(a : ColonyMarket, b : ColonyMarket, markets : Array[ColonyMarket]) -> float:
	return 1.0 + absf(markets.find(a) - markets.find(b)) * 0.5
