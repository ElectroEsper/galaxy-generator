class_name Diplomacy
extends RefCounted
## Goal-oriented diplomacy (a small GOAP): once a year each empire looks at its situation, picks its most pressing goal,
## plans the cheapest sequence of diplomatic actions that reaches it, and carries out the first step. The other side
## decides on proposals by its own interests. Facts are booleans keyed per partner ("trade:3", "op_ok:3", ...).

const AID_COST := 20000.0            # treasury spent on aid / a gesture of goodwill
const AID_GOODWILL := 20.0           # goodwill added to the relation (feeds opinion, decays)
const PASSAGE_FEE := 5000.0          # paid once to the empire granting passage
const OP_OK := -10.0                 # opinion at which a trade treaty can be discussed
const OP_GOOD := 10.0                # opinion at which passage can be discussed
const REFUSAL_COOLDOWN := 5          # years before re-proposing to an empire that refused
const MAX_DEPTH := 4
const STRONGER := 1.3                # strength ratio an empire wants before starting a war
const RIVAL_BORDER := 15           # a border this long with negative opinion is a rivalry worth fighting over
const HUNGER_RANGE := 180.0       # unclaimed charted systems this close to an empire's own count as free land
const HUNGER_BORDER := 3           # land-hungry empires covet a neighbour sharing at least this much border
const WAR_BORDER := 5                # border segments that make a neighbour's systems worth fighting for
const PEACE_EXHAUSTION := 50.0       # an empire this exhausted wants out
const PEACE_COOLDOWN := 2            # years between peace offers to the same enemy

# ---------------------------------------------------------------- Actions
## Each action: name, partner, cost, preconditions {fact: bool}, effects {fact: bool}.
static func _actions(sim, e, others : Array) -> Array:
	var acts : Array = []
	for x in others:
		var i : int = x.id
		acts.append({"name": "propose_trade", "x": x, "cost": 1.0,
			"pre": {"met:%d" % i: true, "op_ok:%d" % i: true, "trade:%d" % i: false, "war:%d" % i: false}, "eff": {"trade:%d" % i: true}})
		acts.append({"name": "propose_passage", "x": x, "cost": 1.5,
			"pre": {"met:%d" % i: true, "op_good:%d" % i: true, "pass:%d" % i: false, "cash": true, "war:%d" % i: false}, "eff": {"pass:%d" % i: true}})
		acts.append({"name": "send_aid", "x": x, "cost": 3.0,
			"pre": {"met:%d" % i: true, "op_ok:%d" % i: false, "reach:%d" % i: true, "cash": true}, "eff": {"op_ok:%d" % i: true}})
		acts.append({"name": "send_aid", "x": x, "cost": 3.0,
			"pre": {"met:%d" % i: true, "op_ok:%d" % i: true, "op_good:%d" % i: false, "cash": true}, "eff": {"op_good:%d" % i: true}})
		# War
		acts.append({"name": "arm", "x": x, "cost": 2.0,
			"pre": {"met:%d" % i: true, "stronger:%d" % i: false, "arming": false}, "eff": {"stronger:%d" % i: true, "arming": true}})
		acts.append({"name": "declare_war", "x": x, "cost": 4.0 + 12.0 * (1.0 - Personality.t(e, "aggression")),
			"pre": {"hostile:%d" % i: true, "stronger:%d" % i: true, "war:%d" % i: false, "tired": false}, "eff": {"war:%d" % i: true}})
		acts.append({"name": "declare_war", "x": x, "cost": 5.0 + 12.0 * (1.0 - Personality.t(e, "aggression")),     # war of conquest: no grievance needed, only want
			"pre": {"covet:%d" % i: true, "stronger:%d" % i: true, "war:%d" % i: false, "tired": false}, "eff": {"war:%d" % i: true}})
		acts.append({"name": "sue_for_peace", "x": x, "cost": 1.0,
			"pre": {"war:%d" % i: true}, "eff": {"war:%d" % i: false}})
	return acts

# ---------------------------------------------------------------- World state
static func _facts(sim, e, others : Array) -> Dictionary:
	var f : Dictionary = {"cash": e.treasury >= AID_COST * 2.0, "arming": sim.tick_count / 12 < e.arming_until, "tired": e.exhaustion >= 20.0}
	var hungry : bool = _land_hungry(sim, e)
	f["hungry"] = hungry
	for x in others:
		var r : Dictionary = sim._rel(e, x)
		var i : int = x.id
		f["covet:%d" % i] = hungry and r["met"] and r["border"] >= HUNGER_BORDER and sim.tick_count / 12 >= r.get("truce_until", 0)
		f["met:%d" % i] = r["met"]
		f["trade:%d" % i] = r["trade_treaty"]
		f["pass:%d" % i] = r["passage"]
		f["op_ok:%d" % i] = r["opinion"] >= OP_OK
		f["op_good:%d" % i] = r["opinion"] >= OP_GOOD
		f["reach:%d" % i] = r["opinion"] >= OP_OK - AID_GOODWILL * 0.8   # one gesture can bring them round
		f["hostile:%d" % i] = r["met"] and sim.tick_count / 12 >= r.get("truce_until", 0) and (r["stance"] == "hostile" or r["stance"] == "embargo" or (r["opinion"] < 0.0 and r["border"] >= RIVAL_BORDER))
		f["stronger:%d" % i] = e.strength > x.strength * Personality.attack_ratio(e)
		f["common_threat:%d" % i] = Threat.common_threat(sim, e, x)
		f["war:%d" % i] = sim.wars.any(func(w): return (w["a"] == e and w["b"] == x) or (w["a"] == x and w["b"] == e))
	return f

static func _avg_price(sim, e, g : int) -> float:
	var own : Array = sim._empire_colonies(e)
	var p : float = 0.0
	for c in own: p += c.price[g]
	return p / maxf(own.size(), 1.0)

# ---------------------------------------------------------------- Goals
## Returns [{"name", "priority", "want": {fact: bool}}], most pressing first.
static func _goals(sim, e, others : Array) -> Array:
	var goals : Array = []
	# Supply: goods we're short of, from the met empire that has them cheapest.
	for g in Goods.ALL:
		var mine : float = _avg_price(sim, e, g)
		if mine < ColonyMarket.BASE_PRICE * 1.8:
			continue
		var best = null; var bp : float = mine * 0.7
		for x in others:
			if not sim._rel(e, x)["met"]: continue
			var p : float = _avg_price(sim, x, g)
			if p < bp: bp = p; best = x
		if best != null and not sim._rel(e, best)["trade_treaty"]:
			goals.append({"name": "secure %s from %s" % [["Ore", "Metal", "Parts", "Food", "Water"][g], best.name], "priority": mine / ColonyMarket.BASE_PRICE * Personality.w(e, "mercantile"), "want": {"trade:%d" % best.id: true}})
	# Reach: a trade partner whose colonies we can't reach because a third empire's territory is in the way.
	for x in others:
		var r : Dictionary = sim._rel(e, x)
		if not r["trade_treaty"]: continue
		var z = _blocker(sim, e, x)
		if z != null:
			goals.append({"name": "reach %s through %s" % [x.name, z.name], "priority": 1.5, "want": {"pass:%d" % z.id: true}})
	# Calm: a hostile neighbour along a long border.
	for x in others:
		var r : Dictionary = sim._rel(e, x)
		if r["met"] and r["opinion"] < -25.0 and r["border"] > 0:
			goals.append({"name": "ease tension with %s" % x.name, "priority": 0.5 + r["border"] / 10.0, "want": {"op_ok:%d" % x.id: true}})
	# Commerce: open trade with anyone friendly enough.
	for x in others:
		var r : Dictionary = sim._rel(e, x)
		if r["met"] and not r["trade_treaty"] and r["opinion"] >= OP_GOOD:
			goals.append({"name": "open trade with %s" % x.name, "priority": 0.3 * Personality.w(e, "mercantile"), "want": {"trade:%d" % x.id: true}})
	# War: end a war going badly; deter a stronger hostile neighbour; seize the border from a weaker hostile one.
	for x in others:
		var r : Dictionary = sim._rel(e, x)
		var at_war : bool = sim.wars.any(func(w): return (w["a"] == e and w["b"] == x) or (w["a"] == x and w["b"] == e))
		if at_war:
			if e.exhaustion >= Personality.peace_exhaustion(e) or e.strength < x.strength * 0.8:
				goals.append({"name": "end the war with %s" % x.name, "priority": 5.0, "want": {"war:%d" % x.id: false}})
			continue
		var hostile : bool = r["met"] and (r["stance"] == "hostile" or r["stance"] == "embargo" or (r["opinion"] < 0.0 and r["border"] >= RIVAL_BORDER))
		if (hostile or e.threat.get(x.id, 0.0) >= 1.5) and x.strength > e.strength:
			goals.append({"name": "deter %s" % x.name, "priority": (1.0 + r["border"] / 10.0) * Personality.w(e, "caution"), "want": {"stronger:%d" % x.id: true}})
		if hostile and Personality.t(e, "aggression") >= 0.25 and r["border"] >= WAR_BORDER and sim.tick_count / 12 >= r.get("truce_until", 0) and e.exhaustion < 20.0:
			goals.append({"name": "seize the border with %s" % x.name, "priority": (0.8 + r["border"] / 15.0) * Personality.w(e, "aggression"), "want": {"war:%d" % x.id: true}})
	# Land hunger: nothing left to settle nearby, so take it from the weakest neighbour along a shared border.
	if _land_hungry(sim, e) and e.exhaustion < 20.0 and Personality.t(e, "aggression") >= 0.25:
		var best = null
		for x in sim.empires:
			if x == e or sim.wars.any(func(w): return w["a"] == e or w["b"] == e): continue
			var r : Dictionary = sim._rel(e, x)
			if r["met"] and r["border"] >= HUNGER_BORDER and sim.tick_count / 12 >= r.get("truce_until", 0) and (best == null or x.strength < best.strength):
				best = x
		if best != null:
			goals.append({"name": "expand into %s (no free land left)" % best.name, "priority": 0.9 * Personality.w(e, "expansion") * Personality.w(e, "aggression"), "want": {"war:%d" % best.id: true}})
	goals.sort_custom(func(a, b): return a["priority"] > b["priority"])
	return goals

## At least 5 systems, and no unclaimed star system (charted or not) within HUNGER_RANGE of any of e's systems.
static func _land_hungry(sim, e) -> bool:
	var mine : Array = sim.all_systems().filter(func(s): return s.owner == e)
	if mine.size() < 5:
		return false
	for s in sim.all_systems():
		if s.owner == null:
			for m in mine:
				if m.position.distance_to(s.position) <= HUNGER_RANGE:
					return false
	return true

## The first other empire whose territory lies between e's capital and x's capital without passage rights.
static func _blocker(sim, e, x):
	var a : Vector2 = e.capital.position
	var b : Vector2 = x.capital.position
	var n : int = int(a.distance_to(b) / sim.ROUTE_SAMPLE)
	for i in range(1, n):
		var z = sim.owner_at(a.lerp(b, float(i) / float(n)))
		if z != null and z != e and z != x and not sim.treaty(e, z, "passage"):
			return z
	return null

# ---------------------------------------------------------------- Planner
static func _satisfied(facts : Dictionary, want : Dictionary) -> bool:
	for k in want:
		if facts.get(k, false) != want[k]: return false
	return true

static func _applicable(facts : Dictionary, a : Dictionary) -> bool:
	for k in a["pre"]:
		if facts.get(k, false) != a["pre"][k]: return false
	return true

## Cheapest action sequence (uniform-cost search, depth-limited) from facts to a state satisfying want. [] if none.
static func plan(facts : Dictionary, want : Dictionary, actions : Array) -> Array:
	var frontier : Array = [[0.0, facts, []]]
	var seen : Dictionary = {}
	while not frontier.is_empty():
		frontier.sort_custom(func(p, q): return p[0] < q[0])
		var node : Array = frontier.pop_front()
		var st : Dictionary = node[1]
		if _satisfied(st, want):
			return node[2]
		if node[2].size() >= MAX_DEPTH:
			continue
		var sig : String = str(st)
		if seen.has(sig): continue
		seen[sig] = true
		for a in actions:
			if not _applicable(st, a): continue
			var nxt : Dictionary = st.duplicate()
			for k in a["eff"]: nxt[k] = a["eff"][k]
			if a["name"] == "send_aid": nxt["cash"] = st["cash"]   # assume one gesture is affordable
			frontier.append([node[0] + a["cost"], nxt, node[2] + [a]])
	return []

# ---------------------------------------------------------------- Partner decisions
## Would x sign a trade treaty with e? It weighs its opinion of e and whether e sells goods x is short of.
static func _accepts_trade(sim, x, e) -> bool:
	var r : Dictionary = sim._rel(x, e)
	var benefit : float = 0.5
	for g in Goods.ALL:
		var theirs : float = _avg_price(sim, x, g)
		if theirs >= ColonyMarket.BASE_PRICE * 1.5 and _avg_price(sim, e, g) < theirs * 0.8:
			benefit += 1.0
	return r["opinion"] / 20.0 + benefit >= 1.0

static func _accepts_passage(sim, z, e) -> bool:
	return sim._rel(z, e)["opinion"] >= OP_GOOD

# ---------------------------------------------------------------- Yearly turn
static func yearly(sim) -> void:
	Threat.yearly(sim)
	Personality.yearly(sim)
	for e in sim.empires:
		_turn(sim, e)

static func _turn(sim, e) -> void:
	var others : Array = sim.empires.filter(func(x): return x != e)
	var facts : Dictionary = _facts(sim, e, others)
	var actions : Array = _actions(sim, e, others)
	var year : int = sim.tick_count / 12
	for goal in _goals(sim, e, others):
		if _satisfied(facts, goal["want"]):
			continue
		var p : Array = plan(facts, goal["want"], actions)
		if p.is_empty():
			continue
		var a : Dictionary = p[0]
		var x = a["x"]
		var cool : int = PEACE_COOLDOWN if a["name"] == "sue_for_peace" else REFUSAL_COOLDOWN
		if e.refusals.get(x.id, -100) + cool > year and a["name"] in ["propose_trade", "propose_passage", "sue_for_peace"]:
			continue
		_execute(sim, e, x, a, goal, year)
		return                                   # one diplomatic initiative per year

static func _execute(sim, e, x, a : Dictionary, goal : Dictionary, year : int) -> void:
	var r : Dictionary = sim._rel(e, x)
	match a["name"]:
		"send_aid":
			e.treasury -= AID_COST
			x.treasury += AID_COST
			r["goodwill"] += AID_GOODWILL
			r["opinion"] = minf(100.0, r["opinion"] + AID_GOODWILL * 0.5)
			sim._event("%s sends aid to %s (goal: %s)" % [e.name, x.name, goal["name"]])
		"propose_trade":
			if _accepts_trade(sim, x, e):
				r["trade_treaty"] = true
				sim._event("%s and %s sign a trade treaty (goal: %s)" % [e.name, x.name, goal["name"]])
			else:
				e.refusals[x.id] = year
				sim._event("%s refuses a trade treaty with %s" % [x.name, e.name])
		"arm":
			e.arming_until = year + Military.ARMING_YEARS
			sim._event("%s arms (goal: %s; strength %d vs %d)" % [e.name, goal["name"], e.strength, x.strength])
		"declare_war":
			Military.declare(sim, e, x)
		"sue_for_peace":
			var w = null
			for ww in sim.wars:
				if (ww["a"] == e and ww["b"] == x) or (ww["a"] == x and ww["b"] == e): w = ww
			if w == null:
				return
			# The enemy accepts when it's tired too, losing, or holds nothing of ours worth keeping the war going for.
			var holds : int = sim.all_systems().filter(func(s): return s.owner == e and s.occupier == x).size()
			if x.exhaustion >= PEACE_EXHAUSTION * 0.6 or x.strength < e.strength or holds > 0 and x.exhaustion >= 25.0:
				sim._event("%s sues for peace with %s: accepted" % [e.name, x.name])
				Military.make_peace(sim, w)
			else:
				e.refusals[x.id] = year
				sim._event("%s sues for peace with %s: refused" % [e.name, x.name])
		"propose_passage":
			if _accepts_passage(sim, x, e):
				r["passage"] = true
				e.treasury -= PASSAGE_FEE; x.treasury += PASSAGE_FEE
				sim._event("%s grants %s free passage (goal: %s)" % [x.name, e.name, goal["name"]])
			else:
				e.refusals[x.id] = year
				sim._event("%s refuses %s passage" % [x.name, e.name])
