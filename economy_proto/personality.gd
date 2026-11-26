class_name Personality
extends RefCounted
## Empire personality: traits on a 0..1 scale that weight the diplomacy planner's goals, action costs and thresholds, and
## the military budget. Traits drift every year (a random walk damped by the empire's stability), shift with events
## (wars won or lost, trade, incidents, crowding, bankruptcy) and occasionally jump in a regime change.
## A 0.5 trait reproduces the behaviour from before personalities existed.

const TRAITS := ["aggression", "expansion", "mercantile", "xenophobia", "militarism", "caution", "intervention"]
const DRIFT := 0.03                 # yearly random walk at stability 0
const REGIME_BASE := 0.01           # yearly chance of a regime change
const REGIME_CRISIS := 0.06         # ... added when exhausted (60+) or bankrupt
const REGIME_JUMP := 0.35
const REGIME_COOLDOWN := 10        # years before another regime change can happen
const REVERT := 0.04               # yearly pull back toward the regime's own values (its identity)           # size of the shift for the traits a new regime changes

static var rng := RandomNumberGenerator.new()   # own stream: never disturbs the sim's random numbers

static func generate(e, seed_value : int) -> void:
	rng.seed = seed_value * 7919 + e.id * 104729
	for t in TRAITS:
		e.traits[t] = clampf(rng.randfn(0.5, 0.2), 0.05, 0.95)
	e.base_traits = e.traits.duplicate()
	e.stability = rng.randf_range(0.3, 0.9)

static func t(e, name : String) -> float:
	return e.traits.get(name, 0.5)

## Multiplier centred on 1.0 at trait 0.5: 0.5x at 0, 1.5x at 1.
static func w(e, name : String) -> float:
	return 0.5 + t(e, name)

## Strength ratio this empire wants before attacking: 1.0 for the most aggressive, 1.6 for the least.
static func attack_ratio(e) -> float:
	return 1.0 + 0.6 * (1.0 - t(e, "aggression"))

## Exhaustion at which it wants out of a war: 30 for the most cautious, 70 for the least.
static func peace_exhaustion(e) -> float:
	return 30.0 + 40.0 * (1.0 - t(e, "caution"))

static func label(e) -> String:
	var hi : Array = []
	for n in TRAITS:
		if t(e, n) >= 0.65: hi.append(n)
	var lo : Array = []
	for n in TRAITS:
		if t(e, n) <= 0.3: lo.append("not " + n)
	return " ".join(hi + lo) if not (hi + lo).is_empty() else "balanced"

static func _shift(sim, e, name : String, amount : float, why : String = "") -> void:
	var before : float = t(e, name)
	e.traits[name] = clampf(before + amount, 0.0, 1.0)
	if why != "" and absf(amount) >= 0.1:
		sim._event("%s grows %s %s (%s)" % [e.name, "more" if amount > 0 else "less", name, why])

# ---------------------------------------------------------------- Yearly drift
static func yearly(sim) -> void:
	for e in sim.empires:
		for n in TRAITS:
			_shift(sim, e, n, rng.randfn(0.0, DRIFT * (1.0 - e.stability)) + REVERT * (e.base_traits.get(n, 0.5) - t(e, n)))
		# Internal pressures
		if e.treasury < 0.0:
			_shift(sim, e, "caution", 0.03)
		if Diplomacy._land_hungry(sim, e):
			_shift(sim, e, "expansion", 0.02)
		# External: long-standing trade treaties breed merchants and trust
		for x in sim.empires:
			if x == e: continue
			var r : Dictionary = sim._rel(e, x)
			if r["trade_treaty"]:
				_shift(sim, e, "mercantile", 0.01)
				_shift(sim, e, "xenophobia", -0.01)
		# Regime change
		var crisis : bool = e.exhaustion >= 60.0 or e.treasury < 0.0
		if sim.tick_count / 12 >= e.regime_year + REGIME_COOLDOWN and rng.randf() < REGIME_BASE + (REGIME_CRISIS if crisis else 0.0):
			var changed : Array = []
			for n in TRAITS:
				if rng.randf() < 0.4:
					_shift(sim, e, n, rng.randf_range(-REGIME_JUMP, REGIME_JUMP))
					changed.append(n)
			e.regime_year = sim.tick_count / 12
			e.base_traits = e.traits.duplicate()   # the new regime's values become what the empire drifts back to
			e.stability = clampf(e.stability + rng.randf_range(-0.2, 0.2), 0.1, 0.95)
			sim._event("REGIME CHANGE in %s%s: now %s" % [e.name, " (crisis)" if crisis else "", label(e)])

# ---------------------------------------------------------------- Events
## A claim-jump incident: the victim distrusts foreigners a little more.
static func on_incident(sim, victim) -> void:
	_shift(sim, victim, "xenophobia", 0.05)

## Peace: winners are emboldened; a loser either turns revanchist or, if the war broke it, pacifist.
static func on_peace(sim, winner, loser, ceded : int) -> void:
	if winner == null:
		return
	_shift(sim, winner, "aggression", 0.05)
	if ceded == 0:
		return
	if loser.exhaustion >= 80.0 and t(loser, "caution") > 0.4:
		_shift(sim, loser, "aggression", -0.15, "a crushing defeat")
		_shift(sim, loser, "caution", 0.1)
	else:
		_shift(sim, loser, "aggression", 0.1 + 0.03 * ceded, "revanchism after losing %d systems" % ceded)
		_shift(sim, loser, "militarism", 0.1, "revanchism")
