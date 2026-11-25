extends SceneTree
## Where is Parts made vs needed, and are the producer colonies' ports the limit?
func _initialize() -> void:
	var ticks : int = 400
	for a in OS.get_cmdline_user_args():
		if a.begins_with("ticks="): ticks = int(a.get_slice("=", 1))
	var sim = load("res://economy_proto/economy_sim.gd").new()
	sim.use_galaxy = true; sim.all_planets = true; sim.galaxy_colonies = 100
	sim.max_corps = 60; sim.growth_enabled = true; sim.auto_run = false
	root.add_child(sim); sim.setup()
	var full_ports := 0.0; var samples := 0; var share_full := {}
	for t in ticks:
		sim.step()
		if t >= ticks - 40:
			samples += 1
			for c in sim.markets:
				if c.port_used >= c.port_slots(): full_ports += 1.0
	var G := Goods.PARTS
	var cols : Array = sim.markets.duplicate()
	cols.sort_custom(func(a, b): return a.capacity[G] > b.capacity[G])
	var tot : float = 0.0
	for c in cols: tot += c.capacity[G]
	var producing := 0
	for c in cols:
		if c.capacity[G] > 1.0: producing += 1
	print("Parts capacity total %.0f across %d colonies (of 100)" % [tot, producing])
	var run := 0.0
	for i in 8:
		var c = cols[i]
		run += c.capacity[G]
		print("  #%d cap=%.1f (cum %.0f%%) use=%.1f stock=%.1f price=%.0f pop=%.0f ports %d/%d" % [i + 1, c.capacity[G], 100.0 * run / tot, c.use[G], c.stock[G], c.price[G], c.pop, c.port_used, c.port_slots()])
	var empty := 0; var needy := 0.0
	for c in sim.markets:
		if c.stock[G] < 1.0:
			empty += 1; needy += c.use[G]
	print("stocked-out colonies %d, their Parts use %.0f of total %.0f" % [empty, needy, sim.markets.reduce(func(s, c): return s + c.use[G], 0.0)])
	print("share of colony-ticks with ports full (last 40 ticks): %.0f%%" % (100.0 * full_ports / (samples * 100.0)))
	var pc := 0
	for k in sim.corps:
		if k.kind == Corporation.Kind.PRODUCER:
			for f in k.facilities:
				if f.good == G: pc += 1
	print("Parts producer facilities: %d; per corp:" % pc, sim.corps.filter(func(k): return k.kind == Corporation.Kind.PRODUCER).map(func(k): return k.facilities.size()))
	quit()
