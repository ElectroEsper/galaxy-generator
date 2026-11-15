class_name Planet


enum BaseType {NORMAL, GAS_GIANT, ICE_GIANT, ASTEROID_BELT}
enum VolcanismLevel {NONE, DEAD, DORMANT, RESTRAINED, ACTIVE, HYPER_ACTIVE}
enum TempLevel {CRYOGENIC, FRIGID, TEMPERATE, TORRID, INFERNAL}
enum LifeStage {STERILE, NASCENT, FLOURISHING}
enum PlanetClass {
	# Special
	ASTEROID_RING,

	# Young systems (age-gated)
	PROTOPLANETARY_CORE,
	PROTO_GIANT,
	DEBRIS_DISK_REMNANT,

	# Gas Giants
	PEGASEAN,
	HYPER_DENSE_CRONIAN,
	JOVIAN,

	# Ice Giants
	SULTRY_NEPTUNIAN,
	DENSE_NEPTUNIAN,
	NEPTUNIAN,

	# Rocky - Infernal
	VENERIAN,
	CORROSIVE_MAGMA_TRAP,
	SCORCHED_GREENHOUSE,
	HERMIAN,

	# Rocky - Cryogenic
	SUB_GLACIAL,
	PLUTONIAN,

	# Rocky - Volatile-starved (dry catch-all)
	MOLTEN_OBSIDIAN,
	SUPER_DRY_IRON_BALL,
	DRY_HUSK,
	SCORCHED_WASTELAND,

	# Rocky - Torrid
	STEAM_WORLD,
	PYROCLASTIC_SMOLDER,

	# Rocky - Frigid
	GLACIAL_LOCKED,
	CRYO_VOLCANIC_FISSURE,
	SCOURED_CRYOVOLCANIC,
	CRYO_DENSE_TITANIAN,
	BOREAL_ALPINE,
	ROCKY_TUNDRA,
	GLACIAL_TAIGA,

	# Rocky - Temperate
	TWILIGHT,
	EXO_CARBONIFEROUS,
	HUMID_WETLAND,
	OCEAN,
	PRIMORDIAL_OCEAN,
	ABIOTIC_OCEAN,
	MAGNETO_STRIPPED_GARDEN,
	FADING_GARDEN,
	ERODING_HUSK,
	COOLED_FOSSIL,
	ARID,
	BARREN_STEPPE,
	SAVANNA,
	DUST_SAVANNA,
	GARDEN,
	BUDDING_GARDEN,
	BARREN_EDEN,
}

var distance : float
var type : BaseType
var mass : float
var radius : float
var moon_count : int
var has_water : bool
var has_subsurface_ocean : bool
var has_ice : bool
var has_water_or_ice : bool
var has_volatile_ice : bool
var has_volatile : bool

var life_stage : LifeStage
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

func get_life_geo_favorability(level : VolcanismLevel) -> float:
	match level:
		VolcanismLevel.DEAD:
			return 0.3
		VolcanismLevel.DORMANT:
			return 0.7
		VolcanismLevel.RESTRAINED:
			return 1.0
		VolcanismLevel.ACTIVE:
			return 1.0
		VolcanismLevel.HYPER_ACTIVE:
			return 0.5
		_:
			return 0.0
func get_life_stage(has_water : bool, star_age: float, volcanic_level: VolcanismLevel) -> LifeStage:
	if not has_water:
		return LifeStage.STERILE
	if star_age < AstronomyData.DATABASE.Constants.life_possible_threshold:
		return LifeStage.STERILE
	
	var geo_favorability : float = get_life_geo_favorability(volcanic_level)
	var effective_age : float = (star_age - AstronomyData.DATABASE.Constants.life_possible_threshold) * geo_favorability
	
	if effective_age >= AstronomyData.DATABASE.Constants.biosphere_mature_threshold:
		return LifeStage.FLOURISHING
	elif effective_age > 0.0:
		return LifeStage.NASCENT
	else:
		return LifeStage.STERILE

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
	
	var formation_budget : float = clampf(0.3 + 0.5 / (1 + exp(-8 * ( (distance/star.frostline) - 1))), 0.0, 1.0)
	var oxygen_factor : float = min(1.0, star.metallicity / star.oxygen_threshold)
	var water_budget : float = formation_budget * oxygen_factor
		
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
	
	# Volatile stuff
	var can_volatiles : bool = temp_eq < 250.0
	var r_volatile : float = distance / star.volatileline
	var volatile_formation_budget : float = clampf(0.3 + 0.5 / (1 + exp(-8 * (r_volatile - 1))), 0.0, 1.0)
	var volatile_factor : float = min(1.0, star.metallicity / AstronomyData.DATABASE.Constants.base_volatile_threshold)
	var volatile_budget : float = volatile_formation_budget * volatile_factor
	
	
	has_volatile_ice = can_volatiles and (randf() <= volatile_budget)
	has_volatile = can_volatiles and (randf() <= volatile_budget * clampf(athmosphere_retention_index, 0.0, 1.0))
	
	# Water stuff
	has_ice = can_ice and (randf() <= water_budget)
	has_water = can_water and (randf() <= water_budget * clampf(athmosphere_retention_index, 0.0, 1.0))
	has_subsurface_ocean = can_ice and (volcanism >= VolcanismLevel.RESTRAINED)
	has_water_or_ice = has_ice or has_water or has_subsurface_ocean
	
	# If we have no water, and this planet could have some, let's redo the regulation_coeff, to get a proper-value)
	if (not has_water and can_water):
		regulation_coef = get_regulation_coef(has_water, is_tectonic, outgassing_factor)
		greenhouse_volcanic_factor = outgassing_factor * regulation_coef * (1 + age_bonus) * condensation_gate
		athmosphere_retention_index = 1 - (((1 - (mass / (radius * (temp_eq/288)))) / 4.5) * star.age) + regulation_coef
	
	life_stage = get_life_stage(has_water, star.age, volcanism)
	
	var greenhouse_mult = (1 + greenhouse_volcanic_factor + clampf(athmosphere_retention_index,0.0,1.0))**(1.0/6.0)
	temperature_raw = roundi(temp_eq * pow( 1 + greenhouse_volcanic_factor + clampf(athmosphere_retention_index,0.0,1.0) ,1.0/6.0))
	temperature_gh = roundi(temperature_raw - temp_eq)
	if star_age_is_protoplanetary(star):
		var C = AstronomyData.DATABASE.Constants
		var r_scale : float = clampf((distance - star.min_orbit) / max(star.max_orbit - star.min_orbit, 0.0001), 0.0, 1.0)
		var accretion : float = C.protoplanet_temp_min + (C.protoplanet_temp_max - C.protoplanet_temp_min) * exp(-C.protoplanet_falloff_rate * r_scale)
		temperature_raw = roundi(accretion + temp_eq * C.protoplanet_insolation_weight)
		temperature_gh = 0
	planet_class = get_planet_class(volcanism, star.age)
	temperature = get_temperature_class(temperature_raw)
	print(PlanetClass.find_key(planet_class), " @ ", temperature_raw, "K (+", temperature_gh, ") [", VolcanismLevel.find_key(volcanism), " / ", is_tectonic, " / ", is_tidallock, "]" )
	add_to_universe_data()

func star_age_is_protoplanetary(star : Star) -> bool:
	return star.age < AstronomyData.DATABASE.Constants.protoplanet_age_threshold

func add_to_universe_data() :
	var data : Dictionary = Universe.data.planets
	if data.has(PlanetClass.find_key(planet_class)):
		data[PlanetClass.find_key(planet_class)] += 1
	else:
		data[PlanetClass.find_key(planet_class)] = 1
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
func get_regulation_coef(water : bool, is_tectonic : bool, outgassing_factor : float) -> float:
	if water and is_tectonic:
		return outgassing_factor * 0.1
	elif water:
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
func get_planet_class(volcanic_level : VolcanismLevel, star_age : float) -> PlanetClass:
	return classify_planet(
		type, volcanic_level, temperature_raw, temperature_gh,
		has_water_or_ice, has_volatile, has_volatile_ice, is_tidallock, has_magnetic, is_tectonic, life_stage, star_age
	)
func get_temperature_class(k : int) -> TempLevel:
	if k >= 500:
		return TempLevel.INFERNAL
	elif k >= 341:
		return TempLevel.TORRID
	elif k >= 250:
		return TempLevel.TEMPERATE
	elif k >= 100:
		return TempLevel.FRIGID
	else:
		return TempLevel.CRYOGENIC

static func classify_planet(
	base_type : BaseType,
	volcanic_level : VolcanismLevel,
	temperature_raw : float,
	temperature_gh : float,
	has_water_or_ice : bool,
	has_volatiles : bool,
	has_volatile_ice : bool,
	is_tidallock : bool,
	has_magnetic : bool,
	is_tectonic : bool,
	life_stage : LifeStage,
	star_age : float = 99.0
) -> PlanetClass:
	# Protoplanets: system too young to have settled
	if star_age < AstronomyData.DATABASE.Constants.protoplanet_age_threshold:
		match base_type:
			BaseType.ASTEROID_BELT:
				return PlanetClass.DEBRIS_DISK_REMNANT
			BaseType.GAS_GIANT, BaseType.ICE_GIANT:
				return PlanetClass.PROTO_GIANT
			_:
				return PlanetClass.PROTOPLANETARY_CORE

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

	# Ice Giants
	if base_type == BaseType.ICE_GIANT:
		if temperature_raw >= 341:
			return PlanetClass.SULTRY_NEPTUNIAN
		elif temperature_gh >= 120:
			return PlanetClass.DENSE_NEPTUNIAN
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
			return PlanetClass.MOLTEN_OBSIDIAN
		if volcanic_level == VolcanismLevel.DEAD and temperature_gh <= 1:
			return PlanetClass.SUPER_DRY_IRON_BALL
		if temperature_raw < 341:
			return PlanetClass.DRY_HUSK
		return PlanetClass.SCORCHED_WASTELAND

	# Rocky - Torrid
	if temperature_raw >= 341 and temperature_raw < 500:
		if has_water_or_ice and temperature_gh >= 80:
			return PlanetClass.STEAM_WORLD
		if volcanic_level == VolcanismLevel.HYPER_ACTIVE or temperature_gh >= 30:
			return PlanetClass.PYROCLASTIC_SMOLDER
		return PlanetClass.SCORCHED_WASTELAND

	# Frigid
	if temperature_raw >= 100 and temperature_raw <= 249:
		if is_tidallock:
			return PlanetClass.GLACIAL_LOCKED

		if volcanic_level == VolcanismLevel.HYPER_ACTIVE and temperature_gh >= 25:
			if has_volatile_ice:
				return PlanetClass.CRYO_VOLCANIC_FISSURE
			else:
				return PlanetClass.SCOURED_CRYOVOLCANIC

		if temperature_gh >= 40 and has_volatiles:
			return PlanetClass.CRYO_DENSE_TITANIAN

		if is_tectonic or volcanic_level in [VolcanismLevel.ACTIVE, VolcanismLevel.HYPER_ACTIVE]:
			if has_volatile_ice:
				return PlanetClass.BOREAL_ALPINE
			else:
				return PlanetClass.ROCKY_TUNDRA

		return PlanetClass.GLACIAL_TAIGA

	# Temperate
	if not has_water_or_ice:
		return PlanetClass.DRY_HUSK

	if is_tidallock:
		return PlanetClass.TWILIGHT

	if temperature_gh >= 60 and volcanic_level == VolcanismLevel.HYPER_ACTIVE:
		match life_stage:
			LifeStage.FLOURISHING:
				return PlanetClass.EXO_CARBONIFEROUS
			LifeStage.NASCENT:
				return PlanetClass.HUMID_WETLAND
			LifeStage.STERILE:
				return PlanetClass.ABIOTIC_OCEAN

	if temperature_gh >= 40 and not is_tectonic:
		match life_stage:
			LifeStage.FLOURISHING:
				return PlanetClass.OCEAN
			LifeStage.NASCENT:
				return PlanetClass.PRIMORDIAL_OCEAN
			LifeStage.STERILE:
				return PlanetClass.ABIOTIC_OCEAN

	if not has_magnetic:
		match life_stage:
			LifeStage.FLOURISHING:
				return PlanetClass.MAGNETO_STRIPPED_GARDEN
			LifeStage.NASCENT:
				return PlanetClass.FADING_GARDEN
			LifeStage.STERILE:
				return PlanetClass.ERODING_HUSK

	match volcanic_level:
		VolcanismLevel.DEAD:
			return PlanetClass.COOLED_FOSSIL
		VolcanismLevel.DORMANT:
			if life_stage == LifeStage.STERILE:
				return PlanetClass.BARREN_STEPPE
			return PlanetClass.ARID
		VolcanismLevel.RESTRAINED:
			if life_stage == LifeStage.STERILE:
				return PlanetClass.DUST_SAVANNA
			return PlanetClass.SAVANNA
		VolcanismLevel.ACTIVE, VolcanismLevel.HYPER_ACTIVE:
			match life_stage:
				LifeStage.FLOURISHING:
					return PlanetClass.GARDEN
				LifeStage.NASCENT:
					return PlanetClass.BUDDING_GARDEN
				LifeStage.STERILE:
					return PlanetClass.BARREN_EDEN

	assert(false, "Unhandled VolcanismLevel/LifeStage combination in Temperate branch")
	return PlanetClass.GARDEN
