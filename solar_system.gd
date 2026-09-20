class_name Star
extends Node


@export var star_class: AstronomyData.StarClass
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

# Related to greenhouse effect...
var accu_cap : int = 100
var tauaccum : float

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
	l = randf_range(AstronomyData.DATABASE.StarClass.luminosity[star_class][0],AstronomyData.DATABASE.StarClass.luminosity[star_class][1])
	metallicity = randf_range(AstronomyData.DATABASE.StarClass.minMetalicity[star_class],AstronomyData.DATABASE.StarPopulation[pop].metalicity)
	age = randf_range(AstronomyData.DATABASE.StarPopulation[pop].age_min,AstronomyData.DATABASE.StarPopulation[pop].age_max)
	mass = get_mass_from_l(l)
	
	hz_inner = sqrt(l) / 1.1
	hz_outer = sqrt(l) / 0.53
	frostline = 4.85 * sqrt(l)
	min_orbit = 0.1 * sqrt(l)
	max_orbit = 73 * sqrt(mass)
	
	tauaccum = age
	
	
func get_mass_from_l(l : float) -> float:
	if l <= 0.0:
		return 0.0
	if l < 0.03:
		return pow(l, 1.0 / 2.3)
	elif l < 16.0:
		return pow(l, 1.0 / 4.0)
	elif l < 35000.0:
		return pow(l , 1.0 / 3.5)
	else:
		return l
	
