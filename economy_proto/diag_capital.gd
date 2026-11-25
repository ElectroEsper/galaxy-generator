extends SceneTree
## Capital World starting state and its first years.
func _initialize() -> void:
	var sim = load("res://economy_proto/economy_sim.gd").new()
	sim.use_galaxy = true; sim.all_planets = true; sim.galaxy_colonies = 100
	sim.max_corps = 60; sim.growth_enabled = true; sim.auto_run = false; sim.colonize = true
	root.add_child(sim); sim.setup()
	var cap = sim.capital
	print("capital: ", cap.planet_label, " max_pop ", cap.max_pop, " richness ", cap.richness)
	var by : Dictionary = {}
	for k in sim.corps:
		for f in k.facilities:
			var key : String = "%s%s" % [Goods.ALL[f.good], "r" if f.recipe_mode else "x"]
			by[key] = by.get(key, 0) + 1
	print("seeded facilities (good id, r=recipe x=extract): ", by)
	for g in Goods.ALL:
		print("  good %d capacity %.1f" % [g, cap.capacity[g]])
	for t in 60:
		sim.step()
		if t % 6 == 5:
			print("t=%d pop=%.0f stock O/M/P/F/W=%.0f/%.0f/%.0f/%.0f/%.0f price=%.0f/%.0f/%.0f/%.0f/%.0f use=%.1f/%.1f/%.1f/%.1f/%.1f" % [t + 1, cap.pop, cap.stock[0], cap.stock[1], cap.stock[2], cap.stock[3], cap.stock[4], cap.price[0], cap.price[1], cap.price[2], cap.price[3], cap.price[4], cap.use[0], cap.use[1], cap.use[2], cap.use[3], cap.use[4]])
	quit()
