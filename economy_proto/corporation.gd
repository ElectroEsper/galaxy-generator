class_name Corporation
extends RefCounted
## Profit-driven agent. Each tick: operate facilities -> maybe close losers ->
## maybe expand into the best opportunity (payback-gated, saturation-aware).

enum Kind {EXTRACTOR, PRODUCER, FREIGHT, SURVEYOR}

## The sim, for agents that act beyond settled markets (surveying the frontier, founding outposts). Null in old setups.
static var world : Node = null

const CAPEX := 80.0
const UPKEEP := 1.0
const SHIP_CAPACITY := 6.0
const SHIP_UPKEEP := 1.5
const CLASS_CAP_MULT := 2.0     # cargo per ship doubles each fleet class
const CLASS_UPKEEP_MULT := 1.4  # but upkeep per ship only x1.4, so bigger hulls are cheaper per unit
const CLASS_REFIT_COST := 0.3   # refit cost = CAPEX * ships * this * class
const MAX_SHIP_CLASS := 6
const SHIP_TIME := 4.0      # distance units a ship can sail per tick (a delivery costs its lane distance + LOAD_TIME)
const LOAD_TIME := 0.5
const GROW_FILL := 0.15    # add capacity only while holds are at least this full on average
const SHIP_COST := 0.4        # per unit per distance step
const EXPORT_SHARE := 1.0    # share of the regional deficit a site can count on exporting to (Freight carries it)
const PAYBACK_HORIZON := 25.0 # ticks; expand only if CAPEX / margin < this
const REQUEST_COVER := 4.0     # producers ask Freight to keep this many ticks of inputs on the shelf
const MAX_LEVEL := 8
const LEVEL_BONUS := 0.6        # each level adds this fraction of base output
const UPKEEP_GROWTH := 0.25     # each level adds this fraction of base upkeep (jobs/slots stay the same)
const EXTRACT_CAP_MULT := 40.0  # a site can't be extracted beyond richness x this per good, however upgraded
const HEADROOM := 1.3          # build until capacity ~ HEADROOM x use
const IDLE_BLOCK := 0.3        # no new capacity for a good while more than this share of our plants making it lose money
const CLOSE_AFTER := 20       # consecutive losing ticks before closing a facility
const INSOLVENT_AFTER := 15   # ticks with cash < 0 before dissolving
# --- Surveying & colonization (1 tick = 1 month) ---
const SURVEY_MONTHS := 6.0       # an Earth-sized body; see survey_months()
const INTRA_SYSTEM_DIST := 0.4   # lane cost between bodies of the same star system
const SURVEY_LOSS := 0.03        # chance a survey ship is lost on a survey (space is dangerous)
const SURVEY_LOSS_GIANT := 0.04  # extra risk around giants (radiation, storms, moons)
const SURVEY_LOSS_BELT := 0.03   # extra risk in belts (debris)
const SHIP_BUY_MONTHS := 6       # a surveyor can commission at most one new ship this often
const SURVEY_UPKEEP := 2.0       # per survey ship per tick
const SURVEY_SHIP_COST := 150.0
const SURVEY_YIELD := 0.6        # share of true richness a good survey reveals (decays as more is found)
const SURVEY_DECAY := 8.0        # discovery decay; divided by richness on the 0-10 scale, so rich worlds keep yielding
const SURVEY_CONTRACT := 20.0    # the state pays this for each first survey of a planet
const CLAIM_PRICE := 150.0       # per unit of revealed richness, paid by the first extractor to work the deposit
const MAX_UNSOLD_CLAIMS := 6     # a surveyor stops buying ships while this many finds are still unsold
const OUTPOST_COST := 160.0      # founding an outpost on a surveyed planet (on top of the facility)
const OUTPOST_SETTLERS := 20.0   # people moved from an existing colony
const OUTPOST_PAYBACK := 60.0    # months: a new colony is a long-term investment, judged on a longer horizon
# --- Construction: building and upgrading consume materials delivered to the site, and take time ---
const BUILD_METAL := 10.0        # per new facility (upgrades: x (0.4 + 0.2 x level))
const BUILD_PARTS := 4.0
const BUILD_MONTHS := 6          # minimum construction time
const OUTPOST_METAL := 15.0      # habitat for the first settlers, on top of the facility
const OUTPOST_PARTS := 6.0

class Facility:
	var colony : ColonyMarket
	var good : int
	var recipe_mode : bool = false   # true: manufactures `good` from inputs; false: extracts it from the ground
	var level : int = 1
	var losing_ticks : int = 0
	var build : Dictionary = {}      # materials still to be delivered (good -> qty)
	var build_ticks : int = 0        # months of construction left
	var pending_level : int = 0      # an upgrade under construction (0 = none)
	func building() -> bool:
		return build_ticks > 0 or not build.is_empty()
	func _init(c : ColonyMarket, g : int, recipe : bool = false) -> void:
		colony = c; good = g; recipe_mode = recipe
	func extracts() -> bool:
		return not recipe_mode
	func level_mult() -> float:
		return 1.0 + LEVEL_BONUS * (level - 1)
	## Units of `good` this facility can add per tick at its current level.
	func throughput() -> float:
		var base : float = colony.richness.get(good, 0.0) if extracts() else Goods.RECIPES[good]["yield"]
		return base * level_mult()
	func upkeep() -> float:
		return UPKEEP * (1.0 + UPKEEP_GROWTH * (level - 1))
	## Cost to go from the current level to the next.
	func upgrade_cost() -> float:
		return CAPEX * (0.4 + 0.2 * level)
	func upgrade_scale() -> float:
		return 0.4 + 0.2 * level

var kind : Kind
var empire = null               # Empire it belongs to (taxed there); may trade and build in any colony
var cash : float
var facilities : Array[Facility] = []
var ships : int = 0
var ship_class : int = 1       # fleet-wide hull class; refits upgrade every ship at once
var broke_ticks : int = 0
var idle_ticks : int = 0
var upgrades : int = 0
var utilisation : float = 0.0   # share of voyages that found a profitable lane
var rr : int = 0
var marg_rate : float = 0.0    # EMA profit per unit of sailing time on the last (marginal) delivery each tick
var fill : float = 0.0          # average hold fill on those voyages
var moved : float = 0.0
var last_moves : Array = []       # shipments made this tick (for the visual layer)

func _init(k : Kind, starting_cash : float, e = null) -> void:
	kind = k; cash = starting_cash; empire = e

## A local business graduating into a corporation: first facility is at home.
func seed_facility(c : ColonyMarket, g : int, recipe : bool = false) -> void:
	var f := Facility.new(c, g, recipe)
	facilities.append(f)
	_register(f, 1.0)
	c.facility_count += 1
	if f.extracts(): c.extractor_count += 1

## Keep colony capacity / extraction bookkeeping in sync with a facility's throughput.
func _register(f : Facility, sign : float) -> void:
	reg_cache.clear()
	invalidate_good(f.good)
	f.colony.capacity[f.good] += sign * f.throughput()
	if f.extracts():
		f.colony.extraction[f.good] = f.colony.extraction.get(f.good, 0.0) + sign * f.throughput()

static func _site_room(c : ColonyMarket, g : int, recipe : bool = false) -> float:
	if recipe:
		return INF
	return c.richness.get(g, 0.0) * EXTRACT_CAP_MULT - c.extraction.get(g, 0.0)

## Idle and able to act on an opening (used so emergence doesn't found redundant corporations).
func is_idle_funded() -> bool:
	return facilities.is_empty() and cash >= CAPEX * 1.5

func is_dead() -> bool:
	# A corporation only ever dissolves by going bankrupt; idle ones just wait for an opening.
	return broke_ticks >= INSOLVENT_AFTER

## Called when a corporation dissolves: its capacity leaves the market.
func dissolve() -> void:
	for f in facilities:
		_register(f, -1.0)
		f.colony.facility_count -= 1
		if f.extracts(): f.colony.extractor_count -= 1
	facilities.clear()

## Regional totals are asked for thousands of times a tick, so they're cached: `use` only changes when markets tick
## (the sim clears the cache each tick), `capacity` entries are dropped whenever a facility is (un)registered.
static var reg_cache : Dictionary = {}
## Outpost options per (empire, good), cached separately: they depend only on that good's regional supply/demand,
## the claims on that good and the month's precomputed outpost values, so a new facility only invalidates its own good.
static var out_cache : Dictionary = {}

static func invalidate_all() -> void:
	reg_cache.clear()
	out_cache.clear()

static func invalidate_good(g : int) -> void:
	for key in out_cache.keys():
		if key.get_slice(":", 1) == str(g):
			out_cache.erase(key)

static func _outpost_list(markets : Array[ColonyMarket], e, g : int) -> Array:
	var key : String = "%d:%d:%d" % [e.id, g, markets.size()]
	if out_cache.has(key):
		return out_cache[key]
	var opts : Array = []
	var unmet : float = _regional(markets, "use", g) * HEADROOM - _regional(markets, "capacity", g)
	var base : Array = world.outpost_base(e)
	for ri in base.size():
		var row : Array = base[ri]
		if row[1] != g:
			continue
		var c : ColonyMarket = row[0]
		var q : float = row[2]
		if unmet < q * 0.5:
			continue
		var absorb : float = minf(1.0, unmet * EXPORT_SHARE / q)
		var m : float = row[3] * q * absorb - UPKEEP
		var cl : Dictionary = c.intel_for(e)["claims"]
		var fee : float = CLAIM_PRICE * cl[g]["value"] if cl.has(g) else 0.0
		var cost : float = row[4] + fee
		if m > 0.0:
			# compared on the same scale as ordinary projects: payback / (OUTPOST_PAYBACK / PAYBACK_HORIZON);
			# index after every market option, in outpost order, so the merged walk orders exactly like one combined list
			opts.append([cost / m * PAYBACK_HORIZON / OUTPOST_PAYBACK, 1000000 + ri, {"pb": cost / m * PAYBACK_HORIZON / OUTPOST_PAYBACK, "c": c, "g": g, "recipe": false, "frontier": true, "cost": cost}])
	opts.sort()
	var out : Array = []
	for o in opts:
		o[2]["i"] = o[1]
		out.append(o[2])
	out_cache[key] = out
	return out

static var sub_prof : Dictionary = {}   # profiling: operate vs review time per kind (usec)

## Every new-facility and outpost option for a kind of corporation, best payback first (stable: ties keep scan order).
static func _opportunity_board(markets : Array[ColonyMarket], k : Kind, e = null) -> Array:
	var key : String = "board%d:%d:%d" % [k, markets.size(), e.id if e != null else -1]
	if reg_cache.has(key):
		return reg_cache[key]
	var tb : int = Time.get_ticks_usec()
	sub_prof["board_builds"] = sub_prof.get("board_builds", 0) + 1000   # shows as a count in the PROFILE line
	var opts : Array = []
	var as_recipe : bool = k == Kind.PRODUCER
	for c in markets:
		if c.facility_slots_free() <= 0:
			continue
		for g in Goods.ALL:
			if (as_recipe and not Goods.RECIPES.has(g)) or (not as_recipe and not Goods.is_raw(g)):
				continue
			var q : float = 1.0 if as_recipe else c.richness.get(g, 0.0)
			if q <= 0.0 or _site_room(c, g, as_recipe) < q:
				continue
			# Demand-pull: only build where regional use exceeds regional capacity.
			var unmet : float = _regional(markets, "use", g) * HEADROOM - _regional(markets, "capacity", g)
			if unmet < q * 0.5:
				continue
			# Local absorption: output beyond what this colony's market can use only sells at crashed prices.
			var absorb : float = minf(1.0, (c.use[g] * HEADROOM + unmet * EXPORT_SHARE) / q)
			var m : float = _unit_margin(c, g, as_recipe) * q * _input_availability(c, g, as_recipe) * absorb - UPKEEP
			var cost_n : float = CAPEX + _materials_cost(c, 1.0)
			if m > 0.0:
				opts.append({"pb": cost_n / m, "i": opts.size(), "c": c, "g": g, "recipe": as_recipe, "frontier": false, "cost": cost_n})
	# Native sort on [payback, scan index] pairs (fast, same order as the explicit tie-break), then reorder the options.
	var keys : Array = []
	for o in opts: keys.append([o["pb"], o["i"]])
	keys.sort()
	var sorted_opts : Array = []
	for kk in keys: sorted_opts.append(opts[kk[1]])
	opts = sorted_opts
	reg_cache[key] = opts
	sub_prof["board_build_time"] = sub_prof.get("board_build_time", 0) + (Time.get_ticks_usec() - tb)
	return opts

static func _regional(markets : Array[ColonyMarket], field : String, g : int) -> float:
	var key : String = "%s%d:%d" % [field, g, markets.size()]
	if reg_cache.has(key):
		return reg_cache[key]
	var t : float = 0.0
	for m in markets:
		t += m.get(field)[g]
	reg_cache[key] = t
	return t

func run(markets : Array[ColonyMarket]) -> void:
	if kind == Kind.FREIGHT:
		_run_freight(markets)
	elif kind == Kind.SURVEYOR:
		_run_survey(markets)
	else:
		var t0 : int = Time.get_ticks_usec()
		_run_facilities()
		var t1 : int = Time.get_ticks_usec()
		_review_and_expand(markets)
		var t2 : int = Time.get_ticks_usec()
		var kn : String = Kind.find_key(kind).to_lower()
		sub_prof[kn + "_operate"] = sub_prof.get(kn + "_operate", 0) + (t1 - t0)
		sub_prof[kn + "_review"] = sub_prof.get(kn + "_review", 0) + (t2 - t1)
		idle_ticks = idle_ticks + 1 if facilities.is_empty() else 0
	broke_ticks = broke_ticks + 1 if cash < 0.0 else 0

func _run_facilities() -> void:
	for f in facilities:
		var c : ColonyMarket = f.colony
		if f.building():
			_advance_build(f)
			if f.pending_level == 0:
				continue            # a new facility produces nothing until it's finished; an upgrading one keeps running
		if f.extracts():
			# Same discipline as producers: don't extract at a loss; idle until price recovers.
			if _unit_margin(c, f.good, false) <= 0.0:
				continue
			var q : float = c.richness.get(f.good, 0.0) * f.level_mult() * Military.output_factor(c)
			c.stock[f.good] += q
			cash += q * (c.price[f.good] - Goods.RAW_COST[f.good])
		else:
			var r : Dictionary = Goods.RECIPES[f.good]
			# Operating discipline: don't buy inputs at a loss; idle until the margin recovers.
			var idle : bool = _unit_margin(c, f.good, true) <= 0.0
			var runs : float = 0.0 if idle else f.level_mult() * Military.output_factor(c)
			for i in r["in"]:
				c.note_use(i, r["in"][i] * f.level_mult())           # desired input draw, even if the shelf is empty
				# Ask Freight for a few ticks' worth of inputs when the shelf runs low.
				var want : float = r["in"][i] * f.level_mult() * REQUEST_COVER
				if c.stock[i] < want:
					c.requests.append({"good": i, "qty": want - c.stock[i], "payer": self})
				if not idle:
					runs = minf(runs, c.stock[i] / r["in"][i])
			if runs <= 0.0:
				continue
			for i in r["in"]:
				var n : float = runs * r["in"][i]
				c.stock[i] -= n
				cash -= n * c.price[i]
			var out : float = runs * r["yield"]
			c.stock[f.good] += out
			cash += out * c.price[f.good]
	for f in facilities:
		cash -= f.upkeep()

static func _unit_margin(c : ColonyMarket, g : int, recipe : bool = false) -> float:
	if not recipe:
		return c.price[g] - Goods.RAW_COST[g]
	var r : Dictionary = Goods.RECIPES[g]
	var m : float = r["yield"] * c.price[g]
	for i in r["in"]:
		m -= r["in"][i] * c.price[i]
	return m

## 0..1: how well-stocked this colony is with the inputs a recipe needs.
static func _input_availability(c : ColonyMarket, g : int, recipe : bool = false) -> float:
	if not recipe:
		return 1.0
	var a : float = 1.0
	for i in Goods.RECIPES[g]["in"]:
		a = minf(a, c.stock[i] / (c.use[i] * ColonyMarket.COVER_TICKS * 0.5))
	return clampf(a, 0.05, 1.0)

func _facility_margin(f : Facility) -> float:
	return _unit_margin(f.colony, f.good, f.recipe_mode) * f.throughput() - f.upkeep()

func _review_and_expand(markets : Array[ColonyMarket]) -> void:
	for f in facilities.duplicate():
		f.losing_ticks = f.losing_ticks + 1 if _facility_margin(f) <= 0.0 else 0
		# Only shed capacity that is genuinely surplus; otherwise a price dip makes every
		# facility close in the same tick and the market swings straight into shortage.
		var surplus : bool = _regional(markets, "capacity", f.good) > _regional(markets, "use", f.good) * HEADROOM
		# Chronic losers close regardless: an idle facility still costs upkeep and maintenance demand.
		if (f.losing_ticks > CLOSE_AFTER and surplus) or f.losing_ticks > CLOSE_AFTER * 4:
			facilities.erase(f)
			_register(f, -1.0)
			f.colony.facility_count -= 1
			if f.extracts(): f.colony.extractor_count -= 1
	# In trouble: shed the worst loss-maker each month instead of riding idle plants into bankruptcy.
	if cash < 0.0:
		var worst : Facility = null
		var wm : float = 0.0
		for f in facilities:
			var fm : float = _facility_margin(f)
			if f.losing_ticks > 3 and fm < wm:
				wm = fm; worst = f
		if worst != null:
			facilities.erase(worst)
			_register(worst, -1.0)
			worst.colony.facility_count -= 1
			if worst.extracts(): worst.colony.extractor_count -= 1
	if cash < CAPEX * 0.6:
		return
	# Don't add capacity for a good while our own plants making it stand idle (inputs too dear, not demand too low).
	var idle_share : Dictionary = {}
	var n_by : Dictionary = {}
	for f in facilities:
		if f.building(): continue
		n_by[f.good] = n_by.get(f.good, 0) + 1
		if f.losing_ticks > 2: idle_share[f.good] = idle_share.get(f.good, 0) + 1
	for g in idle_share: idle_share[g] = float(idle_share[g]) / float(n_by[g])
	# Candidate actions: build a new facility, or upgrade one of ours. Pick the best payback.
	var best_payback : float = INF
	var best_new_c : ColonyMarket = null
	var best_new_g : int = -1
	var best_new_recipe : bool = false
	var best_up : Facility = null
	# New facilities and outposts: the options are the same for every corporation of a kind, so they're ranked once
	# (the "opportunity board", rebuilt whenever capacity or markets change) and each corporation takes the best
	# one it can afford that isn't a good its own plants are idling on.
	var best_frontier : bool = false
	var lists : Array = [_opportunity_board(markets, kind, empire)]
	if kind == Kind.EXTRACTOR and world != null and empire != null:
		for g in Goods.ALL:
			if Goods.is_raw(g): lists.append(_outpost_list(markets, empire, g))
	var ptr : Array = []
	ptr.resize(lists.size()); ptr.fill(0)
	while true:
		var bi : int = -1
		for li in lists.size():
			if ptr[li] >= lists[li].size(): continue
			var cand : Dictionary = lists[li][ptr[li]]
			if bi < 0:
				bi = li; continue
			var cur : Dictionary = lists[bi][ptr[bi]]
			if cand["pb"] < cur["pb"] or (cand["pb"] == cur["pb"] and cand["i"] < cur["i"]): bi = li
		if bi < 0:
			break
		var o : Dictionary = lists[bi][ptr[bi]]
		ptr[bi] += 1
		if o["pb"] >= best_payback:
			break
		if idle_share.get(o["g"], 0.0) > IDLE_BLOCK:
			continue
		if cash < o["cost"] * (1.2 if o["frontier"] else 1.5):
			continue
		best_payback = o["pb"]; best_new_c = o["c"]; best_new_g = o["g"]; best_new_recipe = o["recipe"]; best_frontier = o["frontier"]
		break
	for f in facilities:
		if f.level >= MAX_LEVEL or f.building() or idle_share.get(f.good, 0.0) > IDLE_BLOCK:
			continue
		var delta : float = f.throughput() / f.level_mult() * LEVEL_BONUS      # extra output from one more level
		if _site_room(f.colony, f.good, f.recipe_mode) < delta or cash < f.upgrade_cost():
			continue
		var unmet_u : float = _regional(markets, "use", f.good) * HEADROOM - _regional(markets, "capacity", f.good)
		if unmet_u < delta * 0.5:
			continue
		var absorb_u : float = minf(1.0, (f.colony.use[f.good] * HEADROOM + unmet_u * EXPORT_SHARE) / (f.throughput() + delta))
		var gain : float = _unit_margin(f.colony, f.good, f.recipe_mode) * delta * _input_availability(f.colony, f.good, f.recipe_mode) * absorb_u - UPKEEP * UPKEEP_GROWTH
		var cost_u : float = f.upgrade_cost() + _materials_cost(f.colony, f.upgrade_scale())
		if gain > 0.0 and cost_u / gain < best_payback:
			best_payback = cost_u / gain; best_up = f; best_new_c = null; best_frontier = false
	if best_payback >= PAYBACK_HORIZON:
		return
	if best_up != null:
		cash -= best_up.upgrade_cost()
		best_up.pending_level = best_up.level + 1
		best_up.build = {Goods.METAL: BUILD_METAL * best_up.upgrade_scale(), Goods.PARTS: BUILD_PARTS * best_up.upgrade_scale()}
		best_up.build_ticks = BUILD_MONTHS
		upgrades += 1
	elif best_new_c != null:
		if best_frontier:
			if not world.found_outpost(best_new_c, empire):
				return
			cash -= OUTPOST_COST
		cash -= CAPEX
		if not best_new_recipe:
			_buy_claim(best_new_c, best_new_g)
		var f := Facility.new(best_new_c, best_new_g, best_new_recipe)
		f.build = {Goods.METAL: BUILD_METAL + (OUTPOST_METAL if best_frontier else 0.0), Goods.PARTS: BUILD_PARTS + (OUTPOST_PARTS if best_frontier else 0.0)}
		f.build_ticks = BUILD_MONTHS
		facilities.append(f)
		_register(f, 1.0)          # planned capacity counts at once, so others don't pile onto the same gap
		best_new_c.facility_count += 1
		if f.extracts(): best_new_c.extractor_count += 1

## Materials for a project at colony c, at today's local prices.
static func _materials_cost(c : ColonyMarket, scale : float, outpost : bool = false) -> float:
	var metal : float = BUILD_METAL * scale + (OUTPOST_METAL if outpost else 0.0)
	var parts : float = BUILD_PARTS * scale + (OUTPOST_PARTS if outpost else 0.0)
	return metal * c.price[Goods.METAL] + parts * c.price[Goods.PARTS]

## Construction: take what's on the colony's shelf (paying for it), ask Freight for the rest.
func _advance_build(f : Facility) -> void:
	var c : ColonyMarket = f.colony
	f.build_ticks = maxi(0, f.build_ticks - 1)
	for g in f.build.keys():
		var want : float = f.build[g]
		c.note_use(g, want / float(BUILD_MONTHS))      # construction is demand like any other
		var take : float = minf(c.stock[g], want)
		if take < want:
			c.requests.append({"good": g, "qty": want - take, "payer": self})
		c.stock[g] -= take
		cash -= take * c.price[g]
		f.build[g] = want - take
		if f.build[g] <= 0.01:
			f.build.erase(g)
	if not f.building() and f.pending_level > 0:
		_register(f, -1.0)
		f.level = f.pending_level
		f.pending_level = 0
		_register(f, 1.0)

func ship_capacity() -> float:
	return SHIP_CAPACITY * pow(CLASS_CAP_MULT, ship_class - 1)

## route_ok answers are fixed for the month; this run asks for the same few pairs thousands of times, so memoize with an int key.
var _route_memo : Dictionary = {}
func _route_ok_memo(a : ColonyMarket, b : ColonyMarket) -> bool:
	var key : int = a.get_instance_id() * 1000003 + b.get_instance_id()
	if _route_memo.has(key):
		return _route_memo[key]
	var ok : bool = world.route_ok(empire, a, b)
	_route_memo[key] = ok
	return ok

var _tariff_memo_d : Dictionary = {}
func _tariff_memo(a : ColonyMarket, b : ColonyMarket) -> float:
	var key : int = a.owner.id * 64 + b.owner.id
	if _tariff_memo_d.has(key):
		return _tariff_memo_d[key]
	var t : float = world.tariff_rate(a, b)
	_tariff_memo_d[key] = t
	return t

func _run_freight(markets : Array[ColonyMarket]) -> void:
	last_moves = []
	_route_memo.clear()
	_tariff_memo_d.clear()
	var budget : float = float(1 + ships) * SHIP_TIME   # fleet sailing time this tick; short lanes allow many deliveries per ship
	var total_budget : float = budget
	var cap : float = ship_capacity()
	var done : int = 0
	var moved_before : float = moved
	var last_rate : float = -1.0
	# Contracts first: deliver inputs that producers have asked for (producer pays the shipping fee).
	var n : int = markets.size()
	rr = (rr + 7) % maxi(n, 1)    # rotate who gets served first, so low-index colonies don't hog the fleet
	for di in n:
		var dest : ColonyMarket = markets[(di + rr) % n]
		if budget <= 0.0:
			break
		for req in dest.requests:
			if budget <= 0.0:
				break
			if not dest.port_free():
				break
			var g : int = req["good"]
			var src : ColonyMarket = null
			for m in markets:
				if m != dest and m.port_free() and m.stock[g] >= 8.0 and (src == null or m.stock[g] > src.stock[g]):
					if world != null and not _route_ok_memo(m, dest):
						continue                     # closed: no treaty with an empire at either end or along the way (checked last: only for a would-be pick)
					src = m
			if src == null:
				continue
			var q : float = minf(minf(req["qty"], cap), src.stock[g] * 0.5)
			if q <= 0.0:
				continue
			var fee : float = SHIP_COST * _dist(src, dest, markets) * q
			var ctrip : float = _dist(src, dest, markets) + LOAD_TIME
			budget -= ctrip
			last_rate = (q * (dest.price[g] - src.price[g]) + fee) / ctrip
			src.port_used += 1; dest.port_used += 1
			src.stock[g] -= q; dest.stock[g] += q
			req["qty"] -= q
			cash += q * (dest.price[g] - src.price[g]) + fee
			if req["payer"] != null:
				req["payer"].cash -= fee
			if world != null and src.owner != dest.owner:
				var customs : float = world.tariff_rate(src, dest) * q * dest.price[g]
				cash -= customs
				world.record_trade(src, dest, q * dest.price[g], customs)
			moved += q
			done += 1
			last_moves.append({"from": src, "to": dest, "good": g, "qty": q})
	# Candidate lanes: for each good, cheapest sources x dearest destinations (keeps it O(n log n) at 100 colonies).
	var sources : Dictionary = {}
	var dests : Dictionary = {}
	for g in Goods.ALL:
		var by_price : Array = markets.duplicate()
		by_price.sort_custom(func(x, y): return x.price[g] < y.price[g])
		sources[g] = by_price.slice(0, 6)
		by_price.reverse()
		dests[g] = by_price.slice(0, 6)
	while budget > 0.0:
		var best_m : float = 0.0
		var best : Array = []
		for g in Goods.ALL:
			for a in sources[g]:
				if a.stock[g] < 6.0 or not a.port_free():
					continue
				for b in dests[g]:
					if a == b or not b.port_free():
						continue
					var m : float = b.price[g] - a.price[g] - SHIP_COST * _dist(a, b, markets)
					if a.owner != b.owner and world != null:
						m -= _tariff_memo(a, b) * b.price[g]   # customs paid to the destination's empire
					if m > best_m:
						if world != null and not _route_ok_memo(a, b):
							continue                  # closed: no treaty at either end or along the way (checked only for a would-be pick)
						best_m = m; best = [g, a, b]
		if best_m <= 0.3:
			break
		var g : int = best[0]; var a : ColonyMarket = best[1]; var b : ColonyMarket = best[2]
		var q : float = minf(minf(a.stock[g] * 0.5, cap), maxf(0.0, cash / a.price[g]))
		if q <= 0.0:
			break
		var trip : float = _dist(a, b, markets) + LOAD_TIME
		budget -= trip
		last_rate = q * best_m / trip
		a.port_used += 1; b.port_used += 1
		a.stock[g] -= q; b.stock[g] += q
		cash += q * best_m
		if a.owner != b.owner and world != null:
			world.record_trade(a, b, q * b.price[g], world.tariff_rate(a, b) * q * b.price[g])
		moved += q
		done += 1
		last_moves.append({"from": a, "to": b, "good": g, "qty": q})
	utilisation = 0.8 * utilisation + 0.2 * (1.0 - maxf(budget, 0.0) / total_budget)
	# Fill: how full the holds were on the voyages made. Half-empty holds mean capacity isn't the bottleneck.
	if done > 0:
		fill = 0.8 * fill + 0.2 * minf((moved - moved_before) / (float(done) * cap), 1.0)
	if last_rate >= 0.0:
		marg_rate = 0.9 * marg_rate + 0.1 * last_rate
	elif budget > 0.0:
		marg_rate *= 0.9    # lanes ran dry before the budget did: extra ships earn nothing
	cash -= SHIP_UPKEEP * pow(CLASS_UPKEEP_MULT, ship_class - 1) * (1 + ships)
	# Fleet grows only while it is actually busy, and shrinks when idle.
	# No fleet cap: cash and utilisation alone decide.
	# Brake: a new ship must pay for itself (same payback rule as facilities), judged on the marginal delivery, not the average.
	var ship_upkeep : float = SHIP_UPKEEP * pow(CLASS_UPKEEP_MULT, ship_class - 1)
	var marg_gain : float = marg_rate * SHIP_TIME - ship_upkeep
	if cash > CAPEX * 3.0 and utilisation > 0.85 and fill > GROW_FILL and marg_gain > 0.0 and CAPEX / marg_gain < PAYBACK_HORIZON:
		# Grow by whichever is cheaper per unit of cargo: one more ship, or refitting the whole fleet to the next class.
		var refit : float = CAPEX * float(ships) * CLASS_REFIT_COST * float(ship_class)
		var refit_per_cap : float = refit / (float(ships) * ship_capacity() * (CLASS_CAP_MULT - 1.0)) if ships > 0 else INF
		var ship_per_cap : float = CAPEX / ship_capacity()
		if ship_class < MAX_SHIP_CLASS and ships > 0 and refit_per_cap < ship_per_cap and cash > refit * 2.0:
			cash -= refit; ship_class += 1
		else:
			cash -= CAPEX; ships += 1
	elif utilisation < 0.25 and ships > 0:
		ships -= 1

static func _dist(a : ColonyMarket, b : ColonyMarket, markets : Array[ColonyMarket]) -> float:
	# Within one star system: a short hop. Between systems: map-space distance (px) -> lane cost units.
	if a.system != null and a.system == b.system:
		return INTRA_SYSTEM_DIST
	return 1.0 + a.position.distance_to(b.position) / 200.0


# ---------------------------------------------------------------- Surveying
var survey_jobs : Array = []      # [{"target": ColonyMarket, "eta": ticks left}]
var months_since_buy : int = 0
var ships_lost : int = 0

## Bigger bodies take longer: ~6 months for an Earth-sized world, ~1.5 years for a giant; belts by the size of their ring.
static func survey_months(c : ColonyMarket) -> float:
	return minf(2.0 + 4.0 * pow(maxf(c.body_radius, 0.2), 0.6), 24.0)

static func loss_chance(c : ColonyMarket) -> float:
	var p : float = SURVEY_LOSS
	if c.planet_label.begins_with("Asteroid") or c.planet_label.begins_with("Debris"): p += SURVEY_LOSS_BELT
	elif c.body_radius > 5.0: p += SURVEY_LOSS_GIANT
	return p
var surveys_done : int = 0
var claims_sold : int = 0

## Claims on a body live in the knowledge of the empire that found them: the owner's for a settled colony,
## otherwise the buyer's own empire (it can only build outposts where its own surveyors looked).
func _claims_at(c : ColonyMarket) -> Dictionary:
	var e = c.owner if (c.settled and c.owner != null) else empire
	if e == null:
		return c.claims
	return c.intel_for(e)["claims"]

func claim_fee(c : ColonyMarket, g : int) -> float:
	var cl : Dictionary = _claims_at(c)
	return CLAIM_PRICE * cl[g]["value"] if cl.has(g) else 0.0

## The first extractor to work a surveyed deposit buys the claim from the surveyor who found it.
func _buy_claim(c : ColonyMarket, g : int) -> void:
	var cl : Dictionary = _claims_at(c)
	if not cl.has(g):
		return
	var fee : float = CLAIM_PRICE * cl[g]["value"]
	var owner : Corporation = cl[g]["owner"]
	cash -= fee
	owner.cash += fee
	owner.claims_sold += 1
	cl.erase(g)

func unsold_claims() -> int:
	var n : int = 0
	if world == null or empire == null:
		return 0
	for c in world.frontier:
		if not c.intel.has(empire.id):
			continue
		var cl : Dictionary = c.intel[empire.id]["claims"]
		for g in cl:
			if cl[g]["owner"] == self: n += 1
	return n

func _run_survey(markets : Array[ColonyMarket]) -> void:
	last_moves = []
	months_since_buy += 1
	for j in survey_jobs.duplicate():
		j["eta"] -= 1.0
		if j["eta"] <= 0.0:
			survey_jobs.erase(j)
			if randf() < loss_chance(j["target"]):
				ships_lost += 1
				if ships > 0:
					ships -= 1            # ship and findings lost
				else:
					cash -= SURVEY_SHIP_COST * 0.5   # the last vessel is replaced at a cost
				continue
			_complete_survey(j["target"])
	var free : int = (1 + ships) - survey_jobs.size()
	for i in free:
		var t : ColonyMarket = _pick_survey_target(markets)
		if t == null:
			break
		survey_jobs.append({"target": t, "eta": survey_months(t) + _dist(t, world.nearest_settled(t, empire), markets) / SHIP_TIME})
	cash -= SURVEY_UPKEEP * (1 + ships)
	# Grow on speculation (few unsold finds) or on paid work (a backlog of state orders bigger than the fleet can clear in a year).
	var ordered : int = empire.survey_backlog if empire != null else 0
	var per_ship_year : float = 12.0 / (SURVEY_MONTHS + 1.0)
	if months_since_buy >= SHIP_BUY_MONTHS and cash > SURVEY_SHIP_COST * 4.0 and (unsold_claims() < MAX_UNSOLD_CLAIMS or ordered > (1 + ships) * per_ship_year):
		cash -= SURVEY_SHIP_COST
		ships += 1
		months_since_buy = 0
	elif cash < SURVEY_SHIP_COST and ships > 0 and ordered == 0:
		ships -= 1                       # sell a ship rather than go broke
		cash += SURVEY_SHIP_COST * 0.5

## Surveyors can't see true richness: an unsurveyed planet is worth a flat prior, a surveyed one a little
## less each time (they can't tell how much is left). Value per month of ship time, nearest first.
## The survey board (one per empire): every body the empire may survey, ranked by value per month of ship time, built once
## and reused until something that affects it changes (a survey completes, space is charted, a colony is founded, a new month).
static func _build_survey_board(markets : Array[ColonyMarket], e) -> void:
	var rows : Array = []
	var i : int = 0
	for c in world.known_frontier(e) + markets.filter(func(m): return m.owner == e):
		var rich : Dictionary = c.known_rich(e)
		var known : float = 0.0
		for g in rich: known += rich[g]
		var n : int = c.surveys_by(e)
		var ev : float = 1.0 if n == 0 else 0.4 * known / float(n)
		var v : float = ev / (survey_months(c) + _dist(c, world.nearest_settled(c, e), markets) / SHIP_TIME)
		if v > 0.0:
			rows.append([v, i, c])
		i += 1
	# Best first; equal values keep scan order (same pick as a linear scan with a strict '>').
	rows.sort_custom(func(a, b): return a[0] > b[0] or (a[0] == b[0] and a[1] < b[1]))
	e.survey_board = rows
	e.survey_board_valid = true

## Surveyors can't see true richness: an unsurveyed planet is worth a flat prior, a surveyed one a little
## less each time (they can't tell how much is left). Each free ship takes the best body its empire isn't already surveying.
func _pick_survey_target(markets : Array[ColonyMarket]) -> ColonyMarket:
	if not empire.survey_board_valid:
		_build_survey_board(markets, empire)
	var busy : Dictionary = {}
	for k in world.corps:
		if k.kind == Kind.SURVEYOR and k.empire == empire:
			for j in k.survey_jobs: busy[j["target"]] = true
	for row in empire.survey_board:
		if not busy.has(row[2]):
			return row[2]
	return null

func _complete_survey(t : ColonyMarket) -> void:
	var info : Dictionary = t.intel_for(empire)
	if info["surveys"] == 0:
		# Paid by the state: an ordered survey at the order price, otherwise the small standing contract fee.
		var fee : float = SURVEY_CONTRACT
		if empire.survey_backlog > 0:
			empire.survey_backlog -= 1
			fee = world.SURVEY_ORDER_PRICE
		cash += fee
		empire.treasury -= fee
	t.surveys += 1
	info["surveys"] += 1
	empire.survey_board_valid = false
	surveys_done += 1
	for g in t.hidden_richness:
		var r : float = t.hidden_richness[g]
		var amount : float = r * randf_range(0.4, 1.0) * exp(-SURVEY_DECAY / (r * 5.0) * info["found"].get(g, 0.0)) * SURVEY_YIELD
		var inc : float = t.reveal(empire, g, amount)
		if inc > 0.0 and t.extraction.get(g, 0.0) <= 0.0:
			var cl : Dictionary = info["claims"]
			var prev : float = cl[g]["value"] if cl.has(g) and cl[g]["owner"] == self else 0.0
			cl[g] = {"owner": self, "value": prev + inc}
			invalidate_good(g)