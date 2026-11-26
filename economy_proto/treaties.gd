class_name Treaties
extends RefCounted
## War goals, war score, negotiated peace terms, and revanchism.
##
## - An attacker states its war goals when it declares (they cost reputation in proportion to their value), or tries an
##   ultimatum first (one demand: concede it or it's war). Aggressive, reckless empires strike first instead: no warning,
##   a short first-strike edge, and a heavier reputation cost.
## - The war score (-100..100 for side a) sums occupations, the strength balance and the exhaustion gap.
## - Peace is negotiated: the side ahead demands terms worth up to its war score, scaled up by its aggression (greed);
##   the other side accepts, counter-offers by dropping the costliest terms, or fights on. A capitulating empire takes
##   whatever is demanded.
## - Terms: cede systems, reparations, open market, transit rights, demilitarisation, humiliation.
## - Terms taken beyond what the war score justified are greed: they feed the loser's revanchism and cost the winner
##   reputation. Revanchists claim their lost systems, strike when the victor is distracted, seek its enemies as allies,
##   repudiate imposed terms when they can, radicalise while paying, and slowly forget.

# Term values, in war-score points
const VALUE_SYSTEM := 10.0             # + population / 40, capped below
const VALUE_SYSTEM_MAX := 30.0
const VALUE_REPARATIONS := 20.0
const VALUE_OPEN_MARKET := 6.0
const VALUE_TRANSIT := 4.0
const VALUE_DEMILITARIZE := 15.0
const VALUE_HUMILIATE := 5.0
const UNOCCUPIED_MARKUP := 1.5         # demanding a system you don't hold costs more score
# Term parameters
const REPARATIONS_SHARE := 0.25        # of the payer's smoothed monthly tax
const REPARATIONS_YEARS := 10
const DEMILITARIZE_CAP := 0.5          # of the payer's own army target
const DEMILITARIZE_YEARS := 15
const FORCED_YEARS := 20               # open market / transit rights
const HUMILIATE_REP := 10.0
# Declaring
const REP_PER_GOAL_POINT := 0.15       # reputation cost of stated goals
const REP_SURPRISE := 5.0              # extra cost of a war without warning
const FIRST_STRIKE_MONTHS := 3
# Negotiation
const WHITE_PEACE_SCORE := 8.0
const LOSER_TOLERANCE := 1.2           # a loser accepts terms worth up to this x the score
# Revanchism (0..100 per grudge)
const REV_BASE := 10.0
const REV_PER_GREED := 25.0
const REV_PER_SYSTEM := 5.0
const REV_PER_PAYMENT_YEAR := 3.0
const REV_FADE := 1.5                  # per year with no imposed term still running, x (1 + mercantile)
const REV_ACT := 30.0                  # level at which the revanchist starts looking for its chance
const REV_REPUDIATE := 40.0
const REP_REPUDIATE := 10.0
const REP_PER_GREED := 15.0            # winner's reputation lost per unit of greed above 1.2

# ---------------------------------------------------------------- Values and score
static func system_pop(s, owner) -> float:
	var p : float = 0.0
	for c in s.bodies:
		if c.owner == owner: p += c.pop
	return p

static func value(sim, t : Dictionary) -> float:
	match t["kind"]:
		"cede":
			var v : float = minf(VALUE_SYSTEM + system_pop(t["system"], t["from"]) / 40.0, VALUE_SYSTEM_MAX)
			return v if t["system"].occupier == t["to"] else v * UNOCCUPIED_MARKUP
		"reparations": return VALUE_REPARATIONS
		"open_market": return VALUE_OPEN_MARKET
		"transit": return VALUE_TRANSIT
		"demilitarize": return VALUE_DEMILITARIZE
		"humiliate": return VALUE_HUMILIATE
	return 0.0

static func total(sim, terms : Array) -> float:
	var v : float = 0.0
	for t in terms: v += value(sim, t)
	return v

## War score from side's point of view, -100..100.
static func score(sim, w : Dictionary, side) -> float:
	var other = w["b"] if side == w["a"] else w["a"]
	var held : int = 0; var lost : int = 0
	for s in sim.all_systems():
		if s.owner == other and s.occupier == side: held += 1
		elif s.owner == side and s.occupier == other: lost += 1
	var st : float = 25.0 * (side.strength - other.strength) / maxf(side.strength + other.strength, 1.0)
	return clampf(12.0 * (held - lost) + st + 0.4 * (other.exhaustion - side.exhaustion), -100.0, 100.0)

# ---------------------------------------------------------------- War goals
## What an attacker wants from its target, by personality and situation.
static func choose_goals(sim, a, b) -> Array:
	var goals : Array = []
	var rev = a.revanche.get(b.id)
	var claims : Array = rev["claims"].filter(func(s): return s.owner == b) if rev != null else []
	for s in claims:
		goals.append({"kind": "cede", "system": s, "from": b, "to": a})
	var n : int = 1 + int(round(2.0 * Personality.t(a, "expansion") * Personality.t(a, "aggression")))
	var cands : Array = Military.fronts(sim, b, a).filter(func(s): return not s.bodies.has(b.capital) and not claims.has(s))
	cands.sort_custom(func(x, y): return system_pop(x, b) > system_pop(y, b) or (system_pop(x, b) == system_pop(y, b) and x.name < y.name))
	for s in cands.slice(0, maxi(0, n - claims.size())):
		goals.append({"kind": "cede", "system": s, "from": b, "to": a})
	if Personality.t(a, "mercantile") >= 0.6:
		goals.append({"kind": "open_market", "from": b, "to": a})
	if a.threat.get(b.id, 0.0) >= 1.5:
		goals.append({"kind": "demilitarize", "from": b, "to": a})
	if b.treasury > a.treasury and Personality.t(a, "aggression") >= 0.5:
		goals.append({"kind": "reparations", "from": b, "to": a})
	if Personality.t(a, "aggression") >= 0.7:
		goals.append({"kind": "humiliate", "from": b, "to": a})
	return goals

static func describe(t : Dictionary) -> String:
	match t["kind"]:
		"cede": return "%s -> %s" % [t["system"].name, t["to"].name]
		"reparations": return "reparations to %s" % t["to"].name
		"open_market": return "open market for %s" % t["to"].name
		"transit": return "transit rights for %s" % t["to"].name
		"demilitarize": return "%s demilitarises" % t["from"].name
		"humiliate": return "%s humiliated" % t["from"].name
	return t["kind"]

static func describe_all(terms : Array) -> String:
	return ", ".join(PackedStringArray(terms.map(func(t): return describe(t))))

# ---------------------------------------------------------------- Going to war
## The planner chose war on b. Reckless empires strike first; the rest try an ultimatum.
static func go_to_war(sim, a, b) -> void:
	var goals : Array = choose_goals(sim, a, b)
	if Personality.t(a, "aggression") >= 0.65 and Personality.t(a, "caution") <= 0.4:
		Alliances.adjust_reputation(sim, a, -REP_SURPRISE, "surprise attack on %s" % b.name)
		Military.declare(sim, a, b, null, goals)
		sim.wars[-1]["first_strike_until"] = sim.tick_count + FIRST_STRIKE_MONTHS
		sim._event("%s strikes %s without warning" % [a.name, b.name])
		return
	var demand : Array = goals.filter(func(t): return t["kind"] == "cede").slice(0, 1)
	if demand.is_empty():
		demand = goals.slice(0, 1)
	if demand.is_empty():
		Military.declare(sim, a, b, null, goals)
		return
	# The target yields if it expects to lose badly; proud or revanchist empires yield less.
	var ratio : float = a.strength / maxf(Alliances.effective_strength(sim, b, a), 1.0)
	var spine : float = 1.3 + 0.6 * (1.0 - Personality.t(b, "caution")) + 0.4 * Personality.t(b, "aggression")
	if ratio >= spine:
		sim._event("%s yields to %s's ultimatum: %s" % [b.name, a.name, describe_all(demand)])
		_apply(sim, demand, a, b, total(sim, demand), true)
		Alliances.adjust_reputation(sim, a, -3.0, "ultimatum to %s" % b.name)
	else:
		sim._event("%s rejects %s's ultimatum (%s)" % [b.name, a.name, describe_all(demand)])
		Military.declare(sim, a, b, null, goals)

# ---------------------------------------------------------------- Making peace
## What the side ahead demands with a war score of s: its goals first, then occupied systems and extras, up to a budget
## that grows with its aggression (greed).
static func demand(sim, w : Dictionary, winner, loser, s : float) -> Array:
	var budget : float = s * (0.8 + 0.7 * Personality.t(winner, "aggression"))
	var cands : Array = []
	if winner == w["a"]:
		cands += w.get("goals", []).filter(func(t): return t["kind"] != "cede" or t["system"].owner == loser)
	var occupied : Array = sim.all_systems().filter(func(x): return x.owner == loser and x.occupier == winner)
	occupied.sort_custom(func(x, y): return system_pop(x, loser) > system_pop(y, loser) or (system_pop(x, loser) == system_pop(y, loser) and x.name < y.name))
	for x in occupied:
		if not cands.any(func(t): return t["kind"] == "cede" and t["system"] == x):
			cands.append({"kind": "cede", "system": x, "from": loser, "to": winner})
	for k in ["reparations", "humiliate"]:
		if Personality.t(winner, "aggression") >= 0.5 and not cands.any(func(t): return t["kind"] == k):
			cands.append({"kind": k, "from": loser, "to": winner})
	var out : Array = []
	var v : float = 0.0
	for t in cands:
		var tv : float = value(sim, t)
		if v + tv <= budget:
			out.append(t); v += tv
	return out

## proposer wants peace. Returns true if peace was made.
static func negotiate(sim, w : Dictionary, proposer) -> bool:
	var sa : float = score(sim, w, w["a"])
	if absf(sa) < WHITE_PEACE_SCORE:
		var other = w["b"] if proposer == w["a"] else w["a"]
		if other.exhaustion >= 25.0 or proposer.exhaustion >= 25.0:
			sim._event("%s and %s agree to a white peace" % [proposer.name, other.name])
			Military.make_peace(sim, w, [])
			return true
		return false
	var winner = w["a"] if sa > 0.0 else w["b"]
	var loser = w["b"] if sa > 0.0 else w["a"]
	var s : float = absf(sa)
	var terms : Array = demand(sim, w, winner, loser, s)
	var v : float = total(sim, terms)
	if proposer == loser:
		# The winner names its price; the loser asked for peace, so it accepts a fair price or, if desperate, any price.
		if v <= s * LOSER_TOLERANCE or loser.exhaustion >= 60.0:
			sim._event("%s sues for peace with %s and accepts: %s" % [loser.name, winner.name, describe_all(terms) if not terms.is_empty() else "nothing"])
			_settle(sim, w, terms, winner, loser, s)
			return true
		sim._event("%s sues for peace with %s: terms too harsh (%s)" % [loser.name, winner.name, describe_all(terms)])
		return false
	# The winner offers terms; the loser accepts, or counters by dropping the costliest terms until the price is fair.
	if v <= s * LOSER_TOLERANCE or loser.exhaustion >= 50.0:
		sim._event("%s accepts %s's terms: %s" % [loser.name, winner.name, describe_all(terms) if not terms.is_empty() else "nothing"])
		_settle(sim, w, terms, winner, loser, s)
		return true
	var counter : Array = terms.duplicate()
	counter.sort_custom(func(x, y): return value(sim, x) < value(sim, y))
	while not counter.is_empty() and total(sim, counter) > s:
		counter.pop_back()
	if winner.exhaustion >= 30.0 or total(sim, counter) >= 0.6 * v:
		sim._event("%s counters %s's terms; agreed: %s" % [loser.name, winner.name, describe_all(counter) if not counter.is_empty() else "white peace"])
		_settle(sim, w, counter, winner, loser, s)
		return true
	sim._event("%s rejects %s's counter-offer; the war goes on" % [winner.name, loser.name])
	return false

## side has collapsed: the other side takes what it demands, with a larger budget.
static func capitulate(sim, w : Dictionary, side) -> void:
	var winner = w["b"] if side == w["a"] else w["a"]
	var s : float = maxf(absf(score(sim, w, winner)), 30.0) * 1.5
	var terms : Array = demand(sim, w, winner, side, s)
	sim._event("%s capitulates to %s: %s" % [side.name, winner.name, describe_all(terms) if not terms.is_empty() else "nothing"])
	_settle(sim, w, terms, winner, side, s / 1.5)

static func _settle(sim, w : Dictionary, terms : Array, winner, loser, s : float) -> void:
	var tv : float = total(sim, terms)          # valued while the occupations still stand
	Military.make_peace(sim, w, terms)
	_apply(sim, terms, winner, loser, s, false, tv)

## Carry out the terms, then the consequences of greed.
static func _apply(sim, terms : Array, winner, loser, fair : float, concession : bool, tv : float = -1.0) -> void:
	if tv < 0.0: tv = total(sim, terms)
	var year : int = sim.tick_count / 12
	var r : Dictionary = sim._rel(winner, loser)
	var ceded : Array = []
	for t in terms:
		match t["kind"]:
			"cede":
				Military.transfer_system(sim, t["system"], winner, loser)
				ceded.append(t["system"])
			"reparations":
				r["reparations"] = {"payer": loser.id, "payee": winner.id, "monthly": REPARATIONS_SHARE * loser.avg_tax, "until": year + REPARATIONS_YEARS}
			"open_market":
				r["trade_treaty"] = true; r["forced_market"] = {"payer": loser.id, "until": year + FORCED_YEARS}
			"transit":
				r["passage"] = true; r["forced_transit"] = {"payer": loser.id, "until": year + FORCED_YEARS}
			"demilitarize":
				loser.demilitarized_until = year + DEMILITARIZE_YEARS
				loser.demilitarized_by = winner.id
			"humiliate":
				Alliances.adjust_reputation(sim, loser, -HUMILIATE_REP, "humiliated by %s" % winner.name)
	winner.systems_taken += ceded.size()
	if terms.is_empty():
		return
	var greed : float = tv / maxf(fair, 1.0)
	if greed > 1.2 and not concession:
		Alliances.adjust_reputation(sim, winner, -REP_PER_GREED * (greed - 1.2), "harsh peace imposed on %s" % loser.name)
	# Revanchism
	var rev : Dictionary = loser.revanche.get(winner.id, {"level": 0.0, "claims": [], "since": year})
	rev["level"] = minf(100.0, rev["level"] + (REV_BASE * (0.5 if concession else 1.0)) + REV_PER_GREED * maxf(0.0, greed - 0.8) + REV_PER_SYSTEM * ceded.size())
	for s in ceded:
		if not rev["claims"].has(s): rev["claims"].append(s)
	rev["since"] = year
	loser.revanche[winner.id] = rev
	if loser.exhaustion >= 80.0 and Personality.t(loser, "caution") > 0.4:
		Personality._shift(sim, loser, "aggression", -0.15, "a crushing defeat")     # broken rather than bitter
		Personality._shift(sim, loser, "caution", 0.1)
		rev["level"] *= 0.5
	elif rev["level"] >= REV_ACT:
		Personality._shift(sim, loser, "aggression", 0.05 + rev["level"] / 1000.0, "revanchism against %s" % winner.name)
		Personality._shift(sim, loser, "militarism", 0.05, "")
	sim._event("%s's grudge against %s: %d%s" % [loser.name, winner.name, rev["level"], " (claims %s)" % ", ".join(PackedStringArray(rev["claims"].map(func(x): return x.name))) if not rev["claims"].is_empty() else ""])

# ---------------------------------------------------------------- Yearly
static func yearly(sim) -> void:
	var year : int = sim.tick_count / 12
	for i in sim.empires.size():
		for j in range(i + 1, sim.empires.size()):
			var r : Dictionary = sim._rel(sim.empires[i], sim.empires[j])
			for key in ["reparations", "forced_market", "forced_transit"]:
				if r.has(key) and year >= r[key]["until"]:
					r.erase(key)
					sim._event("%s between %s and %s ends" % [key.replace("_", " ").capitalize(), sim.empires[i].name, sim.empires[j].name])
	for e in sim.empires:
		if e.demilitarized_until > 0 and year >= e.demilitarized_until:
			e.demilitarized_until = 0
		for wid in e.revanche.keys():
			var x = sim.empires[wid]
			var rev : Dictionary = e.revanche[wid]
			var r : Dictionary = sim._rel(e, x)
			var paying : bool = r.has("reparations") and r["reparations"]["payer"] == e.id
			var bound : bool = paying or (e.demilitarized_until > 0 and e.demilitarized_by == wid) or (r.has("forced_market") and r["forced_market"]["payer"] == e.id) or (r.has("forced_transit") and r["forced_transit"]["payer"] == e.id)
			if paying:                     # every payment is a reminder
				rev["level"] = minf(100.0, rev["level"] + REV_PER_PAYMENT_YEAR)
				Personality._shift(sim, e, "aggression", 0.02)
				Personality._shift(sim, e, "xenophobia", 0.01)
			# Repudiation: throw off imposed terms when the victor is distracted or weaker
			var chance : bool = Alliances.in_any_war(sim, x) or x.strength < e.strength
			if bound and rev["level"] >= REV_REPUDIATE and Personality.t(e, "aggression") >= 0.4 and chance:
				for key in ["reparations", "forced_market", "forced_transit"]:
					if r.has(key) and r[key]["payer"] == e.id:
						r.erase(key)
						if key == "forced_market": r["trade_treaty"] = false
						if key == "forced_transit": r["passage"] = false
				if e.demilitarized_by == wid: e.demilitarized_until = 0
				Alliances.adjust_reputation(sim, e, -REP_REPUDIATE, "repudiated its treaty with %s" % x.name)
				Alliances.adjust_trust(sim, x, e, -20.0)
				sim._event("%s repudiates the terms imposed by %s" % [e.name, x.name])
			if not bound:
				rev["level"] -= REV_FADE * (1.0 + Personality.t(e, "mercantile"))
			rev["claims"] = rev["claims"].filter(func(s): return s.owner == x)
			if rev["level"] <= 0.0:
				e.revanche.erase(wid)
				sim._event("%s has forgiven %s" % [e.name, x.name])

## Monthly: reparations payments.
static func monthly(sim) -> void:
	for i in sim.empires.size():
		for j in range(i + 1, sim.empires.size()):
			var r : Dictionary = sim._rel(sim.empires[i], sim.empires[j])
			if not r.has("reparations"): continue
			var rp : Dictionary = r["reparations"]
			var payer = sim.empires[rp["payer"]]; var payee = sim.empires[rp["payee"]]
			var amt : float = minf(rp["monthly"], maxf(payer.treasury, 0.0))
			payer.treasury -= amt; payee.treasury += amt

## The revanchist's chance: the victor is at war elsewhere, or no longer clearly stronger.
static func opportunity(sim, e, x) -> bool:
	var rev = e.revanche.get(x.id)
	if rev == null or rev["level"] < REV_ACT:
		return false
	var busy : bool = sim.wars.any(func(w): return (w["a"] == x or w["b"] == x) and w["a"] != e and w["b"] != e)
	var need : float = 0.8 if busy else 1.0
	return e.strength >= Alliances.effective_strength(sim, x, e) * need
