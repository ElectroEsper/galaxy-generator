class_name Military
extends RefCounted
## Abstract military: each empire has a strength number, bought from its treasury with Metal and Parts taken from its
## capital's market (so armament competes with civilians and construction for goods), and kept up with cash and Parts.
## Wars are fought monthly along fronts (systems near the enemy's): Lanchester-style attrition, occupation of enemy front
## systems by the side with the upper hand, war exhaustion, and peace terms that cede occupied systems.

# Army size: an empire keeps the army whose upkeep is this share of its (smoothed) monthly tax income, x militarism
const SHARE_UNMET := 0.0             # no contact with anyone: no military (a lone empire behaves exactly as before)
const SHARE_PEACE := 0.10            # x (1 + threat, capped)
const SHARE_ARMING := 0.25           # while the planner has decided to arm (ARMING_YEARS)
const SHARE_WAR := 0.40
const THREAT_CAP := 2.0
const BUILD_RATE := 0.05             # of the target, per month
const DEMOBILIZE := 0.02             # of the excess, per month
const ARMING_YEARS := 5
# Cost of one point of strength, and its upkeep
const UNIT_CASH := 20.0
const UNIT_METAL := 2.0
const UNIT_PARTS := 1.0
const UPKEEP_CASH := 0.5             # per strength per month
const UPKEEP_PARTS := 0.01           # per strength per month (spares)
const UNPAID_DECAY := 0.02           # strength lost per month when upkeep can't be met
# Combat
const ATTRITION := 0.01              # each side loses this x the other's committed strength per month
const COMMIT := 0.7                  # share of strength committed to a war (the rest garrisons elsewhere)
const OCCUPY_RATE := 0.25            # monthly chance to take a front system, x (superiority - 0.55) / 0.45
const FRONT_OUTPUT := 0.8            # output multiplier for colonies in front systems
const OCCUPIED_OUTPUT := 0.5         # ... and in occupied systems
const OCCUPIED_POP_LOSS := 0.005     # per month in occupied systems
# Exhaustion (0..100)
const EXH_PER_MONTH := 0.4
const EXH_LOSS_WEIGHT := 60.0        # x share of strength lost this month
const EXH_PER_OCCUPIED := 4.0        # when one of its systems is occupied
const EXH_CAPITULATE := 100.0
const EXH_RECOVER := 1.0
const TRUCE_YEARS := 15             # no new war between the same pair for this long after a peace             # per month at peace

# ---------------------------------------------------------------- Monthly
static func monthly(sim) -> void:
	for e in sim.empires:
		_fund(sim, e)
	for w in sim.wars.duplicate():
		_fight(sim, w)
	for e in sim.empires:
		if not sim.wars.any(func(w): return w["a"] == e or w["b"] == e):
			e.exhaustion = maxf(0.0, e.exhaustion - EXH_RECOVER)

## Share of smoothed monthly income the empire is willing to spend on upkeep: sets its target army size.
static func _share(sim, e) -> float:
	var m : float = 0.3 + 1.4 * Personality.t(e, "militarism")
	if sim.wars.any(func(w): return w["a"] == e or w["b"] == e):
		return SHARE_WAR * m
	if sim.tick_count / 12 < e.arming_until:
		return SHARE_ARMING * m
	var met : bool = sim.empires.any(func(x): return x != e and sim._rel(e, x)["met"])
	return SHARE_PEACE * m * (1.0 + minf(e.max_threat, THREAT_CAP)) if met else SHARE_UNMET

## Target strength: what the empire's chosen share of income can keep up.
static func target_strength(sim, e) -> float:
	var cap : ColonyMarket = e.capital
	var upkeep_unit : float = UPKEEP_CASH + UPKEEP_PARTS * cap.price[Goods.PARTS]
	return _share(sim, e) * e.avg_tax / upkeep_unit

## Monthly: pay upkeep, then build toward the target (paid from the treasury, goods from the capital) or stand down.
static func _fund(sim, e) -> void:
	var cap : ColonyMarket = e.capital
	e.avg_tax = 0.95 * e.avg_tax + 0.05 * e.month_tax
	e.month_tax = 0.0
	# Upkeep
	if e.strength > 0.0:
		var parts_need : float = e.strength * UPKEEP_PARTS
		_note(sim, e, Goods.PARTS, parts_need)
		var bought : Array = _buy(sim, e, Goods.PARTS, parts_need)
		var cost : float = e.strength * UPKEEP_CASH + bought[1]
		e.treasury -= cost
		e.mil_spent += cost
		if bought[0] < parts_need * 0.99 or e.treasury < 0.0:
			e.strength *= 1.0 - UNPAID_DECAY
	var target : float = target_strength(sim, e)
	e.target_strength = target
	if e.strength > target * 1.1:
		e.strength -= (e.strength - target) * DEMOBILIZE    # stand down slowly
		return
	if e.strength >= target or e.treasury <= 0.0:
		return
	# Build: at most BUILD_RATE of the target per month, and no more than a tenth of the treasury
	var unit_est : float = UNIT_CASH + UNIT_METAL * cap.price[Goods.METAL] + UNIT_PARTS * cap.price[Goods.PARTS]
	var n : float = minf(target - e.strength, maxf(target * BUILD_RATE, 1.0))
	n = minf(n, e.treasury * 0.1 / unit_est)
	var avail_m : float = _available(sim, e, Goods.METAL); var avail_p : float = _available(sim, e, Goods.PARTS)
	_note(sim, e, Goods.METAL, n * UNIT_METAL); _note(sim, e, Goods.PARTS, n * UNIT_PARTS)
	n = minf(n, minf(avail_m / UNIT_METAL, avail_p / UNIT_PARTS))
	if n <= 0.0:
		return
	var cost : float = n * UNIT_CASH + _buy(sim, e, Goods.METAL, n * UNIT_METAL)[1] + _buy(sim, e, Goods.PARTS, n * UNIT_PARTS)[1]
	e.treasury -= cost
	e.mil_spent += cost
	e.strength += n

## The empire's own colonies, cheapest first for good g (ties by name, for determinism).
static func _sources(sim, e, g : int) -> Array:
	var own : Array = sim._empire_colonies(e).duplicate()
	own.sort_custom(func(a, b): return a.price[g] < b.price[g] or (a.price[g] == b.price[g] and a.name < b.name))
	return own

static func _available(sim, e, g : int) -> float:
	var t : float = 0.0
	for c in sim._empire_colonies(e): t += c.stock[g]
	return t

## Register military demand across the empire (spread by population), so prices and producers respond.
static func _note(sim, e, g : int, qty : float) -> void:
	var own : Array = sim._empire_colonies(e)
	var pop : float = 0.0
	for c in own: pop += c.pop
	if pop <= 0.0: return
	for c in own: c.note_use(g, qty * c.pop / pop)

## Buy up to qty of g from the empire's colonies, cheapest first. Returns [bought, cost].
static func _buy(sim, e, g : int, qty : float) -> Array:
	var got : float = 0.0
	var cost : float = 0.0
	for c in _sources(sim, e, g):
		if got >= qty: break
		var take : float = minf(c.stock[g], qty - got)
		if take <= 0.0: continue
		c.stock[g] -= take
		got += take
		cost += take * c.price[g]
	return [got, cost]

# ---------------------------------------------------------------- War
## Systems of `side` within border range of the enemy's (its front), excluding ones the enemy already occupies.
static func fronts(sim, side, enemy) -> Array:
	var mine : Array = sim.all_systems().filter(func(s): return s.owner == side and s.occupier == null)
	var theirs : Array = sim.all_systems().filter(func(s): return s.owner == enemy)
	return mine.filter(func(s): return theirs.any(func(t): return t.position.distance_to(s.position) <= sim.BORDER_RANGE))

## parent: the war this one joins (an ally answering a call to arms), or null for a war of choice.
static func declare(sim, a, b, parent = null) -> void:
	var r : Dictionary = sim._rel(a, b)
	r["trade_treaty"] = false; r["passage"] = false
	r["stance"] = "embargo"
	var w : Dictionary = {"a": a, "b": b, "start": sim.tick_count, "peak_a": a.strength, "peak_b": b.strength, "parent": parent}
	sim.wars.append(w)
	if parent == null:
		a.wars_started.append(sim.tick_count / 12)
		Alliances.adjust_trust(sim, b, a, Alliances.TRUST_ATTACKED)
		Alliances.adjust_reputation(sim, a, Alliances.REP_WAR_OF_CHOICE, "attacked %s" % b.name)
		sim._event("WAR: %s declares war on %s (strength %d vs %d)" % [a.name, b.name, a.strength, b.strength])
		Alliances.call_to_arms(sim, a, b, w)
	sim.on_system_claimed()   # routes change with stances

static func _fight(sim, w : Dictionary) -> void:
	var a = w["a"]; var b = w["b"]
	var fa : Array = fronts(sim, a, b)
	var fb : Array = fronts(sim, b, a)
	a.exhaustion += EXH_PER_MONTH; b.exhaustion += EXH_PER_MONTH
	if fa.is_empty() and fb.is_empty():
		_check_capitulation(sim, w)
		return                      # no shared front: only blockade and exhaustion
	# Allies who joined this war (against a, on b's side) fight alongside b on b's front
	# (only those with no front of their own against a: they send forces to b's front instead)
	var helpers : Array = sim.wars.filter(func(x): return x.get("parent") == w and fronts(sim, x["a"], a).is_empty() and fronts(sim, a, x["a"]).is_empty()).map(func(x): return x["a"])
	var sa : float = a.strength * COMMIT
	var sb : float = b.strength * COMMIT
	var sh : float = 0.0
	for h in helpers: sh += h.strength * COMMIT * 0.5
	var la : float = minf(a.strength, ATTRITION * (sb + sh))
	var lb_total : float = ATTRITION * sa
	var lb : float = minf(b.strength, lb_total * sb / maxf(sb + sh, 0.001))
	for h in helpers:
		var lh : float = minf(h.strength, lb_total * h.strength * COMMIT * 0.5 / maxf(sb + sh, 0.001))
		h.strength -= lh
		h.exhaustion += EXH_LOSS_WEIGHT * lh / maxf(h.strength + lh, 1.0)
	a.strength -= la; b.strength -= lb
	sb += sh
	w["peak_a"] = maxf(w["peak_a"], a.strength); w["peak_b"] = maxf(w["peak_b"], b.strength)
	a.exhaustion += EXH_LOSS_WEIGHT * la / maxf(w["peak_a"], 1.0)
	b.exhaustion += EXH_LOSS_WEIGHT * lb / maxf(w["peak_b"], 1.0)
	var sup : float = sa / maxf(sa + sb, 0.001)        # a's share of the committed strength
	if sup > 0.55:
		_occupy(sim, a, b, fb, (sup - 0.55) / 0.45)
	elif sup < 0.45:
		_occupy(sim, b, a, fa, (0.45 - sup) / 0.45)
	_check_capitulation(sim, w)

## The stronger side may liberate its own occupied systems first, then take one of the enemy's front systems.
static func _occupy(sim, winner, loser, loser_fronts : Array, edge : float) -> void:
	if randf() >= OCCUPY_RATE * edge:
		return
	var liberate : Array = sim.all_systems().filter(func(s): return s.owner == winner and s.occupier == loser)
	if not liberate.is_empty():
		liberate[0].occupier = null
		sim._event("%s liberates %s from %s" % [winner.name, liberate[0].name, loser.name])
		sim.on_system_claimed()
		return
	var targets : Array = loser_fronts.filter(func(s): return not s.bodies.has(loser.capital))
	if targets.is_empty():
		return
	var t = targets[randi() % targets.size()]
	t.occupier = winner
	loser.exhaustion += EXH_PER_OCCUPIED
	sim._event("%s occupies %s (%s)" % [winner.name, t.name, loser.name])
	sim.on_system_claimed()

static func _check_capitulation(sim, w : Dictionary) -> void:
	for side in [w["a"], w["b"]]:
		if side.exhaustion >= EXH_CAPITULATE:
			var other = w["b"] if side == w["a"] else w["a"]
			sim._event("%s capitulates to %s" % [side.name, other.name])
			make_peace(sim, w)
			return

## Peace: every occupied system changes hands to its occupier (colonies, people, deposits); both sides keep what remains.
static func make_peace(sim, w : Dictionary) -> void:
	var a = w["a"]; var b = w["b"]
	var ceded : Array = []
	for s in sim.all_systems():
		if s.occupier != null and ((s.owner == a and s.occupier == b) or (s.owner == b and s.occupier == a)):
			var winner = s.occupier
			var loser = s.owner
			s.owner = winner
			s.occupier = null
			for c in s.bodies:
				if c.owner == loser:
					var mine : Dictionary = c.intel_for(winner)["rich"]
					for g in c.richness:
						mine[g] = maxf(mine.get(g, 0.0), c.richness[g])   # the winner inherits what the colony knew
					c.owner = winner
					c.richness = mine
			winner.known[s] = true
			ceded.append("%s -> %s" % [s.name, winner.name])
	sim.wars.erase(w)
	for child in sim.wars.duplicate():
		if child.get("parent") == w:
			make_peace(sim, child)          # allies who joined this war make peace with it
	var gain_a : int = ceded.filter(func(c): return c.ends_with(a.name)).size()
	var gain_b : int = ceded.size() - gain_a
	a.systems_taken += gain_a; b.systems_taken += gain_b
	if gain_a > gain_b: Personality.on_peace(sim, a, b, gain_a)
	elif gain_b > gain_a: Personality.on_peace(sim, b, a, gain_b)
	var r : Dictionary = sim._rel(a, b)
	r["stance"] = "hostile"
	r["truce_until"] = sim.tick_count / 12 + TRUCE_YEARS
	r["opinion"] = maxf(r["opinion"], -60.0)
	sim._event("PEACE between %s and %s after %d years%s" % [a.name, b.name, (sim.tick_count - w["start"]) / 12, (": " + ", ".join(ceded)) if not ceded.is_empty() else " (white peace)"])
	sim._clear_empire_caches()
	sim.on_system_claimed()

## Output multiplier for a colony: reduced at the front and under occupation.
static func output_factor(c : ColonyMarket) -> float:
	var s = c.system
	if s == null or Corporation.world == null or Corporation.world.wars.is_empty():
		return 1.0
	if s.occupier != null:
		return OCCUPIED_OUTPUT
	if s.at_front:
		return FRONT_OUTPUT
	return 1.0
