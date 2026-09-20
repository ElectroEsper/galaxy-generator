class_name Planet


enum BaseType {NORMAL, GAS_GIANT, ICE_GIANT, ASTEROID_BELT}
enum VolcanismLevel {NONE, DEAD, DORMANT, RESTRAINED, ACTIVE, HYPER_ACTIVE}
enum TempLevel {CRYOGENIC, FRIGID, TEMPERATE, TORRID, INFERNAL}
enum PlanetClass {
	HERMIAN, 
	VENERIAN, 
	CORROSIVE_MAGMA_TRAP, 
	CALCINATED_WASTELAND,
	VAPOR_TELLURIC,
	PYROCLASTIC_SMOLDER,
	GARDEN,
	OCEAN,
	ARID,
	SAVANNA,
	COOLED_FOSSIL,
	MAGNETO_STRIPPED_GARDEN,
	TWILIGHT,
	EXO_CARBONIFEROUS,
	BOREAL_ALPINE,
	GLACIAL_TAIGA,
	CRYO_VOLCANIC_FISSURE,
	SUB_GLACIAL,
	PLUTONIAN,
	RADIOACTIVE_OBSIDIAN,
	SUPER_DRY_IRON_BALL,
	ANOMALOUS_DRY_HUSK,
	ASTEROID_RING,
	PEGASEAN,
	JOVIAN,
	SULTRY_NEPTUNIAN,
	NEPTUNIAN,
	HYPER_DENSE_CRONIAN,
	GLACIAL_LOCKED,
	CRYO_DENSE_TITANIAN,
	SCORCHED_GREENHOUSE,
	DENSE_NEPTUNIAN
}

var distance : float
var type : BaseType
var mass : float
var radius : float
var moon_count : int
var has_water_or_ice : bool

var is_tectonic : bool
var volcanism : VolcanismLevel
var is_tidallock : bool
var has_magnetic : bool
var temperature : TempLevel
var temperature_raw : int
var temperature_gh : int
var planet_class : PlanetClass

func pre_init_planet(star : Star, orbit_distance : float) :
	distance = orbit_distance
	var r : float = distance / star.frostline
	type = get_initial_type(star, r)

func get_initial_type(star : Star, r : float) -> BaseType :
	if randf() < (0.7 if r >= 1 else 0.03) :
		return BaseType.ICE_GIANT if distance >= star.frostline else BaseType.GAS_GIANT
	return BaseType.NORMAL

func init_planet(star : Star):
	var affected_by_gas_giant : bool = false
	if type == BaseType.NORMAL:
		for slot in star.orbit_slot:
			# If within 2 AU of a Gas Giant or Ice Giant
			if abs(slot.distance - distance) < 2 and (slot.type == BaseType.GAS_GIANT or slot.type == BaseType.ICE_GIANT):
				affected_by_gas_giant = true
	
	if affected_by_gas_giant:
		type = BaseType.ASTEROID_BELT
	
	match type:
		BaseType.ASTEROID_BELT:
			init_as_asteroid_belt()
		_:
			init_as_planet(star)
	
func init_as_asteroid_belt():
	mass = 0.002 / sqrt(distance)
	radius = distance


func init_as_planet(star : Star):
	if type == BaseType.NORMAL:
		mass = randf_range(0.005,2)
		radius = pow(mass,0.27)
	else:
		mass = randf_range(10, 4130)
		radius = randf_range(10.0,12.0)
	
	# if has moon
	if randf() <= 0.5:
		moon_count = randi_range(1,3) if BaseType.NORMAL else randi_range(1,6)
		
	var temp_eq : float = 255 * pow(star.l,0.25) / sqrt(distance)
	var can_water : bool  = true if temp_eq > 188 and temp_eq < 350 else false
	var can_ice : bool  = temp_eq < 273
	var can_ice_or_water : bool  = can_ice or can_water
	has_water_or_ice = can_ice_or_water
	
	# Geological and Greenhouse related variables... That's alot of math... Please help o_O
	var core_comp : float = randf_range(0.8, 1.2) * 1 + (-1.5 + star.metallicity)
	var area_to_vol : float = 3 / radius
	var thermal_lifespan : float = 11 * pow(mass,1/3)
	var age_proportion : float = star.age / thermal_lifespan
	is_tectonic = true if (true if type == BaseType.NORMAL else false) and mass >= 0.5 and age_proportion <= 0.45 else false
	var has_dynamo : bool = true if age_proportion <= 0.65 else false
	var has_volcanism : bool = true if age_proportion <= 0.95 else false
	var volcanism_index : float = 1 - age_proportion
	volcanism = get_volcanism_level(has_volcanism, volcanism_index)
	var outgassing_factor : float = get_outgassing_factor(has_volcanism, volcanism_index, star)
	var age_bonus : float = 0.0 if is_tectonic else star.accu_cap * ( 1 - exp(-star.age / star.tauaccum))
	var condensation_gate : float = 1 / (1 + exp(-0.03 * (temp_eq - 195)))
	var regulation_coef : float = get_regulation_coef(can_water, is_tectonic, outgassing_factor)
	var greenhouse_volcanic_factor : float = outgassing_factor * regulation_coef * (1 + age_bonus) * condensation_gate
	
	# Tidal lock and Magnetic field check
	var initial_rotation = get_initial_rotation_value()
	is_tidallock = false if type == BaseType.ASTEROID_BELT else 1.2 * pow(10,5) * (( initial_rotation * pow(distance, 6)) / (star.mass * pow(radius,2))) < star.age
	has_magnetic = false if is_tidallock else has_dynamo
	
	# Athmosphere stuff...
	var athmosphere_retention_index = 1 - (((1 - (mass / (radius * (temp_eq/288)))) / 4.5) * star.age) + regulation_coef
	var greenhouse_mult = (1 + greenhouse_volcanic_factor + clampf(athmosphere_retention_index,0.0,1.0))**(1.0/6.0)
	temperature_raw = roundi(temp_eq * pow( 1 + greenhouse_volcanic_factor + clampf(athmosphere_retention_index,0.0,1.0) ,1.0/6.0))
	temperature_gh = roundi(temperature_raw - temp_eq)
	planet_class = get_planet_class(volcanism)
	print(PlanetClass.find_key(planet_class), " @ ", temperature_raw, "K (+", temperature_gh, ") [", VolcanismLevel.find_key(volcanism), " / ", is_tectonic, " / ", is_tidallock, "]" )
	
func get_volcanism_level(has_volcanism : bool, index : float) -> VolcanismLevel:
	if not type == BaseType.NORMAL:
		return VolcanismLevel.NONE
	elif not has_volcanism:
		return VolcanismLevel.DEAD
	elif index > 0.8:
		return VolcanismLevel.HYPER_ACTIVE
	elif index > 0.5:
		return VolcanismLevel.ACTIVE
	elif index > 0.25:
		return VolcanismLevel.RESTRAINED
	else:
		return VolcanismLevel.DORMANT
func get_outgassing_factor(has_volcanism : bool, index : float, star : Star) -> float:
	if not type == BaseType.NORMAL:
		return 0.0
	elif not has_volcanism:
		return 0.0
	elif distance / star.frostline > 1 :
		return 0.0
	elif index > 0.8:
		return 1.5
	elif index > 0.5:
		return 1.0
	elif index > 0.25:
		return 0.3
	else:
		return 0.1
func get_regulation_coef(can_water : bool, is_tectonic : bool, outgassing_factor : float) -> float:
	if can_water and is_tectonic:
		return outgassing_factor * 0.1
	elif can_water:
		return outgassing_factor * 0.5
	else:
		return outgassing_factor * 1.5
func get_initial_rotation_value() -> float :
	match type:
		BaseType.ICE_GIANT:
			return 16
		BaseType.NORMAL:
			return 14
		BaseType.GAS_GIANT:
			return 10.5
		_:
			return 0.0

func get_planet_class(volcanic_level : VolcanismLevel) -> PlanetClass:
	return classify_planet(
		type, volcanic_level, temperature_raw, temperature_gh,
		has_water_or_ice, is_tidallock, has_magnetic, is_tectonic
	)


static func classify_planet(
	base_type : BaseType,
	volcanic_level : VolcanismLevel,
	temperature_raw : float,
	temperature_gh : float,
	has_water_or_ice : bool,
	is_tidallock : bool,
	has_magnetic : bool,
	is_tectonic : bool
) -> PlanetClass:
	# Asteroid
	if base_type == BaseType.ASTEROID_BELT:
		return PlanetClass.ASTEROID_RING

	# Gas Giants
	if base_type == BaseType.GAS_GIANT:
		if temperature_raw >= 500:
			return PlanetClass.PEGASEAN
		elif temperature_gh >= 120:
			return PlanetClass.HYPER_DENSE_CRONIAN
		else:
			return PlanetClass.JOVIAN

	# Ice Giants (now symmetric with Gas Giants: raw-temp tier, then a
	# GH-driven dense tier using the same 120 threshold, then baseline)
	if base_type == BaseType.ICE_GIANT:
		if temperature_raw >= 341:
			return PlanetClass.SULTRY_NEPTUNIAN
		elif temperature_gh >= 120:
			return PlanetClass.DENSE_NEPTUNIAN  # NEW
		else:
			return PlanetClass.NEPTUNIAN

	# Rocky - Infernal extremes
	if temperature_raw >= 500:
		if temperature_gh >= 150 or volcanic_level == VolcanismLevel.HYPER_ACTIVE:
			return PlanetClass.VENERIAN
		if temperature_gh >= 50:
			if has_magnetic:
				return PlanetClass.CORROSIVE_MAGMA_TRAP
			else:
				return PlanetClass.SCORCHED_GREENHOUSE
		return PlanetClass.HERMIAN

	# Rocky - Cryogenic (checked before the dry catch-all: water-agnostic by
	# design, since below the frost point the only real variable is core heat)
	if temperature_raw < 100:
		if volcanic_level in [VolcanismLevel.RESTRAINED, VolcanismLevel.ACTIVE, VolcanismLevel.HYPER_ACTIVE]:
			return PlanetClass.SUB_GLACIAL
		return PlanetClass.PLUTONIAN

	# Rocky - Anomalous volatile-starved (Frigid/Temperate/Torrid dry worlds only)
	if not has_water_or_ice:
		if volcanic_level == VolcanismLevel.HYPER_ACTIVE and temperature_raw < 500:
			return PlanetClass.RADIOACTIVE_OBSIDIAN
		if volcanic_level == VolcanismLevel.DEAD and temperature_gh <= 1:
			return PlanetClass.SUPER_DRY_IRON_BALL
		if temperature_raw < 341:
			return PlanetClass.ANOMALOUS_DRY_HUSK
		return PlanetClass.CALCINATED_WASTELAND

	# Rocky - Torrid
	if temperature_raw >= 341 and temperature_raw < 500:
		if has_water_or_ice and temperature_gh >= 80:
			return PlanetClass.VAPOR_TELLURIC
		if volcanic_level == VolcanismLevel.HYPER_ACTIVE or temperature_gh >= 30:
			return PlanetClass.PYROCLASTIC_SMOLDER
		return PlanetClass.CALCINATED_WASTELAND

	# Frigid
	if temperature_raw >= 100 and temperature_raw <= 249:
		if is_tidallock:
			return PlanetClass.GLACIAL_LOCKED
		if volcanic_level == VolcanismLevel.HYPER_ACTIVE and temperature_gh >= 25:
			return PlanetClass.CRYO_VOLCANIC_FISSURE
		if temperature_gh >= 40:
			return PlanetClass.CRYO_DENSE_TITANIAN
		if is_tectonic or volcanic_level in [VolcanismLevel.ACTIVE, VolcanismLevel.HYPER_ACTIVE]:
			return PlanetClass.BOREAL_ALPINE
		return PlanetClass.GLACIAL_TAIGA

	# Temperate
	if not has_water_or_ice:
		return PlanetClass.ANOMALOUS_DRY_HUSK
	if is_tidallock:
		return PlanetClass.TWILIGHT
	if not has_magnetic:
		return PlanetClass.MAGNETO_STRIPPED_GARDEN
	if temperature_gh >= 60 and volcanic_level == VolcanismLevel.HYPER_ACTIVE:
		return PlanetClass.EXO_CARBONIFEROUS
	if temperature_gh >= 40 and not is_tectonic:
		return PlanetClass.OCEAN
	match volcanic_level:
		VolcanismLevel.DEAD:
			return PlanetClass.COOLED_FOSSIL
		VolcanismLevel.DORMANT:
			return PlanetClass.ARID
		VolcanismLevel.RESTRAINED:
			return PlanetClass.SAVANNA
		VolcanismLevel.ACTIVE, VolcanismLevel.HYPER_ACTIVE:
			return PlanetClass.GARDEN

	assert(false, "Unhandled VolcanismLevel in Temperate branch: %s" % volcanic_level)
	return PlanetClass.GARDEN
