extends SceneTree
## Follow the Producer corporations' finances through a run:  -- seed=31 from=440 to=560
func _initialize() -> void:
	var sd : int = 31; var from : int = 440; var to : int = 560
	for a in OS.get_cmdline_user_args():
		if a.begins_with("seed="): sd = int(a.get_slice("=", 1))
		elif a.begins_with("from="): from = int(a.get_slice("=", 1))
		elif a.begins_with("to="): to = int(a.get_slice("=", 1))
	var sim = load("res://economy_proto/economy_sim.gd").new()
	sim.use_galaxy = true; sim.all_planets = true; sim.galaxy_colonies = 100
	sim.max_corps = 60; sim.growth_enabled = true; sim.auto_run = false; sim.colonize = true; sim.rng_seed = sd
	root.add_child(sim); sim.setup()
	for t in to:
		sim.step()
		if t >= from and t % 5 == 0:
			for k in sim.corps:
				if k.kind != Corporation.Kind.PRODUCER: continue
				var idle := 0; var building := 0; var marg := 0.0; var upk := 0.0; var by := {}
				for f in k.facilities:
					if f.building(): building += 1
					var m : float = k._facility_margin(f)
					marg += m; upk += f.upkeep()
					if k._unit_margin(f.colony, f.good, f.recipe_mode) <= 0.0: idle += 1
					by[f.good] = by.get(f.good, 0) + 1
				print("t=%d producer cash=%.0f broke=%d fac=%d idle=%d building=%d sum_margin=%.0f upkeep=%.0f by_good=%s" % [t, k.cash, k.broke_ticks, k.facilities.size(), idle, building, marg, upk, by])
	quit()
