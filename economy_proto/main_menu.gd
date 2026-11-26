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

# Personality editor state (the book is the JSON personality book: blocks, archetypes, rules)
var book : Dictionary = {}
var axis_names : PackedStringArray = []
var effect_names : PackedStringArray = []
var e_status : Label
var e_rules : Dictionary = {}    # rule -> SpinBox
var _loading := false
# Personalities tab
var arch_list : ItemList
var cur : int = -1
var a_name : LineEdit
var a_desc : LineEdit
var a_weight : SpinBox
var a_spread : SpinBox
var a_stab : Array = []
var a_blocks : VBoxContainer
var a_summary : Label
# Trait blocks tab
var block_list : ItemList
var bcur : int = -1
var b_id : LineEdit
var b_name : LineEdit
var b_desc : LineEdit
var b_group : LineEdit
var b_excl : LineEdit
var b_weight : SpinBox
var b_axes : Dictionary = {}     # axis -> [slider, label]
var b_fx : Dictionary = {}       # effect -> SpinBox

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
	axis_names = sim_cls.trait_names()
	effect_names = sim_cls.effect_names()
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

func _book_from_sim(use_saved : bool) -> Dictionary:
	var s = ClassDB.instantiate("GalaxySim")
	var src : String = GameSetup.personalities_json() if use_saved else ""
	if src == "" or s.validate_personalities(src) != "":
		src = s.default_personalities()
	s.free()
	return JSON.parse_string(src)

func _build_editor() -> void:
	var m := MarginContainer.new()
	m.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		m.add_theme_constant_override("margin_" + side, 20)
	add_child(m)
	editor = m
	var v := VBoxContainer.new()
	m.add_child(v)
	var top := HBoxContainer.new()
	v.add_child(top)
	var t := Label.new(); t.text = "Personality editor"; t.add_theme_font_size_override("font_size", 22)
	top.add_child(t)
	var sp := Control.new(); sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL; top.add_child(sp)
	for b in [["Reset to built-in", _reset_book], ["Back without saving", func(): book = _book_from_sim(true); _refresh_all(); _show_editor(false)], ["Save and back", _save_book]]:
		var btn := Button.new(); btn.text = b[0]; btn.pressed.connect(b[1]); top.add_child(btn)
	e_status = Label.new(); e_status.modulate = Color(1, 0.6, 0.5)
	v.add_child(e_status)
	var tabs := TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(tabs)
	tabs.add_child(_build_arch_tab())
	tabs.add_child(_build_block_tab())
	tabs.add_child(_build_rules_tab())
	_refresh_all()

func _list_column(parent : Control, title : String, buttons : Array) -> ItemList:
	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(240, 0)
	parent.add_child(left)
	var l := Label.new(); l.text = title; left.add_child(l)
	var list := ItemList.new()
	list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.add_child(list)
	for b in buttons:
		var btn := Button.new(); btn.text = b[0]; btn.pressed.connect(b[1]); left.add_child(btn)
	return list

func _line(g : GridContainer, label : String) -> LineEdit:
	var l := Label.new(); l.text = label; g.add_child(l)
	var e := LineEdit.new(); e.custom_minimum_size = Vector2(320, 0); g.add_child(e)
	return e

func _build_arch_tab() -> Control:
	var h := HBoxContainer.new(); h.name = "Personalities"
	h.add_theme_constant_override("separation", 16)
	arch_list = _list_column(h, "Personalities", [["New", _new_arch], ["Duplicate", _dup_arch], ["Delete", _del_arch]])
	arch_list.item_selected.connect(_select_arch)
	var sc := ScrollContainer.new(); sc.size_flags_horizontal = Control.SIZE_EXPAND_FILL; h.add_child(sc)
	var right := VBoxContainer.new(); right.size_flags_horizontal = Control.SIZE_EXPAND_FILL; sc.add_child(right)
	var g := GridContainer.new(); g.columns = 2; right.add_child(g)
	a_name = _line(g, "Name"); a_name.text_changed.connect(func(_s): _store_arch())
	a_desc = _line(g, "Description"); a_desc.text_changed.connect(func(_s): _store_arch())
	a_weight = _spin(g, "Weight (how often picked; 0 = never)", 0, 10, 1, 0.1)
	a_spread = _spin(g, "Spread (how much empires of it differ)", 0, 0.4, 0.1, 0.01)
	a_stab = [_spin(g, "Stability min", 0.05, 0.95, 0.3, 0.05), _spin(g, "Stability max", 0.05, 0.95, 0.9, 0.05)]
	for x in [a_weight, a_spread] + a_stab:
		x.value_changed.connect(func(_v): _store_arch())
	right.add_child(HSeparator.new())
	var l := Label.new(); l.text = "Trait blocks (greyed: conflicts with one already chosen)"; right.add_child(l)
	a_blocks = VBoxContainer.new(); right.add_child(a_blocks)
	a_summary = Label.new(); a_summary.autowrap_mode = TextServer.AUTOWRAP_WORD; a_summary.modulate = Color(0.75, 0.8, 0.9)
	right.add_child(a_summary)
	return h

func _build_block_tab() -> Control:
	var h := HBoxContainer.new(); h.name = "Trait blocks"
	h.add_theme_constant_override("separation", 16)
	block_list = _list_column(h, "Trait blocks", [["New", _new_block], ["Duplicate", _dup_block], ["Delete", _del_block]])
	block_list.item_selected.connect(_select_block)
	var sc := ScrollContainer.new(); sc.size_flags_horizontal = Control.SIZE_EXPAND_FILL; h.add_child(sc)
	var right := VBoxContainer.new(); right.size_flags_horizontal = Control.SIZE_EXPAND_FILL; sc.add_child(right)
	var g := GridContainer.new(); g.columns = 2; right.add_child(g)
	b_id = _line(g, "Id (used by personalities)")
	b_name = _line(g, "Name")
	b_desc = _line(g, "Description")
	b_group = _line(g, "Exclusive group (one block per group)")
	b_excl = _line(g, "Also excludes (ids, comma-separated)")
	for e in [b_id, b_name, b_desc, b_group, b_excl]:
		e.text_changed.connect(func(_s): _store_block())
	b_weight = _spin(g, "Weight in regime reforms (0 = never)", 0, 10, 1, 0.1)
	b_weight.value_changed.connect(func(_v): _store_block())
	right.add_child(HSeparator.new())
	var la := Label.new(); la.text = "Axes it pushes (added to the neutral 0.5)"; right.add_child(la)
	var ag := GridContainer.new(); ag.columns = 3; right.add_child(ag)
	for n in axis_names:
		var ln := Label.new(); ln.text = n.capitalize(); ag.add_child(ln)
		var sl := HSlider.new(); sl.min_value = -0.5; sl.max_value = 0.5; sl.step = 0.05; sl.custom_minimum_size = Vector2(260, 0); ag.add_child(sl)
		var val := Label.new(); val.custom_minimum_size = Vector2(60, 0); ag.add_child(val)
		sl.value_changed.connect(func(_v): _store_block())
		b_axes[n] = [sl, val]
	right.add_child(HSeparator.new())
	var lf := Label.new(); lf.text = "Effects it scales (1 = no change)"; right.add_child(lf)
	var fg := GridContainer.new(); fg.columns = 4; right.add_child(fg)
	for n in effect_names:
		var sp := _spin(fg, n.capitalize(), 0.1, 3.0, 1.0, 0.05)
		sp.value_changed.connect(func(_v): _store_block())
		b_fx[n] = sp
	return h

func _build_rules_tab() -> Control:
	var sc := ScrollContainer.new(); sc.name = "Rules"
	var rg := GridContainer.new(); rg.columns = 2; sc.add_child(rg)
	for r in book.get("rules", {}).keys():
		var sp := _spin(rg, r.capitalize(), 0, 100, float(book["rules"][r]), 0.001)
		sp.value_changed.connect(func(v): if not _loading: book["rules"][r] = v)
		e_rules[r] = sp
	return sc

func _refresh_all() -> void:
	_loading = true
	for r in e_rules:
		e_rules[r].value = float(book["rules"].get(r, 0.0))
	_loading = false
	arch_list.clear()
	for a in book["archetypes"]:
		arch_list.add_item(a.get("name", "?"))
	block_list.clear()
	for b in book["blocks"]:
		block_list.add_item(b.get("name", "?"))
	if book["archetypes"].size() > 0:
		_select_arch(clampi(cur, 0, book["archetypes"].size() - 1))
	if book["blocks"].size() > 0:
		_select_block(clampi(bcur, 0, book["blocks"].size() - 1))

# ---- personalities
func _blk(id : String) -> Dictionary:
	for b in book["blocks"]:
		if b["id"] == id:
			return b
	return {}

func _conflicts(id : String, chosen : Array) -> String:
	var b := _blk(id)
	for o_id in chosen:
		if o_id == id: continue
		var o := _blk(o_id)
		if o.is_empty(): continue
		var g : String = b.get("group", "")
		if (g != "" and g == o.get("group", "")) or o_id in b.get("excludes", []) or id in o.get("excludes", []):
			return o.get("name", o_id)
	return ""

func _select_arch(i : int) -> void:
	cur = i
	arch_list.select(i)
	var a : Dictionary = book["archetypes"][i]
	_loading = true
	a_name.text = a.get("name", "")
	a_desc.text = a.get("description", "")
	a_weight.value = a.get("weight", 1.0)
	a_spread.value = a.get("spread", 0.1)
	var st : Array = a.get("stability", [0.3, 0.9])
	a_stab[0].value = st[0]; a_stab[1].value = st[1]
	_loading = false
	_build_block_checks()

func _build_block_checks() -> void:
	for c in a_blocks.get_children():
		c.queue_free()
	var chosen : Array = book["archetypes"][cur].get("blocks", [])
	for b in book["blocks"]:
		var cb := CheckBox.new()
		var id : String = b["id"]
		var grp : String = b.get("group", "")
		cb.text = "%s%s - %s" % [b["name"], (" [%s]" % grp) if grp != "" else "", b.get("description", "")]
		cb.button_pressed = id in chosen
		var clash := _conflicts(id, chosen)
		if not cb.button_pressed and clash != "":
			cb.disabled = true
			cb.tooltip_text = "conflicts with " + clash
		cb.toggled.connect(func(on): _toggle_block(id, on))
		a_blocks.add_child(cb)
	a_summary.text = _summary(chosen)

## The combined axes and effects of a set of blocks, for the summary line.
func _summary(chosen : Array) -> String:
	var ax := {}; var fx := {}
	for id in chosen:
		var b := _blk(id)
		for k in b.get("axes", {}): ax[k] = ax.get(k, 0.5) + b["axes"][k]
		for k in b.get("effects", {}): fx[k] = fx.get(k, 1.0) * b["effects"][k]
	var parts : Array = []
	for k in ax: parts.append("%s %.2f" % [k, clampf(ax[k], 0.05, 0.95)])
	for k in fx: parts.append("%s x%.2f" % [k.replace("_", " "), fx[k]])
	return "Result: " + (", ".join(parts) if parts.size() > 0 else "neutral")

func _toggle_block(id : String, on : bool) -> void:
	var chosen : Array = book["archetypes"][cur].get("blocks", []).duplicate()
	if on and not id in chosen: chosen.append(id)
	if not on: chosen.erase(id)
	book["archetypes"][cur]["blocks"] = chosen
	_build_block_checks()

func _store_arch() -> void:
	if _loading or cur < 0: return
	var a : Dictionary = book["archetypes"][cur]
	a["name"] = a_name.text; a["description"] = a_desc.text; a["weight"] = a_weight.value
	a["spread"] = a_spread.value; a["stability"] = [a_stab[0].value, a_stab[1].value]
	arch_list.set_item_text(cur, a_name.text)

func _new_arch() -> void:
	book["archetypes"].append({"name": "New personality", "description": "", "weight": 1.0, "spread": 0.1, "stability": [0.3, 0.9], "blocks": []})
	cur = book["archetypes"].size() - 1
	_refresh_all()

func _dup_arch() -> void:
	if cur < 0: return
	var a : Dictionary = book["archetypes"][cur].duplicate(true)
	a["name"] += " (copy)"
	book["archetypes"].append(a)
	cur = book["archetypes"].size() - 1
	_refresh_all()

func _del_arch() -> void:
	if cur < 0 or book["archetypes"].size() <= 1:
		e_status.text = "At least one personality is needed."; return
	book["archetypes"].remove_at(cur)
	cur = mini(cur, book["archetypes"].size() - 1)
	_refresh_all()

# ---- trait blocks
func _select_block(i : int) -> void:
	bcur = i
	block_list.select(i)
	var b : Dictionary = book["blocks"][i]
	_loading = true
	b_id.text = b.get("id", ""); b_name.text = b.get("name", ""); b_desc.text = b.get("description", "")
	b_group.text = b.get("group", ""); b_excl.text = ", ".join(b.get("excludes", []))
	b_weight.value = b.get("weight", 1.0)
	for n in axis_names:
		b_axes[n][0].value = b.get("axes", {}).get(n, 0.0)
		b_axes[n][1].text = "%+.2f" % b_axes[n][0].value
	for n in effect_names:
		b_fx[n].value = b.get("effects", {}).get(n, 1.0)
	_loading = false

func _store_block() -> void:
	for n in axis_names:
		b_axes[n][1].text = "%+.2f" % b_axes[n][0].value
	if _loading or bcur < 0: return
	var b : Dictionary = book["blocks"][bcur]
	var old_id : String = b.get("id", "")
	var new_id := b_id.text.strip_edges().to_lower().replace(" ", "_")
	if new_id != old_id and new_id != "":
		for a in book["archetypes"]:   # keep personalities pointing at the renamed block
			var bl : Array = a.get("blocks", [])
			var k := bl.find(old_id)
			if k >= 0: bl[k] = new_id
		b["id"] = new_id
	b["name"] = b_name.text; b["description"] = b_desc.text; b["group"] = b_group.text.strip_edges()
	var ex : Array = []
	for x in b_excl.text.split(",", false):
		if x.strip_edges() != "": ex.append(x.strip_edges())
	b["excludes"] = ex
	b["weight"] = b_weight.value
	var ax := {}
	for n in axis_names:
		if absf(b_axes[n][0].value) > 0.001: ax[n] = b_axes[n][0].value
	b["axes"] = ax
	var fx := {}
	for n in effect_names:
		if absf(b_fx[n].value - 1.0) > 0.001: fx[n] = b_fx[n].value
	b["effects"] = fx
	block_list.set_item_text(bcur, b_name.text)

func _new_block() -> void:
	var n := 1
	while not _blk("trait_%d" % n).is_empty(): n += 1
	book["blocks"].append({"id": "trait_%d" % n, "name": "New trait", "description": "", "group": "", "excludes": [], "axes": {}, "effects": {}, "weight": 1.0})
	bcur = book["blocks"].size() - 1
	_refresh_all()

func _dup_block() -> void:
	if bcur < 0: return
	var b : Dictionary = book["blocks"][bcur].duplicate(true)
	b["id"] += "_copy"; b["name"] += " (copy)"
	book["blocks"].append(b)
	bcur = book["blocks"].size() - 1
	_refresh_all()

func _del_block() -> void:
	if bcur < 0: return
	var id : String = book["blocks"][bcur]["id"]
	book["blocks"].remove_at(bcur)
	for a in book["archetypes"]:
		a.get("blocks", []).erase(id)
	bcur = mini(bcur, book["blocks"].size() - 1)
	_refresh_all()

func _reset_book() -> void:
	book = _book_from_sim(false)
	cur = 0; bcur = 0
	_refresh_all()
	e_status.text = "Built-in personalities restored (not saved yet)."

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
