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
	add_child(sim)
	sim.shipment_made.connect(_on_shipment)

func _on_shipment(a : ColonyMarket, b : ColonyMarket, good : int, qty : float) -> void:
	var s := Ship.new()
	s.from_pos = a.position; s.to_pos = b.position; s.good = good; s.qty = qty
	ships.append(s)
	var key : String = "%s-%s" % [a.name, b.name] if a.name < b.name else "%s-%s" % [b.name, a.name]
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
	# Lanes
	for i in markets.size():
		for j in range(i + 1, markets.size()):
			var a : ColonyMarket = markets[i]; var b : ColonyMarket = markets[j]
			var heat : float = lane_heat.get("%s-%s" % [a.name, b.name], 0.0)
			draw_line(a.position, b.position, Color(0.4, 0.5, 0.7, 0.12 + heat * 0.08), 1.0 + heat * 0.5)
	# Colonies
	for c in markets:
		var r : float = 8.0 + sqrt(c.pop) * 0.9
		var col : Color = Color(0.3, 0.8, 0.4).lerp(Color(0.95, 0.3, 0.25), _shortage(c))
		draw_circle(c.position, r + 3.0, Color(col, 0.18))
		draw_circle(c.position, r, col)
		draw_arc(c.position, r, 0.0, TAU, 32, Color(1, 1, 1, 0.5), 1.5)
		draw_string(font, c.position + Vector2(-r, -r - 8.0), "%s  pop %d  jobs %d" % [c.name, c.pop, c.jobs], HORIZONTAL_ALIGNMENT_LEFT, -1, 14)
		if c.planet_label != "":
			draw_string(font, c.position + Vector2(-r, r + 30.0), c.planet_label, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.6, 0.75, 0.9))
		var tags : Array[String] = []
		for g in c.richness:
			tags.append("%s x%.1f" % [GOOD_NAMES[g], c.richness[g]])
		if not tags.is_empty():
			draw_string(font, c.position + Vector2(-r, r + 16.0), ", ".join(tags), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.8, 0.85, 0.9))
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
	draw_string(font, Vector2(16, 24), "%s (tick %d)   corps %s   promotions %d   attractions %d   ships in transit %d" % [sim.date_label(), sim.tick_count, kinds, sim.promotions, sim.attractions, ships.size()], HORIZONTAL_ALIGNMENT_LEFT, -1, 14)
	draw_string(font, Vector2(16, 44), "[space] pause   [up/down] speed x%.2f   colour: green = supplied, red = Food/Parts shortage" % speed_mult, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.7, 0.7, 0.7))
	var lx : float = 16.0
	for g in Goods.ALL:
		draw_rect(Rect2(Vector2(lx, 52), Vector2(10, 10)), GOOD_COLORS[g])
		draw_string(font, Vector2(lx + 14, 62), GOOD_NAMES[g], HORIZONTAL_ALIGNMENT_LEFT, -1, 12)
		lx += 70.0
