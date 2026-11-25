extends SceneTree
## Prints a CSV time series of the 100-planet test.
##   godot --headless --path . --script res://economy_proto/run_headless_csv.gd -- growth=1 ticks=600
## Lines starting with "CSV," are the data (header first).

func _initialize() -> void:
	# Loaded at runtime (not named statically) so the autoloads exist when these scripts compile.
	var gc = load("res://economy_proto/galaxy_colonies.gd")
	var growth : bool = true
	var ticks : int = 600
	var colonize : bool = false
	var sim_taxes : bool = true
	var sim_state : bool = true
	var planets : int = 100
	var nsys : int = 0
	var nemp : int = 1
	var sim_seed : int = 7
	for a in OS.get_cmdline_user_args():
		if a == "growth=0":
			growth = false
		elif a.begins_with("food="):
			gc.food_mult = float(a.get_slice("=", 1))
		elif a.begins_with("seed="):
			sim_seed = int(a.get_slice("=", 1))
		elif a.begins_with("empires="):
			nemp = int(a.get_slice("=", 1))
		elif a.begins_with("systems="):
			nsys = int(a.get_slice("=", 1))
		elif a.begins_with("planets="):
			planets = int(a.get_slice("=", 1))
		elif a == "state=0":
			sim_state = false
		elif a == "taxes=0":
			sim_taxes = false
		elif a == "colonize=1":
			colonize = true
		elif a.begins_with("ticks="):
			ticks = int(a.get_slice("=", 1))
	var sim = load("res://economy_proto/economy_sim.gd").new()
	sim.use_galaxy = true
	sim.all_planets = true
	sim.galaxy_colonies = planets
	sim.galaxy_systems = nsys
	sim.num_empires = nemp
	sim.max_corps = 60
	sim.growth_enabled = growth
	sim.auto_run = false
	sim.colonize = colonize
	sim.taxes = sim_taxes
	sim.state_colonization = sim_state
	sim.rng_seed = sim_seed
	root.add_child(sim)
	sim.setup()
	var food_sites : int = 0
	for c in sim.markets:
		if c.richness.has(Goods.FOOD):
			food_sites += 1
	print("INFO,food_mult=", gc.food_mult, ",food_sites=", food_sites)
	print("CSV,", sim.METRIC_HEADER)
	if sim.empires.size() > 1:
		print("EMP,", sim.EMPIRE_HEADER)
		print("REL,", sim.RELATION_HEADER)
	print("INFO,systems=", gc.systems.size(), ",bodies=", sim.frontier.size() + 1)
	var wall0 : int = Time.get_ticks_msec()
	var decade0 : int = wall0
	var printed_events : int = 0
	for t in ticks:
		sim.step()
		if t % 4 == 3:
			print("CSV,", sim.metrics_row())
			if t % 12 == 11 and sim.empires.size() > 1:
				for row in sim.empire_rows(): print("EMP,", row)
				for row in sim.relation_rows(): print("REL,", row)
		while printed_events < sim.events.size():
			var ev : Array = sim.events[printed_events]
			print("EVENT,%d,%s" % [ev[0], ev[1]])
			printed_events += 1
		if t % 120 == 119:
			var now : int = Time.get_ticks_msec()
			print("TIME,decade=%d,ms_per_tick=%.1f,colonies=%d" % [(t + 1) / 120, (now - decade0) / 120.0, sim.markets.size()])
			decade0 = now
	print("TIME,total_s=%.1f" % ((Time.get_ticks_msec() - wall0) / 1000.0))
	for k in Corporation.sub_prof:
		print("PROFILE,%s,%.1f" % [k, Corporation.sub_prof[k] / 1000.0])
	for k in sim.prof:
		print("PROFILE,%s,%.1f" % [k, sim.prof[k] / 1000.0])
	quit()
