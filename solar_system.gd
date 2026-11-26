class_name Star
extends Node


var star_class: AstronomyData.StarClass
@export var pop : AstronomyData.StarPop

var l : float
var age : float
var mass : float
var metallicity : float

var hz_inner : float
var hz_outer : float
var frostline : float
var volatileline : float
var min_orbit : float
var max_orbit : float
var oxygen_threshold : float

# Related to greenhouse effect...
var accu_cap : int = 100
var tauaccum : float = 3.0

var orbit_slot : Array[Planet]
var map_position : Vector2 = Vector2.ZERO   # galaxy-map position (set by whoever places the star)

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	pass # Replace with function body.

## pop_weights: population weights for this star's spot on the galaxy map (empty = the default weights).
func init_solar_system(pop_weights : Dictionary = {}):
	pop = select_population(pop_weights) if not pop_weights.is_empty() else select_population()
	set_star_specs_debug()
	pre_set_orbit_slots()
	set_orbit_slots()

## Proportional weighted pick (e.g. from galaxy-map RGBA channels r,g,b,a).
## Returns a population whose class list is never empty.
func select_population(weights : Dictionary = {
		AstronomyData.StarPop.POP2i: 0.25, AstronomyData.StarPop.POP1: 0.25,
		AstronomyData.StarPop.POP1i: 0.25, AstronomyData.StarPop.POP2: 0.25}) -> AstronomyData.StarPop:
	var total : float = 0.0
	for k in weights: total += weights[k]
	var roll : float = randf() * total
	for k in weights:
		roll -= weights[k]
		if roll <= 0.0 and get_valid_star_classes(k).size() > 0:
			return k
	return AstronomyData.StarPop.POP1

func pre_set_orbit_slots():
	var current_distance = min_orbit * randf_range(1.4, 2.0)
	
	while current_distance < max_orbit:
		var new_slot = Planet.new()
		new_slot.pre_init_planet(self, current_distance)
		orbit_slot.append(new_slot)
		
		current_distance *= randf_range(1.4, 2.0)
		
func set_orbit_slots():
	for slot in orbit_slot:
		slot.init_planet(self)

func set_star_specs_debug():
	# Age first (from the population), then the classes whose stars live that long, weighted by abundance
	age = randf_range(AstronomyData.DATABASE.StarPopulation[pop].age_min,AstronomyData.DATABASE.StarPopulation[pop].age_max)
	star_class = pick_star_class(get_valid_star_classes(pop, age))
	l = randf_range(AstronomyData.DATABASE.StarClass.luminosity[star_class][0],AstronomyData.DATABASE.StarClass.luminosity[star_class][1])
	var min_m = AstronomyData.DATABASE.StarClass.minMetalicity[star_class]
	var max_m = AstronomyData.DATABASE.StarPopulation[pop].metalicity
	metallicity = randf_range(min(min_m, max_m), max(min_m, max_m))
	var mult = (age - AstronomyData.DATABASE.StarPopulation[pop].age_min) / (AstronomyData.DATABASE.StarPopulation[pop].age_max - AstronomyData.DATABASE.StarPopulation[pop].age_min)
	mass = AstronomyData.DATABASE.StarClass.mass[star_class][0] * (1 + mult)
	
	hz_inner = sqrt(l / 1.1)
	hz_outer = sqrt(l / 0.53)
	frostline = 4.85 * sqrt(l)
	volatileline = AstronomyData.DATABASE.Constants.volatile_line_multiplier * frostline
	min_orbit = 0.1 * sqrt(l)
	max_orbit = 73 * sqrt(mass)
	oxygen_threshold = AstronomyData.DATABASE.Constants.base_oxygen_threshold / (1.0 + AstronomyData.DATABASE.Constants.alpha_enhancement_coeff * (age/ 10))
	add_to_universe_data()
	
func add_to_universe_data() :
	var data : Dictionary = Universe.data.stars
	if data.has(AstronomyData.StarClass.find_key(star_class)):
		data[AstronomyData.StarClass.find_key(star_class)] += 1
	else:
		data[AstronomyData.StarClass.find_key(star_class)] = 1

## Weighted pick among the allowed classes: abundance ^ class_realism (see AstronomyData).
static func pick_star_class(valid : Array) -> AstronomyData.StarClass:
	if valid.is_empty():
		return AstronomyData.StarClass.M
	var realism : float = AstronomyData.DATABASE.Constants.class_realism
	var weights : Array = valid.map(func(sc): return pow(AstronomyData.DATABASE.StarClass.abundance[sc], realism))
	var total : float = 0.0
	for w in weights: total += w
	var roll : float = randf() * total
	for i in valid.size():
		roll -= weights[i]
		if roll <= 0.0:
			return valid[i]
	return valid[-1]

## Classes a star of this population can be: allowed by the population's metallicity and, when an age is given,
## still alive at that age (class lifetime above it).
func get_valid_star_classes(pop : AstronomyData.StarPop, star_age : float = -1.0) -> Array:
	var pop_metallicity = AstronomyData.DATABASE.StarPopulation[pop].metalicity
	var valid : Array = []
	for sc in AstronomyData.DATABASE.StarClass.minMetalicity:
		if star_age >= 0.0 and AstronomyData.DATABASE.StarClass.lifetime[sc] < star_age:
			continue
		if AstronomyData.DATABASE.StarClass.minMetalicity[sc] <= pop_metallicity:
			valid.append(sc)
	
	return valid
