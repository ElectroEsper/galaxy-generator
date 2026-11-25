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
@export var galaxy_systems : int = 0      # >0: generate this many star systems (all bodies) instead of a planet count
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
		markets = GalaxyColonies.generate_all(galaxy_colonies, galaxy_systems) if all_planets else GalaxyColonies.generate(galaxy_stars, galaxy_colonies)
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

## Several empires can share the galaxy (`num_empires`); with one, behaviour matches the single-state version.
@export var num_empires : int = 1
var empires : Array = []
# --- Relations between empires: contact, opinion, stance, tariffs, incidents (hooks for diplomacy and war later) ---
const BORDER_RANGE := 90.0           # px: two empires' systems this close count as a shared border segment
const TRADE_WEIGHT := 8.0            # opinion from trade: x log(1 + monthly trade value between them)
const BORDER_WEIGHT := 3.0           # opinion lost per shared border segment
const INCIDENT_PENALTY := 15.0       # opinion lost per incident (decays)
const INCIDENT_DECAY := 0.98         # per month
const OPINION_RATE := 0.05           # opinion moves this share of the way to its target each month
const TARIFF : Dictionary = {"friendly": 0.0, "neutral": 0.10, "hostile": 0.35, "embargo": 0.35}
const TERRITORY_RADIUS := 70.0       # px a claimed system's territory reaches (same as the map's territory shader)
const ROUTE_SAMPLE := 20.0           # px between territory checks along a route
const GOODWILL_WEIGHT := 1.0         # opinion from aid / gestures (decays like incidents)
var relations : Dictionary = {}      # "a:b" (a < b) -> {met, opinion, trade, month_trade, border, incidents, stance}
var events : Array = []              # [tick, text] - first contacts, incidents, stance changes
const EMPIRE_COLORS : Array = [Color(0.95, 0.8, 0.35), Color(0.4, 0.75, 1.0), Color(0.95, 0.45, 0.45), Color(0.6, 0.9, 0.5), Color(0.8, 0.6, 1.0), Color(1.0, 0.65, 0.3), Color(0.5, 0.95, 0.9), Color(0.95, 0.6, 0.85)]

func _setup_colonization() -> void:
	Corporation.world = self
	ColonyMarket.external_migration = true
	# Capitals: the best planet that can feed and equip itself (a homeworld without Ore can't run its own industry);
	# further empires take the good homeworld farthest from the existing capitals.
	var value : Dictionary = {}
	var best_v : float = -1.0
	for c in markets:
		var self_sufficient : bool = c.richness.has(Goods.ORE) and (c.richness.has(Goods.FOOD) or c.richness.has(Goods.WATER))
		value[c] = c.site_score * (1.0 if self_sufficient else 0.25)
		best_v = maxf(best_v, value[c])
	var capitals : Array = []
	for i in num_empires:
		var pick : ColonyMarket = null
		var pv : float = -1.0
		for c in markets:
			if capitals.has(c) or (c.system != null and capitals.any(func(x): return x.system == c.system)):
				continue
			var v : float = value[c]
			if i > 0:
				if v < best_v * 0.5:
					continue
				var dmin : float = INF
				for x in capitals: dmin = minf(dmin, x.position.distance_to(c.position))
				v = dmin + v * 0.001         # spread out first, quality breaks ties
			if v > pv:
				pv = v; pick = c
		capitals.append(pick)
	var home_stars : Array = []
	for i in num_empires:
		var e := Empire.new(i, "Empire %d" % (i + 1), EMPIRE_COLORS[i % EMPIRE_COLORS.size()])
		e.capital = capitals[i]
		home_stars.append(capitals[i].name.get_slice(".", 0))
		capitals[i].name = "Capital" if num_empires == 1 else "Capital %d" % (i + 1)
		capitals[i].max_pop = CAPITAL_CEILING
		capitals[i].pop = CAPITAL_POP
		empires.append(e)
	capital = capitals[0]
	for c in markets:
		if not capitals.has(c):
			c.make_frontier()
			frontier.append(c)
	for i in num_empires:
		var e : Empire = empires[i]
		var cap : ColonyMarket = e.capital
		# Home deposits are fully known; distant ones need surveyors.
		for g in cap.richness:
			cap.hidden_richness[g] = cap.richness[g]; cap.found_frac[g] = 1.0
		var info : Dictionary = cap.intel_for(e)
		for g in cap.richness:
			info["rich"][g] = cap.richness[g]; info["found"][g] = 1.0
		info["surveys"] = 1
		cap.surveys = 1
		cap.owner = e
		cap.richness = info["rich"]
		if cap.system != null: cap.system.owner = e
		# The home system is charted from the start (no claims: it's public knowledge at home).
		for c in frontier:
			if c.name.get_slice(".", 0) == home_stars[i]:
				c.surveys = 1
				c.intel_for(e)["surveys"] = 1
				for g in c.hidden_richness:
					c.reveal(e, g, c.hidden_richness[g])
	markets = []
	for e in empires: markets.append(e.capital)
	for sys in GalaxyColonies.systems:
		sys.known = false
	for e in empires:
		_reveal_around(e, e.capital.position, HOME_HORIZON)
	for i in num_empires:
		var e : Empire = empires[i]
		var ex : Corporation; var pr : Corporation
		if i == 0:
			ex = corps[0]; pr = corps[1]
			for k in corps: k.empire = e
		else:
			ex = Corporation.new(Corporation.Kind.EXTRACTOR, 300.0, e)
			pr = Corporation.new(Corporation.Kind.PRODUCER, 300.0, e)
			corps.append(ex); corps.append(pr); corps.append(Corporation.new(Corporation.Kind.FREIGHT, 300.0, e))
		_seed_capital(e.capital, ex, pr)
	for e in empires:
		corps.append(Corporation.new(Corporation.Kind.SURVEYOR, 600.0, e))   # state-chartered survey service

## The homeworld starts with an established economy sized to its population (no capex; it predates the game).
func _seed_capital(cap : ColonyMarket, ex : Corporation, pr : Corporation) -> void:
	var p : float = cap.pop
	# A few passes, because the industry itself needs upkeep (Parts per facility) and inputs (Water for hydroponics).
	for pass_i in 4:
		var hydro : float = 0.0
		for f in pr.facilities:
			if f.good == Goods.FOOD: hydro += f.throughput()
		var parts_need : float = (p * 0.012 + cap.facility_count * ColonyMarket.MAINT_PARTS_PER_FACILITY * (1.0 - ColonyMarket.SALVAGE_RATE) + hydro * 0.1) * 1.3
		var needs : Dictionary = {Goods.FOOD: p * 0.05 * 1.2, Goods.WATER: (p * 0.02 + hydro * 2.0) * 1.3, Goods.PARTS: parts_need,
			Goods.METAL: (p * ColonyMarket.MAINT_METAL_PER_POP + parts_need * 2.0) * 1.1}
		needs[Goods.ORE] = needs[Goods.METAL] * 2.0 * 1.1
		for g in [Goods.WATER, Goods.FOOD, Goods.ORE, Goods.METAL, Goods.PARTS]:
			var guard : int = 0
			while cap.capacity[g] < needs[g] and cap.facility_slots_free() > 0 and guard < 200:
				guard += 1
				var q : float = cap.richness.get(g, 0.0)
				if q > 0.0 and ex._site_room(cap, g, false) >= q:
					ex.seed_facility(cap, g)
				elif Goods.RECIPES.has(g):
					pr.seed_facility(cap, g, true)
				else:
					break
		if pass_i == 3:
			# Shelves at normal cover (prices start near base), and the founding firms are established businesses.
			for g in needs:
				cap.stock[g] = needs[g] * ColonyMarket.COVER_TICKS
			ex.cash = 40.0 * ex.facilities.size() + 300.0
			pr.cash = 40.0 * pr.facilities.size() + 300.0

func _empire_colonies(e : Empire) -> Array:
	return markets.filter(func(m): return m.owner == e)

func _clear_empire_caches() -> void:
	for e in empires: e.clear_caches()
	Corporation.invalidate_all()

## Outpost options' fixed parts for this month, for empire e: [body, good, richness, net unit margin at e's nearest colony
## after shipping, cost without the claim fee]. Rebuilt with the candidate list (each month, or when a colony is founded).
func outpost_base(e : Empire) -> Array:
	if not e.ob_valid:
		var tb : int = Time.get_ticks_usec()
		e.ob_valid = true
		e.ob_cache = []
		for c in frontier_candidates(e):
			if c.settled or not can_send_settlers(c, e):
				continue
			var near : ColonyMarket = nearest_settled(c, e)
			var mats : float = Corporation._materials_cost(near, 1.0, true)
			var rich : Dictionary = c.known_rich(e)
			for g in rich:
				var unit : float = near.price[g] - Goods.RAW_COST[g] - Corporation.SHIP_COST * Corporation._dist(c, near, [])
				e.ob_cache.append([c, g, rich[g], unit, Corporation.CAPEX + Corporation.OUTPOST_COST + mats])
		Corporation.sub_prof["outpost_base_time"] = Corporation.sub_prof.get("outpost_base_time", 0) + (Time.get_ticks_usec() - tb)
		Corporation.sub_prof["outpost_base_builds"] = Corporation.sub_prof.get("outpost_base_builds", 0) + 1000
	return e.ob_cache

## Unsettled bodies with deposits known to e, outside other empires' territory (outpost candidates), computed once per tick.
func frontier_candidates(e : Empire) -> Array:
	if not e.cand_valid:
		e.cand_cache = frontier.filter(func(c): return not c.settled and not c.known_rich(e).is_empty() and e.may_enter(c))
		e.cand_valid = true
	return e.cand_cache

## Closest colony of empire e (where its supplies, settlers and survey ships come from). Cached per tick.
func nearest_settled(c : ColonyMarket, e : Empire = null) -> ColonyMarket:
	if e == null: e = empires[0]
	var ck = c.system if c.system != null else c     # bodies of one system share a map position
	if e.near_cache.has(ck):
		return e.near_cache[ck]
	var best : ColonyMarket = e.capital
	var bd : float = INF
	for m in markets:
		if m.owner != e:
			continue
		var d : float = m.position.distance_to(c.position)
		if d < bd:
			bd = d; best = m
	e.near_cache[ck] = best
	return best

func _settler_donor(c : ColonyMarket, e : Empire) -> ColonyMarket:
	var ck = c.system if c.system != null else c     # bodies of one system share a map position
	if e.donor_cache.has(ck):
		return e.donor_cache[ck]
	# Colonization companies recruit volunteers from any of the empire's colonies big enough to spare them
	# (the home colony's own labour gap grows a little), preferring well-staffed colonies close to the target.
	var best : ColonyMarket = null
	var bv : float = 0.0
	for m in markets:
		if m.owner != e or m.pop < SETTLER_MIN_POP:
			continue
		var v : float = (m.pop / maxf(m.target_pop(), 1.0)) * m.pop / (1.0 + m.position.distance_to(c.position) / 200.0)
		if v > bv:
			bv = v; best = m
	e.donor_cache[ck] = best
	return best

## Settlers can be sent anywhere as long as one of the empire's colonies is big enough (the donor's identity only matters
## when an outpost is actually founded). Checked once a month.
func can_send_settlers(c : ColonyMarket, e : Empire) -> bool:
	if not e.donor_cache.has("any"):
		e.donor_cache["any"] = markets.any(func(m): return m.owner == e and m.pop >= SETTLER_MIN_POP)
	return e.donor_cache["any"]

func _on_settled(c : ColonyMarket, e : Empire) -> void:
	_clear_empire_caches()
	_reveal_around(e, c.position, COLONY_HORIZON)
	c.growth_enabled = growth_enabled
	markets.append(c)
	settlements += 1
	e.settlements += 1

## A corporation founds an outpost for its empire: settlers move from that empire's colony with the most idle people.
func found_outpost(c : ColonyMarket, e : Empire) -> bool:
	var donor : ColonyMarket = _settler_donor(c, e)
	if donor == null or c.settled or not e.may_enter(c):
		return false
	donor.pop -= Corporation.OUTPOST_SETTLERS
	_check_claim_jump(c, e)
	c.settle(Corporation.OUTPOST_SETTLERS, e)
	_on_settled(c, e)
	shipment_made.emit(donor, c, Goods.FOOD, Corporation.OUTPOST_SETTLERS)
	return true

## The colonial office picks the surveyed, unsettled planet that best fills its empire's gaps
## (known deposits weighted by how scarce that good is, plus room to grow), closest first, and pays for it all:
## settlers' passage, habitat materials (taken from the nearest colony's shelf at its prices) and a grant for the local business.
func _state_colonize(e : Empire) -> void:
	var own : Array = _empire_colonies(e)
	var scarcity : Dictionary = {}
	for g in Goods.ALL:
		var p : float = 0.0
		for m in own: p += m.price[g]
		scarcity[g] = p / own.size() / ColonyMarket.BASE_PRICE
	var best : ColonyMarket = null
	var bv : float = 0.0
	for c in frontier:
		if c.settled or c.surveys_by(e) == 0 or not e.may_enter(c):
			continue
		var rich : Dictionary = c.known_rich(e)
		if rich.is_empty():
			continue
		var v : float = c.max_pop / 400.0
		for g in rich: v += rich[g] * scarcity[g]
		v /= 1.0 + c.position.distance_to(nearest_settled(c, e).position) / 200.0
		if v > bv:
			bv = v; best = c
	if best == null:
		return
	var near : ColonyMarket = nearest_settled(best, e)
	var cost : float = Corporation.OUTPOST_COST + STATE_GRANT + STATE_HABITAT_METAL * near.price[Goods.METAL] + STATE_HABITAT_PARTS * near.price[Goods.PARTS]
	if e.treasury < cost * STATE_RESERVE or _settler_donor(best, e) == null:
		return
	var donor : ColonyMarket = _settler_donor(best, e)
	if donor.pop < STATE_SETTLERS * 2.5:
		return
	near.stock[Goods.METAL] = maxf(0.0, near.stock[Goods.METAL] - STATE_HABITAT_METAL)
	near.stock[Goods.PARTS] = maxf(0.0, near.stock[Goods.PARTS] - STATE_HABITAT_PARTS)
	donor.pop -= STATE_SETTLERS
	_check_claim_jump(best, e)
	best.settle(STATE_SETTLERS, e)
	_clear_empire_caches()
	_reveal_around(e, best.position, COLONY_HORIZON)
	best.growth_enabled = growth_enabled
	best.local_cash = STATE_GRANT
	var claims : Dictionary = best.intel_for(e)["claims"]
	for g in claims:                     # the state buys out its surveyors' claims at the going price
		var cl : Dictionary = claims[g]
		var fee : float = Corporation.CLAIM_PRICE * cl["value"]
		cl["owner"].cash += fee; cl["owner"].claims_sold += 1
		e.treasury -= fee; e.state_spent += fee
	claims.clear()
	markets.append(best)
	settlements += 1
	e.settlements += 1
	e.state_colonies += 1
	e.treasury -= cost
	e.state_spent += cost
	shipment_made.emit(donor, best, Goods.FOOD, STATE_SETTLERS)

## Frontier bodies e may survey (charted by e, not another empire's territory), in frontier order; rebuilt when e charts space.
func known_frontier(e : Empire) -> Array:
	if not e.known_valid:
		e.known_frontier_cache = frontier.filter(func(c): return e.may_enter(c))
		e.known_valid = true
	return e.known_frontier_cache

func _reveal_around(e : Empire, pos : Vector2, radius : float) -> int:
	e.known_valid = false
	e.survey_board_valid = false
	var n : int = 0
	for sys in GalaxyColonies.systems:
		if not e.known.has(sys) and sys.position.distance_to(pos) <= radius:
			e.known[sys] = true; sys.known = true; n += 1
	return n

## A random event (probe report, navigation breakthrough, strange signal...) charts a whole dark sector for one empire.
## More likely as e's known space runs out of unsurveyed bodies, so booms tend to arrive when its surveyors go idle.
func _maybe_discover_sector(e : Empire) -> void:
	var known_n : int = 0; var surveyed_n : int = 0
	var dark : Array = []
	for sys in GalaxyColonies.systems:
		if e.known.has(sys):
			for c in sys.bodies:
				known_n += 1
				if c.surveys_by(e) > 0: surveyed_n += 1
		else:
			dark.append(sys)
	if dark.is_empty():
		return
	var exhaustion : float = float(surveyed_n) / maxf(known_n, 1.0)
	if randf() >= SECTOR_BASE_CHANCE + SECTOR_EXHAUSTED_CHANCE * pow(exhaustion, 3.0):
		return
	var centre : SystemNode = dark[randi() % dark.size()]
	_reveal_around(e, centre.position, SECTOR_RADIUS)
	e.sector_events += 1
	sector_events += 1

## Order first surveys of unexplored planets in e's known space, up to the yearly budget.
func _order_surveys(e : Empire) -> void:
	var unexplored : int = 0
	for c in frontier:
		if c.surveys_by(e) == 0 and e.may_enter(c): unexplored += 1
	var n : int = mini(unexplored - e.survey_backlog, int(e.treasury * SURVEY_BUDGET_SHARE / SURVEY_ORDER_PRICE))
	if n > 0:
		e.survey_backlog += n
		e.surveys_ordered += n

## Zero-sum migration inside one empire: people move from better-staffed colonies (pop / jobs-target above average)
## toward worse-staffed ones, so new outposts fill up from the core even when everyone is short of workers.
func _migrate(e : Empire) -> void:
	var own : Array = _empire_colonies(e)
	if own.size() < 2:
		return
	var tp : float = 0.0; var tt : float = 0.0
	for c in own:
		tp += c.pop; tt += c.target_pop()
	var avg : float = tp / maxf(tt, 1.0)
	var pull : Dictionary = {}; var push : Dictionary = {}
	var sp : float = 0.0; var ss : float = 0.0
	for c in own:
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

## Profiling: microseconds spent per phase of the tick (cumulative).
var prof : Dictionary = {}
func _p(phase : String, t0 : int) -> int:
	var now : int = Time.get_ticks_usec()
	prof[phase] = prof.get(phase, 0) + (now - t0)
	return now

func _tick(t : int) -> void:
	var t0 : int = Time.get_ticks_usec()
	_clear_empire_caches()
	for c in markets:
		c.jobs = 0.0
		c.port_used = 0
	for k in corps:
		for f in k.facilities:
			f.colony.jobs += 1.0
	t0 = _p("jobs_reset", t0)
	for k in _turn_order(t):
		var before : float = k.cash
		var tk : int = Time.get_ticks_usec()
		k.run(markets)
		_p("corp_" + Corporation.Kind.find_key(k.kind).to_lower(), tk)
		if taxes:
			var tax : float = maxf(0.0, k.cash - before) * PROFIT_TAX + maxf(0.0, k.cash - WEALTH_FREE) * WEALTH_TAX
			k.cash -= tax; tax_collected += tax
			if k.empire != null:
				k.empire.treasury += tax; k.empire.tax_collected += tax
			else:
				treasury += tax
		for m in k.last_moves:
			shipment_made.emit(m["from"], m["to"], m["good"], m["qty"])
	t0 = Time.get_ticks_usec()
	if colonize:
		for e in empires: _migrate(e)
		t0 = _p("migration", t0)
		for e in empires: _maybe_discover_sector(e)
		t0 = _p("sector_events", t0)
		if empires.size() > 1:
			_update_relations()
			if t % 12 == 6:
				Diplomacy.yearly(self)
		t0 = _p("relations", t0)
		if state_colonization and t % STATE_REVIEW_MONTHS == STATE_REVIEW_MONTHS - 1:
			for e in empires:
				_state_colonize(e)
				_order_surveys(e)
		t0 = _p("state", t0)
		if t % 120 == 119:
			for e in empires:
				if not corps.any(func(k): return k.kind == Corporation.Kind.SURVEYOR and k.empire == e):
					corps.append(Corporation.new(Corporation.Kind.SURVEYOR, 600.0, e))   # the state re-charters a survey service
					e.treasury -= 600.0
	t0 = Time.get_ticks_usec()
	Corporation.invalidate_all()
	for c in markets.duplicate():
		c.tick()
		if t > 20 and corps.size() < max_corps:
			_try_emergence(c)
	t0 = _p("markets_emergence", t0)
	for k in corps:
		if k.is_dead():
			k.dissolve()
	corps = corps.filter(func(k): return not k.is_dead())
	_p("dissolution", t0)

func _rel(a : Empire, b : Empire) -> Dictionary:
	var key : String = "%d:%d" % [mini(a.id, b.id), maxi(a.id, b.id)]
	if not relations.has(key):
		relations[key] = {"met": false, "opinion": 0.0, "trade": 0.0, "month_trade": 0.0, "border": 0, "incidents": 0.0, "stance": "none",
			"trade_treaty": false, "passage": false, "goodwill": 0.0}
	return relations[key]

func _event(text : String) -> void:
	events.append([tick_count, text])

## Customs on a delivery from src to dest: the share of the delivered value the destination's empire takes, or -1 if trade
## between the two empires is impossible (not yet in contact, or embargo). Same empire / no empire: free.
func tariff_rate(src : ColonyMarket, dest : ColonyMarket) -> float:
	if src.owner == null or dest.owner == null or src.owner == dest.owner:
		return 0.0
	var r : Dictionary = _rel(src.owner, dest.owner)
	if not r["met"]:
		return 0.0
	return TARIFF[r["stance"]] * (0.5 if r["trade_treaty"] else 1.0)

func treaty(a : Empire, b : Empire, kind : String) -> bool:
	if a == b:
		return true
	var r : Dictionary = _rel(a, b)
	return r["met"] and r[kind]

## Claimed systems for the territory test, rebuilt monthly.
var _claimed : Array = []
var _claimed_tick : int = -1
var _route_cache : Dictionary = {}
var _claimed_owner : Dictionary = {}     # system -> owner, as of the start of the month (territory is redrawn monthly)

## The empire whose territory covers this point (nearest claimed system within TERRITORY_RADIUS), or null.
func owner_at(p : Vector2) -> Empire:
	if _claimed_tick != tick_count:
		_claimed = GalaxyColonies.systems.filter(func(s): return s.owner != null)
		_claimed_owner.clear()
		for s in _claimed: _claimed_owner[s] = s.owner
		_claimed_tick = tick_count
		_route_cache.clear()
	var best : Empire = null
	var bd : float = TERRITORY_RADIUS
	for s in _claimed:
		var d : float = s.position.distance_to(p)
		if d <= bd:
			bd = d; best = s.owner
	return best

## May a freighter of empire f carry goods from a to b? Every foreign empire involved must have a treaty with f:
## a trade treaty with the empires at either end (to trade with their colonies), and a passage treaty with any other
## empire whose territory the route crosses. Without treaties, foreign space is closed (enclaves stay enclaves).
func route_ok(f : Empire, a : ColonyMarket, b : ColonyMarket) -> bool:
	if f == null or empires.size() <= 1:
		return true
	owner_at(a.position)                     # refreshes the monthly territory cache
	var ka = a.system if a.system != null else a
	var kb = b.system if b.system != null else b
	var key : Array = [f.id, ka, kb]
	if _route_cache.has(key):
		return _route_cache[key]
	var ok : bool = true
	var ends : Array = []
	for o in [a.owner, b.owner]:
		if o != null and o != f:
			if not treaty(f, o, "trade_treaty"):
				ok = false
			ends.append(o)
	if ok:
		# Whose territory each point along the line is in: the first *claimed* system in that point's precomputed
		# nearest-first list (same rule as owner_at, without searching the galaxy every month).
		for near in _route_geometry(a, b):
			var z : Empire = null
			for s in near:
				if _claimed_owner.has(s):
					z = _claimed_owner[s]; break
			if z == null or z == f or ends.has(z):
				continue
			if not treaty(f, z, "passage"):
				ok = false; break
	_route_cache[key] = ok
	return ok

## Route geometry, computed once per pair of positions and kept forever (star systems never move): for each sample point
## along the straight line, every star system within TERRITORY_RADIUS, nearest first (ties: later system first, matching
## owner_at). Whose territory a point is in then only depends on which of those few systems are claimed this month.
var _route_geo : Dictionary = {}
func _route_geometry(a : ColonyMarket, b : ColonyMarket) -> Array:
	var gk : Array = [a.position, b.position]
	if _route_geo.has(gk):
		return _route_geo[gk]
	var pts : Array = []
	var n : int = int(a.position.distance_to(b.position) / ROUTE_SAMPLE)
	var systems : Array = GalaxyColonies.systems
	for i in range(1, n):
		var p : Vector2 = a.position.lerp(b.position, float(i) / float(n))
		var near : Array = []
		for si in systems.size():
			var d : float = systems[si].position.distance_to(p)
			if d <= TERRITORY_RADIUS:
				near.append([d, -si, systems[si]])
		if near.is_empty():
			continue
		near.sort()
		pts.append(near.map(func(x): return x[2]))
	_route_geo[gk] = pts
	return pts

## Freight reports cross-border deliveries (value at the destination price) and the customs it paid.
func record_trade(src : ColonyMarket, dest : ColonyMarket, value : float, customs : float) -> void:
	if src.owner == null or dest.owner == null or src.owner == dest.owner:
		return
	_rel(src.owner, dest.owner)["month_trade"] += value
	dest.owner.treasury += customs
	dest.owner.customs_collected += customs

## An empire settles a system where another empire had already surveyed bodies: a claim-jumping incident.
func _check_claim_jump(c : ColonyMarket, e : Empire) -> void:
	if c.system == null or c.system.owner != null:
		return                               # only when a system is first claimed
	for other in empires:
		if other == e: continue
		if c.system.bodies.any(func(b): return b.surveys_by(other) > 0):
			var r : Dictionary = _rel(e, other)
			r["incidents"] += 1.0
			_event("%s settled %s, which %s had surveyed (incident)" % [e.name, c.system.name, other.name])

## Monthly: contact, border length, trade, opinion and stance for every pair of empires.
func _update_relations() -> void:
	var owned : Dictionary = {}
	for e in empires: owned[e] = []
	for sys in GalaxyColonies.systems:
		if sys.owner != null: owned[sys.owner].append(sys)
	for i in empires.size():
		for j in range(i + 1, empires.size()):
			var a : Empire = empires[i]; var b : Empire = empires[j]
			var r : Dictionary = _rel(a, b)
			if not r["met"]:
				if owned[b].any(func(s): return a.known.has(s)) or owned[a].any(func(s): return b.known.has(s)):
					r["met"] = true; r["stance"] = "neutral"
					_event("First contact: %s and %s" % [a.name, b.name])
				else:
					continue
			var border : int = 0
			for sa in owned[a]:
				for sb in owned[b]:
					if sa.position.distance_to(sb.position) <= BORDER_RANGE: border += 1
			r["border"] = border
			r["trade"] = 0.9 * r["trade"] + 0.1 * r["month_trade"]
			r["month_trade"] = 0.0
			r["incidents"] *= INCIDENT_DECAY
			r["goodwill"] *= INCIDENT_DECAY
			var target : float = TRADE_WEIGHT * log(1.0 + r["trade"]) - BORDER_WEIGHT * border - INCIDENT_PENALTY * r["incidents"] + GOODWILL_WEIGHT * r["goodwill"]
			r["opinion"] = clampf(r["opinion"] + OPINION_RATE * (target - r["opinion"]), -100.0, 100.0)
			var st : String = "neutral"
			if r["opinion"] >= 25.0: st = "friendly"
			elif r["opinion"] <= -60.0: st = "embargo"
			elif r["opinion"] <= -25.0: st = "hostile"
			if st != r["stance"]:
				_event("%s and %s: %s -> %s (opinion %d)" % [a.name, b.name, r["stance"], st, r["opinion"]])
				r["stance"] = st
				if (st == "hostile" or st == "embargo") and (r["trade_treaty"] or r["passage"]):
					r["trade_treaty"] = false; r["passage"] = false
					_event("%s and %s: treaties cancelled" % [a.name, b.name])

## Fair turn order between empires: each month a different empire's corporations act first (they compete for the same
## lanes, ports and opportunities). Within an empire, corporations keep their order; with one empire nothing changes.
func _turn_order(t : int) -> Array:
	if empires.size() <= 1:
		return corps
	var out : Array = []
	var n : int = empires.size()
	for i in n:
		var e : Empire = empires[(t + i) % n]
		for k in corps:
			if k.empire == e: out.append(k)
	for k in corps:
		if k.empire == null: out.append(k)
	return out

## Two emergence paths, both local to a colony:
##  1. Promotion: the informal local business has banked enough profit to incorporate.
##  2. Attraction: workforce demand outpaces population (jobs but not enough people) -> outside founder.
func _try_emergence(c : ColonyMarket) -> void:
	if c.local_cash > PROMOTE_CASH and not c.richness.is_empty():
		var g : int = c.richness.keys()[0]
		var k := Corporation.new(Corporation.Kind.EXTRACTOR, c.local_cash * 0.5, c.owner)
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
		corps.append(Corporation.new(kind, 200.0, c.owner))
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
	for e in empires:
		for c in frontier_candidates(e):
			if c.known_rich(e).get(g, 0.0) > 0.0:
				return true
	return false

## Sum of an Empire field across empires (or the fallback when there are none).
func _esum(field : String, fallback):
	if empires.is_empty():
		return fallback
	var t = 0
	for e in empires: t += e.get(field)
	return t

const RELATION_HEADER := "tick,a,b,met,opinion,stance,border,trade,incidents,trade_treaty,passage,goodwill"
func relation_rows() -> Array:
	var rows : Array = []
	for i in empires.size():
		for j in range(i + 1, empires.size()):
			var r : Dictionary = _rel(empires[i], empires[j])
			rows.append("%d,%d,%d,%d,%.1f,%s,%d,%.1f,%.2f,%d,%d,%.1f" % [tick_count, i, j, 1 if r["met"] else 0, r["opinion"], r["stance"], r["border"], r["trade"], r["incidents"], 1 if r["trade_treaty"] else 0, 1 if r["passage"] else 0, r["goodwill"]])
	return rows

## Per-empire metrics, one row per empire (see EMPIRE_HEADER).
const EMPIRE_HEADER := "tick,empire,colonies,systems,pop,facilities_here,known_systems,surveyed,survey_ships,treasury,tax_collected,state_colonies,sector_events,corps,customs"
func empire_rows() -> Array:
	var rows : Array = []
	for e in empires:
		var own : Array = _empire_colonies(e)
		var pop : float = 0.0; var fac : int = 0
		var sys : Dictionary = {}
		for c in own:
			pop += c.pop; fac += c.facility_count
			if c.system != null: sys[c.system] = true
		var surveyed : int = 0
		for c in frontier:
			if c.surveys_by(e) > 0: surveyed += 1
		var sships : int = 0; var nc : int = 0
		for k in corps:
			if k.empire == e:
				nc += 1
				if k.kind == Corporation.Kind.SURVEYOR: sships += 1 + k.ships
		rows.append("%d,%d,%d,%d,%.0f,%d,%d,%d,%d,%.0f,%.0f,%d,%d,%d,%.0f" % [tick_count, e.id, own.size(), sys.size(), pop, fac, e.known.size(), surveyed, sships, e.treasury, e.tax_collected, e.state_colonies, e.sector_events, nc, e.customs_collected])
	return rows

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
	return "%d,%.0f,%d,%d,%.2f,%.2f,%.2f,%.2f,%d,%d,%d,%d,%d,%d,%d,%.2f,%d,%d,%d,%.2f,%d,%d,%.3f,%d,%d,%d,%d,%d,%.0f,%.0f,%.0f,%d,%d,%.0f,%d,%d,%d,%d,%d,%d" % [tick_count, pop, jobs_n, short_n, avg[Goods.ORE], avg[Goods.METAL], avg[Goods.PARTS], avg[Goods.FOOD], ex, pr, fr, fac, ships, promotions, attractions, (lvl_sum / maxf(fac, 1)), upg, hydro, farm, water_avg, water_sites, sclass, port_use, markets.size(), surveyed, sships, settlements, csold, _esum("treasury", treasury), ccash, tax_collected, nbuild, _esum("state_colonies", 0), _esum("state_spent", 0), _esum("surveys_ordered", 0), _esum("survey_backlog", 0), slost, sys_settled, GalaxyColonies.systems.filter(func(x): return x.known).size(), sector_events]
