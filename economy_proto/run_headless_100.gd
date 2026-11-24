extends SceneTree
## 100-planet test: every generated planet (rocky, giant, belt) is a colony.
## godot --headless --path . --script res://economy_proto/run_headless_100.gd

func _initialize() -> void:
	var sim = load("res://economy_proto/economy_sim.gd").new()
	sim.use_galaxy = true
	sim.all_planets = true
	sim.galaxy_colonies = 100
	sim.max_corps = 60
	var t0 : int = Time.get_ticks_msec()
	root.add_child(sim)
	print("wall time: %.1fs" % ((Time.get_ticks_msec() - t0) / 1000.0))
	var types : Dictionary = {}
	for c in sim.markets:
		var k : String = "rich" if not c.richness.is_empty() else "barren"
		types[k] = types.get(k, 0) + 1
	print("colonies by resource: ", types)
	quit()
