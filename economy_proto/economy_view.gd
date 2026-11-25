extends Node2D
## 2D galaxy view for the economy prototype: colonies, lanes, and ships in transit.
## Colony size = population; colony colour = how short it is on Food/Parts (green ok -> red short).

const TICKS_PER_SECOND := 6.0
const SHIP_SPEED := 160.0   # px / second
const GOOD_COLORS : Dictionary = {
	Goods.ORE: Color(0.75, 0.55, 0.35), Goods.METAL: Color(0.7, 0.8, 0.9),
	Goods.PARTS: Color(1.0, 0.85, 0.3), Goods.FOOD: Color(0.5, 0.9, 0.45), Goods.WATER: Color(0.4, 0.75, 0.95),
}
const GOOD_NAMES : Array[String] = ["Ore", "Metal", "Parts", "Food", "Water"]

class Ship:
	var from_pos : Vector2
	var to_pos : Vector2
	var good : int
	var qty : float
	var travelled : float = 0.0
	func length() -> float:
		return from_pos.distance_to(to_pos)

var sim : Node
var ships : Array[Ship] = []
var lane_heat : Dictionary = {}   # "A-B" -> recent traffic (fades)
var accum : float = 0.0
var paused : bool = false
var speed_mult : float = 1.0

func _ready() -> void:
	sim = load("res://economy_proto/economy_sim.gd").new()
	sim.auto_run = false
	sim.use_galaxy = true
	sim.all_planets = true
	sim.galaxy_colonies = 100
	sim.max_corps = 60
	sim.colonize = true
	add_child(sim)
	sim.shipment_made.connect(_on_shipment)

func _on_shipment(a : ColonyMarket, b : ColonyMarket, good : int, qty : float) -> void:
	var s := Ship.new()
	s.from_pos = a.position; s.to_pos = b.position; s.good = good; s.qty = qty
	ships.append(s)
	if a.system == null or b.system == null or a.system == b.system:
		return
	var na : String = a.system.name; var nb : String = b.system.name
	var key : String = "%s|%s" % [na, nb] if na < nb else "%s|%s" % [nb, na]
	lane_heat[key] = minf(lane_heat.get(key, 0.0) + 1.0, 8.0)

func _unhandled_key_input(e : InputEvent) -> void:
	if e.pressed and not e.echo:
		match e.keycode:
			KEY_SPACE: paused = not paused
			KEY_UP: speed_mult = minf(speed_mult * 2.0, 16.0)
			KEY_DOWN: speed_mult = maxf(speed_mult * 0.5, 0.25)

func _process(delta : float) -> void:
	if not paused:
		accum += delta * TICKS_PER_SECOND * speed_mult
		while accum >= 1.0:
			accum -= 1.0
			sim.step()
			for k in lane_heat.keys():
				lane_heat[k] = maxf(0.0, lane_heat[k] - 0.05)
		for s in ships:
			s.travelled += SHIP_SPEED * delta * speed_mult
		ships = ships.filter(func(s): return s.travelled < s.length())
	queue_redraw()

func _shortage(c : ColonyMarket) -> float:
	var p : float = (c.price[Goods.FOOD] + c.price[Goods.PARTS]) / (2.0 * ColonyMarket.BASE_PRICE)
	return clampf((p - 1.0) / 3.0, 0.0, 1.0)

func _draw() -> void:
	var font : Font = ThemeDB.fallback_font
	var markets : Array[ColonyMarket] = sim.markets
	var sys_pos : Dictionary = {}
	for sys in GalaxyColonies.systems: sys_pos[sys.name] = sys.position
	# Lanes between star systems that trade (heat = recent traffic)
	for key in lane_heat:
		var heat : float = lane_heat[key]
		if heat <= 0.0 or not sys_pos.has(key.get_slice("|", 0)) or not sys_pos.has(key.get_slice("|", 1)):
			continue
		draw_line(sys_pos[key.get_slice("|", 0)], sys_pos[key.get_slice("|", 1)], Color(0.4, 0.5, 0.7, 0.15 + heat * 0.08), 1.0 + heat * 0.5)
	# Star systems: the map's nodes. Unsettled = small star (grey if nothing surveyed, gold ring if deposits are known);
	# settled = disc sized by population, coloured by Food/Parts supply, with "colonies/bodies" and population.
	for sys in GalaxyColonies.systems:
		var settled : Array = sys.settled_bodies()
		var surveyed : int = sys.surveyed_count()
		if settled.is_empty():
			var known : bool = sys.bodies.any(func(c): return not c.richness.is_empty())
			var sc : Color = Color(0.55, 0.55, 0.62, 0.6) if surveyed == 0 else Color(0.75, 0.78, 0.85, 0.85)
			draw_circle(sys.position, 2.5, sc)
			if known:
				draw_arc(sys.position, 5.5, 0.0, TAU, 16, Color(0.95, 0.8, 0.35, 0.9), 1.2)
			continue
		var pop : float = sys.population()
		var short : float = 0.0
		for c in settled: short += _shortage(c) / settled.size()
		var r : float = 7.0 + sqrt(pop) * 0.6
		var col : Color = Color(0.3, 0.8, 0.4).lerp(Color(0.95, 0.3, 0.25), short)
		draw_circle(sys.position, r + 3.0, Color(col, 0.18))
		draw_circle(sys.position, r, col)
		var is_cap : bool = settled.has(sim.capital)
		draw_arc(sys.position, r, 0.0, TAU, 32, Color(1, 0.9, 0.5, 0.9) if is_cap else Color(1, 1, 1, 0.5), 2.0 if is_cap else 1.2)
		var label : String = "%s%s  %d/%d  pop %d" % ["Capital system " if is_cap else "", sys.name, settled.size(), sys.bodies.size(), pop]
		draw_string(font, sys.position + Vector2(-r, -r - 6.0), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 12)
	# Ships
	for s in ships:
		var dir : Vector2 = (s.to_pos - s.from_pos).normalized()
		var pos : Vector2 = s.from_pos + dir * s.travelled
		var size : float = 5.0 + minf(s.qty, 20.0) * 0.25
		var pts := PackedVector2Array([pos + dir * size * 1.4, pos + dir.rotated(2.5) * size, pos + dir.rotated(-2.5) * size])
		draw_colored_polygon(pts, GOOD_COLORS[s.good])
	# HUD
	var kinds : Dictionary = {}
	var cash_total : float = 0.0
	for k in sim.corps:
		var n : String = Corporation.Kind.find_key(k.kind)
		kinds[n] = kinds.get(n, 0) + 1
		cash_total += k.cash
	draw_string(font, Vector2(16, 24), "%s (tick %d)   colonies %d (%d systems)   surveyed %d   corps %s   ships in transit %d" % [sim.date_label(), sim.tick_count, markets.size(), GalaxyColonies.systems.filter(func(s): return not s.settled_bodies().is_empty()).size(), sim.frontier.filter(func(c): return c.surveys > 0).size(), kinds, ships.size()], HORIZONTAL_ALIGNMENT_LEFT, -1, 14)
	draw_string(font, Vector2(16, 44), "[space] pause   [up/down] speed x%.2f   node = star system (n/m = colonies/bodies), colour: green supplied, red short; gold ring = known deposits" % speed_mult, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.7, 0.7, 0.7))
	var lx : float = 16.0
	for g in Goods.ALL:
		draw_rect(Rect2(Vector2(lx, 52), Vector2(10, 10)), GOOD_COLORS[g])
		draw_string(font, Vector2(lx + 14, 62), GOOD_NAMES[g], HORIZONTAL_ALIGNMENT_LEFT, -1, 12)
		lx += 70.0
