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
const SMALL := 0.5                  # a guarantee protects an empire weaker than this x the threat...
const SMALL_END := 0.7              # ... and ends once it is this strong (a gap, so it doesn't flip every year)
const GUARANTEE_MIN_YEARS := 5
# Trust (per pair, one-way: how much A believes B keeps its word) and reputation (what everyone believes), 0..100
const TRUST_START := 50.0
const TRUST_BETRAYED := -40.0       # B abandoned A
const TRUST_ATTACKED := -30.0       # B attacked A
const TRUST_HONOURED := 15.0        # B answered A's call to arms
const TRUST_KEPT := 1.0             # per year a pact or guarantee between them holds
const REP_BETRAYAL := -15.0
const REP_WAR_OF_CHOICE := -5.0
const REP_HONOURED := 5.0
const REP_RECOVERY := 1.0           # per year, toward 50
const PACT_TRUST := 40.0            # needed to sign a pact (+ up to 20 for xenophobes)
const GUARANTEE_TRUST := 30.0

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
			s += ALLY_WEIGHT * y.strength * clampf(y.reputation / 50.0, 0.2, 1.5)   # a known betrayer deters less
	return s

# ---------------------------------------------------------------- Acceptance
## x accepts a pact from e if it fears someone too (ideally the same empire), doesn't dislike e, and isn't at war with it.
static func accepts_pact(sim, x, e) -> bool:
	var r : Dictionary = sim._rel(e, x)
	if r["opinion"] < -10.0 or not can_ally(sim, e, x) or reliance(sim, x, e) < PACT_TRUST + 20.0 * Personality.t(x, "xenophobia"):
		return false
	if e.main_threat >= 0 and x.threat.get(e.main_threat, 0.0) >= Threat.NOTE_LEVEL:
		return true
	return x.max_threat >= Threat.NOTE_LEVEL and r["opinion"] >= 10.0

## Protection is almost always welcome, unless the protected empire distrusts the guarantor.
static func accepts_guarantee(sim, x, e) -> bool:
	return sim._rel(e, x)["opinion"] >= -20.0 and can_ally(sim, e, x) and reliance(sim, x, e) >= GUARANTEE_TRUST

## New pacts and guarantees: not with an empire at war (signing would mean joining it).
static func can_ally(sim, a, b) -> bool:
	return not in_any_war(sim, a) and not in_any_war(sim, b)

# ---------------------------------------------------------------- Trust and reputation
## How much a trusts b (0..100).
static func trust(sim, a, b) -> float:
	return sim._rel(a, b).get("trust", {}).get(a.id, TRUST_START)

static func adjust_trust(sim, a, b, amount : float) -> void:
	var r : Dictionary = sim._rel(a, b)
	if not r.has("trust"): r["trust"] = {}
	r["trust"][a.id] = clampf(trust(sim, a, b) + amount, 0.0, 100.0)

## How far a would rely on b's promises: its own trust where they have history, blended with b's reputation.
static func reliance(sim, a, b) -> float:
	return 0.6 * trust(sim, a, b) + 0.4 * b.reputation

static func adjust_reputation(sim, e, amount : float, why : String) -> void:
	e.reputation = clampf(e.reputation + amount, 0.0, 100.0)
	if absf(amount) >= 10.0:
		sim._event("%s's reputation %s to %d (%s)" % [e.name, "rises" if amount > 0 else "falls", e.reputation, why])

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
			adjust_trust(sim, defender, y, TRUST_HONOURED)
			adjust_reputation(sim, y, REP_HONOURED, "stood by %s" % defender.name)
			Military.declare(sim, y, attacker, war)
		else:
			var r : Dictionary = sim._rel(y, defender)
			r["opinion"] = maxf(-100.0, r["opinion"] - BETRAYAL_OPINION)
			adjust_trust(sim, defender, y, TRUST_BETRAYED)
			adjust_reputation(sim, y, REP_BETRAYAL, "abandoned %s" % defender.name)
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
	for e in sim.empires:
		e.reputation += clampf(50.0 - e.reputation, -REP_RECOVERY, REP_RECOVERY)
		for xid in e.guarantees:
			adjust_trust(sim, sim.empires[xid], e, TRUST_KEPT)
	for i in sim.empires.size():
		for j in range(i + 1, sim.empires.size()):
			var a = sim.empires[i]; var b = sim.empires[j]
			var r : Dictionary = sim._rel(a, b)
			if not r.get("pact", false):
				continue
			adjust_trust(sim, a, b, TRUST_KEPT); adjust_trust(sim, b, a, TRUST_KEPT)
			var calm : bool = a.max_threat < LAPSE_THREAT and b.max_threat < LAPSE_THREAT
			if (calm and year - r.get("pact_year", 0) >= PACT_MIN_YEARS) or r["opinion"] < -30.0:
				r["pact"] = false
				sim._event("The pact between %s and %s lapses" % [a.name, b.name])
	for g in sim.empires:
		for xid in g.guarantees.keys():
			var x = sim.empires[xid]
			var info : Dictionary = g.guarantees[xid]
			if year - info["year"] < GUARANTEE_MIN_YEARS:
				continue
			var t = sim.empires[info["against"]] if info["against"] >= 0 else null
			var safe : bool = t == null or x.strength >= t.strength * SMALL_END or sim._rel(x, t)["border"] == 0
			if safe or g.threat.get(info["against"], 0.0) < LAPSE_THREAT:
				g.guarantees.erase(xid)
				sim._event("%s ends its guarantee of %s" % [g.name, x.name])
