class_name Galaxy
extends Node
## Places star systems on the galaxy map.
##
## With both maps set (the default), placement follows William's image-driven design:
##  - density_map (greyscale): a pixel's brightness is its weight for holding a star, so the bright core and arms are
##    crowded while dust lanes and the void stay empty;
##  - population_map (colour): at a star's pixel, the R, G and B channels are tried brightest first (random order on
##    ties), each passing with a chance equal to its own value; the first to pass picks the stellar population:
##    G = Pop I (arm ridges, youngest), B = Pop I-i (arms), R = Pop II-i, none = Pop II (old).
## The population then drives metallicity, age, class and the whole planet pipeline in Star.init_solar_system().
## Without maps, stars fall back to a uniform disc with the default population weights.

@export var star_amount : int = 500
@export var galaxy_seed : int = 123
@export var density_map : Texture2D = preload("res://galaxy_maps/spiral_density.png")
@export var population_map : Texture2D = preload("res://galaxy_maps/spiral_population.png")

var map_size : Vector2i = Vector2i.ZERO

func _ready() -> void:
	seed(galaxy_seed)
	if density_map != null and population_map != null:
		_place_from_maps()
	else:
		for i in star_amount:
			var ss = Star.new()
			ss.init_solar_system()
			ss.map_position = _random_disc_position()
			add_child(ss)

## Image-driven placement. map_position is in the same unit-disc space as the fallback: (-1..1, -1..1).
func _place_from_maps() -> void:
	var density : Image = density_map.get_image()          # loaded once, not per star
	var colours : Image = population_map.get_image()
	if density.get_size() != colours.get_size():
		push_error("Galaxy: density and population maps must be the same size")
		return
	map_size = density.get_size()
	for px in sample_pixels(density, star_amount):
		var ss = Star.new()
		var pop : AstronomyData.StarPop = population_from_colour(colours.get_pixelv(px))
		ss.init_solar_system({pop: 1.0})
		ss.map_position = Vector2(px) / Vector2(map_size) * 2.0 - Vector2.ONE
		add_child(ss)

## Pick `count` distinct pixels, each with probability proportional to its brightness (weighted draw without
## replacement over a cumulative table: one pass over the image, exact star count).
static func sample_pixels(density : Image, count : int) -> Array[Vector2i]:
	var w : int = density.get_width()
	var h : int = density.get_height()
	var cumulative := PackedFloat64Array()
	cumulative.resize(w * h)
	var total : float = 0.0
	for y in h:
		for x in w:
			var c : Color = density.get_pixel(x, y)
			total += (c.r + c.g + c.b) / 3.0
			cumulative[y * w + x] = total
	var picked : Dictionary = {}
	var out : Array[Vector2i] = []
	if total <= 0.0:
		return out
	var guard : int = count * 50
	while out.size() < count and guard > 0:
		guard -= 1
		var i : int = cumulative.bsearch(randf() * total)
		if i >= w * h or picked.has(i):
			continue                                        # already a star there: draw again
		picked[i] = true
		out.append(Vector2i(i % w, i / w))
	return out

## William's channel rule (see the class comment).
static func population_from_colour(c : Color) -> AstronomyData.StarPop:
	var channels : Array = [["r", c.r], ["g", c.g], ["b", c.b]]
	channels.shuffle()                                       # random order among equal channels
	channels.sort_custom(func(a, b): return a[1] > b[1])     # strict comparison (>= breaks Godot's sort)
	for ch in channels:
		if randf() < ch[1]:
			match ch[0]:
				"r": return AstronomyData.StarPop.POP2i
				"g": return AstronomyData.StarPop.POP1
				"b": return AstronomyData.StarPop.POP1i
	return AstronomyData.StarPop.POP2

## Uniform random point on a unit disc (galaxy-map space).
func _random_disc_position() -> Vector2:
	var a : float = randf() * TAU
	var r : float = sqrt(randf())
	return Vector2(cos(a), sin(a)) * r
