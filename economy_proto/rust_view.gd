extends Node2D
## Map view driven by the Rust simulation (rust/galaxy_gd, class GalaxySim). The sim runs on its own thread; each frame
## this view polls for the newest month and redraws from that snapshot only, so drawing never waits on the sim.
## Build the library first:  cd rust && cargo build --release -p galaxy_gd
## Controls: [space] pause, [up/down] speed, [T] ships, [L] labels, [+/-] zoom, drag with the right mouse button,
## left-click a system for its bodies, deposits and prices ([Esc] closes the panel).

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

var sim
var snap : Dictionary = {}
var ships : Array = []          # [from, to, good, travelled, length]
var log_lines : Array = []
var show_ships : bool = true
var show_labels : bool = true
var territory_rect : ColorRect = null
var territory_sig : String = ""
var ship_layer : Node2D
var tps : float = 0.0
var _tps_n : int = 0
var _tps_t : float = 0.0
var _last_tick : int = -1
var selected : int = -1          # system shown in the info panel
var detail : Dictionary = {}

func _ready() -> void:
	if not ClassDB.class_exists("GalaxySim"):
		push_error("GalaxySim not found: build the Rust extension (cd rust && cargo build --release -p galaxy_gd)")
		return
	sim = ClassDB.instantiate("GalaxySim")
	add_child(sim)
	sim.set_speed(months_per_second)
	var cfg : Dictionary = {"systems": systems, "empires": empires, "planets": planets, "seed": sim_seed}
	if use_maps:
		cfg["density_map"] = density_map
		cfg["population_map"] = population_map
	sim.start(cfg)
	ship_layer = Node2D.new()
	ship_layer.draw.connect(_draw_ships)
	add_child(ship_layer)

func _process(delta : float) -> void:
	if sim == null:
		return
	var s : Dictionary = sim.poll()
	if not s.is_empty():
		snap = s
		_tps_n += s["tick"] - _last_tick if _last_tick >= 0 else 0
		_last_tick = s["tick"]
		for ev in s["events"]:
			log_lines.append(ev)
		while log_lines.size() > 8:
			log_lines.pop_front()
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
		queue_redraw()
	_tps_t += delta
	if _tps_t >= 1.0:
		tps = _tps_n / _tps_t; _tps_n = 0; _tps_t = 0.0
	if not sim.is_paused():
		for sp in ships:
			sp[3] += SHIP_SPEED * delta * minf(months_per_second / 6.0, 4.0)
		ships = ships.filter(func(sp): return sp[3] < sp[4])
	ship_layer.queue_redraw()

func _unhandled_input(e : InputEvent) -> void:
	if e is InputEventKey and e.pressed and not e.echo:
		match e.keycode:
			KEY_SPACE: sim.set_paused(not sim.is_paused())
			KEY_UP:
				months_per_second = minf(months_per_second * 2.0, 960.0); sim.set_speed(months_per_second)
			KEY_DOWN:
				months_per_second = maxf(months_per_second * 0.5, 0.25); sim.set_speed(months_per_second)
			KEY_T:
				show_ships = not show_ships
				if not show_ships: ships.clear()
			KEY_L: show_labels = not show_labels
			KEY_ESCAPE:
				selected = -1; detail = {}; queue_redraw()
			KEY_EQUAL, KEY_KP_ADD: scale *= 1.25
			KEY_MINUS, KEY_KP_SUBTRACT: scale /= 1.25
	elif e is InputEventMouseMotion and e.button_mask & MOUSE_BUTTON_MASK_RIGHT:
		position += e.relative
	elif e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT and not snap.is_empty():
		var p : Vector2 = get_global_transform().affine_inverse() * e.position
		var sys : PackedFloat32Array = snap["systems"]
		var best : int = -1
		var bd : float = 16.0 / scale.x
		for i in range(0, sys.size(), SYS_STRIDE):
			var d : float = p.distance_to(Vector2(sys[i], sys[i + 1]))
			if d < bd:
				bd = d; best = i / SYS_STRIDE
		selected = best
		detail = {}
		if best >= 0:
			sim.request_detail(best)
		queue_redraw()

func _empire_color(i : int) -> Color:
	return EMPIRE_COLORS[i % EMPIRE_COLORS.size()] if i >= 0 else Color(0.55, 0.55, 0.6)

func _rebuild_territory(sys : PackedFloat32Array) -> void:
	if territory_rect == null:
		territory_rect = ColorRect.new()
		territory_rect.size = Vector2(4000, 4000)
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
		if show_labels and settled > 0:
			draw_string(font, p + Vector2(-r, -r - 4.0), "%s %d/%d" % [names[i / SYS_STRIDE], settled, int(sys[i + 6])], HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(1, 1, 1, 0.75))
	# HUD (drawn in screen space: undo the pan/zoom)
	draw_set_transform_matrix(get_global_transform().affine_inverse())
	draw_string(font, Vector2(16, 24), "%s   colonies %d   corps %d   ships in transit %d   [Rust sim, %.0f months/s]" % [snap["date"], snap["colonies"], snap["corps"], ships.size(), tps], HORIZONTAL_ALIGNMENT_LEFT, -1, 14)
	draw_string(font, Vector2(16, 42), "[space] pause  [up/down] speed x%.2f  [T] ships  [L] labels  [+/-] zoom  right-drag pan   striped = occupied, dashed red = front/war, blue = pact (dashed: guarantee)" % (months_per_second / 6.0), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.7, 0.7, 0.7))
	var y : float = 66.0
	for ei in emps.size():
		var e : Dictionary = emps[ei]
		draw_rect(Rect2(16, y - 9, 10, 10), _empire_color(ei))
		var war_note := ""
		if e["at_war_with"].size() > 0:
			war_note = "   AT WAR with %s, exhaustion %d" % [", ".join(e["at_war_with"]), e["exhaustion"]]
		draw_string(font, Vector2(32, y), "%s   %d colonies, %d systems, pop %d, treasury %dk   strength %d   rep %d   [%s]%s" % [e["name"], e["colonies"], e["systems"], e["pop"], e["treasury"] / 1000.0, e["strength"], e["reputation"], e["personality"], war_note], HORIZONTAL_ALIGNMENT_LEFT, -1, 11)
		y += 15.0
	y += 6.0
	for line in log_lines:
		draw_string(font, Vector2(16, y), line, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0.85, 0.85, 0.7))
		y += 13.0
	_draw_detail(font)
	draw_set_transform_matrix(Transform2D.IDENTITY)

## Info panel for the selected system (screen space, right side).
func _draw_detail(font : Font) -> void:
	if detail.is_empty():
		return
	var vw : float = get_viewport_rect().size.x
	var w : float = 330.0
	var x : float = vw - w - 12.0
	var bodies : Array = detail["bodies"]
	var h : float = 54.0 + 46.0 * bodies.size()
	draw_rect(Rect2(x, 60, w, h), Color(0.08, 0.09, 0.12, 0.92))
	draw_rect(Rect2(x, 60, w, h), Color(1, 1, 1, 0.25), false, 1.0)
	var owner : int = detail["owner"]
	var owner_name : String = snap["empires"][owner]["name"] if owner >= 0 and owner < snap["empires"].size() else "unclaimed"
	var occ : int = detail["occupier"]
	var title : String = "%s  (%s star)  %s%s" % [detail["name"], detail["star"], owner_name, ("  occupied by " + snap["empires"][occ]["name"]) if occ >= 0 else ""]
	draw_string(font, Vector2(x + 10, 80), title, HORIZONTAL_ALIGNMENT_LEFT, w - 20, 13, _empire_color(owner) if owner >= 0 else Color.WHITE)
	draw_string(font, Vector2(x + 10, 96), "prices: Ore / Metal / Parts / Food / Water   [Esc] close", HORIZONTAL_ALIGNMENT_LEFT, w - 20, 10, Color(0.6, 0.6, 0.6))
	var y : float = 116.0
	for b in bodies:
		var head : String = "%s  %s" % [b["name"], b["class"]]
		if b["settled"]:
			head += "   pop %d / %d   %d facilities" % [b["pop"], b["max_pop"], b["facilities"]]
		else:
			head += "   unsettled"
		draw_string(font, Vector2(x + 10, y), head, HORIZONTAL_ALIGNMENT_LEFT, w - 20, 11, Color.WHITE if b["settled"] else Color(0.7, 0.7, 0.7))
		var dep : String = ", ".join(b["deposits"]) if b["deposits"].size() > 0 else "no known deposits"
		draw_string(font, Vector2(x + 18, y + 14), dep, HORIZONTAL_ALIGNMENT_LEFT, w - 28, 10, Color(0.85, 0.8, 0.55))
		if b["settled"]:
			var pr : PackedFloat32Array = b["prices"]
			var parts : PackedStringArray = []
			for g in pr.size():
				parts.append("%.0f" % pr[g])
			var short : bool = (pr[3] + pr[2]) / 20.0 > 2.0
			draw_string(font, Vector2(x + 18, y + 28), "prices " + " / ".join(parts), HORIZONTAL_ALIGNMENT_LEFT, w - 28, 10, Color(1.0, 0.45, 0.4) if short else Color(0.7, 0.85, 0.7))
		y += 46.0

func _draw_ships() -> void:
	for sp in ships:
		var dir : Vector2 = (sp[1] - sp[0]).normalized()
		var pos : Vector2 = sp[0] + dir * sp[3]
		var pts := PackedVector2Array([pos + dir * 6.0, pos + dir.rotated(2.5) * 4.0, pos + dir.rotated(-2.5) * 4.0])
		ship_layer.draw_colored_polygon(pts, GOOD_COLORS[sp[2] % GOOD_COLORS.size()])
