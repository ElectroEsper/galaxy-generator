class_name Threat
extends RefCounted
## Threat assessment: every year each empire scores how dangerous every other empire it has met is to itself.
## The score feeds its army size (Military.target_strength), its "deter" goals, and the common_threat facts that
## pacts and coalitions build on. A score of 1 is roughly "an equal neighbour along a short border".

const MIN_STRENGTH := 5.0           # floor on our own strength when comparing (a disarmed empire isn't infinitely afraid)
const STRENGTH_CAP := 5.0
const WAR_MEMORY := 30              # years a war declaration counts against its author
const TRAJECTORY_YEARS := 20
const NOTE_LEVEL := 1.0             # threats at or above this are logged when they become an empire's main threat

static func yearly(sim) -> void:
	var year : int = sim.tick_count / 12
	for e in sim.empires:
		e.sys_history.append(sim.all_systems().filter(func(s): return s.owner == e).size())
	for e in sim.empires:
		var top = null
		var top_score : float = 0.0
		for x in sim.empires:
			if x == e: continue
			var sc : float = score(sim, e, x, year)
			e.threat[x.id] = sc
			if sc > top_score: top_score = sc; top = x
		var prev_top : int = e.main_threat
		e.max_threat = top_score
		e.main_threat = top.id if top != null and top_score >= NOTE_LEVEL else -1
		if e.main_threat != prev_top and e.main_threat >= 0:
			sim._event("%s now sees %s as its main threat (%.1f)" % [e.name, top.name, top_score])

## How threatening x is to e.
static func score(sim, e, x, year : int) -> float:
	var r : Dictionary = sim._rel(e, x)
	if not r["met"]:
		return 0.0
	var strength : float = minf(x.strength / maxf(e.strength, MIN_STRENGTH), STRENGTH_CAP)
	var proximity : float = (1.0 + r["border"] / 10.0) if r["border"] > 0 else 0.3
	var recent : int = x.wars_started.filter(func(y): return year - y <= WAR_MEMORY).size()
	var record : float = minf(1.0 + 0.25 * recent + 0.1 * x.systems_taken, 3.0)
	var growth : float = 0.0
	if x.sys_history.size() > TRAJECTORY_YEARS:
		var then : int = x.sys_history[x.sys_history.size() - 1 - TRAJECTORY_YEARS]
		growth = clampf(float(x.sys_history[-1] - then) / maxf(then, 1.0), 0.0, 2.0)
	var at_war : bool = sim.wars.any(func(w): return (w["a"] == e and w["b"] == x) or (w["a"] == x and w["b"] == e))
	var temper : float = 0.5 + (Personality.t(e, "caution") + Personality.t(e, "xenophobia")) * 0.5
	return 0.5 * strength * proximity * record * (1.0 + growth) * (1.5 if at_war else 1.0) * temper

## Do e and some other empire both see x as a serious threat? (the basis for pacts and coalitions)
static func common_threat(sim, e, x) -> bool:
	if e.threat.get(x.id, 0.0) < NOTE_LEVEL:
		return false
	return sim.empires.any(func(y): return y != e and y != x and y.threat.get(x.id, 0.0) >= NOTE_LEVEL and sim._rel(e, y)["met"])
