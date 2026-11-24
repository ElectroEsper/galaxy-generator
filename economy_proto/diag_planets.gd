extends SceneTree
## Prints what the 100 generated planets are (class histogram, resource coverage).
func _initialize() -> void:
	seed(7)
	var gc = load("res://economy_proto/galaxy_colonies.gd")
	var markets = gc.generate_all(100)
	var classes : Dictionary = {}
	var ore : int = 0
	var food : int = 0
	var none : int = 0
	for c in markets:
		classes[c.planet_label] = classes.get(c.planet_label, 0) + 1
		if c.richness.has(Goods.ORE): ore += 1
		if c.richness.has(Goods.FOOD): food += 1
		if c.richness.is_empty(): none += 1
	print("planets=%d  with_ore=%d  with_food=%d  with_nothing=%d" % [markets.size(), ore, food, none])
	var keys : Array = classes.keys()
	keys.sort_custom(func(a, b): return classes[a] > classes[b])
	for k in keys:
		print("  %-28s %d" % [k, classes[k]])
	quit()
