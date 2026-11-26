extends SceneTree
## Headless check: personality API, a menu-style start, save, load. Run: godot --headless --script res://economy_proto/test_menu_save.gd
func _init() -> void:
	var s = ClassDB.instantiate("GalaxySim")
	root.add_child(s)
	var book : String = s.default_personalities()
	print("traits: ", s.trait_names())
	print("valid default: '", s.validate_personalities(book), "'")
	print("bad trait: ", s.validate_personalities('{"archetypes":[{"name":"X","traits":{"greed":{"mean":1,"spread":0}}}]}'))
	var b = JSON.parse_string(book)
	b["archetypes"] = [{"name": "Only Warmongers", "weight": 1, "traits": {"aggression": {"mean": 0.95, "spread": 0.0}}}]
	s.set_speed(500.0)
	s.start({"systems": 30, "empires": 3, "seed": 5, "personalities": JSON.stringify(b)})
	await create_timer(1.5).timeout
	var d : Dictionary = s.poll()
	print("date ", d.get("date"), " personality ", d["empires"][0]["personality"])
	s.set_paused(true)
	print("save: '", s.save_game("user://saves/test.sav"), "'")
	var t0 : int = s.poll().get("tick", -1)
	s.set_paused(false)
	await create_timer(0.5).timeout
	print("load: '", s.load_game("user://saves/test.sav"), "'")
	await create_timer(0.05).timeout
	print("after load tick ", s.poll().get("tick"), " (saved at ", t0, ")")
	print("load missing: ", s.load_game("user://saves/nope.sav"))
	s.stop()
	quit()
