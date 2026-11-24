extends SceneTree
## godot --headless --path . --script res://economy_proto/run_headless.gd

func _init() -> void:
	var sim = load("res://economy_proto/economy_sim.gd").new()
	root.add_child(sim)
	quit()
