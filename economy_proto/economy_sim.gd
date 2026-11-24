extends Node
## Headless prototype driver. Add as a Node in a scene (or autoload) and run.
## Prints a snapshot every PRINT_EVERY ticks.

const TICKS := 400
const PRINT_EVERY := 80
const MAX_CORPS := 12
const PROMOTE_CASH := 80.0
var promotions : int = 0
var attractions : int = 0

var markets : Array[ColonyMarket] = []
var corps : Array[Corporation] = []

signal shipment_made(from_market : ColonyMarket, to_market : ColonyMarket, good : int, qty : float)

var tick_count : int = 0
@export var auto_run : bool = true

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
	corps = [
		Corporation.new(Corporation.Kind.EXTRACTOR, 300.0),
		Corporation.new(Corporation.Kind.PRODUCER, 300.0),
		Corporation.new(Corporation.Kind.FREIGHT, 300.0),
	]

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
		if not k.last_move.is_empty():
			var m : Dictionary = k.last_move
			shipment_made.emit(m["from"], m["to"], m["good"], m["qty"])
	for c in markets:
		c.tick()
		if t > 20 and corps.size() < MAX_CORPS:
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
		corps.append(Corporation.new(_founding_kind(), 200.0))
		attractions += 1

func _print_snapshot(t : int) -> void:
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
	var raw_unmet : float = 0.0
	var proc_unmet : float = 0.0
	for g in Goods.ALL:
		var u : float = Corporation._regional(markets, "use", g) * Corporation.HEADROOM - Corporation._regional(markets, "capacity", g)
		if Goods.is_raw(g):
			raw_unmet += maxf(u, 0.0)
		else:
			proc_unmet += maxf(u, 0.0)
	return Corporation.Kind.EXTRACTOR if raw_unmet > proc_unmet else Corporation.Kind.PRODUCER
