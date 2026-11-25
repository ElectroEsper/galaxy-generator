extends SceneTree
## How much of the economy's Ore comes from asteroid belts, and what is their headroom?
func _initialize() -> void:
	var sim = load("res://economy_proto/economy_sim.gd").new()
	sim.use_galaxy = true; sim.all_planets = true; sim.galaxy_colonies = 100
	sim.max_corps = 60; sim.growth_enabled = true; sim.auto_run = false
	root.add_child(sim); sim.setup()
	for t in 400: sim.step()
	var G := Goods.ORE
	var groups := {}
	for c in sim.markets:
		var kind : String = c.planet_label.get_slice(" ", 0) if c.planet_label != "" else "?"
		var d : Dictionary = groups.get(kind, {"n": 0, "ore_sites": 0, "richness": 0.0, "extracted": 0.0, "pop": 0.0})
		d["n"] += 1; d["pop"] += c.pop
		if c.richness.has(G):
			d["ore_sites"] += 1; d["richness"] += c.richness[G]; d["extracted"] += c.extraction.get(G, 0.0)
		groups[kind] = d
	for c in sim.markets:
		if c.planet_label.begins_with("Asteroid"):
			print("belt pop=%.0f/%.0f fac=%d ext=%d free=%d ore: rich=%.1f extracted=%.1f cap=%.0f price=%.0f stock=%.0f" % [c.pop, c.max_pop, c.facility_count, c.extractor_count, c.facility_slots_free(), c.richness[G], c.extraction.get(G, 0.0), c.richness[G] * Corporation.EXTRACT_CAP_MULT, c.price[G], c.stock[G]])
	for k in groups:
		var d : Dictionary = groups[k]
		print("%-14s n=%d ore_sites=%d richness_sum=%.1f cap=%.0f extracted=%.0f avg_pop=%.0f" % [k, d["n"], d["ore_sites"], d["richness"], d["richness"] * Corporation.EXTRACT_CAP_MULT, d["extracted"], d["pop"] / d["n"]])
	for k in sim.corps:
		if k.kind == Corporation.Kind.FREIGHT:
			print("FREIGHT ships=%d class=%d cap/ship=%.0f util=%.2f fill=%.2f marg_rate=%.2f cash=%.0f" % [k.ships, k.ship_class, k.ship_capacity(), k.utilisation, k.fill, k.marg_rate, k.cash])
	var open_req := 0.0; var n_req := 0
	for c in sim.markets:
		for r in c.requests: open_req += r["qty"]; n_req += 1
	print("open input requests at end of tick: %d (%.0f units)" % [n_req, open_req])
	quit()
