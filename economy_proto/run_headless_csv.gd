extends SceneTree
## Prints a CSV time series of the 100-planet test.
##   godot --headless --path . --script res://economy_proto/run_headless_csv.gd -- growth=1 ticks=600
## Lines starting with "CSV," are the data (header first).

func _initialize() -> void:
	var growth : bool = true
	var ticks : int = 600
	for a in OS.get_cmdline_user_args():
		if a == "growth=0":
			growth = false
		elif a.begins_with("ticks="):
			ticks = int(a.get_slice("=", 1))
	var sim = load("res://economy_proto/economy_sim.gd").new()
	sim.use_galaxy = true
	sim.all_planets = true
	sim.galaxy_colonies = 100
	sim.max_corps = 60
	sim.growth_enabled = growth
	sim.auto_run = false
	root.add_child(sim)
	sim.setup()
	print("CSV,", sim.METRIC_HEADER)
	for t in ticks:
		sim.step()
		if t % 4 == 3:
			print("CSV,", sim.metrics_row())
	quit()
