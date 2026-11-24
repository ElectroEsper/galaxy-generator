class_name GalaxyColonies
extends RefCounted
## Bridge: generated stars/planets -> colonies for the economy prototype.

const VIEW_CENTER := Vector2(576.0, 340.0)
const VIEW_RADIUS := Vector2(470.0, 250.0)

## Generate `star_count` stars and return up to `colony_count` colonies (best planet per star).
static func generate(star_count : int, colony_count : int) -> Array[ColonyMarket]:
	var candidates : Array = []   # [score, ColonyMarket]
	for i in star_count:
		var star := Star.new()
		star.init_solar_system()
		var a : float = randf() * TAU
		star.map_position = Vector2(cos(a), sin(a)) * sqrt(randf())
		var best : Planet = null
		var best_score : float = 0.0
		for p in star.orbit_slot:
			var s : float = _score(p, star)
			if s > best_score:
				best_score = s; best = p
		if best != null:
			candidates.append([best_score, _to_colony(best, star, i)])
	candidates.sort_custom(func(x, y): return x[0] > y[0])
	var out : Array[ColonyMarket] = []
	for k in mini(colony_count, candidates.size()):
		out.append(candidates[k][1])
	return out

static func _score(p : Planet, star : Star) -> float:
	if p.type != Planet.BaseType.NORMAL or star.age < AstronomyData.DATABASE.Constants.protoplanet_age_threshold:
		return 0.0
	var ore : float = p.resources.richness.get(PlanetResources.ResourceType.ORE, 0.0)
	var food : float = p.resources.richness.get(PlanetResources.ResourceType.EDIBLES, 0.0)
	var habitable : float = 3.0 if (p.temperature_raw >= 250 and p.temperature_raw <= 340) else 0.0
	return ore + food * 1.5 + habitable

static func _to_colony(p : Planet, star : Star, idx : int) -> ColonyMarket:
	var rich : Dictionary = {}
	var ore : float = p.resources.richness.get(PlanetResources.ResourceType.ORE, 0.0)
	var food : float = p.resources.richness.get(PlanetResources.ResourceType.EDIBLES, 0.0)
	if ore >= 1.0:
		rich[Goods.ORE] = ore / 5.0          # 0-10 richness -> 0-2 units/tick
	if food >= 1.0:
		rich[Goods.FOOD] = food / 5.0
	var ceiling : float = clampf(120.0 + p.mass * 120.0 + 250.0 * p.life_stage, 120.0, 800.0)
	var c := ColonyMarket.new("S%d" % idx, randf_range(40.0, 90.0), rich, ceiling)
	c.position = VIEW_CENTER + star.map_position * VIEW_RADIUS
	c.planet_label = "%s" % Planet.PlanetClass.find_key(p.planet_class).capitalize().replace("_", " ")
	return c


## Every planet (rocky, giant, belt) becomes a colony, until `planet_count` is reached.
## Planets of one star sit close together on the map; giants/belts get small population ceilings.
static func generate_all(planet_count : int) -> Array[ColonyMarket]:
	var out : Array[ColonyMarket] = []
	var star_idx : int = 0
	while out.size() < planet_count:
		var star := Star.new()
		star.init_solar_system()
		var a : float = randf() * TAU
		star.map_position = Vector2(cos(a), sin(a)) * sqrt(randf())
		for p in star.orbit_slot:
			if out.size() >= planet_count:
				break
			var c : ColonyMarket = _to_colony(p, star, out.size())
			c.name = "S%d.%d" % [star_idx, out.size()]
			c.position += Vector2.from_angle(randf() * TAU) * randf_range(6.0, 18.0)
			if p.type != Planet.BaseType.NORMAL:
				c.max_pop = 100.0 if p.type == Planet.BaseType.ASTEROID_BELT else 80.0
				c.pop = minf(c.pop, c.max_pop * 0.5)
			out.append(c)
		star_idx += 1
	return out
