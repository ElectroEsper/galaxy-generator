extends Node

var data : Dictionary = {
	stars = {},
	planets = {}
}

func print_universe_stats(universe_data : Dictionary) -> void:
	var stars : Dictionary = universe_data.stars
	var planets : Dictionary = universe_data.planets

	var total_stars : int = 0
	var star_class_counts : Dictionary = {}
	var pop_counts : Dictionary = {}

	for star in stars.keys():
		var count : int = stars[star]
		total_stars += count

		var sc_name : String = AstronomyData.StarClass.find_key(star)
		star_class_counts[sc_name] = star_class_counts.get(sc_name, 0) + count


	var total_planets : int = 0
	var planet_class_counts : Dictionary = {}

	for planet in planets.keys():
		var count : int = planets[planet]
		total_planets += count

		var pc_name : String = Planet.PlanetClass.find_key(planet.planet_class)
		planet_class_counts[pc_name] = planet_class_counts.get(pc_name, 0) + count

	print("=".repeat(50))
	print("UNIVERSE STATS")
	print("=".repeat(50))

	print("\nStars: %d" % total_stars)
	print("-".repeat(30))
	for sc_name in star_class_counts.keys():
		_print_stat_line(sc_name, star_class_counts[sc_name], total_stars)

	print("\nPopulations:")
	print("-".repeat(30))
	for pop_name in pop_counts.keys():
		_print_stat_line(pop_name, pop_counts[pop_name], total_stars)

	print("\nPlanets: %d" % total_planets)
	print("-".repeat(30))
	for pc_name in planet_class_counts.keys():
		_print_stat_line(pc_name, planet_class_counts[pc_name], total_planets)

	print("=".repeat(50))


func _print_stat_line(label : String, count : int, total : int) -> void:
	var pct : float = (100.0 * count / total) if total > 0 else 0.0
	print("  %-24s %5d  (%.1f%%)" % [label, count, pct])
