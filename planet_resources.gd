class_name PlanetResources
extends RefCounted
## Tier 0 resource model: Richness (planet, fixed 0-10), Grade (per discovery),
## abstracted pool (TRP), and renewable collapse/restoration.

enum Resource {ORE, EXOTIC_ORE, RADIOACTIVE_ORE, VOLATILES, WATER, EDIBLES, BIOMASS, CRYSTALITES}

# Tune per resource: multiplies planet mass into a total resource pool (TRP).
const QUANTITY_SCALE : Dictionary = {
	Resource.ORE: 1.0, Resource.EXOTIC_ORE: 0.2, Resource.RADIOACTIVE_ORE: 0.1,
	Resource.VOLATILES: 0.8, Resource.WATER: 1.0, Resource.EDIBLES: 0.5,
	Resource.BIOMASS: 0.5, Resource.CRYSTALITES: 0.15,
}

var richness : Dictionary = {}      # Resource -> float 0..10
var pool : Dictionary = {}          # Resource -> float remaining (TRP)
var found_fraction : Dictionary = {} # Resource -> float 0..1
var is_collapsed : Dictionary = {}  # renewable Resource -> bool
var has_been_restored : bool = false


func get_total_pool(planet_mass : float, res : Resource) -> float:
	return planet_mass * QUANTITY_SCALE[res] * (richness.get(res, 0.0) / 10.0)


## One survey success. Returns amount found; richer planets decay slower.
func roll_discovery(planet : Planet, res : Resource) -> Dictionary:
	var C = AstronomyData.DATABASE.Constants
	var r : float = richness.get(res, 0.0)
	if r <= 0.0:
		return {"amount": 0.0, "grade": 0.0}
	var grade : float = clampf(r * randf_range(0.4, 1.0) * planet.get_life_geo_favorability(planet.volcanism), 0.0, 10.0)
	var decay_rate : float = C.base_decay_rate / max(r, 0.5)
	var remaining_factor : float = exp(-decay_rate * found_fraction.get(res, 0.0))
	var trp : float = get_total_pool(planet.mass, res)
	var amount : float = trp * (grade / 10.0) * remaining_factor * C.discovery_yield_factor
	amount = min(amount, pool.get(res, trp))
	found_fraction[res] = clampf(found_fraction.get(res, 0.0) + amount / max(trp, 0.0001), 0.0, 1.0)
	return {"amount": amount, "grade": grade}


## Logistic growth with Allee effect for renewables (Edibles, Biomass, Water-fresh).
func step_renewable(planet : Planet, res : Resource, r_growth : float, K : float, harvest : float, dt : float) -> void:
	var C = AstronomyData.DATABASE.Constants
	var P : float = pool.get(res, K) - harvest
	var A : float = C.allee_fraction * K
	P += r_growth * P * (1.0 - P / K) * ((P / A) - 1.0) * dt
	if P <= C.collapse_floor_fraction * K:
		pool[res] = 0.0
		is_collapsed[res] = true
		planet.life_stage = Planet.LifeStage.STERILE  # ecological collapse
	else:
		pool[res] = minf(P, K)


func restore(planet : Planet, res : Resource, seed_value : float) -> void:
	is_collapsed[res] = false
	pool[res] = seed_value
	has_been_restored = true


func display_prefix() -> String:
	return "Restored " if has_been_restored else ""


## Fraction of planetary water that is drinkable / usable as freshwater.
static func get_freshwater_fraction(humidity_final : float, temperature_raw : float) -> float:
	return clampf(0.05 + (1.0 - humidity_final) * 0.5 + clampf((280.0 - temperature_raw) / 150.0, 0.0, 0.3), 0.03, 0.6)
