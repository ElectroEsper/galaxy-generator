extends SceneTree
## Screenshot of the Rust-driven view after the sim has run a while.
##   xvfb-run godot --path . --script res://economy_proto/shot_rust_view.gd -- out=/tmp/view.png frames=900

var frames := 0
var limit := 900
var out := "user://rust_view.png"

func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("out="): out = a.get_slice("=", 1)
		elif a.begins_with("frames="): limit = int(a.get_slice("=", 1))
	var v = load("res://economy_proto/rust_view.tscn").instantiate()
	v.months_per_second = 60.0
	root.add_child(v)

func _process(_d : float) -> bool:
	frames += 1
	if frames == limit:
		root.get_viewport().get_texture().get_image().save_png(out)
		print("SAVED ", out)
		return true
	return false
