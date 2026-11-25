extends Node
## Headless prototype driver. Add as a Node in a scene (or autoload) and run.
## Prints a snapshot every PRINT_EVERY ticks.

const TICKS := 400
const PRINT_EVERY := 80
const PROMOTE_CASH := 80.0
var promotions : int = 0
var attractions : int = 0

var markets : Array[ColonyMarket] = []
var corps : Array[Corporation] = []

signal shipment_made(from_market : ColonyMarket, to_market : ColonyMarket, good : int, qty : float)

var tick_count : int = 0
@export var auto_run : bool = true
@export var use_galaxy : bool = false   # true: colonies come from generated stars/planets
@export var galaxy_stars : int = 120
@export var galaxy_colonies : int = 10
@export var all_planets : bool = false     # true: every generated planet is a colony (galaxy_colonies = how many)
var max_corps : int = 12
## Colonization mode: start from one Capital World; every other planet is unsettled frontier with unknown deposits.
@export var colonize : bool = false
var frontier : Array[ColonyMarket] = []   # every non-capital planet (settled ones stay listed, flagged `settled`)
var capital : ColonyMarket = null
var settlements : int = 0
const CAPITAL_POP := 600.0     # what one well-endowed planet can support on its own deposits
const CAPITAL_CEILING := 3000.0
const SETTLER_MIN_POP := 100.0  # a colony this big can spare settlers for an outpost
const MIGRATION_RATE := 0.02
# --- State finances ---
const PROFIT_TAX := 0.25         # share of a corporation's monthly profit
const WEALTH_TAX := 0.005        # per month on cash above WEALTH_FREE (~6%/year): drains idle hoards
const WEALTH_FREE := 800.0       # working capital left untaxed (~10 facilities' worth)
var treasury : float = 0.0
var tax_collected : float = 0.0  # cumulative
@export var taxes : bool = true
# --- State colonization: the treasury founds colonies for strategic reasons, not profit ---
@export var state_colonization : bool = true
const STATE_REVIEW_MONTHS := 12      # the colonial office reviews the frontier once a year
const STATE_SETTLERS := 40.0         # a state colony ships more people than a company outpost
const STATE_GRANT := 60.0            # seed money for the new colony's local business (promotion happens at 80)
const STATE_HABITAT_METAL := 30.0
const STATE_HABITAT_PARTS := 12.0
const STATE_RESERVE := 2.0           # only spend if the treasury holds this many times the cost
var state_colonies : int = 0
# State survey programme: each year the state orders surveys of unexplored planets, paid on completion.
const SURVEY_ORDER_PRICE := 80.0     # paid per ordered first survey (instead of the flat contract fee)
const SURVEY_BUDGET_SHARE := 0.05    # at most this share of the treasury is committed to new orders each year
# --- Known space: only systems near settled space are charted; random sector discoveries open new regions ---
const HOME_HORIZON := 160.0          # px around the Capital known at the start
const COLONY_HORIZON := 110.0        # each newly settled system charts its neighbourhood
const SECTOR_RADIUS := 140.0         # a sector discovery charts every system this close to its centre
const SECTOR_BASE_CHANCE := 0.002    # per month, even while known space still has work
const SECTOR_EXHAUSTED_CHANCE := 0.04 # per month extra when known space is fully surveyed
var sector_events : int = 0
var survey_backlog : int = 0         # ordered surveys not yet done
var surveys_ordered : int = 0
var state_spent : float = 0.0     # share of a colony's job gap filled per tick (from colonies with idle people)
var growth_enabled : bool = true

func _ready() -> void:
	setup()
	if auto_run:
		run_headless()

func run_headless() -> void:
	for t in TICKS:
		step()
		if t % PRINT_EVERY == PRINT_EVERY - 1:
			_print_snapshot(t + 1)

## Time scale: one tick is one month. Rates and horizons across the prototype are tuned to this.
const MONTHS_PER_TICK := 1.0

func years_elapsed() -> float:
	return tick_count * MONTHS_PER_TICK / 12.0

func date_label() -> String:
	var m : int = int(tick_count * MONTHS_PER_TICK)
	return "year %d, month %d" % [m / 12, m % 12 + 1]

@export var rng_seed : int = 7

func setup() -> void:
	seed(rng_seed)
	if use_galaxy:
		markets = GalaxyColonies.generate_all(galaxy_colonies) if all_planets else GalaxyColonies.generate(galaxy_stars, galaxy_colonies)
	else:
		_setup_handmade()
	for c in markets:
		c.growth_enabled = growth_enabled
	_setup_corps()
	if colonize:
		_setup_colonization()

func _setup_corps() -> void:
	corps = [
		Corporation.new(Corporation.Kind.EXTRACTOR, 300.0),
		Corporation.new(Corporation.Kind.PRODUCER, 300.0),
		Corporation.new(Corporation.Kind.FREIGHT, 300.0),
	]

func _setup_colonization() -> void:
	Corporation.world = self
	ColonyMarket.external_migration = true
	# Best planet that can feed and equip itself: a homeworld without Ore can't run its own industry.
	var best : ColonyMarket = markets[0]
	var best_v : float = -1.0
	for c in markets:
		var self_sufficient : bool = c.richness.has(Goods.ORE) and (c.richness.has(Goods.FOOD) or c.richness.has(Goods.WATER))
		var v : float = c.site_score * (1.0 if self_sufficient else 0.25)
		if v > best_v:
			best_v = v; best = c
	capital = best
	var home_star : String = capital.name.get_slice(".", 0)
	capital.name = "Capital"
	capital.max_pop = CAPITAL_CEILING
	capital.pop = CAPITAL_POP
	for c in markets:
		if c != capital:
			c.make_frontier()
			frontier.append(c)
	# Home deposits are fully known; distant ones need surveyors.
	for g in capital.richness:
		capital.hidden_richness[g] = capital.richness[g]; capital.found_frac[g] = 1.0
	capital.surveys = 1
	# The home system is charted from the start (no claims: it's public knowledge).
	for c in frontier:
		if c.name.get_slice(".", 0) == home_star:
			c.surveys = 1
			for g in c.hidden_richness:
				c.reveal(g, c.hidden_richness[g])
	markets = [capital]
	for sys in GalaxyColonies.systems:
		sys.known = false
	_reveal_around(capital.position, HOME_HORIZON)
	_seed_capital()
	corps.append(Corporation.new(Corporation.Kind.SURVEYOR, 600.0))   # state-chartered survey service

## The homeworld starts with an established economy sized to its population (no capex; it predates the game).
func _seed_capital() -> void:
	var ex : Corporation = corps[0]
	var pr : Corporation = corps[1]
	var p : float = capital.pop
	# A few passes, because the industry itself needs upkeep (Parts per facility) and inputs (Water for hydroponics).
	for pass_i in 4:
		var hydro : float = 0.0
		for f in pr.facilities:
			if f.good == Goods.FOOD: hydro += f.throughput()
		var parts_need : float = (p * 0.012 + capital.facility_count * ColonyMarket.MAINT_PARTS_PER_FACILITY * (1.0 - ColonyMarket.SALVAGE_RATE) + hydro * 0.1) * 1.3
		var needs : Dictionary = {Goods.FOOD: p * 0.05 * 1.2, Goods.WATER: (p * 0.02 + hydro * 2.0) * 1.3, Goods.PARTS: parts_need,
			Goods.METAL: (p * ColonyMarket.MAINT_METAL_PER_POP + parts_need * 2.0) * 1.1}
		needs[Goods.ORE] = needs[Goods.METAL] * 2.0 * 1.1
		for g in [Goods.WATER, Goods.FOOD, Goods.ORE, Goods.METAL, Goods.PARTS]:
			var guard : int = 0
			while capital.capacity[g] < needs[g] and capital.facility_slots_free() > 0 and guard < 200:
				guard += 1
				var q : float = capital.richness.get(g, 0.0)
				if q > 0.0 and ex._site_room(capital, g, false) >= q:
					ex.seed_facility(capital, g)
				elif Goods.RECIPES.has(g):
					pr.seed_facility(capital, g, true)
				else:
					break
		if pass_i == 3:
			# Shelves at normal cover (prices start near base), and the founding firms are established businesses.
			for g in needs:
				capital.stock[g] = needs[g] * ColonyMarket.COVER_TICKS
			ex.cash = 40.0 * ex.facilities.size() + 300.0
			pr.cash = 40.0 * pr.facilities.size() + 300.0

## Closest settled colony (where supplies, settlers and survey ships come from).
func nearest_settled(c : ColonyMarket) -> ColonyMarket:
	var best : ColonyMarket = capital
	var bd : float = INF
	for m in markets:
		var d : float = m.position.distance_to(c.position)
		if d < bd:
			bd = d; best = m
	return best

func _settler_donor(c : ColonyMarket) -> ColonyMarket:
	# Colonization companies recruit volunteers from any colony big enough to spare them (the home colony's
	# own labour gap grows a little), preferring well-staffed colonies close to the target.
	var best : ColonyMarket = null
	var bv : float = 0.0
	for m in markets:
		if m.pop < SETTLER_MIN_POP:
			continue
		var v : float = (m.pop / maxf(m.target_pop(), 1.0)) * m.pop / (1.0 + m.position.distance_to(c.position) / 200.0)
		if v > bv:
			bv = v; best = m
	return best

func can_send_settlers(c : ColonyMarket) -> bool:
	return _settler_donor(c) != null

## A corporation founds an outpost: settlers move from the colony with the most idle people (nearest first).
func found_outpost(c : ColonyMarket) -> bool:
	var donor : ColonyMarket = _settler_donor(c)
	if donor == null or c.settled:
		return false
	donor.pop -= Corporation.OUTPOST_SETTLERS
	c.settle(Corporation.OUTPOST_SETTLERS)
	_reveal_around(c.position, COLONY_HORIZON)
	c.growth_enabled = growth_enabled
	markets.append(c)
	settlements += 1
	shipment_made.emit(donor, c, Goods.FOOD, Corporation.OUTPOST_SETTLERS)
	return true

## The colonial office picks the surveyed, unsettled planet that best fills the economy's gaps
## (known deposits weighted by how scarce that good is, plus room to grow), closest first, and pays for it all:
## settlers' passage, habitat materials (taken from the nearest colony's shelf at its prices) and a grant for the local business.
func _state_colonize() -> void:
	var scarcity : Dictionary = {}
	for g in Goods.ALL:
		var p : float = 0.0
		for m in markets: p += m.price[g]
		scarcity[g] = p / markets.size() / ColonyMarket.BASE_PRICE
	var best : ColonyMarket = null
	var bv : float = 0.0
	for c in frontier:
		if c.settled or c.surveys == 0 or c.richness.is_empty():
			continue
		var v : float = c.max_pop / 400.0
		for g in c.richness: v += c.richness[g] * scarcity[g]
		v /= 1.0 + c.position.distance_to(nearest_settled(c).position) / 200.0
		if v > bv:
			bv = v; best = c
	if best == null:
		return
	var near : ColonyMarket = nearest_settled(best)
	var cost : float = Corporation.OUTPOST_COST + STATE_GRANT + STATE_HABITAT_METAL * near.price[Goods.METAL] + STATE_HABITAT_PARTS * near.price[Goods.PARTS]
	if treasury < cost * STATE_RESERVE or _settler_donor(best) == null:
		return
	var donor : ColonyMarket = _settler_donor(best)
	if donor.pop < STATE_SETTLERS * 2.5:
		return
	near.stock[Goods.METAL] = maxf(0.0, near.stock[Goods.METAL] - STATE_HABITAT_METAL)
	near.stock[Goods.PARTS] = maxf(0.0, near.stock[Goods.PARTS] - STATE_HABITAT_PARTS)
	donor.pop -= STATE_SETTLERS
	best.settle(STATE_SETTLERS)
	_reveal_around(best.position, COLONY_HORIZON)
	best.growth_enabled = growth_enabled
	best.local_cash = STATE_GRANT
	for g in best.claims:                # the state buys out the surveyors' claims at the going price
		var cl : Dictionary = best.claims[g]
		var fee : float = Corporation.CLAIM_PRICE * cl["value"]
		cl["owner"].cash += fee; cl["owner"].claims_sold += 1
		treasury -= fee; state_spent += fee
	best.claims.clear()
	markets.append(best)
	settlements += 1
	state_colonies += 1
	treasury -= cost
	state_spent += cost
	shipment_made.emit(donor, best, Goods.FOOD, STATE_SETTLERS)

func _reveal_around(pos : Vector2, radius : float) -> int:
	var n : int = 0
	for sys in GalaxyColonies.systems:
		if not sys.known and sys.position.distance_to(pos) <= radius:
			sys.known = true; n += 1
	return n

static func is_known(c : ColonyMarket) -> bool:
	return c.system == null or c.system.known

## A random event (probe report, navigation breakthrough, strange signal...) charts a whole dark sector.
## More likely as known space runs out of unsurveyed bodies, so booms tend to arrive when surveyors go idle.
func _maybe_discover_sector() -> void:
	var known_n : int = 0; var surveyed_n : int = 0
	var dark : Array = []
	for sys in GalaxyColonies.systems:
		if sys.known:
			for c in sys.bodies:
				known_n += 1
				if c.surveys > 0: surveyed_n += 1
		else:
			dark.append(sys)
	if dark.is_empty():
		return
	var exhaustion : float = float(surveyed_n) / maxf(known_n, 1.0)
	if randf() >= SECTOR_BASE_CHANCE + SECTOR_EXHAUSTED_CHANCE * pow(exhaustion, 3.0):
		return
	var centre : SystemNode = dark[randi() % dark.size()]
	_reveal_around(centre.position, SECTOR_RADIUS)
	sector_events += 1

## Order first surveys of unexplored planets, up to the yearly budget.
func _order_surveys() -> void:
	var unexplored : int = 0
	for c in frontier:
		if c.surveys == 0 and is_known(c): unexplored += 1
	var n : int = mini(unexplored - survey_backlog, int(treasury * SURVEY_BUDGET_SHARE / SURVEY_ORDER_PRICE))
	if n > 0:
		survey_backlog += n
		surveys_ordered += n

## Zero-sum migration: people move from better-staffed colonies (pop / jobs-target above average)
## toward worse-staffed ones, so new outposts fill up from the core even when everyone is short of workers.
func _migrate() -> void:
	if markets.size() < 2:
		return
	var tp : float = 0.0; var tt : float = 0.0
	for c in markets:
		tp += c.pop; tt += c.target_pop()
	var avg : float = tp / maxf(tt, 1.0)
	var pull : Dictionary = {}; var push : Dictionary = {}
	var sp : float = 0.0; var ss : float = 0.0
	for c in markets:
		var t : float = c.target_pop()
		var dev : float = c.pop - avg * t      # people above (+) or below (-) the average staffing level
		if dev < 0.0 and c.pop < c.max_pop:
			pull[c] = -dev * MIGRATION_RATE; sp += pull[c]
		elif dev > 0.0:
			push[c] = dev * MIGRATION_RATE; ss += push[c]
	var moved : float = minf(sp, ss)
	if moved <= 0.0:
		return
	for c in pull: c.pop += pull[c] / sp * moved
	for c in push: c.pop -= push[c] / ss * moved

func _setup_handmade() -> void:
	markets = [
		ColonyMarket.new("A", 80, {Goods.ORE: 2.0}, 600.0),
		ColonyMarket.new("B", 60, {Goods.FOOD: 2.0}, 400.0),
		ColonyMarket.new("C", 100, {Goods.ORE: 0.5, Goods.FOOD: 0.5}, 500.0),
		ColonyMarket.new("D", 40, {}, 150.0),
		ColonyMarket.new("E", 50, {Goods.ORE: 1.0}, 250.0),
	]
	var spots : Array[Vector2] = [Vector2(140, 170), Vector2(470, 110), Vector2(330, 330), Vector2(640, 300), Vector2(150, 440)]
	for i in markets.size():
		markets[i].position = spots[i]

func step() -> void:
	_tick(tick_count)
	tick_count += 1

func _tick(t : int) -> void:
	for c in markets:
		c.jobs = 0.0
		c.port_used = 0
	for k in corps:
		for f in k.facilities:
			f.colony.jobs += 1.0
	for k in corps:
		var before : float = k.cash
		k.run(markets)
		if taxes:
			var tax : float = maxf(0.0, k.cash - before) * PROFIT_TAX + maxf(0.0, k.cash - WEALTH_FREE) * WEALTH_TAX
			k.cash -= tax; treasury += tax; tax_collected += tax
		for m in k.last_moves:
			shipment_made.emit(m["from"], m["to"], m["good"], m["qty"])
	if colonize:
		_migrate()
		_maybe_discover_sector()
		if state_colonization and t % STATE_REVIEW_MONTHS == STATE_REVIEW_MONTHS - 1:
			_state_colonize()
			_order_surveys()
		if t % 120 == 119 and not corps.any(func(k): return k.kind == Corporation.Kind.SURVEYOR):
			corps.append(Corporation.new(Corporation.Kind.SURVEYOR, 600.0))   # the state re-charters a survey service
			treasury -= 600.0
	for c in markets.duplicate():
		c.tick()
		if t > 20 and corps.size() < max_corps:
			_try_emergence(c)
	for k in corps:
		if k.is_dead():
			k.dissolve()
	corps = corps.filter(func(k): return not k.is_dead())

## Two emergence paths, both local to a colony:
##  1. Promotion: the informal local business has banked enough profit to incorporate.
##  2. Attraction: workforce demand outpaces population (jobs but not enough people) -> outside founder.
func _try_emergence(c : ColonyMarket) -> void:
	if c.local_cash > PROMOTE_CASH and not c.richness.is_empty():
		var g : int = c.richness.keys()[0]
		var k := Corporation.new(Corporation.Kind.EXTRACTOR, c.local_cash * 0.5)
		c.local_cash = 0.0
		k.seed_facility(c, g)
		corps.append(k)
		promotions += 1
		return
	if randf() < maxf(0.0, c.workforce_gap() - 0.15) * 0.03 or randf() < maxf(0.0, c.shortfall_signal - 0.25) * 0.05:
		var kind : Corporation.Kind = _founding_kind()
		for k in corps:                     # an idle funded corporation of this kind will take the opening itself
			if k.kind == kind and k.is_idle_funded():
				return
		corps.append(Corporation.new(kind, 200.0))
		attractions += 1

func _print_snapshot(t : int) -> void:
	if markets.size() > 20:
		_print_summary(t)
		return
	print("--- tick %d --- (promotions=%d attractions=%d)" % [t, promotions, attractions])
	var cap : Array = []
	for g in Goods.ALL:
		cap.append("%.1f/%.1f" % [Corporation._regional(markets, "capacity", g), Corporation._regional(markets, "use", g)])
	print("  capacity/use ORE,METAL,PARTS,FOOD = ", cap)
	for k in corps:
		print("  %s cash=%d facilities=%d ships=%d" % [Corporation.Kind.find_key(k.kind), k.cash, k.facilities.size(), k.ships])
	for c in markets:
		var p : Array = []
		for g in Goods.ALL:
			p.append("%d" % c.price[g])
		print("  %s pop=%d jobs=%d prices(ORE/METAL/PARTS/FOOD) = %s" % [c.name, c.pop, c.jobs, "/".join(p)])

## Derived demand decides what gets founded: unmet raw demand -> Extractor, else Producer.
func _founding_kind() -> Corporation.Kind:
	var fr : float = 0.0
	var fn : int = 0
	for k in corps:
		if k.kind == Corporation.Kind.FREIGHT:
			fr += k.utilisation; fn += 1
	if fn == 0 or (fr / fn > 0.85 and randf() < 0.3):
		return Corporation.Kind.FREIGHT
	var raw_unmet : float = 0.0
	var proc_unmet : float = 0.0
	for g in Goods.ALL:
		var u : float = Corporation._regional(markets, "use", g) * Corporation.HEADROOM - Corporation._regional(markets, "capacity", g)
		# Raw demand only counts if some colony can actually extract it (richness + a free workforce slot);
		# anything with a recipe (including Food via hydroponics) can also be manufactured anywhere.
		if Goods.is_raw(g) and _has_extraction_site(g):
			raw_unmet += maxf(u, 0.0)
		if Goods.RECIPES.has(g):
			proc_unmet += maxf(u, 0.0)
	return Corporation.Kind.EXTRACTOR if raw_unmet > proc_unmet else Corporation.Kind.PRODUCER

func _print_summary(t : int) -> void:
	var kinds : Dictionary = {}
	var cash : float = 0.0
	var fac : int = 0
	var ships : int = 0
	for k in corps:
		var n : String = Corporation.Kind.find_key(k.kind)
		kinds[n] = kinds.get(n, 0) + 1
		cash += k.cash; fac += k.facilities.size(); ships += k.ships
	var pop : float = 0.0
	var short_n : int = 0
	var with_jobs : int = 0
	var avg : Dictionary = {}
	for g in Goods.ALL:
		avg[g] = 0.0
	for c in markets:
		pop += c.pop
		if (c.price[Goods.FOOD] + c.price[Goods.PARTS]) / (2.0 * ColonyMarket.BASE_PRICE) > 2.0:
			short_n += 1
		if c.jobs > 0.0:
			with_jobs += 1
		for g in Goods.ALL:
			avg[g] += c.price[g] / markets.size()
	print("--- tick %d --- colonies=%d pop=%d  colonies_with_jobs=%d  in_shortage=%d  promotions=%d attractions=%d" % [t, markets.size(), pop, with_jobs, short_n, promotions, attractions])
	print("  corps %s  facilities=%d  ships=%d  avg_price ORE/METAL/PARTS/FOOD = %d/%d/%d/%d" % [kinds, fac, ships, avg[Goods.ORE], avg[Goods.METAL], avg[Goods.PARTS], avg[Goods.FOOD]])

func _has_extraction_site(g : int) -> bool:
	for c in markets:
		if c.richness.get(g, 0.0) > 0.0 and c.facility_slots_free() > 0:
			return true
	for c in frontier:
		if not c.settled and c.richness.get(g, 0.0) > 0.0:
			return true
	return false

## One row of time-series metrics (see METRIC_HEADER).
const METRIC_HEADER := "tick,pop,colonies_with_jobs,in_shortage,avg_ore,avg_metal,avg_parts,avg_food,extractors,producers,freight,facilities,ships,promotions,attractions,avg_level,upgrades,hydro_facilities,food_extractors,avg_water,water_sites,ship_class,port_use,settled,surveyed,survey_ships,settlements,claims_sold,treasury,corp_cash,tax_collected,under_construction,state_colonies,state_spent,surveys_ordered,survey_backlog,survey_losses,systems_settled,known_systems,sector_events"
func metrics_row() -> String:
	var pop : float = 0.0
	var jobs_n : int = 0
	var short_n : int = 0
	var avg : Dictionary = {}
	for g in Goods.ALL:
		avg[g] = 0.0
	for c in markets:
		pop += c.pop
		if c.jobs > 0.0:
			jobs_n += 1
		if (c.price[Goods.FOOD] + c.price[Goods.PARTS]) / (2.0 * ColonyMarket.BASE_PRICE) > 2.0:
			short_n += 1
		for g in Goods.ALL:
			avg[g] += c.price[g] / markets.size()
	var lvl_sum : float = 0.0; var upg : int = 0
	var hydro : int = 0; var farm : int = 0
	var water_sites : int = 0; var water_avg : float = 0.0
	for c in markets:
		if c.richness.has(Goods.WATER): water_sites += 1
		water_avg += c.price[Goods.WATER] / markets.size()
	var pu : float = 0.0; var ps : float = 0.0
	for c in markets:
		pu += c.port_used; ps += c.port_slots()
	var port_use : float = pu / maxf(ps, 1.0)
	var ex : int = 0; var pr : int = 0; var fr : int = 0; var fac : int = 0; var ships : int = 0; var sclass : int = 0
	var surveyed : int = 0; var sships : int = 0; var csold : int = 0; var ccash : float = 0.0
	var nbuild : int = 0
	var slost : int = 0
	var seen_sys : Dictionary = {}
	for c in markets:
		if c.system != null: seen_sys[c.system] = true
	var sys_settled : int = seen_sys.size()
	for k in corps:
		ccash += k.cash
		for f in k.facilities:
			if f.building(): nbuild += 1
	for c in frontier:
		if c.surveys > 0: surveyed += 1
	for k in corps:
		match k.kind:
			Corporation.Kind.EXTRACTOR: ex += 1
			Corporation.Kind.PRODUCER: pr += 1
			Corporation.Kind.FREIGHT: fr += 1
		if k.kind == Corporation.Kind.SURVEYOR:
			sships += 1 + k.ships; csold += k.claims_sold; slost += k.ships_lost
			continue
		fac += k.facilities.size(); ships += k.ships; sclass = maxi(sclass, k.ship_class if k.kind == Corporation.Kind.FREIGHT else 0)
		upg += k.upgrades
		for f in k.facilities:
			lvl_sum += f.level
			if f.good == Goods.FOOD:
				if f.recipe_mode: hydro += 1
				else: farm += 1
	return "%d,%.0f,%d,%d,%.2f,%.2f,%.2f,%.2f,%d,%d,%d,%d,%d,%d,%d,%.2f,%d,%d,%d,%.2f,%d,%d,%.3f,%d,%d,%d,%d,%d,%.0f,%.0f,%.0f,%d,%d,%.0f,%d,%d,%d,%d,%d,%d" % [tick_count, pop, jobs_n, short_n, avg[Goods.ORE], avg[Goods.METAL], avg[Goods.PARTS], avg[Goods.FOOD], ex, pr, fr, fac, ships, promotions, attractions, (lvl_sum / maxf(fac, 1)), upg, hydro, farm, water_avg, water_sites, sclass, port_use, markets.size(), surveyed, sships, settlements, csold, treasury, ccash, tax_collected, nbuild, state_colonies, state_spent, surveys_ordered, survey_backlog, slost, sys_settled, GalaxyColonies.systems.filter(func(x): return x.known).size(), sector_events]
