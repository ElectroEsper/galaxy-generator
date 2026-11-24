extends Node
## Headless prototype driver. Add as a Node in a scene (or autoload) and run.
## Prints a snapshot every PRINT_EVERY ticks.

const TICKS := 400
const PRINT_EVERY := 80
const PROMOTE_CASH := 80.0
var promotions : int = 0
var attractions : int = 0

var markets : Array[ColonyMarket] = []
var corps : Array[Corporation] = []

signal shipment_made(from_market : ColonyMarket, to_market : ColonyMarket, good : int, qty : float)

var tick_count : int = 0
@export var auto_run : bool = true
@export var use_galaxy : bool = false   # true: colonies come from generated stars/planets
@export var galaxy_stars : int = 120
@export var galaxy_colonies : int = 10
@export var all_planets : bool = false     # true: every generated planet is a colony (galaxy_colonies = how many)
var max_corps : int = 12
var growth_enabled : bool = true
const MAX_FREIGHT_CORPS := 4

func _ready() -> void:
	setup()
	if auto_run:
		run_headless()

func run_headless() -> void:
	for t in TICKS:
		step()
		if t % PRINT_EVERY == PRINT_EVERY - 1:
			_print_snapshot(t + 1)

func setup() -> void:
	seed(7)
	if use_galaxy:
		markets = GalaxyColonies.generate_all(galaxy_colonies) if all_planets else GalaxyColonies.generate(galaxy_stars, galaxy_colonies)
	else:
		_setup_handmade()
	for c in markets:
		c.growth_enabled = growth_enabled
	_setup_corps()

func _setup_corps() -> void:
	corps = [
		Corporation.new(Corporation.Kind.EXTRACTOR, 300.0),
		Corporation.new(Corporation.Kind.PRODUCER, 300.0),
		Corporation.new(Corporation.Kind.FREIGHT, 300.0),
	]

func _setup_handmade() -> void:
	markets = [
		ColonyMarket.new("A", 80, {Goods.ORE: 2.0}, 600.0),
		ColonyMarket.new("B", 60, {Goods.FOOD: 2.0}, 400.0),
		ColonyMarket.new("C", 100, {Goods.ORE: 0.5, Goods.FOOD: 0.5}, 500.0),
		ColonyMarket.new("D", 40, {}, 150.0),
		ColonyMarket.new("E", 50, {Goods.ORE: 1.0}, 250.0),
	]
	var spots : Array[Vector2] = [Vector2(140, 170), Vector2(470, 110), Vector2(330, 330), Vector2(640, 300), Vector2(150, 440)]
	for i in markets.size():
		markets[i].position = spots[i]

func step() -> void:
	_tick(tick_count)
	tick_count += 1

func _tick(t : int) -> void:
	for c in markets:
		c.jobs = 0.0
	for k in corps:
		for f in k.facilities:
			f.colony.jobs += 1.0
	for k in corps:
		k.run(markets)
		for m in k.last_moves:
			shipment_made.emit(m["from"], m["to"], m["good"], m["qty"])
	for c in markets:
		c.tick()
		if t > 20 and corps.size() < max_corps:
			_try_emergence(c)
	for k in corps:
		if k.is_dead():
			k.dissolve()
	corps = corps.filter(func(k): return not k.is_dead())

## Two emergence paths, both local to a colony:
##  1. Promotion: the informal local business has banked enough profit to incorporate.
##  2. Attraction: workforce demand outpaces population (jobs but not enough people) -> outside founder.
func _try_emergence(c : ColonyMarket) -> void:
	if c.local_cash > PROMOTE_CASH and not c.richness.is_empty():
		var g : int = c.richness.keys()[0]
		var k := Corporation.new(Corporation.Kind.EXTRACTOR, c.local_cash * 0.5)
		c.local_cash = 0.0
		k.seed_facility(c, g)
		corps.append(k)
		promotions += 1
		return
	if randf() < maxf(0.0, c.workforce_gap() - 0.15) * 0.03 or randf() < maxf(0.0, c.shortfall_signal - 0.25) * 0.05:
		var kind : Corporation.Kind = _founding_kind()
		for k in corps:                     # an idle funded corporation of this kind will take the opening itself
			if k.kind == kind and k.is_idle_funded():
				return
		corps.append(Corporation.new(kind, 200.0))
		attractions += 1

func _print_snapshot(t : int) -> void:
	if markets.size() > 20:
		_print_summary(t)
		return
	print("--- tick %d --- (promotions=%d attractions=%d)" % [t, promotions, attractions])
	var cap : Array = []
	for g in Goods.ALL:
		cap.append("%.1f/%.1f" % [Corporation._regional(markets, "capacity", g), Corporation._regional(markets, "use", g)])
	print("  capacity/use ORE,METAL,PARTS,FOOD = ", cap)
	for k in corps:
		print("  %s cash=%d facilities=%d ships=%d" % [Corporation.Kind.find_key(k.kind), k.cash, k.facilities.size(), k.ships])
	for c in markets:
		var p : Array = []
		for g in Goods.ALL:
			p.append("%d" % c.price[g])
		print("  %s pop=%d jobs=%d prices(ORE/METAL/PARTS/FOOD) = %s" % [c.name, c.pop, c.jobs, "/".join(p)])

## Derived demand decides what gets founded: unmet raw demand -> Extractor, else Producer.
func _founding_kind() -> Corporation.Kind:
	var fr : float = 0.0
	var fn : int = 0
	for k in corps:
		if k.kind == Corporation.Kind.FREIGHT:
			fr += k.utilisation; fn += 1
	if fn == 0 or (fn < MAX_FREIGHT_CORPS and fr / fn > 0.85 and randf() < 0.3):
		return Corporation.Kind.FREIGHT
	var raw_unmet : float = 0.0
	var proc_unmet : float = 0.0
	for g in Goods.ALL:
		var u : float = Corporation._regional(markets, "use", g) * Corporation.HEADROOM - Corporation._regional(markets, "capacity", g)
		if Goods.is_raw(g):
			# Only count raw demand that some colony could actually extract (richness + a free workforce slot).
			if _has_extraction_site(g):
				raw_unmet += maxf(u, 0.0)
		else:
			proc_unmet += maxf(u, 0.0)
	return Corporation.Kind.EXTRACTOR if raw_unmet > proc_unmet else Corporation.Kind.PRODUCER

func _print_summary(t : int) -> void:
	var kinds : Dictionary = {}
	var cash : float = 0.0
	var fac : int = 0
	var ships : int = 0
	for k in corps:
		var n : String = Corporation.Kind.find_key(k.kind)
		kinds[n] = kinds.get(n, 0) + 1
		cash += k.cash; fac += k.facilities.size(); ships += k.ships
	var pop : float = 0.0
	var short_n : int = 0
	var with_jobs : int = 0
	var avg : Dictionary = {}
	for g in Goods.ALL:
		avg[g] = 0.0
	for c in markets:
		pop += c.pop
		if (c.price[Goods.FOOD] + c.price[Goods.PARTS]) / (2.0 * ColonyMarket.BASE_PRICE) > 2.0:
			short_n += 1
		if c.jobs > 0.0:
			with_jobs += 1
		for g in Goods.ALL:
			avg[g] += c.price[g] / markets.size()
	print("--- tick %d --- colonies=%d pop=%d  colonies_with_jobs=%d  in_shortage=%d  promotions=%d attractions=%d" % [t, markets.size(), pop, with_jobs, short_n, promotions, attractions])
	print("  corps %s  facilities=%d  ships=%d  avg_price ORE/METAL/PARTS/FOOD = %d/%d/%d/%d" % [kinds, fac, ships, avg[Goods.ORE], avg[Goods.METAL], avg[Goods.PARTS], avg[Goods.FOOD]])

func _has_extraction_site(g : int) -> bool:
	for c in markets:
		if c.richness.get(g, 0.0) > 0.0 and c.facility_slots_free() > 0:
			return true
	return false

## One row of time-series metrics (see METRIC_HEADER).
const METRIC_HEADER := "tick,pop,colonies_with_jobs,in_shortage,avg_ore,avg_metal,avg_parts,avg_food,extractors,producers,freight,facilities,ships,promotions,attractions,avg_level,upgrades"
func metrics_row() -> String:
	var pop : float = 0.0
	var jobs_n : int = 0
	var short_n : int = 0
	var avg : Dictionary = {}
	for g in Goods.ALL:
		avg[g] = 0.0
	for c in markets:
		pop += c.pop
		if c.jobs > 0.0:
			jobs_n += 1
		if (c.price[Goods.FOOD] + c.price[Goods.PARTS]) / (2.0 * ColonyMarket.BASE_PRICE) > 2.0:
			short_n += 1
		for g in Goods.ALL:
			avg[g] += c.price[g] / markets.size()
	var lvl_sum : float = 0.0; var upg : int = 0
	var ex : int = 0; var pr : int = 0; var fr : int = 0; var fac : int = 0; var ships : int = 0
	for k in corps:
		match k.kind:
			Corporation.Kind.EXTRACTOR: ex += 1
			Corporation.Kind.PRODUCER: pr += 1
			Corporation.Kind.FREIGHT: fr += 1
		fac += k.facilities.size(); ships += k.ships
		upg += k.upgrades
		for f in k.facilities:
			lvl_sum += f.level
	return "%d,%.0f,%d,%d,%.2f,%.2f,%.2f,%.2f,%d,%d,%d,%d,%d,%d,%d,%.2f,%d" % [tick_count, pop, jobs_n, short_n, avg[Goods.ORE], avg[Goods.METAL], avg[Goods.PARTS], avg[Goods.FOOD], ex, pr, fr, fac, ships, promotions, attractions, (lvl_sum / maxf(fac, 1)), upg]
