class_name Alliances
extends RefCounted
## Defensive pacts (mutual) and guarantees (one-way protection of a smaller empire).
##
## Empires form them through the GOAP planner when they share a threat (pacts) or want a buffer state between themselves
## and their main threat (guarantees). When an empire is attacked, its pact partners and guarantors are called to arms
## and each decides, by personality and exhaustion, whether to honour the call; breaking a promise costs trust.
## Attackers count the defender's likely allies before declaring war, which is what makes alliances deter.

const ALLY_WEIGHT := 0.6            # share of an ally's strength an attacker expects to face
const PACT_MIN_YEARS := 10          # pacts last at least this long before they can lapse
const LAPSE_THREAT := 0.8           # a pact lapses when neither side fears anyone this much any more
const BETRAYAL_OPINION := 30.0      # opinion lost when an ally refuses the call
const JOIN_EXHAUSTION := 40.0       # too exhausted to join above this
const BETRAYAL_YEARS := 15          # no new pact or guarantee between betrayer and betrayed for this long

# ---------------------------------------------------------------- Queries
static func has_pact(sim, a, b) -> bool:
	return sim._rel(a, b).get("pact", false)

static func guarantees(g, x) -> bool:
	return g.guarantees.has(x.id)

## Empires bound to defend x: pact partners and guarantors.
static func defenders_of(sim, x) -> Array:
	return sim.empires.filter(func(y): return y != x and (has_pact(sim, x, y) or guarantees(y, x)))

## The strength an attacker expects to face when attacking x: x's own plus a share of its defenders'.
static func effective_strength(sim, x, attacker) -> float:
	var s : float = x.strength
	for y in defenders_of(sim, x):
		if y != attacker and not has_pact(sim, y, attacker):
			s += ALLY_WEIGHT * y.strength
	return s

# ---------------------------------------------------------------- Acceptance
## x accepts a pact from e if it fears someone too (ideally the same empire), doesn't dislike e, and isn't at war with it.
static func accepts_pact(sim, x, e) -> bool:
	var r : Dictionary = sim._rel(e, x)
	if r["opinion"] < -10.0 or not can_ally(sim, e, x):
		return false
	if e.main_threat >= 0 and x.threat.get(e.main_threat, 0.0) >= Threat.NOTE_LEVEL:
		return true
	return x.max_threat >= Threat.NOTE_LEVEL and r["opinion"] >= 10.0

## Protection is almost always welcome, unless the protected empire distrusts the guarantor.
static func accepts_guarantee(sim, x, e) -> bool:
	return sim._rel(e, x)["opinion"] >= -20.0 and can_ally(sim, e, x)

## New pacts and guarantees: not with an empire at war (signing would mean joining it), not between enemies, and not
## within BETRAYAL_YEARS of one abandoning the other.
static func can_ally(sim, a, b) -> bool:
	if in_any_war(sim, a) or in_any_war(sim, b):
		return false
	return sim.tick_count / 12 >= sim._rel(a, b).get("betrayed_until", 0)

static func in_any_war(sim, x) -> bool:
	return sim.wars.any(func(w): return w["a"] == x or w["b"] == x)

static func _at_war(sim, a, b) -> bool:
	return sim.wars.any(func(w): return (w["a"] == a and w["b"] == b) or (w["a"] == b and w["b"] == a))

# ---------------------------------------------------------------- Call to arms
## defender has been attacked by attacker: each pact partner and guarantor decides whether to join.
static func call_to_arms(sim, attacker, defender, war : Dictionary) -> void:
	for y in defenders_of(sim, defender):
		if y == attacker or _at_war(sim, y, attacker) or has_pact(sim, y, attacker):
			continue
		var pact : bool = has_pact(sim, y, defender)
		var chance : float
		if pact:
			chance = 0.6 + 0.4 * (1.0 - Personality.t(y, "caution"))
		else:
			chance = 0.3 + 0.6 * Personality.t(y, "intervention")
		if y.exhaustion > JOIN_EXHAUSTION:
			chance *= 0.3
		if randf() < chance:
			sim._event("%s honours its %s and joins %s against %s" % [y.name, "pact" if pact else "guarantee", defender.name, attacker.name])
			Military.declare(sim, y, attacker, war)
		else:
			var r : Dictionary = sim._rel(y, defender)
			r["opinion"] = maxf(-100.0, r["opinion"] - BETRAYAL_OPINION)
			r["betrayed_until"] = sim.tick_count / 12 + BETRAYAL_YEARS
			if pact:
				r["pact"] = false
			else:
				y.guarantees.erase(defender.id)
			sim._event("%s abandons %s to %s (its %s is void)" % [y.name, defender.name, attacker.name, "pact" if pact else "guarantee"])

# ---------------------------------------------------------------- Yearly upkeep
## Pacts lapse when the shared fear is gone (after PACT_MIN_YEARS) or opinion collapses; guarantees end when the
## protected empire is no longer small, or the guarantor no longer fears its neighbour.
static func yearly(sim) -> void:
	var year : int = sim.tick_count / 12
	for i in sim.empires.size():
		for j in range(i + 1, sim.empires.size()):
			var a = sim.empires[i]; var b = sim.empires[j]
			var r : Dictionary = sim._rel(a, b)
			if not r.get("pact", false):
				continue
			var calm : bool = a.max_threat < LAPSE_THREAT and b.max_threat < LAPSE_THREAT
			if (calm and year - r.get("pact_year", 0) >= PACT_MIN_YEARS) or r["opinion"] < -30.0:
				r["pact"] = false
				sim._event("The pact between %s and %s lapses" % [a.name, b.name])
	for g in sim.empires:
		for xid in g.guarantees.duplicate():
			var x = sim.empires[xid]
			if x.strength > g.strength * 0.8 or g.max_threat < LAPSE_THREAT:
				g.guarantees.erase(xid)
				sim._event("%s ends its guarantee of %s" % [g.name, x.name])
