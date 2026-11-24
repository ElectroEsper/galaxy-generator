extends Node
## Headless prototype driver. Add as a Node in a scene (or autoload) and run.
## Prints a snapshot every PRINT_EVERY ticks.

const TICKS := 400
const PRINT_EVERY := 80
const MAX_CORPS := 12

var markets : Array[ColonyMarket] = []
var corps : Array[Corporation] = []

func _ready() -> void:
	seed(7)
	markets = [
		ColonyMarket.new("A", 80, {Goods.ORE: 2.0}),
		ColonyMarket.new("B", 60, {Goods.FOOD: 2.0}),
		ColonyMarket.new("C", 100, {Goods.ORE: 0.5, Goods.FOOD: 0.5}),
		ColonyMarket.new("D", 40, {}),
		ColonyMarket.new("E", 50, {Goods.ORE: 1.0}),
	]
	corps = [
		Corporation.new(Corporation.Kind.EXTRACTOR, 300.0),
		Corporation.new(Corporation.Kind.PRODUCER, 300.0),
		Corporation.new(Corporation.Kind.FREIGHT, 300.0),
	]
	for t in TICKS:
		_tick(t)
		if t % PRINT_EVERY == PRINT_EVERY - 1:
			_print_snapshot(t + 1)

func _tick(t : int) -> void:
	for k in corps:
		k.run(markets)
	for c in markets:
		c.tick()
		# Emergence: sustained shortage premium -> probabilistic corporation founding.
		if t > 20 and corps.size() < MAX_CORPS and randf() < maxf(0.0, c.shortfall_signal - 0.25) * 0.05:
			var kind : Corporation.Kind = [Corporation.Kind.EXTRACTOR, Corporation.Kind.PRODUCER].pick_random()
			corps.append(Corporation.new(kind, 200.0))
	corps = corps.filter(func(k): return not k.is_dead())

func _print_snapshot(t : int) -> void:
	print("--- tick %d ---" % t)
	for k in corps:
		print("  %s cash=%d facilities=%d ships=%d" % [Corporation.Kind.find_key(k.kind), k.cash, k.facilities.size(), k.ships])
	for c in markets:
		var p : Array = []
		for g in Goods.ALL:
			p.append("%d" % c.price[g])
		print("  %s prices(ORE/METAL/PARTS/FOOD) = %s" % [c.name, "/".join(p)])
