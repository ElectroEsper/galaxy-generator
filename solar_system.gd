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
var min_orbit : float
var max_orbit : float
var oxygen_threshold : float

# Related to greenhouse effect...
var accu_cap : int = 100
var tauaccum : float = 3.0

var orbit_slot : Array[Planet]

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	seed(123)
	set_star_specs_debug()
	pre_set_orbit_slots()
	set_orbit_slots()
	pass # Replace with function body.


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	pass

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
	min_orbit = 0.1 * sqrt(l)
	max_orbit = 73 * sqrt(mass)
	oxygen_threshold = AstronomyData.DATABASE.Constants.base_oxygen_threshold / (1.0 + AstronomyData.DATABASE.Constants.alpha_enhancement_coeff * (age/ 10))

func get_valid_star_classes(pop : AstronomyData.StarPop) -> Array:
	var pop_metallicity = AstronomyData.DATABASE.StarPopulation[pop].metalicity
	var valid : Array = []
	for sc in AstronomyData.DATABASE.StarClass.minMetalicity:
		if AstronomyData.DATABASE.StarClass.minMetalicity[sc] <= pop_metallicity:
			valid.append(sc)
	
	return valid
