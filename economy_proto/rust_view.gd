extends Node2D
## Map view driven by the Rust simulation (rust/galaxy_gd, class GalaxySim). The sim runs on its own thread; each frame
## this view polls for the newest month and redraws from that snapshot only, so drawing never waits on the sim.
## Build the library first:  cd rust ; cargo build --release -p galaxy_gd
## Started from the main menu, it uses GameSetup's settings or save.
##
## Controls (also in the in-game help, [H]):
##   mouse wheel / +- zoom (toward the cursor)   left- or right-drag / WASD / arrows pan   [Home] fit galaxy
##   click a system: its panel; click an empire row: its panel and centre on its capital   [Esc] close panels
##   [Space] pause   [1]-[5] speed presets, [ and ] slower/faster   [T] trade ships  [F] forces  [L] labels
##   [F5] quicksave  [F9] quickload  [Ctrl+S] save as new slot  [M] main menu
@export var systems : int = 46
@export var empires : int = 4
@export var planets : int = 100
@export var sim_seed : int = 7
@export var months_per_second : float = 6.0
## Place stars from William's two galaxy images (density + population); off = uniform disc.
@export var use_maps : bool = true
@export_file("*.png") var density_map : String = "res://galaxy_maps/spiral_density.png"
@export_file("*.png") var population_map : String = "res://galaxy_maps/spiral_population.png"

const EMPIRE_COLORS : Array = [Color(0.95, 0.8, 0.35), Color(0.4, 0.75, 1.0), Color(0.95, 0.45, 0.45), Color(0.6, 0.9, 0.5), Color(0.8, 0.6, 1.0), Color(1.0, 0.65, 0.3), Color(0.5, 0.95, 0.9), Color(0.95, 0.6, 0.85)]
const GOOD_COLORS : Array = [Color(0.72, 0.45, 0.25), Color(0.7, 0.78, 0.9), Color(0.95, 0.8, 0.3), Color(0.45, 0.85, 0.4), Color(0.35, 0.65, 1.0)]
const TERRITORY_RADIUS := 70.0
const SHIP_SPEED := 160.0
const MAX_SHIPS := 300
const SYS_STRIDE := 10     # x, y, owner, occupier, at_front, settled bodies, bodies, pop, known, shortage
const GOOD_NAMES : Array = ["Ore", "Metal", "Parts", "Food", "Water"]
const SHIP_STRIDE := 6     # from x, from y, to x, to y, good, qty
const FORCE_STRIDE := 9    # x, y, owner, army, strength, dest x, dest y, in operation, id

var sim
var snap : Dictionary = {}
var ships : Array = []          # [from, to, good, travelled, length]
var log_lines : Array = []
var show_ships : bool = true
var show_labels : bool = true
var show_forces : bool = true
var territory_rect : ColorRect = null
var territory_sig : String = ""
var ship_layer : Node2D
var force_layer : Node2D
var force_prev : Dictionary = {}   # force id -> position at the previous month
var force_from : Dictionary = {}   # force id -> position this month's movement starts from
var force_t : float = 1.0          # 0..1 through the current month (for interpolation)
var tps : float = 0.0
var _tps_n : int = 0
var _tps_t : float = 0.0
var _last_tick : int = -1
var selected : int = -1          # system shown in the info panel
var detail : Dictionary = {}
var sel_empire : int = -1        # empire shown in the empire panel
const SPEEDS : Array = [1.0, 3.0, 6.0, 24.0, 96.0]
const ZOOM_MIN := 0.04
const ZOOM_MAX := 6.0
const PAN_KEYS_SPEED := 700.0
const LEFT_W := 250.0
const RIGHT_W := 290.0
const LOG_H := 130.0
var _drag_from : Vector2 = Vector2.ZERO
var _dragging : bool = false
var _press_pos : Vector2 = Vector2.ZERO
var _fitted : bool = false
var log_filter : int = 0         # 0 all, 1 war, 2 diplomacy, 3 crises, 4 politics
const LOG_KEEP := 300
# UI nodes (CanvasLayer, unaffected by pan/zoom)
var ui : CanvasLayer
var lbl_date : Label
var btn_pause : Button
var lbl_speed : Label
var empire_box : VBoxContainer
var empire_rows : Array = []     # [button, swatch, label, war label, bar]
var log_text : RichTextLabel
var sys_panel : PanelContainer
var sys_text : RichTextLabel
var emp_panel : PanelContainer
var emp_text : RichTextLabel
var help_panel : PanelContainer
var toast : Label
var _toast_t : float = 0.0

func _ready() -> void:
	if not ClassDB.class_exists("GalaxySim"):
		push_error("GalaxySim not found: build the Rust extension (cd rust && cargo build --release -p galaxy_gd)")
		return
	sim = ClassDB.instantiate("GalaxySim")
	add_child(sim)
	sim.set_speed(months_per_second)
	var cfg : Dictionary = {"systems": systems, "empires": empires, "planets": planets, "seed": sim_seed,
		"personalities": GameSetup.personalities_json()}
	if use_maps:
		cfg["density_map"] = density_map
		cfg["population_map"] = population_map
	if not GameSetup.config.is_empty():
		cfg = GameSetup.config
	if GameSetup.load_path != "":
		var err : String = sim.load_game(GameSetup.load_path)
		GameSetup.load_path = ""
		if err != "":
			push_error("Load failed: " + err)
			sim.start(cfg)
		else:
			_note("Loaded")
	else:
		sim.start(cfg)
	ship_layer = Node2D.new()
	ship_layer.draw.connect(_draw_ships)
	add_child(ship_layer)
	force_layer = Node2D.new()
	force_layer.draw.connect(_draw_forces_layer)
	add_child(force_layer)
	_build_ui()

func _process(delta : float) -> void:
	if sim == null:
		return
	var s : Dictionary = sim.poll()
	if not s.is_empty():
		# Forces glide from where they were drawn to this month's position over the next month.
		if s.has("forces"):
			var fo : PackedFloat32Array = s["forces"]
			var from := {}
			for i in range(0, fo.size(), FORCE_STRIDE):
				var id : int = int(fo[i + 8])
				from[id] = _force_drawn_pos(id) if force_prev.has(id) else Vector2(fo[i], fo[i + 1])
			force_from = from
			force_prev.clear()
			for i in range(0, fo.size(), FORCE_STRIDE):
				force_prev[int(fo[i + 8])] = Vector2(fo[i], fo[i + 1])
			force_t = 0.0
		snap = s
		_tps_n += s["tick"] - _last_tick if _last_tick >= 0 else 0
		_last_tick = s["tick"]
		for ev in s["events"]:
			log_lines.append(ev)
		while log_lines.size() > LOG_KEEP:
			log_lines.pop_front()
		if not _fitted:
			_fit_view(); _fitted = true
		_update_ui(s["events"].size() > 0)
		if show_ships:
			var sh : PackedFloat32Array = s["shipments"]
			for i in range(0, sh.size(), SHIP_STRIDE):
				if ships.size() >= MAX_SHIPS:
					break
				var a := Vector2(sh[i], sh[i + 1]); var b := Vector2(sh[i + 2], sh[i + 3])
				if a.distance_to(b) > 1.0:
					ships.append([a, b, int(sh[i + 4]), 0.0, a.distance_to(b)])
		if selected >= 0:
			sim.request_detail(selected)      # keep the panel live
		queue_redraw()
	var det : Dictionary = sim.take_detail()
	if not det.is_empty() and det["id"] == selected:
		detail = det
		_update_sys_panel()
		queue_redraw()
	# Keyboard panning
	var pan := Vector2(float(Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT)) - float(Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT)),
		float(Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP)) - float(Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN)))
	if pan != Vector2.ZERO and not Input.is_key_pressed(KEY_CTRL):
		position += pan * PAN_KEYS_SPEED * delta
		queue_redraw()
	if _toast_t > 0.0:
		_toast_t -= delta
		toast.modulate.a = clampf(_toast_t, 0.0, 1.0)
	_tps_t += delta
	if _tps_t >= 1.0:
		tps = _tps_n / _tps_t; _tps_n = 0; _tps_t = 0.0
	if not sim.is_paused():
		for sp in ships:
			sp[3] += SHIP_SPEED * delta * minf(months_per_second / 6.0, 4.0)
		ships = ships.filter(func(sp): return sp[3] < sp[4])
		force_t = minf(force_t + delta * months_per_second, 1.0)
	ship_layer.queue_redraw()
	force_layer.queue_redraw()

func _unhandled_input(e : InputEvent) -> void:
	if sim == null:
		return
	if e is InputEventKey and e.pressed and not e.echo:
		match e.keycode:
			KEY_SPACE: _toggle_pause()
			KEY_1, KEY_2, KEY_3, KEY_4, KEY_5: _set_speed(SPEEDS[e.keycode - KEY_1])
			KEY_BRACKETRIGHT: _set_speed(minf(months_per_second * 2.0, 960.0))
			KEY_BRACKETLEFT: _set_speed(maxf(months_per_second * 0.5, 0.25))
			KEY_T: _set_toggle("ships", not show_ships)
			KEY_L: _set_toggle("labels", not show_labels)
			KEY_F: _set_toggle("forces", not show_forces)
			KEY_H: help_panel.visible = not help_panel.visible
			KEY_HOME: _fit_view()
			KEY_F5: _save(GameSetup.QUICKSAVE)
			KEY_F9: _load(GameSetup.QUICKSAVE)
			KEY_S:
				if e.ctrl_pressed: _save_new()
			KEY_M: _to_menu()
			KEY_ESCAPE:
				if help_panel.visible: help_panel.visible = false
				else: _select_system(-1); _select_empire(-1)
			KEY_EQUAL, KEY_KP_ADD: _zoom_at(get_viewport_rect().size * 0.5, 1.25)
			KEY_MINUS, KEY_KP_SUBTRACT: _zoom_at(get_viewport_rect().size * 0.5, 0.8)
	elif e is InputEventMouseButton:
		if e.pressed and e.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom_at(e.position, 1.15)
		elif e.pressed and e.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_at(e.position, 1.0 / 1.15)
		elif e.button_index == MOUSE_BUTTON_LEFT:
			if e.pressed:
				_press_pos = e.position; _dragging = false
			elif not _dragging:
				_click_system(e.position)
			else:
				_dragging = false
	elif e is InputEventMouseMotion and e.button_mask & (MOUSE_BUTTON_MASK_RIGHT | MOUSE_BUTTON_MASK_MIDDLE | MOUSE_BUTTON_MASK_LEFT):
		if e.button_mask & MOUSE_BUTTON_MASK_LEFT and not _dragging and e.position.distance_to(_press_pos) < 6.0:
			return
		_dragging = e.button_mask & MOUSE_BUTTON_MASK_LEFT != 0
		position += e.relative
		queue_redraw()

func _zoom_at(screen : Vector2, f : float) -> void:
	var ns : float = clampf(scale.x * f, ZOOM_MIN, ZOOM_MAX)
	var world : Vector2 = get_global_transform().affine_inverse() * screen
	scale = Vector2(ns, ns)
	position = screen - world * ns
	queue_redraw()

## Frame all known systems in the space left between the panels.
func _fit_view() -> void:
	if snap.is_empty():
		return
	var sys : PackedFloat32Array = snap["systems"]
	var r := Rect2(Vector2(sys[0], sys[1]), Vector2.ZERO)
	for i in range(0, sys.size(), SYS_STRIDE):
		r = r.expand(Vector2(sys[i], sys[i + 1]))
	r = r.grow(TERRITORY_RADIUS * 0.6)
	var vs := get_viewport_rect().size
	var area := Rect2(Vector2(LEFT_W + 12, 46), vs - Vector2(LEFT_W + 12 + 10, 46 + LOG_H + 6))
	var ns : float = clampf(minf(area.size.x / maxf(r.size.x, 1.0), area.size.y / maxf(r.size.y, 1.0)), ZOOM_MIN, ZOOM_MAX)
	scale = Vector2(ns, ns)
	position = area.get_center() - r.get_center() * ns
	queue_redraw()

func _click_system(screen : Vector2) -> void:
	if snap.is_empty():
		return
	var p : Vector2 = get_global_transform().affine_inverse() * screen
	var sys : PackedFloat32Array = snap["systems"]
	var best : int = -1
	var bd : float = 16.0 / scale.x
	for i in range(0, sys.size(), SYS_STRIDE):
		var d : float = p.distance_to(Vector2(sys[i], sys[i + 1]))
		if d < bd:
			bd = d; best = i / SYS_STRIDE
	_select_system(best)

func _select_system(i : int) -> void:
	if i >= 0 and emp_panel.visible:
		_select_empire(-1)
	selected = i
	detail = {}
	sys_panel.visible = i >= 0
	if i >= 0:
		sys_text.text = "[color=#999]loading...[/color]"
		sim.request_detail(i)
	queue_redraw()

func _select_empire(i : int) -> void:
	if i >= 0 and sys_panel.visible:
		_select_system(-1)
	sel_empire = i
	emp_panel.visible = i >= 0
	_update_empire_panel()
	queue_redraw()

func _toggle_pause() -> void:
	sim.set_paused(not sim.is_paused())
	_update_controls()

func _set_speed(v : float) -> void:
	months_per_second = v
	sim.set_speed(v)
	_update_controls()

func _set_toggle(what : String, on : bool) -> void:
	match what:
		"ships":
			show_ships = on
			if not on: ships.clear()
		"forces": show_forces = on
		"labels": show_labels = on
	for b in ui.find_children("Toggle_" + what, "Button", true, false):
		b.set_pressed_no_signal(on)
	queue_redraw()

func _to_menu() -> void:
	sim.stop(); GameSetup.config = {}
	get_tree().change_scene_to_file("res://economy_proto/main_menu.tscn")

func _save_new() -> void:
	_save("%s/%s.sav" % [GameSetup.SAVE_DIR, Time.get_datetime_string_from_system().replace(":", "-")])

func _empire_color(i : int) -> Color:
	return EMPIRE_COLORS[i % EMPIRE_COLORS.size()] if i >= 0 else Color(0.55, 0.55, 0.6)

func _rebuild_territory(sys : PackedFloat32Array) -> void:
	if territory_rect == null:
		territory_rect = ColorRect.new()
		territory_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		territory_rect.show_behind_parent = true
		var mat := ShaderMaterial.new()
		mat.shader = load("res://economy_proto/territory.gdshader")
		var cols : Array = []
		for i in 8: cols.append(_empire_color(i))
		mat.set_shader_parameter("colors", cols)
		mat.set_shader_parameter("radius", TERRITORY_RADIUS)
		territory_rect.material = mat
		add_child(territory_rect)
	# Cover every system (plus the territory radius), wherever the galaxy sits in map coordinates.
	var bounds := Rect2(Vector2(sys[0], sys[1]), Vector2.ZERO)
	for i in range(0, sys.size(), SYS_STRIDE):
		bounds = bounds.expand(Vector2(sys[i], sys[i + 1]))
	bounds = bounds.grow(TERRITORY_RADIUS + 4.0)
	territory_rect.position = bounds.position
	territory_rect.size = bounds.size
	var claimed : Array = []
	for i in range(0, sys.size(), SYS_STRIDE):
		if sys[i + 2] >= 0.0:
			claimed.append(Color(sys[i], sys[i + 1], sys[i + 2], 1.0))
	var img := Image.create(maxi(claimed.size(), 1), 1, false, Image.FORMAT_RGBAF)
	for i in claimed.size():
		img.set_pixel(i, 0, claimed[i])
	var mat : ShaderMaterial = territory_rect.material
	mat.set_shader_parameter("systems", ImageTexture.create_from_image(img))
	mat.set_shader_parameter("count", claimed.size())
	mat.set_shader_parameter("origin", bounds.position)

func _draw() -> void:
	if snap.is_empty():
		return
	var font : Font = ThemeDB.fallback_font
	var sys : PackedFloat32Array = snap["systems"]
	var names : PackedStringArray = snap["system_names"]
	var emps : Array = snap["empires"]
	# Territory (GPU), rebuilt only when ownership changes
	var sig := ""
	for i in range(0, sys.size(), SYS_STRIDE):
		sig += str(int(sys[i + 2]))
	if sig != territory_sig:
		territory_sig = sig
		_rebuild_territory(sys)
	# Alliances and wars between capitals
	var pacts : PackedInt32Array = snap["pacts"]
	for i in range(0, pacts.size(), 2):
		draw_line(emps[pacts[i]]["capital"], emps[pacts[i + 1]]["capital"], Color(0.55, 0.85, 1.0, 0.7), 2.5)
	var guar : PackedInt32Array = snap["guarantees"]
	for i in range(0, guar.size(), 2):
		draw_dashed_line(emps[guar[i]]["capital"], emps[guar[i + 1]]["capital"], Color(0.55, 0.85, 1.0, 0.5), 1.5, 6.0)
	var wars : PackedInt32Array = snap["wars"]
	for i in range(0, wars.size(), 2):
		draw_dashed_line(emps[wars[i]]["capital"], emps[wars[i + 1]]["capital"], Color(1.0, 0.2, 0.15, 0.8), 2.0, 10.0)
	# Star systems
	var at_war : bool = wars.size() > 0
	for i in range(0, sys.size(), SYS_STRIDE):
		var p := Vector2(sys[i], sys[i + 1])
		var owner : int = int(sys[i + 2])
		var occ : int = int(sys[i + 3])
		var settled : int = int(sys[i + 5])
		var pop : float = sys[i + 7]
		if sys[i + 8] < 0.5 and owner < 0:
			draw_circle(p, 2.0, Color(0.3, 0.3, 0.35))          # uncharted
			continue
		var r : float = 4.0 + sqrt(pop) * 0.35 if settled > 0 else 3.0
		draw_circle(p, r, _empire_color(owner) if owner >= 0 else Color(0.55, 0.55, 0.6))
		if sys[i + 9] > 0.05:
			draw_arc(p, r + 1.5, 0.0, TAU, 24, Color(1.0, 0.25, 0.2, 0.35 + 0.6 * sys[i + 9]), 2.0)   # short of food/parts
		if i / SYS_STRIDE == selected:
			draw_arc(p, r + 7.0, 0.0, TAU, 32, Color.WHITE, 1.5)
		if occ >= 0:
			draw_arc(p, r + 4.0, 0.0, TAU, 32, _empire_color(occ), 3.5)
			for k in range(-2, 3):
				var o := Vector2(k * r * 0.4, 0.0)
				draw_line(p + o + Vector2(-r * 0.35, r * 0.6), p + o + Vector2(r * 0.35, -r * 0.6), _empire_color(occ), 2.0)
		elif sys[i + 4] > 0.5 and at_war:
			for k in 12:
				draw_arc(p, r + 4.0, k * TAU / 12.0, k * TAU / 12.0 + TAU / 24.0, 4, Color(1.0, 0.25, 0.2, 0.9), 2.0)
		if show_labels and settled > 0 and scale.x >= 0.45:   # unreadable when zoomed far out
			draw_string(font, p + Vector2(-r, -r - 4.0), "%s %d/%d" % [names[i / SYS_STRIDE], settled, int(sys[i + 6])], HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(1, 1, 1, 0.75))
	if sel_empire >= 0 and sel_empire < emps.size():
		var c : Vector2 = emps[sel_empire]["capital"]
		draw_arc(c, 16.0, 0.0, TAU, 40, _empire_color(sel_empire), 2.0)
		draw_arc(c, 20.0, 0.0, TAU, 40, Color(_empire_color(sel_empire), 0.4), 1.0)

func _draw_ships() -> void:
	for sp in ships:
		var dir : Vector2 = (sp[1] - sp[0]).normalized()
		var pos : Vector2 = sp[0] + dir * sp[3]
		var pts := PackedVector2Array([pos + dir * 6.0, pos + dir.rotated(2.5) * 4.0, pos + dir.rotated(-2.5) * 4.0])
		ship_layer.draw_colored_polygon(pts, GOOD_COLORS[sp[2] % GOOD_COLORS.size()])

func _save(path : String) -> void:
	DirAccess.make_dir_recursive_absolute(GameSetup.SAVE_DIR)
	var err : String = sim.save_game(path)
	_note("Saved " + path.get_file().get_basename() if err == "" else "Save failed: " + err)

func _load(path : String) -> void:
	if not FileAccess.file_exists(path):
		_note("No save at " + path.get_file()); return
	var err : String = sim.load_game(path)
	if err == "":
		ships.clear(); _select_system(-1); _select_empire(-1); _last_tick = -1; territory_sig = ""; log_lines.clear()
	_note("Loaded " + path.get_file().get_basename() if err == "" else "Load failed: " + err)

func _note(t : String) -> void:
	if toast == null:
		log_lines.append("** " + t); return
	toast.text = t
	_toast_t = 3.0
	toast.modulate.a = 1.0

## Where a force is drawn right now: between last month's drawn position and this month's, by the month's progress.
func _force_drawn_pos(id : int) -> Vector2:
	var to : Vector2 = force_prev.get(id, Vector2.ZERO)
	var from : Vector2 = force_from.get(id, to)
	return from.lerp(to, force_t)

func _draw_forces_layer() -> void:
	if show_forces and snap.has("forces"):
		_draw_forces(snap["forces"])

## Fleets (triangles) and armies (squares), sized by strength, in their empire's colour. Forces in an operation
## show a line to where they are heading; several forces in one system are fanned out so each stays visible.
## Positions glide smoothly between months.
func _draw_forces(fo : PackedFloat32Array) -> void:
	var font : Font = ThemeDB.fallback_font
	var stacked : Dictionary = {}
	var L := force_layer
	for i in range(0, fo.size(), FORCE_STRIDE):
		var at := Vector2(fo[i], fo[i + 1])
		var p := _force_drawn_pos(int(fo[i + 8]))
		var key := Vector2i(int(at.x), int(at.y))
		var k : int = 0
		if p.distance_to(at) < 1.0:   # fan out only forces sitting in a system
			k = stacked.get(key, 0)
			stacked[key] = k + 1
		p += Vector2(10.0 + 9.0 * (k % 3), -10.0 - 9.0 * (k / 3))
		var col := _empire_color(int(fo[i + 2]))
		var size : float = clampf(2.5 + sqrt(fo[i + 4]) * 0.35, 3.0, 11.0)
		var dest := Vector2(fo[i + 5], fo[i + 6])
		if fo[i + 7] > 0.5 and dest.distance_to(Vector2(fo[i], fo[i + 1])) > 1.0:
			L.draw_dashed_line(p, dest, Color(col, 0.6), 1.2, 5.0)
		if fo[i + 3] > 0.5:
			L.draw_rect(Rect2(p - Vector2(size, size) * 0.8, Vector2(size, size) * 1.6), col)
			L.draw_rect(Rect2(p - Vector2(size, size) * 0.8, Vector2(size, size) * 1.6), Color(0, 0, 0, 0.8), false, 1.0)
		else:
			var tri := PackedVector2Array([p + Vector2(0, -size), p + Vector2(size * 0.9, size * 0.7), p + Vector2(-size * 0.9, size * 0.7)])
			L.draw_colored_polygon(tri, col)
			tri.append(tri[0])
			L.draw_polyline(tri, Color(0, 0, 0, 0.8), 1.0)
		if show_labels and fo[i + 4] >= 20.0:
			L.draw_string(font, p + Vector2(size + 2, 4), str(int(fo[i + 4])), HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color(1, 1, 1, 0.8))

## Event log colours: war red, peace green, crises orange, operations and battles amber, politics violet.
func _event_color(line : String) -> Color:
	if line.contains("WAR:") or line.contains("occupies") or line.contains("strikes"):
		return Color(1.0, 0.45, 0.4)
	if line.contains("PEACE") or line.contains("liberates") or line.contains("compromise"):
		return Color(0.55, 0.95, 0.55)
	if line.contains("CRISIS") or line.contains("crisis") or line.contains("backs down") or line.contains("concedes"):
		return Color(1.0, 0.7, 0.3)
	if line.contains("OPERATION") or line.contains("BATTLE") or line.contains("operation"):
		return Color(0.95, 0.85, 0.45)
	if line.contains("REGIME") or line.contains("pact") or line.contains("guarantee") or line.contains("shelves") or line.contains("stays out"):
		return Color(0.8, 0.7, 1.0)
	return Color(0.8, 0.8, 0.72)

# ================================================================== UI (CanvasLayer)
func _panel_style(alpha : float = 0.9) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.07, 0.08, 0.11, alpha)
	sb.border_color = Color(1, 1, 1, 0.12)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(8)
	return sb

func _panel(parent : Node) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", _panel_style())
	parent.add_child(p)
	return p

func _button(parent : Node, text : String, tip : String, cb : Callable, toggle_name : String = "") -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_NONE
	if toggle_name != "":
		b.name = "Toggle_" + toggle_name
		b.toggle_mode = true
		b.toggled.connect(func(on): _set_toggle(toggle_name, on))
	else:
		b.pressed.connect(cb)
	parent.add_child(b)
	return b

func _build_ui() -> void:
	ui = CanvasLayer.new()
	add_child(ui)
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var th := Theme.new()
	th.default_font_size = 12
	root.theme = th
	ui.add_child(root)

	# --- Top bar: date, time controls, toggles, game menu
	var top := _panel(root)
	top.set_anchors_preset(Control.PRESET_TOP_WIDE)
	top.offset_left = 6; top.offset_right = -6; top.offset_top = 6
	var tb := HBoxContainer.new()
	tb.add_theme_constant_override("separation", 6)
	top.add_child(tb)
	lbl_date = Label.new()
	lbl_date.custom_minimum_size = Vector2(130, 0)
	lbl_date.add_theme_font_size_override("font_size", 14)
	tb.add_child(lbl_date)
	btn_pause = _button(tb, "Pause", "Pause / resume  [Space]", _toggle_pause)
	btn_pause.custom_minimum_size = Vector2(52, 0)
	_button(tb, "<<", "Slower  [ [ ]", func(): _set_speed(maxf(months_per_second * 0.5, 0.25)))
	lbl_speed = Label.new()
	lbl_speed.custom_minimum_size = Vector2(70, 0)
	lbl_speed.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tb.add_child(lbl_speed)
	_button(tb, ">>", "Faster  [ ] ]", func(): _set_speed(minf(months_per_second * 2.0, 960.0)))
	tb.add_child(VSeparator.new())
	_button(tb, "Ships", "Trade ships  [T]", Callable(), "ships").button_pressed = show_ships
	_button(tb, "Forces", "Fleets and armies  [F]", Callable(), "forces").button_pressed = show_forces
	_button(tb, "Labels", "System and force labels  [L]", Callable(), "labels").button_pressed = show_labels
	_button(tb, "Fit", "Fit the galaxy in view  [Home]", _fit_view)
	var spacer := Control.new(); spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL; tb.add_child(spacer)
	_button(tb, "Quicksave", "[F5]", func(): _save(GameSetup.QUICKSAVE))
	_button(tb, "Quickload", "[F9]", func(): _load(GameSetup.QUICKSAVE))
	_button(tb, "Save as...", "New save slot  [Ctrl+S]", _save_new)
	_button(tb, "Help", "Controls and map legend  [H]", func(): help_panel.visible = not help_panel.visible)
	_button(tb, "Menu", "Back to the main menu  [M]", _to_menu)

	# --- Left: empires
	var left := _panel(root)
	left.position = Vector2(6, 46)
	left.custom_minimum_size = Vector2(LEFT_W, 0)
	var lv := VBoxContainer.new()
	left.add_child(lv)
	var lt := Label.new(); lt.text = "Empires  (click for details)"; lt.modulate = Color(0.8, 0.8, 0.8)
	lv.add_child(lt)
	empire_box = VBoxContainer.new()
	empire_box.add_theme_constant_override("separation", 2)
	lv.add_child(empire_box)

	# --- Bottom-left: event log with filter
	var logp := _panel(root)
	logp.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	logp.offset_left = 6; logp.offset_bottom = -6; logp.offset_top = -LOG_H; logp.offset_right = 500
	var lgv := VBoxContainer.new()
	logp.add_child(lgv)
	var lgh := HBoxContainer.new()
	lgv.add_child(lgh)
	var lgt := Label.new(); lgt.text = "Events"; lgt.modulate = Color(0.8, 0.8, 0.8)
	lgh.add_child(lgt)
	var sp2 := Control.new(); sp2.size_flags_horizontal = Control.SIZE_EXPAND_FILL; lgh.add_child(sp2)
	var filt := OptionButton.new()
	filt.focus_mode = Control.FOCUS_NONE
	for n in ["All", "War", "Diplomacy", "Crises", "Politics"]:
		filt.add_item(n)
	filt.item_selected.connect(func(i): log_filter = i; _refresh_log())
	lgh.add_child(filt)
	log_text = RichTextLabel.new()
	log_text.bbcode_enabled = true
	log_text.scroll_following = true
	log_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	log_text.add_theme_font_size_override("normal_font_size", 10)
	lgv.add_child(log_text)

	# --- Right: system panel
	sys_panel = _panel(root)
	sys_panel.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	sys_panel.offset_left = -RIGHT_W; sys_panel.offset_right = -6; sys_panel.offset_top = 46; sys_panel.offset_bottom = -6
	sys_panel.visible = false
	var sv := VBoxContainer.new()
	sys_panel.add_child(sv)
	var sh := HBoxContainer.new(); sv.add_child(sh)
	var st := Label.new(); st.text = "System"; st.modulate = Color(0.8, 0.8, 0.8); st.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sh.add_child(st)
	_button(sh, "x", "Close  [Esc]", func(): _select_system(-1))
	sys_text = RichTextLabel.new()
	sys_text.bbcode_enabled = true
	sys_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sys_text.add_theme_font_size_override("normal_font_size", 11)
	sv.add_child(sys_text)

	# --- Empire panel (below the empire list)
	# Shares the right column with the system panel: opening one closes the other.
	emp_panel = _panel(root)
	emp_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	emp_panel.offset_left = -RIGHT_W; emp_panel.offset_right = -6; emp_panel.offset_top = 46
	emp_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	emp_panel.visible = false
	var ev := VBoxContainer.new()
	emp_panel.add_child(ev)
	var eh := HBoxContainer.new(); ev.add_child(eh)
	var et := Label.new(); et.text = "Empire"; et.modulate = Color(0.8, 0.8, 0.8); et.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	eh.add_child(et)
	_button(eh, "x", "Close  [Esc]", func(): _select_empire(-1))
	emp_text = RichTextLabel.new()
	emp_text.bbcode_enabled = true
	emp_text.fit_content = true
	emp_text.custom_minimum_size = Vector2(RIGHT_W - 24, 0)
	emp_text.add_theme_font_size_override("normal_font_size", 11)
	ev.add_child(emp_text)

	# --- Help overlay
	var hc := CenterContainer.new()
	hc.set_anchors_preset(Control.PRESET_FULL_RECT)
	hc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(hc)
	help_panel = _panel(hc)
	help_panel.visible = false
	var ht := RichTextLabel.new()
	ht.bbcode_enabled = true
	ht.fit_content = true
	ht.custom_minimum_size = Vector2(600, 0)
	ht.add_theme_font_size_override("normal_font_size", 11)
	ht.add_theme_font_size_override("bold_font_size", 13)
	ht.text = """[b]Controls[/b]
Mouse wheel or +/-: zoom toward the cursor
Left or right drag, WASD or arrows: pan        Home: fit the galaxy
Click a system: its bodies, prices and forces
Click an empire row: its details, centred on its capital
Space: pause        1-5: speed presets        [lb] and ]: slower / faster
T / F / L: trade ships, forces, labels
F5 / F9: quicksave / quickload        Ctrl+S: save as a new slot
M: main menu        Esc: close panels        H: this help

[b]Map[/b]
Coloured areas: territory
Red ring around a system: short of food or parts (redder = worse)
Striped system with a coloured ring: occupied        Dashed red ring: front line in a war
Blue line between capitals: defensive pact (dashed: guarantee)        Dashed red line: war
Triangle: fleet        Square: army        Dashed line from a force: its operation's destination
Small arrows: trade shipments, coloured by good (ore, metal, parts, food, water)"""
	help_panel.add_child(ht)

	# --- Toast (save/load messages)
	toast = Label.new()
	toast.set_anchors_preset(Control.PRESET_CENTER_TOP)
	toast.offset_top = 64
	toast.add_theme_font_size_override("font_size", 15)
	toast.add_theme_color_override("font_outline_color", Color.BLACK)
	toast.add_theme_constant_override("outline_size", 4)
	toast.modulate.a = 0.0
	root.add_child(toast)
	_update_controls()

func _update_controls() -> void:
	if btn_pause == null:
		return
	var paused : bool = sim.is_paused()
	btn_pause.text = "Play" if paused else "Pause"
	lbl_speed.text = ("paused" if paused else "%s mo/s" % (str(int(months_per_second)) if months_per_second >= 1.0 else "%.2f" % months_per_second))

func _update_ui(new_events : bool) -> void:
	lbl_date.text = snap["date"].capitalize()
	_update_controls()
	var emps : Array = snap["empires"]
	while empire_rows.size() < emps.size():
		var idx := empire_rows.size()
		var b := Button.new()
		b.flat = true
		b.focus_mode = Control.FOCUS_NONE
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.custom_minimum_size = Vector2(LEFT_W - 16, 30)
		b.pressed.connect(func(): _on_empire_row(idx))
		var h := HBoxContainer.new()
		h.set_anchors_preset(Control.PRESET_FULL_RECT)
		h.mouse_filter = Control.MOUSE_FILTER_IGNORE
		b.add_child(h)
		var sw := ColorRect.new(); sw.custom_minimum_size = Vector2(6, 0); sw.color = _empire_color(idx); sw.mouse_filter = Control.MOUSE_FILTER_IGNORE
		h.add_child(sw)
		var v := VBoxContainer.new(); v.mouse_filter = Control.MOUSE_FILTER_IGNORE; v.add_theme_constant_override("separation", 0)
		v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		h.add_child(v)
		var l1 := Label.new(); l1.add_theme_font_size_override("font_size", 11); l1.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var l2 := Label.new(); l2.add_theme_font_size_override("font_size", 9); l2.modulate = Color(0.75, 0.75, 0.75); l2.mouse_filter = Control.MOUSE_FILTER_IGNORE
		l2.clip_text = true
		v.add_child(l1); v.add_child(l2)
		var bar := ProgressBar.new(); bar.custom_minimum_size = Vector2(36, 5); bar.show_percentage = false; bar.max_value = 100.0
		bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER; bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		bar.tooltip_text = "War exhaustion"
		var fill := StyleBoxFlat.new(); fill.bg_color = Color(1.0, 0.5, 0.2); bar.add_theme_stylebox_override("fill", fill)
		h.add_child(bar)
		empire_box.add_child(b)
		empire_rows.append([b, l1, l2, bar])
	for i in emps.size():
		var e : Dictionary = emps[i]
		var row : Array = empire_rows[i]
		var war : bool = e["at_war_with"].size() > 0
		row[1].text = "%s   %d sys   pop %s%s" % [e["name"], e["systems"], _short(e["pop"]), ("   AT WAR" if war else "")]
		row[1].add_theme_color_override("font_color", Color(1.0, 0.55, 0.5) if war else Color.WHITE)
		row[2].text = "fleet %d  army %d%s   %s" % [e.get("fleet", 0.0), e.get("army", 0.0), ("  ops %d" % e["operations"]) if e.get("operations", 0) > 0 else "", e["personality"].get_slice(" (", 0)]
		row[3].visible = war
		row[3].value = e["exhaustion"]
		row[0].tooltip_text = "%s\n%s" % [e["name"], e["personality"]]
	if new_events:
		_refresh_log()
	_update_empire_panel()

func _short(v : float) -> String:
	return "%.1fk" % (v / 1000.0) if v >= 1000.0 else str(int(v))

func _on_empire_row(i : int) -> void:
	if sel_empire == i:
		_select_empire(-1); return
	_select_empire(i)
	# Centre on its capital.
	var c : Vector2 = snap["empires"][i]["capital"]
	position = get_viewport_rect().size * 0.5 - c * scale.x
	queue_redraw()

func _update_empire_panel() -> void:
	if emp_panel == null or not emp_panel.visible or snap.is_empty() or sel_empire < 0:
		return
	var emps : Array = snap["empires"]
	if sel_empire >= emps.size():
		return
	var e : Dictionary = emps[sel_empire]
	var col := _empire_color(sel_empire).to_html(false)
	var pacts : Array = []
	var guar_by : Array = []
	var guar_of : Array = []
	var pk : PackedInt32Array = snap["pacts"]
	for i in range(0, pk.size(), 2):
		if pk[i] == sel_empire: pacts.append(emps[pk[i + 1]]["name"])
		elif pk[i + 1] == sel_empire: pacts.append(emps[pk[i]]["name"])
	var gk : PackedInt32Array = snap["guarantees"]
	for i in range(0, gk.size(), 2):
		if gk[i] == sel_empire: guar_of.append(emps[gk[i + 1]]["name"])
		elif gk[i + 1] == sel_empire: guar_by.append(emps[gk[i]]["name"])
	var t := "[color=#%s][b]%s[/b][/color]\n" % [col, e["name"]]
	t += "[color=#bbb]%s[/color]\n\n" % e["personality"]
	t += "Systems %d    Colonies %d    Population %s\n" % [e["systems"], e["colonies"], _short(e["pop"])]
	t += "Treasury %s    Reputation %d\n" % [_short(e["treasury"]), e["reputation"]]
	t += "Fleet %d    Army %d    Operations %d\n" % [e.get("fleet", 0.0), e.get("army", 0.0), e.get("operations", 0)]
	if e["at_war_with"].size() > 0:
		t += "\n[color=#ff8a80]At war with %s[/color]   exhaustion %d / 100\n" % [", ".join(e["at_war_with"]), e["exhaustion"]]
	else:
		t += "\n[color=#9e9]At peace[/color]\n"
	if pacts.size() > 0: t += "Defensive pacts: %s\n" % ", ".join(pacts)
	if guar_of.size() > 0: t += "Guarantees: %s\n" % ", ".join(guar_of)
	if guar_by.size() > 0: t += "Guaranteed by: %s\n" % ", ".join(guar_by)
	emp_text.text = t

func _update_sys_panel() -> void:
	if detail.is_empty():
		return
	var emps : Array = snap["empires"]
	var owner : int = detail["owner"]
	var occ : int = detail["occupier"]
	var t := "[b][font_size=13]%s[/font_size][/b]   [color=#aaa]%s star[/color]\n" % [detail["name"], detail["star"]]
	if owner >= 0 and owner < emps.size():
		t += "[color=#%s]%s[/color]" % [_empire_color(owner).to_html(false), emps[owner]["name"]]
	else:
		t += "[color=#aaa]Unclaimed[/color]"
	if occ >= 0 and occ < emps.size():
		t += "   [color=#ff8a80]occupied by %s[/color]" % emps[occ]["name"]
	t += "\n"
	var fl : PackedStringArray = detail.get("forces", PackedStringArray())
	if fl.size() > 0:
		t += "\n[b]Forces[/b]\n"
		for f in fl:
			t += "[color=#f2d973]%s[/color]\n" % f
	t += "\n[b]Bodies[/b]   [color=#888]prices: Ore / Metal / Parts / Food / Water[/color]\n"
	for b in detail["bodies"]:
		if b["settled"]:
			t += "[b]%s[/b]  %s   pop %d / %d   %d facilities\n" % [b["name"], b["class"], b["pop"], b["max_pop"], b["facilities"]]
		else:
			t += "[color=#999]%s  %s   unsettled[/color]\n" % [b["name"], b["class"]]
		t += "   [color=#d9cc8c]%s[/color]\n" % (", ".join(b["deposits"]) if b["deposits"].size() > 0 else "no known deposits")
		if b["settled"]:
			var pr : PackedFloat32Array = b["prices"]
			var parts : PackedStringArray = []
			for g in pr.size():
				parts.append("%.0f" % pr[g])
			var short : bool = (pr[3] + pr[2]) / 20.0 > 2.0
			t += "   [color=%s]%s[/color]\n" % ["#ff7a70" if short else "#a8d8a8", " / ".join(parts)]
	sys_text.text = t

func _log_matches(line : String) -> bool:
	match log_filter:
		1: return line.contains("WAR:") or line.contains("occupies") or line.contains("liberates") or line.contains("OPERATION") or line.contains("BATTLE") or line.contains("operation") or line.contains("PEACE") or line.contains("capitul") or line.contains("joins")
		2: return line.contains("pact") or line.contains("guarantee") or line.contains("treaty") or line.contains("PEACE") or line.contains("stays out") or line.contains("shelves") or line.contains("embargo") or line.contains("trade")
		3: return line.contains("CRISIS") or line.contains("crisis") or line.contains("backs") or line.contains("concedes") or line.contains("mediat") or line.contains("compromise")
		4: return line.contains("REGIME") or line.contains("reputation") or line.contains("personality") or line.contains("adopts")
	return true

func _refresh_log() -> void:
	var out : PackedStringArray = []
	for line in log_lines:
		if _log_matches(line):
			out.append("[color=#%s]%s[/color]" % [_event_color(line).to_html(false), line.replace("[", "[lb]")])
	log_text.text = "\n".join(out.slice(maxi(0, out.size() - 120)))
