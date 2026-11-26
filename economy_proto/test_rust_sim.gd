extends SceneTree
## Headless check of the Rust extension: start a galaxy, let the sim thread run, print a few snapshots.
##   godot --headless --path . --script res://economy_proto/test_rust_sim.gd

var sim
var frames := 0
var seen := 0

func _initialize() -> void:
	sim = ClassDB.instantiate("GalaxySim")
	root.add_child(sim)
	sim.set_speed(240.0)
	sim.start({"systems": 46, "empires": 4, "planets": 100, "seed": 7})

func _process(_delta : float) -> bool:
	frames += 1
	var s : Dictionary = sim.poll()
	if not s.is_empty():
		seen += 1
		if seen % 60 == 1:
			var e0 : Dictionary = s["empires"][0]
			print("SNAP %s colonies=%d corps=%d systems=%d shipments=%d | %s: %d systems, strength %d [%s]" % [s["date"], s["colonies"], s["corps"], s["systems"].size() / 9, s["shipments"].size() / 6, e0["name"], e0["systems"], e0["strength"], e0["personality"]])
		for ev in s["events"]:
			if "WAR" in ev or "PEACE" in ev or "pact" in ev:
				print("  EVENT ", ev)
	OS.delay_msec(5)
	if frames > 1500:
		sim.stop()
		print("DONE frames=%d snapshots=%d" % [frames, seen])
		return true
	return false
