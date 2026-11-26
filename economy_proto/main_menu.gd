extends Control
## Main menu: galaxy settings (systems, empires, seed, galaxy shape), a personality editor, and loading saves.
## Personalities are saved to user://personalities.json and used by every new galaxy.

const VIEW_SCENE := "res://economy_proto/rust_view.tscn"

var f_systems : SpinBox
var f_empires : SpinBox
var f_seed : SpinBox
var f_maps : CheckBox
var saves_list : ItemList
var status : Label
var main_box : Control
var editor : Control

# Personality editor state
var book : Dictionary = {}
var trait_names : PackedStringArray = []
var arch_list : ItemList
var cur : int = -1
var e_name : LineEdit
var e_desc : LineEdit
var e_weight : SpinBox
var e_stab : Array = []          # [min, max] SpinBoxes
var e_traits : Dictionary = {}   # trait -> [mean slider, spread slider, value label]
var e_rules : Dictionary = {}    # rule -> SpinBox
var e_status : Label
var _loading_fields := false

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color(0.04, 0.05, 0.08)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	if not ClassDB.class_exists("GalaxySim"):
		var l := Label.new()
		l.text = "GalaxySim not found: build the Rust extension (cd rust && cargo build --release -p galaxy_gd)"
		add_child(l)
		return
	var sim_cls = ClassDB.instantiate("GalaxySim")
	trait_names = sim_cls.trait_names()
	var src := GameSetup.personalities_json()
	if src == "" or sim_cls.validate_personalities(src) != "":
		src = sim_cls.default_personalities()
	book = JSON.parse_string(src)
	sim_cls.free()
	_build_main()
	_build_editor()
	_show_editor(false)

# ---------------------------------------------------------------- main panel
func _build_main() -> void:
	var c := CenterContainer.new()
	c.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(c)
	main_box = c
	var v := VBoxContainer.new()
	v.custom_minimum_size = Vector2(420, 0)
	v.add_theme_constant_override("separation", 10)
	c.add_child(v)
	var title := Label.new()
	title.text = "GALAXY"
	title.add_theme_font_size_override("font_size", 40)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(title)
	var g := GridContainer.new()
	g.columns = 2
	g.add_theme_constant_override("h_separation", 16)
	v.add_child(g)
	f_systems = _spin(g, "Star systems", 10, 2000, 46, 1)
	f_empires = _spin(g, "Empires", 1, 8, 4, 1)
	f_seed = _spin(g, "Seed", 0, 999999, randi() % 100000, 1)
	var lm := Label.new(); lm.text = "Galaxy shape"; g.add_child(lm)
	f_maps = CheckBox.new(); f_maps.text = "Spiral (from images)"; f_maps.button_pressed = true; g.add_child(f_maps)
	var reroll := Button.new(); reroll.text = "Random seed"
	reroll.pressed.connect(func(): f_seed.value = randi() % 100000)
	v.add_child(reroll)
	var start := Button.new(); start.text = "Start new galaxy"
	start.pressed.connect(_on_start)
	v.add_child(start)
	var pers := Button.new(); pers.text = "Edit personalities..."
	pers.pressed.connect(func(): _show_editor(true))
	v.add_child(pers)
	v.add_child(HSeparator.new())
	var ls := Label.new(); ls.text = "Saved games"
	v.add_child(ls)
	saves_list = ItemList.new()
	saves_list.custom_minimum_size = Vector2(0, 140)
	saves_list.item_activated.connect(func(i): _on_load())
	v.add_child(saves_list)
	var lb := Button.new(); lb.text = "Load selected"
	lb.pressed.connect(_on_load)
	v.add_child(lb)
	status = Label.new()
	status.modulate = Color(1, 0.6, 0.5)
	v.add_child(status)
	_refresh_saves()

func _spin(parent : Control, label : String, lo : float, hi : float, val : float, step : float) -> SpinBox:
	var l := Label.new(); l.text = label; parent.add_child(l)
	var s := SpinBox.new()
	s.min_value = lo; s.max_value = hi; s.step = step; s.value = val
	s.custom_minimum_size = Vector2(140, 0)
	parent.add_child(s)
	return s

func _refresh_saves() -> void:
	saves_list.clear()
	for n in GameSetup.list_saves():
		saves_list.add_item(n)

func _on_start() -> void:
	var cfg := {"systems": int(f_systems.value), "empires": int(f_empires.value), "seed": int(f_seed.value), "planets": 100,
		"personalities": GameSetup.personalities_json()}
	if f_maps.button_pressed:
		cfg["density_map"] = "res://galaxy_maps/spiral_density.png"
		cfg["population_map"] = "res://galaxy_maps/spiral_population.png"
	GameSetup.config = cfg
	GameSetup.load_path = ""
	get_tree().change_scene_to_file(VIEW_SCENE)

func _on_load() -> void:
	var sel := saves_list.get_selected_items()
	if sel.is_empty():
		status.text = "Pick a save first."
		return
	GameSetup.load_path = "%s/%s.sav" % [GameSetup.SAVE_DIR, saves_list.get_item_text(sel[0])]
	get_tree().change_scene_to_file(VIEW_SCENE)

# ---------------------------------------------------------------- personality editor
func _show_editor(on : bool) -> void:
	main_box.visible = not on
	editor.visible = on

func _build_editor() -> void:
	var m := MarginContainer.new()
	m.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		m.add_theme_constant_override("margin_" + side, 24)
	add_child(m)
	editor = m
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 20)
	m.add_child(h)
	# Left: archetype list and buttons
	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(260, 0)
	h.add_child(left)
	var t := Label.new(); t.text = "Personalities"; t.add_theme_font_size_override("font_size", 22)
	left.add_child(t)
	arch_list = ItemList.new()
	arch_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	arch_list.item_selected.connect(_select)
	left.add_child(arch_list)
	for b in [["New", _new_arch], ["Duplicate", _dup_arch], ["Delete", _del_arch], ["Reset to built-in", _reset_book]]:
		var btn := Button.new(); btn.text = b[0]; btn.pressed.connect(b[1]); left.add_child(btn)
	left.add_child(HSeparator.new())
	var save := Button.new(); save.text = "Save and back"; save.pressed.connect(_save_book)
	left.add_child(save)
	var back := Button.new(); back.text = "Back without saving"
	back.pressed.connect(func(): _reload_book(); _show_editor(false))
	left.add_child(back)
	e_status = Label.new(); e_status.autowrap_mode = TextServer.AUTOWRAP_WORD; e_status.modulate = Color(1, 0.6, 0.5)
	left.add_child(e_status)
	# Right: fields of the selected archetype, then the global rules
	var sc := ScrollContainer.new()
	sc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(sc)
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(right)
	var g := GridContainer.new(); g.columns = 2
	right.add_child(g)
	var l1 := Label.new(); l1.text = "Name"; g.add_child(l1)
	e_name = LineEdit.new(); e_name.custom_minimum_size = Vector2(320, 0); g.add_child(e_name)
	e_name.text_changed.connect(func(_s): _store())
	var l2 := Label.new(); l2.text = "Description"; g.add_child(l2)
	e_desc = LineEdit.new(); g.add_child(e_desc)
	e_desc.text_changed.connect(func(_s): _store())
	e_weight = _spin(g, "Weight (how often picked; 0 = never)", 0, 10, 1, 0.1)
	e_weight.value_changed.connect(func(_v): _store())
	e_stab = [_spin(g, "Stability min", 0.05, 0.95, 0.3, 0.05), _spin(g, "Stability max", 0.05, 0.95, 0.9, 0.05)]
	for s in e_stab:
		s.value_changed.connect(func(_v): _store())
	right.add_child(HSeparator.new())
	var th := Label.new(); th.text = "Traits: average and spread (0.5 = neutral)"
	right.add_child(th)
	var tg := GridContainer.new(); tg.columns = 4
	tg.add_theme_constant_override("h_separation", 12)
	right.add_child(tg)
	for n in trait_names:
		var ln := Label.new(); ln.text = n.capitalize(); tg.add_child(ln)
		var mean := HSlider.new(); mean.min_value = 0.0; mean.max_value = 1.0; mean.step = 0.01; mean.custom_minimum_size = Vector2(220, 0)
		var spread := HSlider.new(); spread.min_value = 0.0; spread.max_value = 0.4; spread.step = 0.01; spread.custom_minimum_size = Vector2(120, 0)
		var val := Label.new(); val.custom_minimum_size = Vector2(110, 0)
		tg.add_child(mean); tg.add_child(spread); tg.add_child(val)
		mean.value_changed.connect(func(_v): _store())
		spread.value_changed.connect(func(_v): _store())
		e_traits[n] = [mean, spread, val]
	right.add_child(HSeparator.new())
	var rh := Label.new(); rh.text = "Rules for every personality (drift, regime change)"
	right.add_child(rh)
	var rg := GridContainer.new(); rg.columns = 2
	right.add_child(rg)
	for r in book.get("rules", {}).keys():
		var sp := _spin(rg, r.capitalize(), 0, 100, float(book["rules"][r]), 0.001)
		sp.value_changed.connect(func(v): book["rules"][r] = v)
		e_rules[r] = sp
	_refresh_list()

func _refresh_list() -> void:
	arch_list.clear()
	for a in book["archetypes"]:
		arch_list.add_item(a.get("name", "?"))
	if book["archetypes"].size() > 0:
		_select(clampi(cur, 0, book["archetypes"].size() - 1))

func _select(i : int) -> void:
	cur = i
	arch_list.select(i)
	var a : Dictionary = book["archetypes"][i]
	_loading_fields = true
	e_name.text = a.get("name", "")
	e_desc.text = a.get("description", "")
	e_weight.value = a.get("weight", 1.0)
	var st : Array = a.get("stability", [0.3, 0.9])
	e_stab[0].value = st[0]; e_stab[1].value = st[1]
	var tr : Dictionary = a.get("traits", {})
	for n in trait_names:
		var r : Dictionary = tr.get(n, {"mean": 0.5, "spread": 0.2})
		e_traits[n][0].value = r["mean"]
		e_traits[n][1].value = r["spread"]
	_loading_fields = false
	_update_labels()

func _update_labels() -> void:
	for n in trait_names:
		e_traits[n][2].text = "%.2f ± %.2f" % [e_traits[n][0].value, e_traits[n][1].value]

## Copy the fields into the book. Traits left at the default (0.5 ± 0.2) are omitted, so the JSON stays readable.
func _store() -> void:
	_update_labels()
	if _loading_fields or cur < 0:
		return
	var tr := {}
	for n in trait_names:
		var m : float = e_traits[n][0].value
		var s : float = e_traits[n][1].value
		if absf(m - 0.5) > 0.001 or absf(s - 0.2) > 0.001:
			tr[n] = {"mean": m, "spread": s}
	book["archetypes"][cur] = {"name": e_name.text, "description": e_desc.text, "weight": e_weight.value,
		"stability": [e_stab[0].value, e_stab[1].value], "traits": tr}
	arch_list.set_item_text(cur, e_name.text)

func _new_arch() -> void:
	book["archetypes"].append({"name": "New personality", "description": "", "weight": 1.0, "stability": [0.3, 0.9], "traits": {}})
	cur = book["archetypes"].size() - 1
	_refresh_list()

func _dup_arch() -> void:
	if cur < 0: return
	var a : Dictionary = book["archetypes"][cur].duplicate(true)
	a["name"] = a["name"] + " (copy)"
	book["archetypes"].append(a)
	cur = book["archetypes"].size() - 1
	_refresh_list()

func _del_arch() -> void:
	if cur < 0 or book["archetypes"].size() <= 1:
		e_status.text = "At least one personality is needed."
		return
	book["archetypes"].remove_at(cur)
	cur = mini(cur, book["archetypes"].size() - 1)
	_refresh_list()

func _reset_book() -> void:
	var s = ClassDB.instantiate("GalaxySim")
	book = JSON.parse_string(s.default_personalities())
	s.free()
	cur = 0
	for r in e_rules: e_rules[r].value = float(book["rules"][r])
	_refresh_list()
	e_status.text = "Built-in personalities restored (not saved yet)."

func _reload_book() -> void:
	var s = ClassDB.instantiate("GalaxySim")
	var src := GameSetup.personalities_json()
	if src == "" or s.validate_personalities(src) != "":
		src = s.default_personalities()
	s.free()
	book = JSON.parse_string(src)
	cur = 0
	for r in e_rules: e_rules[r].value = float(book["rules"][r])
	_refresh_list()

func _save_book() -> void:
	var json := JSON.stringify(book, "  ")
	var s = ClassDB.instantiate("GalaxySim")
	var err : String = s.validate_personalities(json)
	s.free()
	if err != "":
		e_status.text = err
		return
	var f := FileAccess.open(GameSetup.PERSONALITY_PATH, FileAccess.WRITE)
	f.store_string(json)
	f.close()
	e_status.text = ""
	_show_editor(false)
