class_name Military
extends RefCounted
## Abstract military: each empire has a strength number, bought from its treasury with Metal and Parts taken from its
## capital's market (so armament competes with civilians and construction for goods), and kept up with cash and Parts.
## Wars are fought monthly along fronts (systems near the enemy's): Lanchester-style attrition, occupation of enemy front
## systems by the side with the upper hand, war exhaustion, and peace terms that cede occupied systems.

# Spending: share of the empire's monthly tax income put into the military
const SHARE_UNMET := 0.0             # no contact with anyone: no military (a lone empire behaves exactly as before)
const SHARE_PEACE := 0.05
const SHARE_ARMING := 0.20           # while the planner has decided to arm (ARMING_YEARS)
const SHARE_WAR := 0.35
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

static func _share(sim, e) -> float:
	if sim.wars.any(func(w): return w["a"] == e or w["b"] == e):
		return SHARE_WAR
	if sim.tick_count / 12 < e.arming_until:
		return SHARE_ARMING
	var met : bool = sim.empires.any(func(x): return x != e and sim._rel(e, x)["met"])
	return SHARE_PEACE if met else SHARE_UNMET

## Pay upkeep, then buy new strength with this month's military budget (goods from the capital's shelves, at its prices).
static func _fund(sim, e) -> void:
	var cap : ColonyMarket = e.capital
	# Upkeep
	if e.strength > 0.0:
		var cash_need : float = e.strength * UPKEEP_CASH
		var parts_need : float = e.strength * UPKEEP_PARTS
		cap.note_use(Goods.PARTS, parts_need)
		var parts_got : float = minf(cap.stock[Goods.PARTS], parts_need)
		cap.stock[Goods.PARTS] -= parts_got
		var cost : float = cash_need + parts_got * cap.price[Goods.PARTS]
		e.treasury -= cost
		e.mil_spent += cost
		if parts_got < parts_need * 0.99 or e.treasury < 0.0:
			e.strength *= 1.0 - UNPAID_DECAY
	# New strength
	var budget : float = _share(sim, e) * e.month_tax
	e.month_tax = 0.0
	if budget <= 0.0 or e.treasury <= 0.0:
		return
	budget = minf(budget, e.treasury)
	var unit : float = UNIT_CASH + UNIT_METAL * cap.price[Goods.METAL] + UNIT_PARTS * cap.price[Goods.PARTS]
	var n : float = budget / unit
	cap.note_use(Goods.METAL, n * UNIT_METAL)
	cap.note_use(Goods.PARTS, n * UNIT_PARTS)
	n = minf(n, minf(cap.stock[Goods.METAL] / UNIT_METAL, cap.stock[Goods.PARTS] / UNIT_PARTS))
	if n <= 0.0:
		return
	cap.stock[Goods.METAL] -= n * UNIT_METAL
	cap.stock[Goods.PARTS] -= n * UNIT_PARTS
	e.treasury -= n * unit
	e.mil_spent += n * unit
	e.strength += n

# ---------------------------------------------------------------- War
## Systems of `side` within border range of the enemy's (its front), excluding ones the enemy already occupies.
static func fronts(sim, side, enemy) -> Array:
	var mine : Array = sim.all_systems().filter(func(s): return s.owner == side and s.occupier == null)
	var theirs : Array = sim.all_systems().filter(func(s): return s.owner == enemy)
	return mine.filter(func(s): return theirs.any(func(t): return t.position.distance_to(s.position) <= sim.BORDER_RANGE))

static func declare(sim, a, b) -> void:
	var r : Dictionary = sim._rel(a, b)
	r["trade_treaty"] = false; r["passage"] = false
	r["stance"] = "embargo"
	sim.wars.append({"a": a, "b": b, "start": sim.tick_count, "peak_a": a.strength, "peak_b": b.strength})
	sim._event("WAR: %s declares war on %s (strength %d vs %d)" % [a.name, b.name, a.strength, b.strength])
	sim.on_system_claimed()   # routes change with stances

static func _fight(sim, w : Dictionary) -> void:
	var a = w["a"]; var b = w["b"]
	var fa : Array = fronts(sim, a, b)
	var fb : Array = fronts(sim, b, a)
	a.exhaustion += EXH_PER_MONTH; b.exhaustion += EXH_PER_MONTH
	if fa.is_empty() and fb.is_empty():
		_check_capitulation(sim, w)
		return                      # no shared front: only blockade and exhaustion
	var sa : float = a.strength * COMMIT
	var sb : float = b.strength * COMMIT
	var la : float = minf(a.strength, ATTRITION * sb)
	var lb : float = minf(b.strength, ATTRITION * sa)
	a.strength -= la; b.strength -= lb
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
