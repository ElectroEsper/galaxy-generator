class_name ColonyMarket
extends RefCounted
## Per-colony market. Price is derived from stock cover (stock / (use * COVER)),
## so it is stateless and cannot run away the way an integrated price can.

const BASE_PRICE := 10.0
const COVER_TICKS := 10.0

var name : String
var pop : float
var port_used : int = 0            # deliveries handled this tick (reset each tick)
var richness : Dictionary          # Goods.ID -> float (raw goods only)
var stock : Dictionary = {}
var price : Dictionary = {}
var use : Dictionary = {}          # smoothed consumption rate per good
var use_this_tick : Dictionary = {}
var capacity : Dictionary = {}     # units/tick that facilities here can add, per good
var max_pop : float = 400.0        # habitability ceiling (from the planet in the real game)
var extraction : Dictionary = {}   # raw good -> output of corporate extraction facilities here (capped by richness)
var extractor_count : int = 0     # of which raw-extraction facilities (they need fewer workers)
var facility_count : int = 0       # facilities built here (kept in sync by Corporation)
var requests : Array = []          # input requests posted by producers this tick (served by Freight)
var growth_enabled : bool = true   # births + maintenance demand (false = PR #8 baseline behaviour)
var jobs : float = 0.0             # facilities operating here (set by the sim each tick)
var local_cash : float = 0.0       # profit accrued by the colony's informal local business
var planet_label : String = ""       # planet class, shown by the view
var position : Vector2 = Vector2.ZERO  # galaxy-map position (used by the visual layer)
var shortfall_signal : float = 0.0 # smoothed price premium of pop goods -> corp emergence
# --- Colonization & surveying ---
## When true, the sim moves people between colonies (zero-sum migration) instead of colonies conjuring migrants.
static var external_migration : bool = false
var settled : bool = true
var system = null                     # SystemNode this body belongs to
var body_radius : float = 1.0          # size of the body (drives survey time)
var site_score : float = 0.0          # how attractive the planet looks as a home (picks the Capital World)
var hidden_richness : Dictionary = {} # true richness; `richness` holds only what surveys have revealed
var found_frac : Dictionary = {}      # revealed share of each good's true richness
var surveys : int = 0
var claims : Dictionary = {}          # (legacy, unused with empires) see intel
var owner = null                       # Empire that settled this body
## Per-empire knowledge: empire id -> {"rich": {good: known richness}, "found": {good: share of true richness found},
## "surveys": int, "claims": {good: {"owner": Corporation, "value": float}}}. For a settled body, `richness` IS the owner's
## "rich" dictionary (same object), so the owner's surveys feed its extraction directly.
var intel : Dictionary = {}

func _init(n : String, p : float, rich : Dictionary, ceiling : float = 400.0) -> void:
	name = n; pop = p; richness = rich; max_pop = ceiling
	for g in Goods.ALL:
		stock[g] = 40.0; price[g] = BASE_PRICE; use[g] = 0.1; capacity[g] = 0.0
	# Local business: small informal extraction for every raw resource the colony has.
	for g in richness:
		capacity[g] += local_output(g)
	# Subsistence output also counts as capacity, so corporations only build for demand beyond it.
	capacity[Goods.FOOD] += SUBSISTENCE_FOOD
	capacity[Goods.PARTS] += SUBSISTENCE_PARTS

const USE_FLOOR := 0.02            # tiny, so a 100-colony map doesn't invent phantom demand
const BASE_SELF_POP := 30.0
const JOBS_PER_FACILITY := 8.0
const MAINT_METAL_PER_POP := 0.004
const MAINT_PARTS_PER_FACILITY := 0.08
# Rates are per tick; one tick = one month (see EconomySim.MONTHS_PER_TICK).
const BIRTH_RATE := 0.003     # ~3.7%/year with enough food and room (historical colonial growth was ~2-4%)
const DEATH_RATE := 0.02      # ~21%/year when starving
## Subsistence: every colony feeds and equips its baseline population without any corporation.
const SUBSISTENCE_FOOD := BASE_SELF_POP * 0.05
const SUBSISTENCE_PARTS := BASE_SELF_POP * 0.012

## Workforce caps how many facilities a colony can host (spreads industry across colonies).
## Raw extraction is capital-heavy: a mine takes only this share of a worker slot.
const EXTRACTOR_SLOT := 0.5

func facility_slots_free() -> int:
	var load : float = float(facility_count - extractor_count) + float(extractor_count) * EXTRACTOR_SLOT
	return int(floor(max_pop / JOBS_PER_FACILITY - load))

func local_output(g : int) -> float:
	return richness.get(g, 0.0) * 0.25

## Workforce demand outpacing the population is the emergence signal (0 = balanced).
func workforce_gap() -> float:
	return (target_pop() - pop) / maxf(pop, 1.0)

func target_pop() -> float:
	return minf(BASE_SELF_POP + jobs * JOBS_PER_FACILITY, max_pop)

## Recycling: share of maintenance consumption recovered as scrap (cuts net Metal/Parts demand, hence Ore).
const SALVAGE_RATE := 0.5

func maintenance_demand(g : int) -> float:
	match g:
		Goods.METAL: return pop * MAINT_METAL_PER_POP
		Goods.PARTS: return facility_count * MAINT_PARTS_PER_FACILITY
	return 0.0

func pop_demand(g : int) -> float:
	var d : float = 0.0
	match g:
		Goods.FOOD: d = pop * 0.05
		Goods.PARTS: d = pop * 0.012
		Goods.WATER: d = pop * 0.02
	if growth_enabled:
		# Maintenance demand: buildings and facilities wear out and need Metal / Parts.
		match g:
			Goods.METAL: d += pop * MAINT_METAL_PER_POP
			Goods.PARTS: d += facility_count * MAINT_PARTS_PER_FACILITY
	return d

func note_use(g : int, amount : float) -> void:
	use_this_tick[g] = use_this_tick.get(g, 0.0) + amount

func tick() -> void:
	stock[Goods.FOOD] += SUBSISTENCE_FOOD
	stock[Goods.PARTS] += SUBSISTENCE_PARTS
	for g in richness:
		var q : float = local_output(g)
		if price[g] > Goods.RAW_COST[g]:
			stock[g] += q
			local_cash += q * (price[g] - Goods.RAW_COST[g])
	# Abstract migration: population drifts toward what the local economy can employ.
	if growth_enabled:
		# Births need food and room; starvation kills; jobs only ever attract migrants (no forced shrink).
		var need : float = maxf(pop_demand(Goods.FOOD), 0.001)
		var fed : float = clampf(stock[Goods.FOOD] / (need * 3.0), 0.0, 1.0)
		pop += pop * BIRTH_RATE * fed * (1.0 - pop / max_pop) - pop * DEATH_RATE * (1.0 - fed)
		if not external_migration:
			pop += maxf(0.0, target_pop() - pop) * 0.02
		pop = clampf(pop, 5.0, max_pop)
	else:
		pop += (target_pop() - pop) * 0.02
	for g in Goods.ALL:
		var take : float = minf(stock[g], pop_demand(g))
		stock[g] -= take
		# Salvage: part of what maintenance wears out is recovered as scrap and goes back into stock.
		if growth_enabled and take > 0.0 and (g == Goods.METAL or g == Goods.PARTS):
			stock[g] += SALVAGE_RATE * maintenance_demand(g) * take / maxf(pop_demand(g), 0.001)
		# Desired consumption (not just what was available) so stock-outs stay visible as demand.
		var used : float = pop_demand(g) + use_this_tick.get(g, 0.0)
		use[g] = 0.9 * use[g] + 0.1 * maxf(used, USE_FLOOR)
		var cover : float = stock[g] / (use[g] * COVER_TICKS)
		price[g] = BASE_PRICE * clampf(pow(maxf(cover, 0.001), -0.7), 0.1, 10.0)
	use_this_tick.clear()
	requests.clear()
	var premium : float = (price[Goods.FOOD] + price[Goods.PARTS]) / (2.0 * BASE_PRICE) - 1.0
	shortfall_signal = 0.9 * shortfall_signal + 0.1 * premium

## Port congestion: a colony can load/unload only so many deliveries per tick, whoever's ships they are.
const PORT_BASE := 4
const PORT_POP_PER_SLOT := 100.0

func port_slots() -> int:
	return PORT_BASE + int(pop / PORT_POP_PER_SLOT)

func port_free() -> bool:
	return port_used < port_slots()

## Turn a generated colony into an unsettled frontier planet: nobody lives there and its deposits are unknown.
func make_frontier() -> void:
	hidden_richness = richness.duplicate()
	for g in richness:
		capacity[g] -= local_output(g)
	richness = {}
	settled = false
	pop = 0.0

func intel_for(e) -> Dictionary:
	if not intel.has(e.id):
		intel[e.id] = {"rich": {}, "found": {}, "surveys": 0, "claims": {}}
	return intel[e.id]

## What empire e knows of this body's deposits (empty if it never surveyed it).
func known_rich(e) -> Dictionary:
	return intel[e.id]["rich"] if intel.has(e.id) else {}

func surveys_by(e) -> int:
	return intel[e.id]["surveys"] if intel.has(e.id) else 0

## A survey by empire e revealed `amount` more of good g (capped by the true richness). Returns how much was new.
func reveal(e, g : int, amount : float) -> float:
	var info : Dictionary = intel_for(e)
	var r : float = hidden_richness.get(g, 0.0)
	var old : float = info["rich"].get(g, 0.0)
	var nv : float = minf(r, old + amount)
	if nv <= old + 0.001:
		return 0.0
	info["rich"][g] = nv
	info["found"][g] = nv / maxf(r, 0.001)
	if settled and owner == e:
		Corporation.invalidate_all()
		capacity[g] += (nv - old) * 0.25      # the local business starts working the new find
	return nv - old

## First settlers arrive, sent by empire e: the body (and its whole system) becomes e's, and e's knowledge drives its economy.
func settle(settlers : float, e = null) -> void:
	settled = true
	pop = settlers
	if e != null:
		owner = e
		richness = intel_for(e)["rich"]
		if system != null and system.owner == null:
			system.owner = e
	Corporation.invalidate_all()
	for g in richness:
		capacity[g] += local_output(g)
