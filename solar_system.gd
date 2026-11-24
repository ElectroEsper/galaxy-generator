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

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	pass # Replace with function body.

func init_solar_system():
	pop = select_population()
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
	var valid_classes = get_valid_star_classes(pop)
	if (valid_classes.size() > 1):
		valid_classes.shuffle()
	star_class = AstronomyData.StarClass.M if valid_classes.size() == 0 else valid_classes[0]
	l = randf_range(AstronomyData.DATABASE.StarClass.luminosity[star_class][0],AstronomyData.DATABASE.StarClass.luminosity[star_class][1])
	var min_m = AstronomyData.DATABASE.StarClass.minMetalicity[star_class]
	var max_m = AstronomyData.DATABASE.StarPopulation[pop].metalicity
	metallicity = randf_range(min(min_m, max_m), max(min_m, max_m))
	age = randf_range(AstronomyData.DATABASE.StarPopulation[pop].age_min,AstronomyData.DATABASE.StarPopulation[pop].age_max)
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

func get_valid_star_classes(pop : AstronomyData.StarPop) -> Array:
	var pop_metallicity = AstronomyData.DATABASE.StarPopulation[pop].metalicity
	var valid : Array = []
	for sc in AstronomyData.DATABASE.StarClass.minMetalicity:
		if AstronomyData.DATABASE.StarClass.minMetalicity[sc] <= pop_metallicity:
			valid.append(sc)
	
	return valid
