extends SceneTree
## Per-good supply/demand snapshot after N ticks:  godot --headless --path . --script res://economy_proto/diag_goods.gd -- ticks=400
func _initialize() -> void:
	var ticks : int = 400
	for a in OS.get_cmdline_user_args():
		if a.begins_with("ticks="): ticks = int(a.get_slice("=", 1))
	var sim = load("res://economy_proto/economy_sim.gd").new()
	sim.use_galaxy = true; sim.all_planets = true; sim.galaxy_colonies = 100
	sim.max_corps = 60; sim.growth_enabled = true; sim.auto_run = false
	root.add_child(sim); sim.setup()
	for t in ticks: sim.step()
	var names := ["ORE", "METAL", "PARTS", "FOOD", "WATER"]
	for g in Goods.ALL:
		var cap := 0.0; var use := 0.0; var price := 0.0; var stock := 0.0; var out := 0
		for c in sim.markets:
			cap += c.capacity[g]; use += c.use[g]; price += c.price[g]; stock += c.stock[g]
			if c.stock[g] < 1.0: out += 1
		var nf := 0; var lv := 0.0
		for k in sim.corps:
			for f in k.facilities:
				if f.good == g: nf += 1; lv += f.level
		print("%-6s capacity=%7.1f use=%7.1f cover=%.2f avg_price=%5.1f stockouts=%d/100 facilities=%d avg_level=%.2f" % [names[g], cap, use, cap / maxf(use, 0.01), price / 100.0, out, nf, lv / maxf(nf, 1)])
	for g in [Goods.ORE, Goods.WATER, Goods.FOOD]:
		var sites := 0; var room := 0.0; var ext := 0.0; var free_sites := 0
		for c in sim.markets:
			if c.richness.has(g):
				sites += 1
				var cap_site : float = c.richness[g] * Corporation.EXTRACT_CAP_MULT
				room += cap_site; ext += c.extraction.get(g, 0.0)
				if c.extraction.get(g, 0.0) < cap_site * 0.95: free_sites += 1
		print("%s sites=%d site-cap total=%.0f extracted=%.0f sites with headroom=%d" % [names[g], sites, room, ext, free_sites])
	var oh := 0; var oh_slots := 0; var oh_pop := 0.0
	for c in sim.markets:
		if c.richness.has(Goods.ORE) and c.extraction.get(Goods.ORE, 0.0) < c.richness[Goods.ORE] * Corporation.EXTRACT_CAP_MULT * 0.95:
			oh += 1; oh_pop += c.pop
			if c.facility_slots_free() > 0: oh_slots += 1
	print("ore sites with headroom=%d, of which with free workforce slots=%d (avg pop %.0f)" % [oh, oh_slots, oh_pop / maxf(oh, 1)])
	var kinds := {}
	for k in sim.corps:
		var kn : String = Corporation.Kind.find_key(k.kind)
		kinds[kn] = kinds.get(kn, 0) + 1
	print("corps: ", kinds)
	var hist := {}
	var cashless := 0
	for k in sim.corps:
		for f in k.facilities:
			if f.good == Goods.ORE:
				hist[f.level] = hist.get(f.level, 0) + 1
				var room : float = k._site_room(f.colony, f.good, f.recipe_mode)
				if room < f.throughput() / f.level_mult() * Corporation.LEVEL_BONUS: cashless += 1
	print("ore facility levels: ", hist, " blocked by site room: ", cashless)
	var slots := 0; var used := 0
	for c in sim.markets:
		slots += int(c.max_pop / 8.0); used += c.facility_count
	print("workforce slots used %d / %d" % [used, slots])
	var cash := {}
	for k in sim.corps:
		var kn : String = Corporation.Kind.find_key(k.kind)
		cash[kn] = cash.get(kn, 0.0) + k.cash
	print("corp cash by kind: ", cash)
	quit()
